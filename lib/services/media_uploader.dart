import 'dart:io';

import '../config/app_config.dart';
import '../models/media_item.dart';
import 'media_store.dart';
import 's3_upload_service.dart';

/// Uploads queued media **directly to S3** using on-device SigV4 signing with
/// the build-time AWS credentials in [AppConfig].
///
/// Deliberately free of Flutter UI dependencies so it can run in the
/// background sync isolate as well as the main app.
class MediaUploader {
  MediaUploader(this.store);

  final MediaStore store;

  /// Uploads everything still pending. Returns the number uploaded.
  Future<int> syncPending({void Function()? onChanged}) async {
    var uploaded = 0;
    for (final item in List<MediaItem>.of(store.items)) {
      if (!item.needsUpload) continue;
      if (await uploadOne(item)) uploaded++;
      onChanged?.call();
    }
    return uploaded;
  }

  /// Uploads a single queued item to S3. Returns `true` on success.
  Future<bool> uploadOne(MediaItem item) async {
    if (!AppConfig.hasS3Upload) {
      await _fail(
        item,
        'S3 upload not configured. Provide AWS_S3_BUCKET plus '
        'AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.',
      );
      return false;
    }

    final file = File(item.localPath);
    if (!await file.exists()) {
      await _fail(item, 'Local file missing.');
      return false;
    }

    await store.upsert(item.copyWith(status: UploadStatus.uploading));

    try {
      final key = '${AppConfig.s3Prefix}/${item.fileName}';
      final s3 = S3UploadService(
        bucket: AppConfig.s3Bucket,
        region: AppConfig.s3Region,
        accessKeyId: AppConfig.awsAccessKeyId,
        secretAccessKey: AppConfig.awsSecretAccessKey,
        sessionToken: AppConfig.awsSessionToken,
      );
      await s3.upload(file: file, key: key, contentType: item.mimeType);
      await store.upsert(item.copyWith(
        status: UploadStatus.uploaded,
        attempts: item.attempts + 1,
        s3Key: key,
        clearError: true,
      ));
      return true;
    } catch (e) {
      await _fail(item, e.toString());
      return false;
    }
  }

  Future<void> _fail(MediaItem item, String message) => store.upsert(
        item.copyWith(
          status: UploadStatus.failed,
          attempts: item.attempts + 1,
          lastError: message,
        ),
      );
}
