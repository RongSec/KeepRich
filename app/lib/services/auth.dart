import 'package:flutter/foundation.dart';

import '../models.dart';
import 'accounts.dart';
import 'api.dart';
import 'device_auth.dart';
import 'device_identity.dart';

/// 登录/注册请求统一携带的设备三元组（失败时全空，绝不阻断登录）。
class _DeviceFields {
  const _DeviceFields(this.id, this.name, this.platform);

  final String id;
  final String name;
  final String platform;
}

/// 鉴权状态：会话、当前用户、本机账号卡与设备凭据的统一编排入口。
class AuthState extends ChangeNotifier {
  AuthState({AccountsRepo? accounts, DeviceAuthService? deviceAuth})
      : _accounts = accounts ?? AccountsRepo(),
        _deviceAuth = deviceAuth ?? DeviceAuthService();

  final AccountsRepo _accounts;
  final DeviceAuthService _deviceAuth;

  UserProfile? _user;
  bool _loading = true;

  UserProfile? get user => _user;
  bool get loading => _loading;
  bool get isLoggedIn => _user != null;

  /// 最后一次登录/注册失败的服务器 message（全中文，直接展示）。
  String? lastLoginError;

  /// 会话失效原因：`idle` / `revoked` / `device` / null。登录页据此显示提示条。
  String? sessionExpireReason;

  AccountsRepo get accounts => _accounts;
  DeviceAuthService get deviceAuth => _deviceAuth;

  void clearSessionReason() {
    if (sessionExpireReason == null) return;
    sessionExpireReason = null;
    notifyListeners();
  }

  Future<void> bootstrap() async {
    // 任何一步失败都不能让 _loading 卡在 true —— 那会让整个 Web 卡死在
    // 开屏页永远进不了登录页（secure_storage 在 Web 抛异常曾就是这个效果）。
    try {
      await ApiClient.instance.loadTokens();
    } catch (_) {
      // 读不到本地登录态：按未登录处理
    }
    if (ApiClient.instance.hasToken) {
      try {
        final r = await ApiClient.instance.me();
        if (r.ok && r.data != null) {
          _user = r.data;
        } else {
          ApiClient.instance.clearTokens();
          await ApiClient.instance.clearPersisted();
        }
      } catch (_) {
        // 网络失败：保留 token，进 App 后各页面会自行重试/走 401 刷新
      }
    }
    _loading = false;
    notifyListeners();
  }

  Future<_DeviceFields> _deviceFields() async {
    try {
      return _DeviceFields(
        await DeviceIdentity.id(),
        await DeviceIdentity.name(),
        DeviceIdentity.platform(),
      );
    } catch (_) {
      return const _DeviceFields('', '', '');
    }
  }

  /// 账号密码登录（用户名 或 邮箱，老账号兼容）。
  Future<bool> login(String username, String password,
      {String? mfaCode}) async {
    lastLoginError = null;
    final dev = await _deviceFields();
    final r = await ApiClient.instance.login(
      username,
      password,
      mfaCode: mfaCode,
      deviceId: dev.id,
      deviceName: dev.name,
      platform: dev.platform,
    );
    if (!r.ok || r.data == null) {
      lastLoginError = r.message.isNotEmpty ? r.message : '用户名或密码错误';
      notifyListeners();
      return false;
    }
    return _finishLogin(r.data!);
  }

  /// 指纹/面容解锁成功后，用服务端签发的设备凭据换会话。
  /// 40112（凭据失效）时删本机凭据，由登录页降级到密码表单。
  Future<bool> loginWithDeviceCredential(LocalAccount account) async {
    lastLoginError = null;
    final token = await _deviceAuth.deviceTokenFor(account.uid);
    if (token == null || token.isEmpty) {
      lastLoginError = '设备凭据已失效，请用密码登录';
      notifyListeners();
      return false;
    }
    final dev = await _deviceFields();
    final r = await ApiClient.instance.deviceLogin(
      deviceId: dev.id,
      deviceToken: token,
      deviceName: dev.name,
    );
    if (!r.ok || r.data == null) {
      lastLoginError = r.message.isNotEmpty
          ? r.message
          : '设备凭据已失效，请用密码登录';
      if (r.code == 40112 || r.code == 40111) {
        await _deviceAuth.clearDeviceToken(account.uid);
      }
      notifyListeners();
      return false;
    }
    return _finishLogin(r.data!);
  }

  /// 邀请码注册（单页表单）。成功即已登录，直接由调用方跳 /overview。
  Future<bool> register({
    required String inviteCode,
    required String username,
    required String password,
    required String confirmPassword,
    required String nickname,
    String? email,
  }) async {
    lastLoginError = null;
    final dev = await _deviceFields();
    final r = await ApiClient.instance.register(
      inviteCode: inviteCode,
      username: username,
      password: password,
      confirmPassword: confirmPassword,
      nickname: nickname,
      email: email,
      deviceId: dev.id,
      deviceName: dev.name,
      platform: dev.platform,
    );
    if (!r.ok || r.data == null) {
      lastLoginError = r.message.isNotEmpty ? r.message : '注册失败，请稍后再试';
      notifyListeners();
      return false;
    }
    return _finishLogin(r.data!);
  }

