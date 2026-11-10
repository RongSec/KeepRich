import 'dart:convert';
import 'dart:io';

import 'package:family_finance_app/config.dart';
import 'package:family_finance_app/models.dart';
import 'package:family_finance_app/pages/bookkeeping_page.dart';
import 'package:family_finance_app/pages/overview_page.dart';
import 'package:family_finance_app/services/api.dart';
import 'package:family_finance_app/services/data_bus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 消费额度桶 + 存钱余额校验 + 重复账单修复（B2/B3）验收。
/// 用本地 HttpServer 假后端；flutter_test 默认把 HttpClient 打成 400，
/// 这里用基类实现覆盖掉全局 Mock，走真实回环网络。
class _RealHttpOverrides extends HttpOverrides {}

/// OverviewData 消费额度桶字段的最小 JSON（其余字段缺省 0）
Map<String, dynamic> _overviewJson({
  double consumptionBalance = 300.5,
  double remainingBudget = 500,
}) {
  return <String, dynamic>{
    'consumptionBalance': consumptionBalance,
    'consumptionAutoIn': 800,
    'consumptionCarryIn': -50,
    'consumptionSpend': 449.5,
    'consumptionRefund': 120,
    'monthConsumableLeft': consumptionBalance,
    'remainingBudget': remainingBudget,
    'savingBalance': 1000,
    'investmentBalance': 2000,
    'emergencyBalance': 300,
    'pensionBalance': 400,
    'allocation': <String, dynamic>{
      'monthlyIncome': 10000,
      'consumptionThisMonth': 800,
      'consumptionTarget': 800,
    },
    'topPurchases': <dynamic>[],
  };
}

Map<String, dynamic> _txJson({int id = 1, String note = '买菜'}) {
  return <String, dynamic>{
    'id': id,
    'uid': 1,
    'type': 'expense',
    'category': 'daily',
    'amount': 12.5,
    'note': note,
    'occurredAt': 1794300000,
  };
}

Map<String, dynamic> _txPageJson() {
  return <String, dynamic>{
    'code': 0,
    'message': '',
    'data': <String, dynamic>{
      'list': <Map<String, dynamic>>[_txJson()],
      'total': 1,
      'worryPerBuy': 0,
      'sumIncome': 0,
      'sumExpense': 12.5,
      'sumTransfer': 0,
    },
  };
}

