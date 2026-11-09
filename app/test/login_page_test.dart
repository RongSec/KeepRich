import 'dart:convert';

import 'package:family_finance_app/pages/login_page.dart';
import 'package:family_finance_app/services/accounts.dart';
import 'package:family_finance_app/services/auth.dart';
import 'package:family_finance_app/services/device_auth.dart';
import 'package:family_finance_app/widgets/account_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 登录页三段式 + 降级路径 + 两端尺寸无溢出的 widget 验收。
class _FakeDeviceAuth extends DeviceAuthService {
  _FakeDeviceAuth({this.biometricAvailable = false, this.result = UnlockResult.canceled});

  final bool biometricAvailable;
  final UnlockResult result;
  int _fails = 0;

  @override
  bool get canUse => biometricAvailable;

  @override
  int get failCount => _fails;

  @override
  bool get isSupported => biometricAvailable;

  @override
  bool get isEnrolled => biometricAvailable;

  @override
  Future<void> init() async {}

  @override
  void resetFailCount() {
    _fails = 0;
  }

  @override
  Future<UnlockResult> unlock() async {
    if (result == UnlockResult.failed) _fails++;
    return result;
  }

  @override
  Future<String?> deviceTokenFor(int uid) async => null;
}

class _TestHost extends StatelessWidget {
  const _TestHost({
    required this.accounts,
    required this.deviceAuth,
    required this.auth,
  });

  final AccountsRepo accounts;
  final DeviceAuthService deviceAuth;
  final AuthState auth;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthState>.value(value: auth),
        ChangeNotifierProvider<AccountsRepo>.value(value: accounts),
        ChangeNotifierProvider<DeviceAuthService>.value(value: deviceAuth),
      ],
      child: const MaterialApp(home: LoginPage()),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AccountsRepo accounts;
  late AuthState auth;

  Future<void> pumpAt(
    WidgetTester tester,
    Size size,
    DeviceAuthService deviceAuth, {
    bool withAccount = true,
    String? sessionReason,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{
      if (withAccount)
        'accounts_v1': jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'uid': 7,
            'username': 'alice_lin',
            'nickname': '林小满',
            'avatar': '',
            'lastLoginAt': 1794300000,
            'hasDeviceCredential': true,
          },
        ]),
    });
    accounts = AccountsRepo();
    auth = AuthState(accounts: accounts, deviceAuth: deviceAuth);
    auth.sessionExpireReason = sessionReason;

    await tester.pumpWidget(_TestHost(
      accounts: accounts,
      deviceAuth: deviceAuth,
      auth: auth,
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('本机无账号卡：纯表单、无空头像框、无切换按钮（375×667）',
      (tester) async {
    await pumpAt(tester, const Size(375, 667), _FakeDeviceAuth(),
        withAccount: false);

    expect(find.byType(AccountCard), findsNothing);
    expect(find.text('切换用户'), findsNothing);
    expect(find.text('本机已记住的账号'), findsNothing);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('还没有账号？立即注册'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本机无账号卡：纯表单无溢出（1440×900）', (tester) async {
    await pumpAt(tester, const Size(1440, 900), _FakeDeviceAuth(),
        withAccount: false);
    expect(find.byType(AccountCard), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('本机有账号卡：头像→主按钮→切换用户 顺序不颠倒', (tester) async {
    await pumpAt(tester, const Size(375, 667),
        _FakeDeviceAuth(biometricAvailable: true));

    expect(find.byType(AccountCard), findsOneWidget);
    expect(find.text('林小满'), findsOneWidget);
    expect(find.text('alice_lin'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.text('切换用户'), findsOneWidget);
    expect(find.text('用密码登录'), findsOneWidget);

    final cardY = tester.getCenter(find.byType(AccountCard)).dy;
    final primaryY = tester.getCenter(find.text('登录')).dy;
    final switchY = tester.getCenter(find.text('切换用户')).dy;
    expect(cardY < primaryY, isTrue);
    expect(primaryY < switchY, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有账号卡宽屏 1440×900 不溢出', (tester) async {
    await pumpAt(tester, const Size(1440, 900),
        _FakeDeviceAuth(biometricAvailable: true));
    expect(find.byType(AccountCard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换用户：用户名框为空、有返回，默认账号不变', (tester) async {
    await pumpAt(tester, const Size(375, 667),
        _FakeDeviceAuth(biometricAvailable: true));

    await tester.tap(find.text('切换用户'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('使用账号密码登录'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);
    expect(find.text('本机已记住的账号'), findsOneWidget);
    final editable = tester.widget<EditableText>(find.descendant(
        of: find.byType(TextField).at(0), matching: find.byType(EditableText)));
    expect(editable.controller.text, isEmpty);
    expect(accounts.defaultAccount?.username, 'alice_lin');
    expect(tester.takeException(), isNull);
  });

  testWidgets('指纹取消：提示「已取消指纹验证」且失败计数不增加', (tester) async {
    final fake = _FakeDeviceAuth(
        biometricAvailable: true, result: UnlockResult.canceled);
    await pumpAt(tester, const Size(375, 667), fake);

    await tester.tap(find.text('登录'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('已取消指纹验证'), findsOneWidget);
    expect(fake.failCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('指纹连错 3 次：强制展开密码表单且不再调指纹', (tester) async {
    final fake =
        _FakeDeviceAuth(biometricAvailable: true, result: UnlockResult.failed);
    await pumpAt(tester, const Size(375, 667), fake);

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('登录'));
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('指纹连续 3 次未通过，请改用密码登录'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('用密码登录'), findsNothing);
    expect(fake.failCount, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('闲置过期：黄色提示条 + 主按钮变「验证并登录」', (tester) async {
    await pumpAt(tester, const Size(375, 667),
        _FakeDeviceAuth(biometricAvailable: true),
        sessionReason: 'idle');

    expect(find.text('已超过 24 小时未使用，请重新验证身份'), findsOneWidget);
    expect(find.text('验证并登录'), findsOneWidget);
    expect(find.text('登录'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
