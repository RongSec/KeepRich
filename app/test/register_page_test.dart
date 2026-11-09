import 'package:family_finance_app/pages/register_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// v0.5.0 邀请码注册页验收（前端侧）：
/// ① 单页 6 字段、顺序固定、两处常驻说明在位；
/// ② 主按钮「注册并进入」、底部「已有账号？返回登录」；
/// ③ **页面上不出现任何验证码 / 邮件相关字样**；
/// ④ 375×667 与 1440×900 两端渲染都不溢出（溢出会在测试里直接抛异常）；
/// ⑤ 邀请码归一化与用户名 / 昵称 / 密码的就地中文校验。
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

  Future<void> tapSubmit(WidgetTester tester) async {
    final button = find.text('注册并进入');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('小屏 375×667：字段齐全、无溢出、无验证码/邮件字样', (tester) async {
    await pumpAt(tester, const Size(375, 667));

    expect(find.text('邀请码'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('昵称'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('确认密码'), findsOneWidget);
    expect(find.text('邮箱（选填）'), findsOneWidget);
    expect(find.text('注册并进入'), findsOneWidget);
    expect(find.text('已有账号？返回登录'), findsOneWidget);
    expect(find.text('登录时使用「用户名 + 密码」，请记牢'), findsOneWidget);
    expect(find.text('需要管理员提供的邀请码才能注册'), findsOneWidget);

    // 反面断言：本版不存在验证码 / 发信链路
    expect(find.textContaining('验证码'), findsNothing);
    expect(find.textContaining('邮件'), findsNothing);
    expect(find.textContaining('发送'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏 1440×900：字段齐全、无溢出', (tester) async {
    await pumpAt(tester, const Size(1440, 900));

    expect(find.text('注册并进入'), findsOneWidget);
    expect(find.text('邀请码'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('昵称'), findsOneWidget);
    expect(find.textContaining('验证码'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空表单提交：就地提示，不跳页', (tester) async {
    await pumpAt(tester, const Size(375, 667));

    await tapSubmit(tester);

    expect(find.text('请输入邀请码'), findsOneWidget);
    expect(find.text('请输入用户名'), findsOneWidget);
    expect(find.text('请输入昵称'), findsOneWidget);
    expect(find.text('请输入密码'), findsOneWidget);
    expect(find.text('请再次输入密码'), findsOneWidget);
    // 邮箱选填，不该报错
    expect(find.text('邮箱格式不正确'), findsNothing);
    expect(find.text('注册并进入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('邀请码归一化 + 用户名 / 密码 / 确认密码就地校验', (tester) async {
    await pumpAt(tester, const Size(375, 667));

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(6));

    // 小写 + 连字符分组自动归一为 8 位大写
    await tester.enterText(fields.at(0), 'k7qx-9mrt');
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<EditableText>(find.descendant(
            of: fields.at(0), matching: find.byType(EditableText))).controller.text,
        'K7QX9MRT');

    await tester.enterText(fields.at(1), '中文名');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('用户名只能使用英文字母、数字和下划线，不能用中文'),
        findsOneWidget);

    await tester.enterText(fields.at(1), 'alice_lin');
    await tester.enterText(fields.at(2), '林小满');
    await tester.enterText(fields.at(3), 'abcdefgh');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('密码需同时包含字母和数字'), findsOneWidget);

    await tester.enterText(fields.at(3), 'abc12345');
    await tester.enterText(fields.at(4), 'abc123456');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('两次输入的密码不一致'), findsOneWidget);

    await tester.enterText(fields.at(4), 'abc12345');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('两次输入的密码不一致'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
