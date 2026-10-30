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
    await ApiClient.instance.loadTokens();
    if (ApiClient.instance.hasToken) {
      final r = await ApiClient.instance.me();
      if (r.ok && r.data != null) {
        _user = r.data;
      } else {
        ApiClient.instance.clearTokens();
        await ApiClient.instance.clearPersisted();
      }
    }
    _loading = false;
    notifyListeners();
  }

  Future<bool> login(String username, String password, {String? mfaCode}) async {
    final r = await ApiClient.instance.login(username, password, mfaCode: mfaCode);
    if (r.ok && r.data != null) {
      final me = await ApiClient.instance.me();
      _user = me.data;
      notifyListeners();
      return true;
    }
    return false;
  }

  Future<void> logout() async {
    ApiClient.instance.clearTokens();
    await ApiClient.instance.clearPersisted();
    _user = null;
    notifyListeners();
  }

  void setUser(UserProfile u) {
    _user = u;
    notifyListeners();
  }
}
