import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import 'data_bus.dart';
import '../models.dart';

/// 云托管网关实测会让部分 JSON 响应的 body 落成 String（dio 未自动解码，
/// 直接 `as Map<String, dynamic>` 就抛 type cast 错误），统一在此兜底解码
void decodeStringResponseBody(Response resp) {
  final d = resp.data;
  if (d is String && d.isNotEmpty) {
    try {
      final decoded = jsonDecode(d);
      if (decoded is Map) resp.data = decoded;
    } catch (e) {
      debugPrint('[dio] decode fail: $e; head=${d.substring(0, d.length > 120 ? 120 : d.length)}');
    }
  }
}

/// API 客户端
class ApiClient {
  ApiClient._() {
    _dio = _buildDio();
  }
  static final ApiClient instance = ApiClient._();

  static const _secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));

  /// ---- token 落地存储 ----
  ///
  /// 移动端用系统安全存储；Web 端 flutter_secure_storage 插件不可用
  /// （read/write 会抛 MissingPluginException，曾把 bootstrap 打断，
  /// 整个 Web 卡在开屏页进不了登录），改用 SharedPreferences。
  Future<String?> _readStored(String key) async {
    if (kIsWeb) {
      final p = await SharedPreferences.getInstance();
      return p.getString('tok_$key');
    }
    try {
      return await _secure.read(key: key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeStored(String key, String value) async {
    if (kIsWeb) {
      final p = await SharedPreferences.getInstance();
      await p.setString('tok_$key', value);
      return;
    }
    try {
      await _secure.write(key: key, value: value);
    } catch (_) {}
  }

  Future<void> _deleteStored(String key) async {
    if (kIsWeb) {
      final p = await SharedPreferences.getInstance();
      await p.remove('tok_$key');
      return;
    }
    try {
      await _secure.delete(key: key);
    } catch (_) {}
  }

  late Dio _dio;
  String? _accessToken;
  String? _refreshToken;
  Future<bool>? _refreshFuture;

  /// 服务端地址变更后重建连接（保留 token）
  void rebuild() {
    _dio = _buildDio();
  }

  Dio _buildDio() {
    final dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {'Content-Type': 'application/json'},
      validateStatus: (s) => s != null && s < 500,
    ));
    // 注意：这里必须用局部变量 dio，不能用 _dio（构造期 _dio 还没赋值）
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (_accessToken != null) {
          options.headers['Authorization'] = 'Bearer $_accessToken';
          // 云托管网关会用自家 JWT 覆盖 Authorization 头（实测确认），
          // X-Finance-Token 是实测可透传的自定义头，后端优先从它取
          options.headers['X-Finance-Token'] = _accessToken!;
        }
        // 云托管域名要求每个请求都带 sharecode，否则一律 403
        final code = AppConfig.shareCode;
        if (code != null && code.isNotEmpty) {
          options.queryParameters['sharecode'] = code;
        }
        handler.next(options);
      },
      // 401 必须在 onResponse 里处理：BaseOptions 的 validateStatus 接受了 <500，
      // Dio 会把 401 当成"成功响应"，onError 永远不会触发 —— 之前 refresh
      // 一次都没发出过，token 过期后整屏只剩 "invalid or expired token"。
      onResponse: (resp, handler) async {
        decodeStringResponseBody(resp);
        // 写操作成功 → 广播数据变更，所有财务页面自动重载（无需手动刷新）
        final d = resp.data;
        if (resp.requestOptions.method != 'GET' &&
            d is Map &&
            d['code'] == 0) {
          markDataChanged();
        }
        if (resp.statusCode != 401) {
          handler.next(resp);
          return;
        }
        final req = resp.requestOptions;
        // 并发场景共享同一个刷新 Future，避免 A 刷新时 B 把新 token 清掉
        if (_refreshToken != null && req.extra['retried'] != true) {
          final refreshed = await _refreshAccessToken();
          if (refreshed) {
            req.extra['retried'] = true;
            req.headers['Authorization'] = 'Bearer $_accessToken';
            try {
              final clone = await dio.fetch(req);
              handler.resolve(clone);
              return;
            } catch (_) {
              // 重试失败则继续走下面的失效处理
            }
          }
        }
        // access + refresh 都不可用：清登录态并跳回登录页
        await clearPersisted();
        clearTokens();
        onSessionExpired?.call();
        handler.next(resp);
      },
      onError: (e, handler) async {
        handler.next(e);
      },
    ));
    return dio;
  }

  /// 会话已失效（refresh 也失败）回调：由 AuthState 注册，用来跳回登录页
  static void Function()? onSessionExpired;

  void setTokens({String? access, String? refresh}) {
    if (access != null) _accessToken = access;
    if (refresh != null) _refreshToken = refresh;
  }

  void clearTokens() {
    _accessToken = null;
    _refreshToken = null;
  }

  bool get hasToken => _accessToken != null;

  /// 当前 access token（WS 握手等场景用）
  String? get accessToken => _accessToken;

  /// 用 refresh token 换取新 access token。
  /// 并发调用共享同一个 Future，刷新过程中进来的请求会等它，而不是各自判定失败。
  Future<bool> _refreshAccessToken() {
    return _refreshFuture ??= _doRefresh().whenComplete(() {
      _refreshFuture = null;
    });
  }

  Future<bool> _doRefresh() async {
    try {
      final sc = AppConfig.shareCode;
      final r = await Dio(BaseOptions(
        baseUrl: AppConfig.apiBaseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      )).post(
        '/auth/refresh',
        queryParameters:
            (sc == null || sc.isEmpty) ? null : {'sharecode': sc},
        data: {'refreshToken': _refreshToken},
      );
      decodeStringResponseBody(r);
      final data = r.data as Map<String, dynamic>?;
      if (data != null && data['code'] == 0 && data['data'] != null) {
        final d = data['data'] as Map<String, dynamic>;
        _accessToken = d['accessToken'] as String?;
        await persistTokens();
        return _accessToken != null;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> loadTokens() async {
    _accessToken = await _readStored('access_token');
    _refreshToken = await _readStored('refresh_token');
    // 迁移：旧版本 token 存 SharedPreferences 的搬进安全存储
    final p = await SharedPreferences.getInstance();
    final legacyAccess = p.getString('access_token');
    final legacyRefresh = p.getString('refresh_token');
    if (legacyAccess != null || legacyRefresh != null) {
      _accessToken ??= legacyAccess;
      _refreshToken ??= legacyRefresh;
      await persistTokens();
      await p.remove('access_token');
      await p.remove('refresh_token');
    }
  }

  Future<void> persistTokens() async {
    if (_accessToken != null) {
      await _writeStored('access_token', _accessToken!);
    }
    if (_refreshToken != null) {
      await _writeStored('refresh_token', _refreshToken!);
    }
  }

  Future<void> clearPersisted() async {
    await _deleteStored('access_token');
    await _deleteStored('refresh_token');
  }

  Future<ApiResponse<LoginResult>> login(String username, String password,
      {String? mfaCode}) async {
    final r = await _dio.post('/auth/login', data: {
      'username': username,
      'password': password,
      if (mfaCode != null) 'mfaCode': mfaCode,
    });
    final resp = ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => LoginResult.fromJson(d as Map<String, dynamic>));
    if (resp.ok && resp.data != null) {
      setTokens(
          access: resp.data!.accessToken, refresh: resp.data!.refreshToken);
      await persistTokens();
    }
    return resp;
  }

  Future<ApiResponse<UserProfile>> me() async {
    final r = await _dio.get('/auth/me');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => UserProfile.fromJson(d as Map<String, dynamic>));
  }

  /// 在线更新：版本检查（公开接口）
  Future<ApiResponse<Map<String, dynamic>>> checkAppVersion({
    required String platform,
    required String current,
    String? did,
    String? abi,
    String? build,
  }) async {
    final r = await _dio.get('/app/version', queryParameters: {
      'platform': platform,
      'current': current,
      if (did != null) 'did': did,
      if (abi != null && abi.isNotEmpty) 'abi': abi,
      // 构建号：版本号被误复用时仍可识别"同号新构建"
      if (build != null && build.isNotEmpty) 'build': build,
    });
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  /// Web 端版本检查（不需要登录）
  Future<ApiResponse<Map<String, dynamic>>> checkWebVersion(
      {required int buildNumber}) async {
    final r = await _dio.get('/app/web-version', queryParameters: {
      'build': buildNumber,
    });
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<OverviewData>> overview(
      {String scope = 'personal'}) async {
    final r = await _dio.get('/overview', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => OverviewData.fromJson(d as Map<String, dynamic>));
  }

  Future<ApiResponse<ChartData>> overviewChart(
      {String scope = 'personal', String period = 'month'}) async {
    final r = await _dio.get('/overview/chart',
        queryParameters: {'scope': scope, 'period': period});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => ChartData.fromJson(d as Map<String, dynamic>));
  }

  Future<ApiResponse<Map<String, dynamic>>> txPage({
    String scope = 'personal',
    String? type,
    String? category,
    String? recorder,
    int? startAt,
    int? endAt,
    String? exceedWorry,
    int page = 1,
    int size = 50,
  }) async {
    final r = await _dio.get('/transactions', queryParameters: {
      'scope': scope,
      if (type != null) 'type': type,
      if (category != null) 'category': category,
      if (recorder != null) 'recorder': recorder,
      if (startAt != null) 'startAt': startAt,
      if (endAt != null) 'endAt': endAt,
      if (exceedWorry != null) 'exceedWorry': exceedWorry,
      'page': page,
      'size': size,
    });
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> createTx(
      Map<String, dynamic> body) async {
    final r = await _dio.post('/transactions', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<PurchaseItem>>> purchaseList(
      {String scope = 'personal'}) async {
    final r =
        await _dio.get('/purchase-plans', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) {
      final list = d as List<dynamic>;
      return list
          .map((e) => PurchaseItem.fromJson(e as Map<String, dynamic>))
          .toList();
    });
  }

  Future<ApiResponse<Map<String, dynamic>>> createPurchase(
      Map<String, dynamic> body) async {
    final r = await _dio.post('/purchase-plans', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> checkPurchase(
      {String scope = 'personal'}) async {
    final r = await _dio
        .post('/purchase-plans/check', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> getPlan(
      {String scope = 'personal'}) async {
    final r = await _dio.get('/plan', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> savePlan(
      Map<String, dynamic> body) async {
    final r = await _dio.post('/plan', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> getFamily() async {
    final r = await _dio.get('/family');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> createFamily(
      String name, String description) async {
    final r = await _dio
        .post('/family', data: {'name': name, 'description': description});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> applyJoin(
      String code, String message) async {
    final r = await _dio
        .post('/family/join', data: {'code': code, 'message': message});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<dynamic>>> listJoinRequests() async {
    final r = await _dio.get('/family/requests');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => (d as List<dynamic>?) ?? []);
  }

  Future<ApiResponse<Map<String, dynamic>>> approveJoin(
      int requestId, bool approve) async {
    final r = await _dio.post('/family/approve',
        data: {'requestId': requestId, 'approve': approve});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> bindForever() async {
    final r = await _dio.post('/family/bind-forever');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> syncPersonalData() async {
    final r = await _dio.post('/family/sync');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> requestDeleteFamily(
      {String reason = ''}) async {
    final r = await _dio.post('/family/delete', data: {
      'reason': reason,
    });
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> voteDeleteFamily(
      int requestId, bool vote) async {
    final r = await _dio.post('/family/delete/vote', data: {
      'requestId': requestId,
      'vote': vote,
    });
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> listDeleteVotes() async {
    final r = await _dio.get('/family/delete/votes');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> updateProfile(
      Map<String, dynamic> body) async {
    final r = await _dio.post('/profile', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> changePassword(
      String oldPwd, String newPwd) async {
    final r = await _dio.post('/profile/password',
        data: {'oldPassword': oldPwd, 'newPassword': newPwd});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> mfaSetup() async {
    final r = await _dio.post('/mfa/setup');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> mfaEnable(String code) async {
    final r = await _dio.post('/mfa/enable', data: {'code': code});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<InvestmentRecord>>> investmentList(
      {String scope = 'personal', int? year, int limit = 36}) async {
    final r = await _dio.get('/investments', queryParameters: {
      'scope': scope,
      if (year != null) 'year': year,
      'limit': limit,
    });
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) {
      final list = (d as List<dynamic>?) ?? [];
      return list
          .map((e) => InvestmentRecord.fromJson(e as Map<String, dynamic>))
          .toList();
    });
  }

  Future<ApiResponse<Map<String, dynamic>>> investmentCurrent(
      {String scope = 'personal'}) async {
    final r = await _dio
        .get('/investments/current', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> investmentSettlement(
      {String scope = 'personal'}) async {
    final r = await _dio
        .get('/investments/settlement', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> investmentUpsert(
      Map<String, dynamic> body) async {
    final r = await _dio.post('/investments', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<FamilyMember>>> familyMembers() async {
    final r = await _dio.get('/family/members');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) {
      final list = (d as List<dynamic>?) ?? [];
      return list
          .map((e) => FamilyMember.fromJson(e as Map<String, dynamic>))
          .toList();
    });
  }

  Future<ApiResponse<Map<String, dynamic>>> reportError({
    required String message,
    String? stack,
    String? url,
    String? platform,
    String? app,
    String? version,
  }) async {
    final r = await _dio.post('/errors', data: {
      'message': message,
      if (stack != null) 'stack': stack,
      if (url != null) 'url': url,
      'platform': platform ?? 'web',
      'app': app ?? 'client',
      'version': version ?? '',
    });
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== Admin APIs =====
  Future<ApiResponse<List<dynamic>>> adminListUsers() async {
    final r = await _dio.get('/admin/users');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => (d as List<dynamic>?) ?? []);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminToggleUser(
      int id, bool disabled) async {
    final r = await _dio
        .post('/admin/users/$id/toggle', data: {'disabled': disabled});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminResetPassword(
      int id, String newPassword) async {
    final r = await _dio.post('/admin/users/$id/reset-password',
        data: {'newPassword': newPassword});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminResetMfa(int id) async {
    final r = await _dio.post('/admin/users/$id/reset-mfa');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<dynamic>>> adminListFamilies() async {
    final r = await _dio.get('/admin/families');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => (d as List<dynamic>?) ?? []);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminFamilyStats(int id) async {
    final r = await _dio.get('/admin/families/$id/stats');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminDeleteFamily(int id) async {
    final r = await _dio.delete('/admin/families/$id');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<dynamic>>> adminListErrors() async {
    final r = await _dio.get('/admin/errors');
    // 后端返回 {list:[...], total:...}，取 list 字段
    return ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => (d['list'] as List<dynamic>?) ?? []);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminDeleteError(int id) async {
    final r = await _dio.delete('/admin/errors/$id');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminClearErrors() async {
    final r = await _dio.delete('/admin/errors');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<dynamic>>> adminListAudit(
      {String? keyword,
      String? action,
      String? status,
      int page = 1,
      int size = 100}) async {
    final r = await _dio.get('/admin/audit', queryParameters: {
      if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
      if (action != null) 'action': action,
      if (status != null) 'status': status,
      'page': page,
      'size': size,
    });
    return ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => (d['list'] as List<dynamic>?) ?? []);
  }

  // ===== 未来财务 =====
  Future<ApiResponse<FutureFinanceData>> futureFinance(
      {String scope = 'personal'}) async {
    final r = await _dio.get('/future', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => FutureFinanceData.fromJson(d as Map<String, dynamic>));
  }

  Future<ApiResponse<Map<String, dynamic>>> createHousingLoan(
      Map<String, dynamic> body) async {
    final r = await _dio.post('/future/housing-loans', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> updateHousingLoan(
      int id, Map<String, dynamic> body) async {
    final r = await _dio.put('/future/housing-loans/$id', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteHousingLoan(int id) async {
    final r = await _dio.delete('/future/housing-loans/$id');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> createCommercialLoan(
      Map<String, dynamic> body) async {
    final r = await _dio.post('/future/commercial-loans', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> updateCommercialLoan(
      int id, Map<String, dynamic> body) async {
    final r = await _dio.put('/future/commercial-loans/$id', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteCommercialLoan(int id) async {
    final r = await _dio.delete('/future/commercial-loans/$id');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> createBorrowedMoney(
      Map<String, dynamic> body) async {
    final r = await _dio.post('/future/borrowed', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> updateBorrowedMoney(
      int id, Map<String, dynamic> body) async {
    final r = await _dio.put('/future/borrowed/$id', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteBorrowedMoney(int id) async {
    final r = await _dio.delete('/future/borrowed/$id');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> createBenefit(
      Map<String, dynamic> body) async {
    final r = await _dio.post('/future/benefits', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> updateBenefit(
      int id, Map<String, dynamic> body) async {
    final r = await _dio.put('/future/benefits/$id', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteBenefit(int id) async {
    final r = await _dio.delete('/future/benefits/$id');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> investmentCheck() async {
    final r = await _dio.get('/future/investment-check');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== 家庭成员管理 =====
  Future<ApiResponse<Map<String, dynamic>>> updateFamilyMember(
      int id, bool isAdmin) async {
    final r = await _dio.put('/family/members/$id', data: {'isAdmin': isAdmin});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> removeFamilyMember(int id) async {
    final r = await _dio.delete('/family/members/$id');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== 家庭立即删除 =====
  Future<ApiResponse<Map<String, dynamic>>> forceDeleteFamily() async {
    final r = await _dio.post('/family/force-delete');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== 账单编辑 =====
  Future<ApiResponse<Map<String, dynamic>>> updateTx(
      int id, Map<String, dynamic> body) async {
    final r = await _dio.put('/transactions/$id', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteTxFallback(int id) async {
    final r = await _dio.delete('/transactions/$id');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== 投资桶 =====
  Future<ApiResponse<Map<String, dynamic>>> investmentUpsertFuture(
      Map<String, dynamic> body) async {
    final r = await _dio.post('/investments', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== 大件规划 =====
  Future<ApiResponse<List<dynamic>>> listPurchasePlans(
      {String scope = 'personal'}) async {
    final r =
        await _dio.get('/purchase-plans', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => (d as List<dynamic>?) ?? []);
  }

  Future<ApiResponse<Map<String, dynamic>>> createPurchasePlan(
      Map<String, dynamic> body) async {
    final r = await _dio.post('/purchase-plans', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> updatePurchasePlan(
      int id, Map<String, dynamic> body) async {
    final r = await _dio.put('/purchase-plans/$id', data: body);
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> deletePurchasePlan(int id) async {
    final r = await _dio.delete('/purchase-plans/$id');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== 通知 =====
  Future<ApiResponse<Map<String, dynamic>>> listNotifications(
      {int page = 1, int size = 50, bool unreadOnly = false}) async {
    final r = await _dio.get('/notifications', queryParameters: {
      'page': page,
      'size': size,
      if (unreadOnly) 'unread': '1',
    });
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> markNotificationRead(int id) async {
    final r = await _dio.post('/notifications/$id/read');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> markAllNotificationsRead() async {
    final r = await _dio.post('/notifications/read-all');
    return ApiResponse.fromJson(
        r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }
}
