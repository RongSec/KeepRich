// 基本冒烟测试：验证应用能正常启动
import 'package:flutter_test/flutter_test.dart';

import 'package:family_finance_app/main.dart';

void main() {
  testWidgets('App boots', (WidgetTester tester) async {
    await tester.pumpWidget(const AppRoot());
    await tester.pump();
    // 开屏页有 300ms 入场延时 + 3200ms 跳转 Timer，测试结束前必须让它们
    // 走完，否则 flutter_test 会以「A Timer is still pending」判失败。
    // 沙漏的 repeat 动画由帧驱动，用 pump 定点推进即可，不用 pumpAndSettle。
    await tester.pump(const Duration(milliseconds: 3500));
    // 不验证具体 UI，只验证不抛异常
  });
}
