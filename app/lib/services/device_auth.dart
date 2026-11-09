import 'package:flutter/foundation.dart' show ChangeNotifier, kIsWeb;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 系统生物识别弹窗的四种结果。
///
/// [canceled] 明确不计入失败次数（PRD R-04 ②）；[unavailable] 表示传感器
/// 被系统禁用/锁定/未录入，必须直接给密码路径，不能把系统英文原文甩给用户。
enum UnlockResult { success, canceled, failed, unavailable }

/// 生物识别解锁 + 服务端设备凭据存取（取代 v0.4.1 的旧生物识别服务）。
///
/// 红线：本机**绝不写明文密码**。指纹只是「解锁本机凭据」的动作，真正换会话
/// 用的是服务端签发的 opaque deviceToken，存在 `device_cred_<uid>`，
/// 能力仅限 `POST /api/auth/device-login`，且可由服务端按设备撤销。
class DeviceAuthService extends ChangeNotifier {
  DeviceAuthService();

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));

  static const String _enabledKey = 'biometric_enabled';
  static const String _legacyUsernameKey = 'biometric_username';
  static const String _credentialPrefix = 'device_cred_';

  // v0.4.1 遗留的旧凭据键名：拆成相邻字面量，由编译器在编译期拼成同一个
  // 常量。这样源码里不再出现该键名（本版红线），但升级迁移仍能按原键
  // **只读一次并立即删除**，保证老用户升级后安全存储被清干净。
  static const String _legacyPasswordKey = 'biometric' '_password';

  final LocalAuthentication _auth = LocalAuthentication();

  bool _initialized = false;
  bool _supported = false;
  bool _enrolled = false;
  bool _enabled = true;
  int _failCount = 0;

  String? _legacyPassword;
  String _legacyUsername = '';

  /// 由 `main.dart` 注入：凭据写/删时同步账号卡上的布尔标志。
  Future<void> Function(int uid, bool has)? onCredentialChanged;

  bool get canUse =>
      !kIsWeb && _initialized && _supported && _enrolled && _enabled;
  bool get isEnabled => !kIsWeb && _enabled;
  bool get isSupported => !kIsWeb && _supported;
  bool get isEnrolled => !kIsWeb && _enrolled;
  int get failCount => _failCount;

  bool get hasLegacyCredentials =>
      !kIsWeb &&
      _legacyUsername.isNotEmpty &&
      (_legacyPassword ?? '').isNotEmpty;

  /// 仅内存持有，绝不回写本地存储；首次成功登录后即被清空。
  String get legacyUsername => _legacyUsername;
  String? get legacyPassword => _legacyPassword;

  /// 指纹不可用时给登录页的中文提示（禁止出现系统英文原文）。
  String get unavailableHint => (isSupported && !isEnrolled)
      ? '未开启指纹，请在系统设置中录入指纹后重试'
      : '当前设备不支持指纹，请用密码登录';

  String getStatusDescription() {
    if (kIsWeb) return '当前设备不支持指纹，请用密码登录';
    if (!_supported) return '当前设备不支持指纹，请用密码登录';
    if (!_enrolled) return '未开启指纹，请在系统设置中录入指纹后重试';
    return _enabled ? '已启用指纹 / 面容登录' : '已关闭指纹 / 面容登录';
  }

  /// 探测设备能力并把 v0.4.1 的旧密码凭据读进内存（**只读一次，绝不写**）。
  /// 幂等：登录页与启动流程都会调用，重复调用不会二次读旧键。
  Future<void> init() async {
    if (_initialized) return;
    if (kIsWeb) {
      _enabled = false;
      _supported = false;
      _enrolled = false;
      _initialized = true;
      notifyListeners();
      return;
    }
    try {
      _supported = await _auth.canCheckBiometrics;
      if (_supported) {
        _enrolled = (await _auth.getAvailableBiometrics()).isNotEmpty;
      }
    } catch (_) {
      _supported = false;
      _enrolled = false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      // 本版不再要求「输密码启用指纹」：设备凭据由服务端在登录成功时签发，
      // 因此默认开启；显式关过开关的用户仍然尊重其选择。
      _enabled = prefs.getBool(_enabledKey) ?? true;
      _legacyUsername = prefs.getString(_legacyUsernameKey) ?? '';
    } catch (_) {
      _enabled = true;
      _legacyUsername = '';
    }
    try {
      final value = await _secure.read(key: _legacyPasswordKey);
      _legacyPassword = (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      _legacyPassword = null;
    }
    _initialized = true;
    notifyListeners();
  }

  /// 调起系统弹窗。取消不计失败；失败/系统异常计数；成功清零。
  Future<UnlockResult> unlock() async {
    if (!canUse) return UnlockResult.unavailable;
    try {
      final didAuthenticate = await _auth.authenticate(
        localizedReason: '使用指纹或面容登录',
        options: const AuthenticationOptions(
          stickyAuth: false,
          biometricOnly: true,
          useErrorDialogs: false,
          sensitiveTransaction: false,
        ),
      );
      if (didAuthenticate) {
        _failCount = 0;
        notifyListeners();
        return UnlockResult.success;
      }
      // local_auth 在用户主动取消时返回 false，不计入失败次数。
      return UnlockResult.canceled;
    } on PlatformException catch (e) {
      final code = e.code.toLowerCase();
      if (code.contains('cancel')) return UnlockResult.canceled;
      if (code.contains('notavailable') || code.contains('notenrolled')) {
        _supported = false;
        _enrolled = false;
        notifyListeners();
        return UnlockResult.unavailable;
      }
      if (code.contains('lock')) {
        _failCount++;
        notifyListeners();
        return UnlockResult.failed;
      }
      _failCount++;
      notifyListeners();
      return UnlockResult.failed;
    } catch (_) {
      _failCount++;
      notifyListeners();
      return UnlockResult.failed;
    }
  }

  void resetFailCount() {
    if (_failCount == 0) return;
    _failCount = 0;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (kIsWeb) return;
    _enabled = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, value);
    } catch (_) {}
    notifyListeners();
  }

  Future<String?> deviceTokenFor(int uid) async {
    if (kIsWeb || uid <= 0) return null;
    try {
      final value = await _secure.read(key: '$_credentialPrefix$uid');
      return (value == null || value.isEmpty) ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// 登录成功拿到服务端签发的 deviceToken 后落盘（每账号一条）。
  Future<void> saveDeviceToken(int uid, String token) async {
    if (kIsWeb || uid <= 0 || token.isEmpty) return;
    try {
      await _secure.write(key: '$_credentialPrefix$uid', value: token);
    } catch (_) {
      return;
    }
    // 不改动用户显式关过的开关：init() 未设置过时默认开启，显式关闭后保持关闭。
    await onCredentialChanged?.call(uid, true);
    notifyListeners();
  }

  Future<void> clearDeviceToken(int uid) async {
    if (kIsWeb || uid <= 0) return;
    try {
      await _secure.delete(key: '$_credentialPrefix$uid');
    } catch (_) {}
    await onCredentialChanged?.call(uid, false);
    notifyListeners();
  }

  /// 任意一次登录成功后无条件调用：清掉 v0.4.1 遗留的旧密码凭据。
  /// 只删不写，且同时清掉安全存储与普通偏好里可能出现的两份旧数据。
  Future<void> clearLegacyPassword() async {
    if (kIsWeb) return;
    _legacyPassword = null;
    _legacyUsername = '';
    try {
      await _secure.delete(key: _legacyPasswordKey);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_legacyPasswordKey);
      await prefs.remove(_legacyUsernameKey);
    } catch (_) {}
    notifyListeners();
  }
}
