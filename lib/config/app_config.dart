class AppConfig {
  /// Backend API base URL.
  /// iOS Simulator shares the Mac's network stack → localhost works.
  /// Android Emulator: use http://10.0.2.2:8090
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://localhost:8090',
  );

  static const String notifyBaseUrl = String.fromEnvironment(
    'NOTIFY_BASE_URL',
    defaultValue: 'http://localhost:8001',
  );

  // ── AWS SNS (SMS) ──
  // Injected with --dart-define so credentials never live in source control:
  //   flutter run --dart-define=AWS_ACCESS_KEY_ID=... \
  //               --dart-define=AWS_SECRET_ACCESS_KEY=... \
  //               --dart-define=AWS_SNS_SMS_REGION=ap-south-1
  static const String awsAccessKeyId =
      String.fromEnvironment('AWS_ACCESS_KEY_ID');

  static const String awsSecretAccessKey =
      String.fromEnvironment('AWS_SECRET_ACCESS_KEY');

  static const String awsSessionToken =
      String.fromEnvironment('AWS_SESSION_TOKEN');

  static const String awsSnsRegion =
      String.fromEnvironment('AWS_SNS_SMS_REGION', defaultValue: 'ap-south-1');

  /// True when SNS credentials were supplied at build time.
  static bool get hasAwsCredentials =>
      awsAccessKeyId.isNotEmpty && awsSecretAccessKey.isNotEmpty;

  // ── Direct S3 upload ──
  // The app signs requests on-device (AWS SigV4) and PUTs files straight to the
  // bucket. No Lambda / API Gateway is involved.
  //   flutter run --dart-define=AWS_S3_BUCKET=my-bucket \
  //               --dart-define=AWS_S3_REGION=ap-south-1 \
  //               --dart-define=AWS_S3_PREFIX=testing/user1
  static const String s3Bucket = String.fromEnvironment('AWS_S3_BUCKET');

  static const String s3Region =
      String.fromEnvironment('AWS_S3_REGION', defaultValue: 'ap-south-1');

  static const String s3Prefix =
      String.fromEnvironment('AWS_S3_PREFIX', defaultValue: 'testing/user1');

  /// True when the app has everything needed to upload directly to S3.
  static bool get hasS3Upload =>
      s3Bucket.isNotEmpty && hasAwsCredentials;

  static const String apiVersion = '/api/v1';
  static String get apiUrl => '$apiBaseUrl$apiVersion';
  static String get notifyUrl => '$notifyBaseUrl$apiVersion';
}
