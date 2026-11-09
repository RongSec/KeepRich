import 'dart:io';

import 'package:dio/dio.dart';
import 'package:family_finance_app/config.dart';
import 'package:family_finance_app/services/accounts.dart';
import 'package:family_finance_app/services/api.dart';
import 'package:family_finance_app/services/auth.dart';
import 'package:family_finance_app/services/device_auth.dart';
import 'package:family_finance_app/services/device_identity.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// v0.5.0 App 侧端到端契约验收（需要本地后端）：
///   cd backend && APP_PORT=28083 CLOUD_SYNC_ENABLED=false SQLITE_PATH=/tmp/kr_e2e.db \
///       go run -tags sqlite .
///   cd app && KEEPRICH_E2E=1 env -u HTTP_PROXY -u HTTPS_PROXY flutter test --no-pub test/e2e_contract_test.dart
///
/// 覆盖：邀请码注册 → 直接进概览 → 设备列表 → 退出 → 账号卡 → 密码/设备凭据登录
/// → 切换用户 → access 自动 refresh 且**新 refreshToken 落盘** → 冷启动恢复。
/// flutter_test 默认把全部 HttpClient 请求变成 400；本用例要打真实本地后端，
/// 用基类实现（返回真实 _HttpClient）覆盖掉全局 Mock。
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  const secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));
  const base = 'http://127.0.0.1:28083';

  test(
    'v0.5.0 全链路契约：注册 / 账号卡 / 设备凭据 / refresh 轮换落盘',
    () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      HttpOverrides.global = _RealHttpOverrides();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});

      await AppConfig.init();
      await AppConfig.setServerHost(base);
      ApiClient.instance.rebuild();
      ApiClient.instance.clearTokens();
      await ApiClient.instance.clearPersisted();
      await ApiClient.instance.loadTokens();

      final did = await DeviceIdentity.id();
      final dname = await DeviceIdentity.name();
      const dplatform = 'android';

      // ---- 0. 管理员登录 + 生成邀请码（仅测试用裸 Dio，App 业务代码零 invite 入口）----
      final admin = await ApiClient.instance.login(
        'admin',
        'admin123456',
        deviceId: did,
        deviceName: dname,
        platform: dplatform,
      );
      expect(admin.ok, isTrue, reason: admin.message);
      final adminDio = Dio(BaseOptions(
        baseUrl: '$base/api',
        headers: <String, dynamic>{'X-Finance-Token': admin.data!.accessToken},
      ));
      final gen = await adminDio.post('/admin/invite-codes',
          data: <String, dynamic>{
            'count': 2,
            'maxUses': 5,
            'expiresInDays': 7,
            'note': 'app-e2e',
          });
      expect(gen.data['code'], 0);
      final String inviteCode =
          gen.data['data']['codes'][0]['code'] as String;
      expect(inviteCode.length, 8);

      // ---- 1. 邀请码注册 → 200 直接下发 token（注册即登录）----
      final username =
          'e2e${DateTime.now().millisecondsSinceEpoch % 1000000}';
      final reg = await ApiClient.instance.register(
        inviteCode: inviteCode,
        username: username,
        password: 'abc12345',
        confirmPassword: 'abc12345',
        nickname: '联调小满',
        email: 'e2e@example.com',
        deviceId: did,
        deviceName: dname,
        platform: dplatform,
      );
      expect(reg.ok, isTrue, reason: reg.message);
      expect(reg.data!.sessionId, isNotEmpty);
      expect(reg.data!.idleExpireAt, greaterThan(0));
      expect(reg.data!.deviceToken, isNotNull);

      final me = await ApiClient.instance.me();
      expect(me.ok, isTrue, reason: me.message);
      expect(me.data!.username, username);
      expect(me.data!.nickname, '联调小满');
      final family = await ApiClient.instance.getFamily();
      expect(family.data?['family'], isNull,
          reason: '邀请码不绑定家庭：注册出的账号应无家庭');

      // ---- 2. 直接进概览（/overview 200，说明会话可用）----
      final overview = await ApiClient.instance.overview();
      expect(overview.ok, isTrue, reason: overview.message);

      // ---- 3. 已登录设备列表 ----
      final devices = await ApiClient.instance.listDevices();
      expect(devices.ok, isTrue, reason: devices.message);
      expect(devices.data!.list.any((e) => e.current), isTrue);

      // ---- 4. 退出登录（保留设备凭据，便于后面验证 device-login）----
      final logout = await ApiClient.instance.logout(revokeDevice: false);
      expect(logout.ok, isTrue, reason: logout.message);
      await ApiClient.instance.clearPersisted();
      ApiClient.instance.clearTokens();

      // ---- 5. 本机账号仓库 + 设备凭据（AuthState 全链路，登录页账号卡的数据来源）----
      final accounts = AccountsRepo();
      final deviceAuth = DeviceAuthService();
      accounts.onAccountRemoved = deviceAuth.clearDeviceToken;
      deviceAuth.onCredentialChanged = accounts.markCredential;
      final auth = AuthState(accounts: accounts, deviceAuth: deviceAuth);
      final loggedIn = await auth.login(username, 'abc12345');
      expect(loggedIn, isTrue, reason: auth.lastLoginError ?? '');
      expect(accounts.defaultAccount?.username, username);
      expect(accounts.defaultAccount?.nickname, '联调小满');
      expect(accounts.defaultAccount!.hasDeviceCredential, isTrue);
      final cred = await secure.read(key: 'device_cred_${me.data!.id}');
      expect(cred, isNotNull);
      expect(await secure.read(key: 'biometric' '_password'), isNull,
          reason: '首次成功登录后旧密码凭据必须已清除');

      // ---- 6. 指纹路径：设备凭据换会话 ----
      ApiClient.instance.clearTokens();
      final deviceLogin = await ApiClient.instance.deviceLogin(
        deviceId: did,
        deviceToken: cred!,
        deviceName: dname,
      );
      expect(deviceLogin.ok, isTrue, reason: deviceLogin.message);

      // ---- 6b. 凭据被破坏：40112 + 中文文案，App 据此删凭据并降级密码表单 ----
      final broken = await ApiClient.instance.deviceLogin(
        deviceId: did,
        deviceToken: 'dvc_broken_token_for_e2e',
        deviceName: dname,
      );
      expect(broken.code, 40112);
      expect(broken.message, '设备凭据已失效，请用密码登录');
      ApiClient.instance.clearTokens();
      final recovered = await auth.login(username, 'abc12345');
      expect(recovered, isTrue, reason: auth.lastLoginError ?? '');

      // ---- 7. 切换用户：账号卡与设备凭据都保留 ----
      await auth.switchAccount();
      expect(accounts.defaultAccount?.username, username);
      expect(await secure.read(key: 'device_cred_${me.data!.id}'), isNotNull);

      // ---- 8. access 自动 refresh + 新 refreshToken 必须落盘（轮换红线）----
      final relogin = await auth.login(username, 'abc12345');
      expect(relogin, isTrue, reason: auth.lastLoginError ?? '');
      final before = await secure.read(key: 'refresh_token');
      expect(before, isNotNull);
      final reason = await ApiClient.instance.refreshIfNeeded(force: true);
      expect(reason, isEmpty, reason: 'refresh 失败原因：$reason');
      final after = await secure.read(key: 'refresh_token');
      expect(after, isNotNull);
      expect(after, isNot(before), reason: '服务端已轮换，客户端必须落盘新 refresh');

      // ---- 9. 模拟杀进程重启：只从落盘 token 恢复，仍能免登录进概览 ----
      ApiClient.instance.clearTokens();
      await ApiClient.instance.loadTokens();
      expect(ApiClient.instance.hasToken, isTrue);
      final meAfterRestart = await ApiClient.instance.me();
      expect(meAfterRestart.ok, isTrue, reason: meAfterRestart.message);
      expect(meAfterRestart.data!.username, username);

      // ---- 10. 撤销其他设备后本机保持登录 ----
      final revokeOthers = await ApiClient.instance.revokeOthers();
      expect(revokeOthers.ok, isTrue, reason: revokeOthers.message);
      final stillAlive = await ApiClient.instance.me();
      expect(stillAlive.ok, isTrue, reason: stillAlive.message);

      // ---- 11. 改密：后端撤销全会话与设备凭据；客户端本地收尾 + 回登录页 ----
      final oldAccess = await secure.read(key: 'access_token');
      expect(oldAccess, isNotNull);
      final changed = await ApiClient.instance.changePassword('abc12345', 'def67890');
      expect(changed.ok, isTrue, reason: changed.message);

      await auth.passwordChanged();
      expect(auth.isLoggedIn, isFalse);
      expect(auth.sessionExpireReason, 'revoked');
      expect(accounts.defaultAccount?.username, username);
      expect(await secure.read(key: 'device_cred_${me.data!.id}'), isNull);

      final revoked = await Dio(BaseOptions(
        baseUrl: '$base/api',
        headers: <String, dynamic>{'X-Finance-Token': oldAccess},
        validateStatus: (s) => s != null && s < 500,
      )).get('/auth/me');
      expect(revoked.statusCode, 401,
          reason: '改密后旧 access 必须立即失效');
    },
    skip: Platform.environment['KEEPRICH_E2E'] == '1'
        ? false
        : '需要本地后端（KEEPRICH_E2E=1 + 28083 端口）',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
