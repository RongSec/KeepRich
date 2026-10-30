// 基本冒烟测试：验证应用能正常启动
import 'package:flutter_test/flutter_test.dart';

import 'package:family_finance_app/main.dart';

void main() {
  testWidgets('App boots', (WidgetTester tester) async {
    await tester.pumpWidget(const AppRoot());
    await tester.pump();
    // 不验证具体 UI，只验证不抛异常
  });
}
