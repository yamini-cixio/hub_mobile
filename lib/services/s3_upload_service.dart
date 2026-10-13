import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Raised when a direct-to-S3 upload fails.
class S3UploadException implements Exception {
  final String message;
  final int? statusCode;

  const S3UploadException(this.message, {this.statusCode});

  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

/// Uploads a file **directly to Amazon S3** from the device.
///
/// No Lambda / API Gateway is involved: the app signs the request on-device
/// with AWS SigV4 and PUTs the bytes straight to the bucket using
/// `UNSIGNED-PAYLOAD` (valid for S3 over HTTPS), so large files are streamed
/// without being buffered or hashed twice.
class S3UploadService {
  S3UploadService({
    required this.bucket,
    required this.region,
    required this.accessKeyId,
    required this.secretAccessKey,
    this.sessionToken,
  });

  final String bucket;
  final String region;
  final String accessKeyId;
  final String secretAccessKey;
  final String? sessionToken;

  static const _service = 's3';
  static const _payloadHash = 'UNSIGNED-PAYLOAD';

  String? get _token =>
      (sessionToken != null && sessionToken!.isNotEmpty) ? sessionToken : null;

  /// PUTs [file] to `s3://[bucket]/[key]` with the given [contentType].
  ///
  /// Returns the object key on success.
  Future<String> upload({
    required File file,
    required String key,
    required String contentType,
  }) async {
    final length = await file.length();
    if (length == 0) {
      throw const S3UploadException('Refusing to upload an empty file.');
    }

    final canonicalUri = '/${_encodeKey(key)}';
    final host = '$bucket.s3.$region.amazonaws.com';
    final endpoint = Uri.parse('https://$host$canonicalUri');

    final now = DateTime.now().toUtc();
    final amzDate = _amzDate(now);
    final dateStamp = amzDate.substring(0, 8);

    final canonicalHeaders = <String, String>{
      'host': host,
      'x-amz-content-sha256': _payloadHash,
      'x-amz-date': amzDate,
      if (_token != null) 'x-amz-security-token': _token!,
    };
    final signedHeaders = (canonicalHeaders.keys.toList()..sort()).join(';');
    final canonicalHeaderBlock =
        canonicalHeaders.entries.map((e) => '${e.key}:${e.value}\n').join();

    final canonicalRequest = [
      'PUT',
      canonicalUri,
      '',
      canonicalHeaderBlock,
      signedHeaders,
      _payloadHash,
    ].join('\n');

    final credentialScope = '$dateStamp/$region/$_service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      credentialScope,
      _sha256Hex(canonicalRequest),
    ].join('\n');

    final signature = _hmacHex(_signingKey(dateStamp), stringToSign);

    final client = HttpClient();
    try {
      final request = await client.openUrl('PUT', endpoint);
      request.headers.set('Content-Type', contentType);
      request.headers.set('x-amz-content-sha256', _payloadHash);
      request.headers.set('X-Amz-Date', amzDate);
      if (_token != null) {
        request.headers.set('X-Amz-Security-Token', _token!);
      }
      request.headers.set(
        'Authorization',
        'AWS4-HMAC-SHA256 '
            'Credential=$accessKeyId/$credentialScope, '
            'SignedHeaders=$signedHeaders, Signature=$signature',
      );
      request.contentLength = length;
      await request.addStream(file.openRead());

      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw S3UploadException(
          'S3 upload failed${body.isEmpty ? '' : ': ${_extractError(body)}'}',
          statusCode: response.statusCode,
        );
      }
      return key;
    } finally {
      client.close(force: true);
    }
  }

  /// RFC 3986 path encoding that preserves `/` separators.
  String _encodeKey(String key) =>
      key.split('/').map(Uri.encodeComponent).join('/');

  List<int> _signingKey(String dateStamp) {
    final kDate = _hmac(utf8.encode('AWS4$secretAccessKey'), dateStamp);
    final kRegion = _hmac(kDate, region);
    final kService = _hmac(kRegion, _service);
    return _hmac(kService, 'aws4_request');
  }

  List<int> _hmac(List<int> key, String data) =>
      Hmac(sha256, key).convert(utf8.encode(data)).bytes;

  String _hmacHex(List<int> key, String data) => _hex(_hmac(key, data));

  String _sha256Hex(String data) => sha256.convert(utf8.encode(data)).toString();

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String _amzDate(DateTime utc) =>
      '${utc.year.toString().padLeft(4, '0')}'
      '${utc.month.toString().padLeft(2, '0')}'
      '${utc.day.toString().padLeft(2, '0')}T'
      '${utc.hour.toString().padLeft(2, '0')}'
      '${utc.minute.toString().padLeft(2, '0')}'
      '${utc.second.toString().padLeft(2, '0')}Z';

  /// Pulls the human-readable reason out of an S3 XML error response.
  String _extractError(String xml) {
    final msg = RegExp(r'<Message>([^<]+)</Message>', caseSensitive: false)
        .firstMatch(xml);
    if (msg != null) return msg.group(1)!;
    final code = RegExp(r'<Code>([^<]+)</Code>', caseSensitive: false)
        .firstMatch(xml);
    return code == null ? xml : code.group(1)!;
  }
}
