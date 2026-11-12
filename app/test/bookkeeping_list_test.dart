import 'dart:convert';
import 'dart:io';

import 'package:family_finance_app/config.dart';
import 'package:family_finance_app/pages/bookkeeping_page.dart';
import 'package:family_finance_app/services/api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 账单列表新 UI 验收：按日期分组、时间|备注可见、无来源标签、
/// 无删除按钮（左滑 Dismissible 删除）。
/// 用本地 HttpServer 假后端；flutter_test 默认把 HttpClient 打成 400，
/// 这里用基类实现覆盖掉全局 Mock，走真实回环网络。
class _RealHttpOverrides extends HttpOverrides {}

/// 账单数据：两笔在 11/12（含来源桶、备注各一），一笔在 11/10。
final DateTime _day1 = DateTime(2026, 11, 12, 12, 34);
final DateTime _day1b = DateTime(2026, 11, 12, 13, 5);
final DateTime _day2 = DateTime(2026, 11, 10, 23, 28);

Map<String, dynamic> _txJson({
  required int id,
  required double amount,
  required String note,
  required DateTime occurredAt,
  String category = 'daily',
  String sourceBucket = '',
}) {
  return <String, dynamic>{
    'id': id,
    'uid': 1,
    'type': 'expense',
    'category': category,
    'amount': amount,
    'note': note,
    'occurredAt': occurredAt.millisecondsSinceEpoch ~/ 1000,
    'sourceBucket': sourceBucket,
  };
}

List<Map<String, dynamic>> _serverList = [];

Map<String, dynamic> _ok(Object? data) =>
    <String, dynamic>{'code': 0, 'message': '', 'data': data};

Map<String, dynamic> _txPageJson() {
  return <String, dynamic>{
    'code': 0,
    'message': '',
    'data': <String, dynamic>{
      'list': _serverList,
      'total': _serverList.length,
      'worryPerBuy': 0,
      'sumIncome': 0,
      'sumExpense': 266,
      'sumTransfer': 0,
    },
  };
}

Future<void> _respond(HttpRequest req, Map<String, dynamic> body) async {
  req.response.statusCode = 200;
  req.response.headers.contentType = ContentType.json;
  req.response.write(jsonEncode(body));
  await req.response.close();
}

/// 推进「fake zone 发起的真实 HTTP」：每轮 40ms 真实时间（I/O 往返）
/// + 泵帧消化微任务/零位计时器；多轮覆盖串行请求的多次往返。
Future<void> _settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 30));
    await tester.pump(const Duration(milliseconds: 30));
  }
}

