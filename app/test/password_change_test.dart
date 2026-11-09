import 'package:family_finance_app/services/accounts.dart';
import 'package:family_finance_app/services/auth.dart';
import 'package:family_finance_app/services/device_auth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 改密成功后客户端本地收尾（T05 ③）：会话作废、设备凭据删除、账号卡保留、
/// 带 revoked 原因回登录页显示「登录已失效，请重新登录」。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('passwordChanged：清会话与设备凭据，保留账号卡并带 revoked 原因',
      () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});

    const secure = FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true));
    final accounts = AccountsRepo();
    final deviceAuth = DeviceAuthService();
    accounts.onAccountRemoved = deviceAuth.clearDeviceToken;
    deviceAuth.onCredentialChanged = accounts.markCredential;
    final auth = AuthState(accounts: accounts, deviceAuth: deviceAuth);

    await accounts.upsertOnLogin(const LocalAccount(
        uid: 5, username: 'alice', nickname: '小满', lastLoginAt: 1700000000));
    await deviceAuth.saveDeviceToken(5, 'dvc_fake_token');
    expect(await secure.read(key: 'device_cred_5'), isNotNull);

    await auth.passwordChanged();

    expect(auth.isLoggedIn, isFalse);
    expect(auth.sessionExpireReason, 'revoked');
    // 会话失效 ≠ 退出登录：账号卡仍在，用户可用新密码重新验证。
    expect(accounts.defaultAccount?.uid, 5);
    expect(accounts.defaultAccount?.displayName(), '小满');
    // 后端改密已撤销全部设备凭据，本机这份必须删掉，避免指纹走进死路。
    expect(await secure.read(key: 'device_cred_5'), isNull);
    expect(await secure.read(key: 'access_token'), isNull);
    expect(await secure.read(key: 'refresh_token'), isNull);
  });
}