  /// 登录/注册/设备登录共用的收尾：拉 /auth/me → 写账号卡 → 存设备凭据 → 清旧密码。
  Future<bool> _finishLogin(LoginResult result) async {
    final me = await ApiClient.instance.me();
    if (!me.ok || me.data == null) {
      // me() 失败不能算登录成功（否则"登录成功又闪回"）
      ApiClient.instance.clearTokens();
      await ApiClient.instance.clearPersisted();
      _user = null;
      lastLoginError =
          me.message.isNotEmpty ? me.message : '登录已失效，请重新登录';
      notifyListeners();
      return false;
    }
    _user = me.data;
    lastLoginError = null;
    sessionExpireReason = null;
    try {
      await _rememberLogin(result, me.data!);
    } catch (_) {
      // 本机存储异常不能把已成功的登录打回去。
    }
    notifyListeners();
    return true;
  }

  Future<void> _rememberLogin(LoginResult result, UserProfile user) async {
    await _accounts.upsertOnLogin(LocalAccount(
      uid: user.id,
      username: user.username,
      nickname: user.nickname,
      avatar: user.avatar,
      hasDeviceCredential: result.deviceToken != null,
    ));
    final token = result.deviceToken;
    if (token != null && token.isNotEmpty) {
      await _deviceAuth.saveDeviceToken(user.id, token);
    }
    // 红线：任何一次成功登录之后，安全存储里不得再存在旧密码凭据。
    await _deviceAuth.clearLegacyPassword();
    _deviceAuth.resetFailCount();
  }

  /// 退出登录：删当前账号卡 + 删其设备凭据 + best-effort 通知服务端撤销。
  /// 网络失败不阻塞本地清理（PRD §3.7 / R-15 ①）。
  Future<void> logout() async {
    final uid = _user?.id;
    // 接口需要 JWT，必须带着 token 先发请求；失败也不影响本机清理。
    try {
      await ApiClient.instance.logout(revokeDevice: true);
    } catch (_) {}
    ApiClient.instance.clearTokens();
    await ApiClient.instance.clearPersisted();
    _user = null;
    sessionExpireReason = null;
    if (uid != null) {
      await _accounts.remove(uid);
    }
    _deviceAuth.resetFailCount();
    notifyListeners();
  }

  /// 切换账号：结束当前会话，但**保留**全部账号卡与设备凭据（R-14 ② / R-15 ②）。
  /// 同时清掉落盘的会话 token，避免下次冷启动又被 bootstrap 自动登回旧账号。
  Future<void> switchAccount() async {
    ApiClient.instance.clearTokens();
    await ApiClient.instance.clearPersisted();
    _user = null;
    sessionExpireReason = null;
    _deviceAuth.resetFailCount();
    notifyListeners();
  }

  /// 会话被服务端判定过期（refresh 也失败）：清掉本地登录态，让路由跳回登录页。
  /// 会话失效 ≠ 退出登录：账号卡与设备凭据一律保留。
  void sessionExpired(String reason) {
    _user = null;
    _loading = false;
    sessionExpireReason = reason;
    notifyListeners();
  }

  /// 修改密码成功：后端已 `RevokeAll` 撤销该账号全部会话与设备凭据。
  ///
  /// 本机会话必须立刻作废，否则下一次请求只会拿到 40111 卡在原页；
  /// 当前账号的设备凭据也已失效，一并删除（账号卡保留，仍可密码登录）。
  /// 带上 `revoked` 原因回登录页，由登录页显示「登录已失效，请重新登录」。
  Future<void> passwordChanged() async {
    // 极端情况下（会话已被 401 先清掉）_user 可能为空，回退到最近登录的账号，
    // 保证那份已失效的设备凭据一定被删掉。
    final uid = _user?.id ?? _accounts.defaultAccount?.uid;
    ApiClient.instance.clearTokens();
    await ApiClient.instance.clearPersisted();
    if (uid != null) {
      await _deviceAuth.clearDeviceToken(uid);
    }
    _user = null;
    _loading = false;
    sessionExpireReason = 'revoked';
    notifyListeners();
  }

  /// 回到前台时调用：access 剩余不足 5 分钟主动刷一次，避免第一屏先吃 401。
  Future<void> refreshIfIdle() async {
    if (!isLoggedIn) return;
    final reason = await ApiClient.instance.refreshIfNeeded();
    if (reason.isEmpty || reason == 'network') return;
    ApiClient.instance.clearTokens();
    await ApiClient.instance.clearPersisted();
    sessionExpired(reason);
  }

  void setUser(UserProfile u) {
    _user = u;
    notifyListeners();
  }
}
