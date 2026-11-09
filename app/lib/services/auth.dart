import 'package:flutter/foundation.dart';

import '../models.dart';
import 'api.dart';

/// 鉴权状态
class AuthState extends ChangeNotifier {
  UserProfile? _user;
  bool _loading = true;

  UserProfile? get user => _user;
  bool get loading => _loading;
  bool get isLoggedIn => _user != null;

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

  /// 最后一次登录失败的服务器 message（限流/MFA 必填等），供登录页展示
  String? lastLoginError;

  Future<bool> login(String username, String password,
      {String? mfaCode}) async {
    final r =
        await ApiClient.instance.login(username, password, mfaCode: mfaCode);
    if (r.ok && r.data != null) {
      final me = await ApiClient.instance.me();
      if (!me.ok || me.data == null) {
        // me() 失败不能算登录成功（否则"登录成功又闪回"）
        ApiClient.instance.clearTokens();
        await ApiClient.instance.clearPersisted();
        _user = null;
        notifyListeners();
        return false;
      }
      _user = me.data;
      lastLoginError = null;
      notifyListeners();
      return true;
    }
    lastLoginError = r.message;
    return false;
  }

  /// 邮箱注册（R-05）：接口直接返回 token，注册成功即视为已登录。
  ///
  /// 与 [login] 一样必须再走一次 `me()` —— 路由守卫用的是 `isLoggedIn`
  /// （`_user != null`），少了这一步会"注册成功又闪回登录页"。
  Future<bool> register(String email, String password,
      {String? nickname}) async {
    final r = await ApiClient.instance
        .register(email: email, password: password, nickname: nickname);
    if (!r.ok || r.data == null) {
      lastLoginError = r.message;
      return false;
    }
    final me = await ApiClient.instance.me();
    if (!me.ok || me.data == null) {
      ApiClient.instance.clearTokens();
      await ApiClient.instance.clearPersisted();
      _user = null;
      lastLoginError = me.message;
      notifyListeners();
      return false;
    }
    _user = me.data;
    lastLoginError = null;
    notifyListeners();
    return true;
  }

  Future<void> logout() async {
    ApiClient.instance.clearTokens();
    await ApiClient.instance.clearPersisted();
    _user = null;
    notifyListeners();
  }

  /// 会话被服务端判定过期（refresh 也失败）：清掉本地登录态，让路由跳回登录页
  void sessionExpired() {
    _user = null;
    _loading = false;
    notifyListeners();
  }

  void setUser(UserProfile u) {
    _user = u;
    notifyListeners();
  }
}
