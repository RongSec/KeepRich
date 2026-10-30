// FCM 占位配置文件
//
// 启用步骤：
// 1. 在 https://console.firebase.google.com 创建项目，添加 Android 应用
// 2. 下载 google-services.json 放到 android/app/google-services.json
// 3. 在 pubspec.yaml 添加依赖：
//      firebase_core: ^2.27.0
//      firebase_messaging: ^14.7.19
// 4. 取消本文件中的 FirebaseOptions 引用并填写真实值
// 5. 后端实现：参见 backend/internal/services/fcm.go
//
// 在依赖未安装前，本文件为纯占位，不会引起编译错误。

class PushConfig {
  // Android
  static const String androidApiKey = 'REPLACE_ME_ANDROID_API_KEY';
  static const String androidAppId = 'REPLACE_ME_ANDROID_APP_ID';
  static const String senderId = 'REPLACE_ME_SENDER_ID';
  static const String projectId = 'REPLACE_ME_PROJECT_ID';
  static const String storageBucket = 'REPLACE_ME.appspot.com';
  // iOS
  static const String iosApiKey = 'REPLACE_ME_IOS_API_KEY';
  static const String iosAppId = 'REPLACE_ME_IOS_APP_ID';
  static const String iosBundleId = 'com.yourname.familyFinanceApp';
  // Web
  static const String webApiKey = 'REPLACE_ME_WEB_API_KEY';
  static const String webAppId = 'REPLACE_ME_WEB_APP_ID';

  static bool get isConfigured =>
      !androidApiKey.startsWith('REPLACE_ME') &&
      !androidAppId.startsWith('REPLACE_ME');
}
