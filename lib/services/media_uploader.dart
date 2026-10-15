import 'dart:io';

import '../config/app_config.dart';
import '../models/media_item.dart';
import 'media_store.dart';
import 'presign_upload_service.dart';

/// Uploads queued media **through the presign Lambda**: it fetches a presigned
/// PUT URL from [AppConfig.awsUploadUrl] and uploads straight to S3, so no AWS
/// credentials are needed in the app.
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
    if (!AppConfig.hasUploadUrl) {
      await _fail(
        item,
        'Upload not configured. Provide AWS_UPLOAD_URL (the presign Lambda '
        'Function URL).',
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
      final service = PresignUploadService(endpoint: AppConfig.awsUploadUrl);
      final key = await service.upload(
        file: file,
        fileName: item.fileName,
        contentType: item.mimeType,
      );
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