/// 烧掉残留的假计时器（Dio 超时 / HttpClient 空闲 / 提示自动消失），
/// 否则 flutter_test 的「测试结束不得有 pending Timer」断言会失败。
Future<void> _burnPendingTimers(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 30));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('账单列表新 UI（本地假后端）', () {
    late HttpServer server;
    int deleteCalls = 0;
    late Future<void> Function(HttpRequest req) route;

    setUp(() async {
      HttpOverrides.global = _RealHttpOverrides();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      deleteCalls = 0;
      _serverList = [
        _txJson(
            id: 1,
            amount: 194,
            note: '青岛西到上海虹桥',
            occurredAt: _day1,
            sourceBucket: 'cash'),
        _txJson(id: 2, amount: 30, note: '', occurredAt: _day1b),
        _txJson(
            id: 3,
            amount: 42,
            note: '六和鸡腿肉',
            occurredAt: _day2,
            category: 'big_purchase'),
      ];
      route = (req) async {
        final path = req.uri.path;
        if (req.method == 'DELETE' && path.contains('/transactions/')) {
          deleteCalls++;
          final id = int.tryParse(path.split('/').last) ?? 0;
          _serverList = _serverList.where((t) => t['id'] != id).toList();
          await _respond(req, _ok(<String, dynamic>{}));
          return;
        }
        if (path.endsWith('/transactions')) {
          await _respond(req, _txPageJson());
          return;
        }
        await _respond(req, _ok(<String, dynamic>{}));
      };
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        try {
          await route(req);
        } catch (_) {
          try {
            req.response.statusCode = 500;
            await req.response.close();
          } catch (_) {}
        }
      });
      await AppConfig.init();
      await AppConfig.setServerHost('http://127.0.0.1:${server.port}');
      ApiClient.instance.rebuild();
      ApiClient.instance
          .setTokens(access: 'fake-access', refresh: 'fake-refresh');
    });

    tearDown(() async {
      await server.close(force: true);
    });

    testWidgets('按日期分组：只有日期，不再显示当日支出/收入合计', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: BookkeepingPage()));
      await _settle(tester);

      // 两个日期组：11月12日（两笔）与 11月10日（一笔）
      expect(find.text('11月12日'), findsOneWidget);
      expect(find.text('11月10日'), findsOneWidget);

      // 日期行后面不再跟 支出/收入 合计（用户要求去掉）
      expect(find.textContaining('支出:'), findsNothing);
      expect(find.textContaining('收入:'), findsNothing);
      expect(find.textContaining('存钱:'), findsNothing);

      // 每笔账单一个左滑删除容器
      expect(find.byType(Dismissible), findsNWidgets(3));
      await _burnPendingTimers(tester);
    });

    testWidgets('账单行：分类图标 + 时间|备注 可见 + 金额带符号，无来源标签、无删除按钮',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: BookkeepingPage()));
      await _settle(tester);

      // 分类图标（daily=购物篮，big_purchase=购物车）
      expect(find.byIcon(Icons.shopping_basket), findsWidgets);
      expect(find.byIcon(Icons.shopping_cart), findsWidgets);

      // 第二行「时间 | 备注」，备注清晰可见
      expect(find.textContaining('11/12 12:34 | 青岛西到上海虹桥'), findsOneWidget);
      expect(find.textContaining('11/10 23:28 | 六和鸡腿肉'), findsOneWidget);
      // 备注为空时只显示时间
      expect(find.textContaining('11/12 13:05'), findsOneWidget);

      // 金额：支出负号
      expect(find.textContaining('-¥194.00'), findsOneWidget);

      // 不显示支出来源标签
      expect(find.textContaining('←'), findsNothing);
      expect(find.textContaining('可支配额度'), findsNothing);
      expect(find.textContaining('消费额度'), findsNothing);

      // 无删除按钮（删除走左滑，滑出背景里的图标不算按钮）
      expect(
          find.descendant(
              of: find.byType(Dismissible), matching: find.byType(IconButton)),
          findsNothing);
      expect(find.byTooltip('删除'), findsNothing);
      await _burnPendingTimers(tester);
    });

    testWidgets('左滑删除：确认对话框二次确认，取消不删、确认后删除', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: BookkeepingPage()));
      await _settle(tester);

      // 左滑第一笔（青岛西到上海虹桥）→ 弹出确认对话框
      await tester.drag(find.byType(Dismissible).first, const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(find.text('删除账单'), findsOneWidget);
      expect(find.textContaining('确认删除'), findsOneWidget);

      // 取消：不发删除请求、账单还在
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(deleteCalls, 0);
      expect(find.textContaining('青岛西到上海虹桥'), findsOneWidget);

      // 再滑一次 → 确认删除：发出 DELETE，列表刷新后该笔消失
      await tester.drag(find.byType(Dismissible).first, const Offset(-500, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      // 先跑完「对话框收起 + 滑除动画」（onDismissed 后才发 DELETE），
      // 再用真实时间推进假后端往返
      await tester.pumpAndSettle();
      await _settle(tester);
      expect(deleteCalls, 1);
      expect(find.textContaining('青岛西到上海虹桥'), findsNothing);
      // 其余账单仍在
      expect(find.textContaining('六和鸡腿肉'), findsOneWidget);
      await _burnPendingTimers(tester);
    });
  });
}
