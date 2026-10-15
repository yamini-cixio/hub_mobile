import 'dart:convert';
import 'dart:io';

/// Raised when obtaining a presigned URL or uploading to it fails.
class PresignUploadException implements Exception {
  final String message;
  final int? statusCode;

  const PresignUploadException(this.message, {this.statusCode});

  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

/// A single presigned part of a multipart upload.
typedef MultipartPart = ({int partNumber, String url});

/// The backend's handling of an upload request.
typedef _PresignPlan = ({
  String mode,
  String? uploadId,
  String? key,
  String? singleUrl,
  List<MultipartPart> parts,
});

/// Uploads a file to S3 through a backend that issues **presigned URLs**.
///
/// The app never holds AWS credentials: it asks the backend (an AWS Lambda
/// Function URL) for short-lived presigned URLs, then PUTs the file bytes
/// straight to S3. Has no Flutter UI dependencies, so it also runs from the
/// background sync isolate.
///
/// Small files use a single presigned PUT. Files larger than
/// [multipartThreshold] are uploaded with S3 **multipart upload**: the backend
/// hands back one presigned URL per part, each part is PUT independently, and
/// the upload is finalised with a complete call.
class PresignUploadService {
  PresignUploadService({
    required this.endpoint,
    this.multipartThreshold = defaultMultipartThreshold,
    this.partSize = defaultPartSize,
  });

  /// Lambda Function URL that returns presigned URLs for the given file.
  final String endpoint;

  /// Files strictly larger than this many bytes use multipart upload.
  final int multipartThreshold;

  /// Target size of each multipart part. S3 requires every part except the
  /// last to be at least [_minPartSize] bytes.
  final int partSize;

  /// Default cutoff above which multipart upload is used (100 MiB).
  static const int defaultMultipartThreshold = 100 * 1024 * 1024;

  /// Default target part size (10 MiB).
  static const int defaultPartSize = 10 * 1024 * 1024;

  /// S3 minimum size for every part except the last (5 MiB).
  static const int _minPartSize = 5 * 1024 * 1024;

  /// S3 maximum number of parts in a single multipart upload.
  static const int _maxParts = 10000;

  /// Requests presigned URL(s) for [fileName] and uploads [file].
  ///
  /// Returns the object key stored in S3.
  Future<String> upload({
    required File file,
    required String fileName,
    required String contentType,
  }) async {
    final length = await file.length();
    if (length == 0) {
      throw const PresignUploadException('Refusing to upload an empty file.');
    }

    if (length <= multipartThreshold) {
      return _uploadSingle(
        file: file,
        fileName: fileName,
        contentType: contentType,
        length: length,
      );
    }

    return _uploadMultipart(
      file: file,
      fileName: fileName,
      contentType: contentType,
      length: length,
    );
  }

  // ── Single-part path ──

  /// Asks the backend for one presigned PUT URL and uploads the whole file.
  Future<String> _uploadSingle({
    required File file,
    required String fileName,
    required String contentType,
    required int length,
  }) async {
    final plan = await _requestPresign({
      'fileName': fileName,
      if (contentType.isNotEmpty) 'mimeType': contentType,
    });
    final url = plan.singleUrl;
    if (url == null || url.isEmpty) {
      throw const PresignUploadException(
        'Presign response did not include an upload URL.',
      );
    }
    await _put(
      stream: file.openRead(),
      url: url,
      contentType: contentType,
      length: length,
    );
    return plan.key ?? _keyFromUrl(url);
  }

  // ── Multipart path ──

  /// Uploads [file] in parts and finalises the S3 multipart upload.
  Future<String> _uploadMultipart({
    required File file,
    required String fileName,
    required String contentType,
    required int length,
  }) async {
    final size = _computePartSize(length);
    final totalParts = (length + size - 1) ~/ size;

    final plan = await _requestPresign({
      'action': 'MULTIPART_INITIATE',
      'fileName': fileName,
      if (contentType.isNotEmpty) 'mimeType': contentType,
      'size': length,
      'totalParts': totalParts,
    });

    // The backend may still answer with a single URL (e.g. a lower limit);
    // honour it rather than failing the upload.
    if (plan.mode != 'MULTIPART' || plan.parts.isEmpty) {
      final url = plan.singleUrl ?? plan.parts.firstOrNull?.url;
      if (url == null || url.isEmpty) {
        throw const PresignUploadException(
          'Multipart initiate response did not include any part URLs.',
        );
      }
      await _put(
        stream: file.openRead(),
        url: url,
        contentType: contentType,
        length: length,
      );
      return plan.key ?? _keyFromUrl(url);
    }

    final uploadId = plan.uploadId;
    final key = plan.key;
    if (uploadId == null || uploadId.isEmpty || key == null || key.isEmpty) {
      throw const PresignUploadException(
        'Multipart initiate response was missing uploadId/objectKey.',
      );
    }

    final parts = List<MultipartPart>.of(plan.parts)
      ..sort((a, b) => a.partNumber.compareTo(b.partNumber));

    final completed = <Map<String, Object>>[];
    for (final part in parts) {
      final start = (part.partNumber - 1) * size;
      final end = start + size > length ? length : start + size;
      final etag = await _put(
        stream: file.openRead(start, end),
        url: part.url,
        contentType: contentType,
        length: end - start,
      );
      // S3's complete call expects `PartNumber`/`ETag` (case-sensitive).
      completed.add({'PartNumber': part.partNumber, 'ETag': etag});
    }

    await _requestPresign({
      'action': 'MULTIPART_COMPLETE',
      'uploadId': uploadId,
      'objectKey': key,
      'parts': completed,
    });
    return key;
  }

