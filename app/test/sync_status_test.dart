import 'package:family_finance_app/services/sync_status.dart';
import 'package:family_finance_app/widgets/sync_status_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// R-11 前端侧验收：横条只有在 `failing == true` 时出现，
/// 且不拦截手势；恢复后自动收起（不弹窗、不需要用户操作）。
///
/// 真实网络路径（连续 3 次 `GET /api/sync/status` 失败）由
/// [SyncStatusService.failureThreshold] + [SyncStatusService.staleSeconds]
/// 控制，属于服务端联调项（后端未部署时无法端到端验证）。
void main() {
  testWidgets('failing=true 时出现横条，恢复后自动收起', (tester) async {
    final svc = SyncStatusService.instance;
    svc.stop();

    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [SyncStatusBanner(), Expanded(child: SizedBox())]),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('云端同步暂时失败，数据已保存在本机'), findsNothing,
        reason: '未失败时不占位');

    svc.debugSetFailing(true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('云端同步暂时失败，数据已保存在本机'), findsOneWidget);

    // 不拦截手势：横条被 IgnorePointer 包住
    expect(
      find.descendant(
        of: find.byType(IgnorePointer),
        matching: find.text('云端同步暂时失败，数据已保存在本机'),
      ),
      findsOneWidget,
    );

    svc.debugSetFailing(false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('云端同步暂时失败，数据已保存在本机'), findsNothing);
  });
}
