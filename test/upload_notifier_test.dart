import 'package:cixiohub_mobile/services/upload_notifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('upload completion text', () {
    test('singular', () {
      expect(UploadNotifier.titleForSuccess(1), 'Upload complete');
      expect(
        UploadNotifier.bodyForSuccess(1),
        '1 file was uploaded to the cloud.',
      );
    });

    test('plural', () {
      expect(UploadNotifier.titleForSuccess(3), 'Uploads complete');
      expect(
        UploadNotifier.bodyForSuccess(3),
        '3 files were uploaded to the cloud.',
      );
    });
  });

  group('upload failure text', () {
    test('singular without error', () {
      expect(UploadNotifier.titleForFailure(1), 'Upload failed');
      expect(
        UploadNotifier.bodyForFailure(1, null),
        '1 file could not be uploaded. It will retry automatically.',
      );
    });

    test('plural includes the first line of the error', () {
      final body = UploadNotifier.bodyForFailure(
        2,
        'S3 upload failed: AccessDenied\nmore detail',
      );
      expect(UploadNotifier.titleForFailure(2), 'Uploads failed');
      expect(body, contains('2 files could not be uploaded.'));
      expect(body, contains('S3 upload failed: AccessDenied'));
      expect(body, isNot(contains('more detail')));
    });

    test('truncates very long error lines', () {
      final body = UploadNotifier.bodyForFailure(1, 'x' * 300);
      expect(body, contains('...'));
      expect(body.length, lessThan(220));
    });
  });

  test('zero count posts nothing', () {
    expect(UploadNotifier.uploadCompleted(count: 0), completes);
    expect(UploadNotifier.uploadFailed(count: 0), completes);
  });
}
