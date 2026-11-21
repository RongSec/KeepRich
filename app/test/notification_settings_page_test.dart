import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:family_finance_app/models.dart';
import 'package:family_finance_app/pages/notification_settings_page.dart';

/// 通知设置页：每类通知一个开关、文案模板可编辑（测试注入，不走网络）。
void main() {
  testWidgets('通知设置页渲染各类开关与模板编辑', (tester) async {
    // 加高视口：ListView 懒加载，否则屏幕外的卡片不会构建
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final settings = [
      for (final t in NotifyType.all)
        NotificationSetting(
            type: t,
            enabled: true,
            titleTemplate: '',
            contentTemplate: '',
            defaultTitleTemplate: '默认标题',
            defaultContentTemplate: '默认内容'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: NotificationSettingsPage(initialSettings: settings),
    ));
    await tester.pumpAndSettle();

    // 每类通知各一个开关，标签齐全
    expect(find.byType(SwitchListTile), findsNWidgets(NotifyType.all.length));
    for (final label in NotifyType.labels.values) {
      expect(find.text(label), findsWidgets);
    }

    // 切换第一个开关（超支提醒）后仍渲染正常
    final first = find.byType(SwitchListTile).first;
    await tester.tap(first);
    await tester.pump();

    // 展开「编辑文案格式」，出现标题/内容模板输入框
    await tester.tap(find.text('编辑文案格式').first);
    await tester.pumpAndSettle();
    expect(find.text('标题模板'), findsOneWidget);
    expect(find.text('内容模板'), findsOneWidget);
  });
}