  /// Picks a part size that stays within S3's part-count limit and never drops
  /// below the 5 MiB minimum.
  int _computePartSize(int length) {
    var size = partSize < _minPartSize ? _minPartSize : partSize;
    final minForMaxParts = (length + _maxParts - 1) ~/ _maxParts;
    if (minForMaxParts > size) size = minForMaxParts;
    return size;
  }

  /// Calls the backend and parses its upload plan (single URL or multipart).
  ///
  /// Contract (the presign Lambda Function URL):
  ///   Single:
  ///     POST {endpoint}
  ///     {"fileName": "<name>", "mimeType": "<mime>"}
  ///     -> 200 {"mode": "SINGLE", "presignedUrl": "<url>", "objectKey": "<key>"}
  ///   Multipart initiate:
  ///     POST {endpoint}
  ///     {"action": "MULTIPART_INITIATE", "fileName": "...", "mimeType": "...",
  ///      "size": <bytes>, "totalParts": <n>}
  ///     -> 200 {"mode": "MULTIPART", "uploadId": "...", "objectKey": "...",
  ///             "parts": [{"partNumber": 1, "url": "..."}, ...]}
  ///   Multipart complete:
  ///     POST {endpoint}
  ///     {"action": "MULTIPART_COMPLETE", "uploadId": "...",
  ///      "objectKey": "...", "parts": [{"PartNumber": 1, "ETag": "..."}, ...]}
  Future<_PresignPlan> _requestPresign(Map<String, Object?> payload) async {
    final uri = Uri.parse(endpoint);
    final payloadBytes = utf8.encode(jsonEncode(payload));

    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      request.headers.contentType = ContentType.json;
      request.contentLength = payloadBytes.length;
      request.add(payloadBytes);
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PresignUploadException(
          'Presign request failed'
          '${body.isEmpty ? '' : ': ${_extractError(body)}'}',
          statusCode: response.statusCode,
        );
      }

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        throw const PresignUploadException(
          'Presign response was not valid JSON.',
        );
      }

      return _parsePlan(json);
    } finally {
      client.close(force: true);
    }
  }

  static _PresignPlan _parsePlan(Map<String, dynamic> json) {
    final mode = (json['mode'] as String?)?.toUpperCase() ?? 'SINGLE';

    final singleUrl = _firstString(
      json,
      const ['url', 'uploadUrl', 'uploadURL', 'presignedUrl'],
    );

    final rawParts = json['parts'];
    final parts = <MultipartPart>[];
    if (rawParts is List) {
      for (final entry in rawParts) {
        if (entry is! Map) continue;
        final partNumber =
            _firstInt(entry, const ['partNumber', 'PartNumber', 'number']);
        final url =
            _firstString(entry, const ['url', 'uploadUrl', 'presignedUrl']);
        if (partNumber != null && url != null) {
          parts.add((partNumber: partNumber, url: url));
        }
      }
    }

    final key = _firstString(
          json,
          const ['key', 'Key', 'objectKey', 'fileName'],
        ) ??
        (singleUrl != null ? _keyFromUrl(singleUrl) : null);

    return (
      mode: mode,
      uploadId: _firstString(json, const ['uploadId', 'UploadId']),
      key: key,
      singleUrl: singleUrl,
      parts: parts,
    );
  }

  /// PUTs bytes to a presigned URL and returns the response `ETag` (empty for
  /// single uploads, which have no per-part ETag to report).
  Future<String> _put({
    required Stream<List<int>> stream,
    required String url,
    required String contentType,
    required int length,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.putUrl(Uri.parse(url));
      if (contentType.isNotEmpty) {
        request.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      request.contentLength = length;
      await request.addStream(stream);

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PresignUploadException(
          'S3 upload failed${body.isEmpty ? '' : ': ${_extractError(body)}'}',
          statusCode: response.statusCode,
        );
      }
      return response.headers.value(HttpHeaders.etagHeader) ?? '';
    } finally {
      client.close(force: true);
    }
  }

  static String? _firstString(Map json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return null;
  }

  static int? _firstInt(Map json, List<String> keys) {
    for (final key in keys) {
      final value = json[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return null;
  }

  /// Derives the object key from a presigned URL's path (used when the backend
  /// does not return it explicitly).
  static String _keyFromUrl(String url) {
    final path = Uri.parse(url).path;
    return Uri.decodeComponent(path.startsWith('/') ? path.substring(1) : path);
  }

  /// Pulls the human-readable reason out of an XML or JSON error response.
  static String _extractError(String body) {
    final msg = RegExp(r'<Message>([^<]+)</Message>', caseSensitive: false)
        .firstMatch(body);
    if (msg != null) return msg.group(1)!;
    final code =
        RegExp(r'<Code>([^<]+)</Code>', caseSensitive: false).firstMatch(body);
    if (code != null) return code.group(1)!;
    final jsonMsg = RegExp(r'"message"\s*:\s*"([^"]+)"').firstMatch(body);
    return jsonMsg?.group(1) ?? body;
  }
}
