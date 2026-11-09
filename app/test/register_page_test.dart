import 'package:family_finance_app/pages/register_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// R-09 验收（前端侧）：
/// ① 字段齐全（邮箱 / 密码 / 确认密码 / 昵称 + 服务端地址入口）；
/// ② 主按钮「注册并进入」、底部「已有账号？返回登录」；
/// ③ **页面上不出现任何验证码 / 邮件激活相关的字段或文案**；
/// ④ 375×667 与 1440×900 两端渲染都不溢出（溢出会在测试里直接抛异常）。
void main() {
  Future<void> pumpAt(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: RegisterPage()),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('小屏 375×667：字段齐全、无溢出、无验证码文案', (tester) async {
    await pumpAt(tester, const Size(375, 667));

    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('确认密码'), findsOneWidget);
    expect(find.text('昵称（选填）'), findsOneWidget);
    expect(find.text('注册并进入'), findsOneWidget);
    expect(find.text('已有账号？返回登录'), findsOneWidget);

    // 反面断言：不允许出现验证码 / 邮件激活相关文案
    expect(find.textContaining('验证码'), findsNothing);
    expect(find.textContaining('激活'), findsNothing);
    expect(find.textContaining('发送验证'), findsNothing);
    expect(find.textContaining('邮件验证'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏 1440×900：字段齐全、无溢出', (tester) async {
    await pumpAt(tester, const Size(1440, 900));

    expect(find.text('注册并进入'), findsOneWidget);
    expect(find.text('邮箱'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空表单提交：就地提示，不跳页', (tester) async {
    await pumpAt(tester, const Size(375, 667));

    await tester.tap(find.text('注册并进入'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('请输入邮箱'), findsOneWidget);
    expect(find.text('请输入密码'), findsOneWidget);
    expect(find.text('请再次输入密码'), findsOneWidget);
    // 昵称选填，不该报错
    expect(find.textContaining('昵称不能超过'), findsNothing);
    // 仍在注册页
    expect(find.text('注册并进入'), findsOneWidget);
  });

  testWidgets('邮箱格式 / 密码强度就地校验', (tester) async {
    await pumpAt(tester, const Size(375, 667));

    await tester.enterText(find.byType(TextFormField).at(0), 'abc@');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('邮箱格式不正确'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(0), 'a@b.com');
    await tester.enterText(find.byType(TextFormField).at(1), 'abcdefgh');
    await tester.enterText(find.byType(TextFormField).at(2), 'abcdefgh');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('密码需同时包含字母和数字'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(1), 'abc12345');
    await tester.enterText(find.byType(TextFormField).at(2), 'abc123456');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('两次输入的密码不一致'), findsOneWidget);

    await tester.enterText(find.byType(TextFormField).at(2), 'abc12345');
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('两次输入的密码不一致'), findsNothing);
  });
}