Map<String, dynamic> _ok(Object? data) =>
    <String, dynamic>{'code': 0, 'message': '', 'data': data};

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

  group('模型与桶定义', () {
    test('OverviewData 消费额度字段容错解析：num/String 兼容、缺失=0', () {
      final d = OverviewData.fromJson(<String, dynamic>{
        'consumptionBalance': '321.55',
        'consumptionAutoIn': 800,
        // consumptionCarryIn 缺失
        'consumptionSpend': '449.5',
        'allocation': <String, dynamic>{},
        'topPurchases': <dynamic>[],
      });
      expect(d.consumptionBalance, 321.55);
      expect(d.consumptionAutoIn, 800);
      expect(d.consumptionCarryIn, 0);
      expect(d.consumptionSpend, 449.5);
      expect(d.consumptionRefund, 0);
    });

    test('B3：所有支出类别都能以「消费额度」为来源', () {
      for (final c in TxCategory.expenseCategories) {
        expect(TxCategory.allowedSourceBuckets[c], contains('consumption'),
            reason: '支出类别 $c 必须支持消费额度来源');
      }
      expect(TxCategory.sourceBucketLabels['consumption'], '消费额度');
      // 与可支配额度并列（多来源）
      expect(TxCategory.allowedSourceBuckets[TxCategory.expenseDaily],
          ['cash', 'consumption']);
    });
  });

  group('页面验收（本地假后端）', () {
    late HttpServer server;
    int txPosts = 0;
    late Future<void> Function(HttpRequest req) route;

    setUp(() async {
      HttpOverrides.global = _RealHttpOverrides();
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      txPosts = 0;
      route = (req) async => _respond(req, _ok(<String, dynamic>{}));
      // 服务端监听必须在真实 zone 注册：fake zone 里的连接事件不会被处理
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

    /// 默认路由：交易列表 / 总览 / 计划 / 创建交易
    void serveDefault() {
      route = (req) async {
        final path = req.uri.path;
        if (req.method == 'POST' && path.endsWith('/transactions')) {
          txPosts++;
          await _respond(req, _ok(<String, dynamic>{}));
          return;
        }
        if (path.endsWith('/transactions')) {
          await _respond(req, _txPageJson());
          return;
        }
        if (path.endsWith('/overview/chart')) {
          await _respond(req, _ok(<String, dynamic>{
            'wealth': <dynamic>[],
            'categoryPie': <dynamic>[],
          }));
          return;
        }
        if (path.endsWith('/overview')) {
          await _respond(req, _ok(_overviewJson()));
          return;
        }
        if (path.endsWith('/plan')) {
          await _respond(req, _ok(<String, dynamic>{'savingRatio': 0.2}));
          return;
        }
        await _respond(req, _ok(<String, dynamic>{}));
      };
    }

    testWidgets('B2 重复账单：连续两次 _load 不产生重复项', (tester) async {
      serveDefault();
      await tester.pumpWidget(const MaterialApp(home: BookkeepingPage()));
      await _settle(tester);
      expect(find.byType(ListTile), findsOneWidget, reason: '首次加载 1 笔');

      // 添加账单后的 _load() 与下拉刷新同款并发：连续两次整表刷新
      markDataChanged();
      markDataChanged();
      await _settle(tester);

      expect(find.byType(ListTile), findsOneWidget,
          reason: '并发刷新后列表不得出现两笔相同账单');
      await _burnPendingTimers(tester);
    });

    testWidgets('存钱超待支配余额：就地红字中文提示并在提交前拦下', (tester) async {
      serveDefault();
      await tester.pumpWidget(const MaterialApp(home: BookkeepingPage()));
      await _settle(tester);

      // 切到存钱 tab，打开记账表单
      await tester.tap(find.widgetWithText(InkWell, '存钱'));
      await _settle(tester);
      await tester.tap(find.text('记存钱'));
      await _settle(tester);

      // 表单显示来源与待支配余额
      expect(find.textContaining('来源：待支配'), findsOneWidget);
      expect(find.textContaining('余额 500.00'), findsOneWidget);

      // 超额输入：就地红字提示
      await tester.enterText(find.widgetWithText(TextField, '金额'), '800');
      await tester.pump();
      expect(find.text('超出待支配余额（可用 500.00 元）'), findsOneWidget);

      // 提交被拦下：不发请求、表单不关闭、中文报错
      await tester.ensureVisible(find.text('保存'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(txPosts, 0, reason: '超额存钱不得发到后端');
      expect(find.textContaining('存钱金额超出待支配余额'), findsOneWidget);
      expect(find.text('记一笔 · 存钱'), findsOneWidget);

      // 金额回到余额内：内联红字消失，正常提交
      await tester.enterText(find.widgetWithText(TextField, '金额'), '300');
      await tester.pump();
      expect(find.text('超出待支配余额（可用 500.00 元）'), findsNothing);
      await tester.ensureVisible(find.text('保存'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await _settle(tester);
      expect(txPosts, 1);
      await _burnPendingTimers(tester);
    });

    testWidgets('支出来源支持「消费额度」：可选中、显示余额、多来源分别校验', (tester) async {
      serveDefault();
      await tester.pumpWidget(const MaterialApp(home: BookkeepingPage()));
      await _settle(tester);

      await tester.tap(find.text('记支出'));
      await _settle(tester);

      // 来源选择器：消费额度与可支配额度并列，且显示各自余额
      expect(find.text('消费额度'), findsOneWidget);
      expect(find.text('可支配额度'), findsOneWidget);
      expect(find.text('余额 300.50 元'), findsOneWidget);
      expect(find.text('余额 500.00 元'), findsOneWidget);

      // 选中消费额度 → 多来源模式
      await tester.tap(find.text('消费额度'));
      await tester.pump();
      expect(find.text('消费额度 金额'), findsOneWidget);

      // 消费额度超出自身余额被拦下
      await tester.enterText(
          find.widgetWithText(TextField, '消费额度 金额'), '999');
      await tester.pump();
      await tester.ensureVisible(find.text('保存'));
      await tester.pump();
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(txPosts, 0, reason: '来源超额不得发到后端');
      expect(find.textContaining('消费额度余额不足'), findsOneWidget);
      await _burnPendingTimers(tester);
    });

    testWidgets('消费桶余额显示：剩余可消费 = 消费额度桶余额，桶卡片含消费额度', (tester) async {
      route = (req) async {
        final path = req.uri.path;
        if (path.endsWith('/overview/chart')) {
          await _respond(req, _ok(<String, dynamic>{
            'wealth': <dynamic>[],
            'categoryPie': <dynamic>[],
          }));
          return;
        }
        if (path.endsWith('/overview')) {
          await _respond(req, _ok(_overviewJson(consumptionBalance: 321.55)));
          return;
        }
        await _respond(req, _ok(<String, dynamic>{}));
      };

      await tester.pumpWidget(const MaterialApp(home: OverviewPage()));
      await _settle(tester);

      // 「剩余可消费」显示消费额度桶余额
      expect(find.text('剩余可消费'), findsOneWidget);
      expect(find.text('321.55'), findsOneWidget);
      // 财务统筹里的消费额度桶卡片（余额）
      expect(find.text('消费额度'), findsOneWidget);
      expect(find.text('321.55 元'), findsOneWidget);
      await _burnPendingTimers(tester);
    });
  });
}
