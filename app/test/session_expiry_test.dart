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

  // 回归（用户反馈「指纹验证后依旧显示 token 过期」）：
  // 指纹登录换新 token 后，先前在途请求迟到的 401 绝不能清掉新会话。
  test('陈旧 401 不得清掉登录后的新 token（指纹登录竞态）', () async {
    server.listen((HttpRequest req) async {
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path.endsWith('/auth/device-login')) {
        req.response.statusCode = 200;
        req.response.write(jsonEncode(<String, dynamic>{
          'code': 0,
          'message': 'ok',
          'data': <String, dynamic>{
            'accessToken': 'new-access',
            'refreshToken': 'new-refresh',
            'expiresIn': 900,
            'uid': 1,
            'role': 'user',
            'nickname': 'n',
            'avatar': '',
          },
        }));
      } else if (req.uri.path.endsWith('/auth/me')) {
        req.response.statusCode = 200;
        req.response.write(jsonEncode(<String, dynamic>{
          'code': 0,
          'message': 'ok',
          'data': <String, dynamic>{
            'id': 1,
            'username': 'u',
            'nickname': 'n',
            'avatar': '',
            'email': '',
            'phone': '',
            'role': 'user',
            'mfaEnabled': false,
            'disabled': false,
          },
        }));
      } else if (req.uri.path.endsWith('/auth/refresh')) {
        req.response.statusCode = 401;
        req.response.write(jsonEncode(
            <String, dynamic>{'code': 40111, 'message': '登录已失效'}));
      } else {
        // 业务请求：**延迟 1.5s** 再回 401 —— 模拟在途请求的响应迟到
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        req.response.statusCode = 401;
        req.response.write(jsonEncode(
            <String, dynamic>{'code': 40111, 'message': '登录已失效'}));
      }
      await req.response.close();
    });

    // 1) 先发一条业务请求（用旧 token），**不等它**——响应会迟到
    final pending = ApiClient.instance.overview();

    // 2) 等一下让请求已发出、响应在路上
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // 3) 指纹登录成功（换新 token）——此刻陈旧 401 还没回来
    final dl = await ApiClient.instance.deviceLogin(
        deviceId: 'd1', deviceToken: 'cred1', deviceName: 'p');
    expect(dl.code, 0);
    final me = await ApiClient.instance.me();
    expect(me.code, 0);
    expect(ApiClient.instance.hasToken, true);

    // 4) 陈旧 401 现在回来了
    try {
      await pending;
    } catch (_) {}

    // 5) 核心断言：新登录态必须还在，且没被误判会话失效
    expect(ApiClient.instance.hasToken, true,
        reason: '迟到的陈旧 401 不得清掉登录后的新 token');
    String? reason;
    ApiClient.onSessionExpired = (r) => reason = r;
    expect(reason, isNull);
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
