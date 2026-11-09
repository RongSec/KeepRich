import 'dart:convert';
import 'dart:io';

import 'package:family_finance_app/config.dart';
import 'package:family_finance_app/services/api.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// flutter_test 默认把全部 HttpClient 请求变成 400；本文件用本地 HttpServer
/// 模拟 401 响应，需要真实网络栈。
class _RealHttpOverrides extends HttpOverrides {}

/// 401 code → 会话失效原因的闭环验证：
/// 40110 → idle（登录页黄色提示条 + 「验证并登录」）、40111 → revoked。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;

  setUp(() async {
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    await AppConfig.init();
    await AppConfig.setServerHost('http://127.0.0.1:${server.port}');
    ApiClient.instance.rebuild();
    ApiClient.instance.setTokens(access: 'fake-access', refresh: 'fake-refresh');
  });

  tearDown(() async {
    ApiClient.onSessionExpired = null;
    await server.close(force: true);
  });

  void serveCode(int code, String message) {
    server.listen((HttpRequest req) async {
      req.response.statusCode = 401;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, dynamic>{
        'code': code,
        'message': message,
      }));
      await req.response.close();
    });
  }

  Future<void> fireBusinessRequest() async {
    try {
      await ApiClient.instance.overview();
    } catch (_) {
      // Dio 抛出的异常由业务页自行兜底，本用例只关心 onSessionExpired。
    }
  }

  test('40110 闲置失效 → 回调 idle（登录页黄条 / 验证并登录）', () async {
    serveCode(40110, '已超过 24 小时未使用，请重新验证身份');
    String? reason;
    ApiClient.onSessionExpired = (r) => reason = r;
    await fireBusinessRequest();
    expect(reason, 'idle');
  });

  test('40111 会话撤销 → 回调 revoked', () async {
    serveCode(40111, '登录已失效，请重新登录');
    String? reason;
    ApiClient.onSessionExpired = (r) => reason = r;
    await fireBusinessRequest();
    expect(reason, 'revoked');
  });

  test('业务 40110 + refresh 40111：仍按 idle 处理（黄条不被覆盖）', () async {
    server.listen((HttpRequest req) async {
      final isRefresh = req.uri.path.endsWith('/auth/refresh');
      req.response.statusCode = 401;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(<String, dynamic>{
        'code': isRefresh ? 40111 : 40110,
        'message': isRefresh
            ? '登录已失效，请重新登录'
            : '已超过 24 小时未使用，请重新验证身份',
      }));
      await req.response.close();
    });
    String? reason;
    ApiClient.onSessionExpired = (r) => reason = r;
    await fireBusinessRequest();
    expect(reason, 'idle');
  });

  test('刷新接口自身 401 不应被当成业务会话失效', () async {
    serveCode(40111, '登录已失效，请重新登录');
    int calls = 0;
    ApiClient.onSessionExpired = (_) => calls++;
    // 直接打公开鉴权接口：interceptor 必须原样放行，不触发全局失效。
    final r = await ApiClient.instance.login('someone', 'secret');
    expect(r.code, 40111);
    expect(calls, 0);
  });
}
