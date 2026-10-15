import 'dart:convert';
import 'dart:io';

import 'package:cixiohub_mobile/services/presign_upload_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Directory tempDir;

  /// Records the presign actions the backend received, in order.
  late List<String> actions;

  /// Bytes received per uploaded part number.
  late Map<int, int> partSizes;

  /// The `parts` payload sent to the complete call.
  late List<dynamic>? completedParts;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    actions = [];
    partSizes = {};
    completedParts = null;
    tempDir = Directory.systemTemp.createTempSync('presign_test');

    server.listen((request) async {
      final path = request.uri.path;
      if (path == '/presign') {
        final payload = jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>;
        final action = payload['action'] as String? ?? 'SINGLE';
        actions.add(action);
        request.response.headers.contentType = ContentType.json;

        if (action == 'MULTIPART_INITIATE') {
          final total = payload['totalParts'] as int;
          request.response.write(jsonEncode({
            'mode': 'MULTIPART',
            'uploadId': 'upload-1',
            'objectKey': 'testing/user1/file.bin',
            'parts': [
              for (var i = 1; i <= total; i++)
                {
                  'partNumber': i,
                  'url': 'http://127.0.0.1:${server.port}/part/$i',
                },
            ],
          }));
        } else if (action == 'MULTIPART_COMPLETE') {
          completedParts = payload['parts'] as List<dynamic>?;
          request.response
              .write(jsonEncode({'message': 'Multipart upload completed'}));
        } else {
          request.response.write(jsonEncode({
            'mode': 'SINGLE',
            'presignedUrl': 'http://127.0.0.1:${server.port}/object',
            'objectKey': 'testing/user1/file.bin',
          }));
        }
      } else if (path.startsWith('/part/')) {
        final partNumber = int.parse(request.uri.pathSegments.last);
        var size = 0;
        await for (final chunk in request) {
          size += chunk.length;
        }
        partSizes[partNumber] = size;
        request.response.statusCode = 200;
        request.response.headers.set('ETag', '"etag-$partNumber"');
      } else {
        await request.drain<void>();
        request.response.statusCode = 200;
        request.response.headers.set('ETag', '"single-etag"');
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    tempDir.deleteSync(recursive: true);
  });

  PresignUploadService service(
      {int threshold = 0, int partSize = 5 * 1024 * 1024}) {
    return PresignUploadService(
      endpoint: 'http://127.0.0.1:${server.port}/presign',
      multipartThreshold: threshold,
      partSize: partSize,
    );
  }

  File writeFile(int bytes) {
    final file = File('${tempDir.path}/file.bin')
      ..writeAsBytesSync(List<int>.filled(bytes, 0));
    return file;
  }

  test('large file uploads via multipart and completes', () async {
    const minPart = 5 * 1024 * 1024;
    final file = writeFile(6 * 1024 * 1024);

    final key = await service().upload(
      file: file,
      fileName: 'file.bin',
      contentType: 'application/octet-stream',
    );

    expect(key, 'testing/user1/file.bin');
    expect(actions, ['MULTIPART_INITIATE', 'MULTIPART_COMPLETE']);
    expect(partSizes, {1: minPart, 2: 1024 * 1024});
    expect(completedParts, [
      {'PartNumber': 1, 'ETag': '"etag-1"'},
      {'PartNumber': 2, 'ETag': '"etag-2"'},
    ]);
  });

  test('file at or below threshold uses a single PUT', () async {
    final file = writeFile(1024);

    final key = await service(threshold: 10 * 1024 * 1024).upload(
      file: file,
      fileName: 'file.bin',
      contentType: 'application/octet-stream',
    );

    expect(key, 'testing/user1/file.bin');
    expect(actions, ['SINGLE']);
    expect(partSizes, isEmpty);
  });

  test('presign failure surfaces the backend error', () async {
    final failing = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    failing.listen((request) async {
      await request.drain<void>();
      request.response
        ..statusCode = 403
        ..write(
            '<Error><Code>AccessDenied</Code><Message>Nope</Message></Error>');
      await request.response.close();
    });
    addTearDown(() => failing.close(force: true));

    final file = writeFile(1024);
    final failingService = PresignUploadService(
      endpoint: 'http://127.0.0.1:${failing.port}/presign',
      multipartThreshold: 10 * 1024 * 1024,
    );

    expect(
      () => failingService.upload(
        file: file,
        fileName: 'file.bin',
        contentType: 'application/octet-stream',
      ),
      throwsA(
        isA<PresignUploadException>()
            .having((e) => e.statusCode, 'statusCode', 403)
            .having((e) => e.message, 'message', contains('Nope')),
      ),
    );
  });
}
