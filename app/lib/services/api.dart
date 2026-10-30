import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../models.dart';

/// API 客户端
class ApiClient {
  ApiClient._() {
    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {'Content-Type': 'application/json'},
      validateStatus: (s) => s != null && s < 500,
    ));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (_accessToken != null) {
          options.headers['Authorization'] = 'Bearer $_accessToken';
        }
        handler.next(options);
      },
      onError: (e, handler) async {
        // 401 → 尝试用 refresh token 换新后重试一次（解决 access 过期后全 App 报错）
        if (e.response?.statusCode == 401 &&
            _refreshToken != null &&
            e.requestOptions.extra['retried'] != true) {
          try {
            final refreshed = await _refreshAccessToken();
            if (refreshed) {
              e.requestOptions.extra['retried'] = true;
              e.requestOptions.headers['Authorization'] = 'Bearer $_accessToken';
              final clone = await _dio.fetch(e.requestOptions);
              return handler.resolve(clone);
            }
          } catch (_) {
            // 刷新失败则走原错误
          }
          await clearPersisted();
          clearTokens();
        }
        handler.next(e);
      },
    ));
  }
  static final ApiClient instance = ApiClient._();

  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  late final Dio _dio;
  String? _accessToken;
  String? _refreshToken;
  bool _refreshing = false;

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

  /// 用 refresh token 换取新 access token
  Future<bool> _refreshAccessToken() async {
    if (_refreshing) return false;
    _refreshing = true;
    try {
      final r = await Dio(BaseOptions(
        baseUrl: AppConfig.apiBaseUrl,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
      )).post('/auth/refresh', data: {'refreshToken': _refreshToken});
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
    } finally {
      _refreshing = false;
    }
  }

  Future<void> loadTokens() async {
    _accessToken = await _secure.read(key: 'access_token');
    _refreshToken = await _secure.read(key: 'refresh_token');
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
    if (_accessToken != null) await _secure.write(key: 'access_token', value: _accessToken!);
    if (_refreshToken != null) await _secure.write(key: 'refresh_token', value: _refreshToken!);
  }

  Future<void> clearPersisted() async {
    await _secure.delete(key: 'access_token');
    await _secure.delete(key: 'refresh_token');
  }

  Future<ApiResponse<LoginResult>> login(String username, String password, {String? mfaCode}) async {
    final r = await _dio.post('/auth/login', data: {
      'username': username,
      'password': password,
      if (mfaCode != null) 'mfaCode': mfaCode,
    });
    final resp = ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => LoginResult.fromJson(d as Map<String, dynamic>));
    if (resp.ok && resp.data != null) {
      setTokens(access: resp.data!.accessToken, refresh: resp.data!.refreshToken);
      await persistTokens();
    }
    return resp;
  }

  Future<ApiResponse<UserProfile>> me() async {
    final r = await _dio.get('/auth/me');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => UserProfile.fromJson(d as Map<String, dynamic>));
  }

  /// 在线更新：版本检查（公开接口）
  Future<ApiResponse<Map<String, dynamic>>> checkAppVersion({
    required String platform,
    required String current,
    String? did,
  }) async {
    final r = await _dio.get('/app/version', queryParameters: {
      'platform': platform,
      'current': current,
      if (did != null) 'did': did,
    });
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<OverviewData>> overview({String scope = 'personal'}) async {
    final r = await _dio.get('/overview', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => OverviewData.fromJson(d as Map<String, dynamic>));
  }

  Future<ApiResponse<ChartData>> overviewChart({String scope = 'personal', String period = 'month'}) async {
    final r = await _dio.get('/overview/chart', queryParameters: {'scope': scope, 'period': period});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => ChartData.fromJson(d as Map<String, dynamic>));
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
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> createTx(Map<String, dynamic> body) async {
    final r = await _dio.post('/transactions', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<PurchaseItem>>> purchaseList({String scope = 'personal'}) async {
    final r = await _dio.get('/purchase-plans', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) {
      final list = d as List<dynamic>;
      return list.map((e) => PurchaseItem.fromJson(e as Map<String, dynamic>)).toList();
    });
  }

  Future<ApiResponse<Map<String, dynamic>>> createPurchase(Map<String, dynamic> body) async {
    final r = await _dio.post('/purchase-plans', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> checkPurchase({String scope = 'personal'}) async {
    final r = await _dio.post('/purchase-plans/check', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> getPlan({String scope = 'personal'}) async {
    final r = await _dio.get('/plan', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> savePlan(Map<String, dynamic> body) async {
    final r = await _dio.post('/plan', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> getFamily() async {
    final r = await _dio.get('/family');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> createFamily(String name, String description) async {
    final r = await _dio.post('/family', data: {'name': name, 'description': description});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> applyJoin(String code, String message) async {
    final r = await _dio.post('/family/join', data: {'code': code, 'message': message});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<dynamic>>> listJoinRequests() async {
    final r = await _dio.get('/family/requests');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => (d as List<dynamic>?) ?? []);
  }

  Future<ApiResponse<Map<String, dynamic>>> approveJoin(int requestId, bool approve) async {
    final r = await _dio.post('/family/approve', data: {'requestId': requestId, 'approve': approve});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> bindForever() async {
    final r = await _dio.post('/family/bind-forever');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> syncPersonalData() async {
    final r = await _dio.post('/family/sync');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> requestDeleteFamily({String reason = ''}) async {
    final r = await _dio.post('/family/delete', data: {
      'reason': reason,
    });
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> voteDeleteFamily(int requestId, bool vote) async {
    final r = await _dio.post('/family/delete/vote', data: {
      'requestId': requestId,
      'vote': vote,
    });
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> listDeleteVotes() async {
    final r = await _dio.get('/family/delete/votes');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> updateProfile(Map<String, dynamic> body) async {
    final r = await _dio.post('/profile', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> changePassword(String oldPwd, String newPwd) async {
    final r = await _dio.post('/profile/password', data: {'oldPassword': oldPwd, 'newPassword': newPwd});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> mfaSetup() async {
    final r = await _dio.post('/mfa/setup');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> mfaEnable(String code) async {
    final r = await _dio.post('/mfa/enable', data: {'code': code});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<InvestmentRecord>>> investmentList({String scope = 'personal', int? year, int limit = 36}) async {
    final r = await _dio.get('/investments', queryParameters: {
      'scope': scope,
      if (year != null) 'year': year,
      'limit': limit,
    });
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) {
      final list = (d as List<dynamic>?) ?? [];
      return list.map((e) => InvestmentRecord.fromJson(e as Map<String, dynamic>)).toList();
    });
  }

  Future<ApiResponse<Map<String, dynamic>>> investmentCurrent({String scope = 'personal'}) async {
    final r = await _dio.get('/investments/current', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> investmentSettlement({String scope = 'personal'}) async {
    final r = await _dio.get('/investments/settlement', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> investmentUpsert(Map<String, dynamic> body) async {
    final r = await _dio.post('/investments', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<FamilyMember>>> familyMembers() async {
    final r = await _dio.get('/family/members');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) {
      final list = (d as List<dynamic>?) ?? [];
      return list.map((e) => FamilyMember.fromJson(e as Map<String, dynamic>)).toList();
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
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== Admin APIs =====
  Future<ApiResponse<List<dynamic>>> adminListUsers() async {
    final r = await _dio.get('/admin/users');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => (d as List<dynamic>?) ?? []);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminToggleUser(int id, bool disabled) async {
    final r = await _dio.post('/admin/users/$id/toggle', data: {'disabled': disabled});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminResetPassword(int id, String newPassword) async {
    final r = await _dio.post('/admin/users/$id/reset-password', data: {'newPassword': newPassword});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminResetMfa(int id) async {
    final r = await _dio.post('/admin/users/$id/reset-mfa');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<dynamic>>> adminListFamilies() async {
    final r = await _dio.get('/admin/families');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => (d as List<dynamic>?) ?? []);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminFamilyStats(int id) async {
    final r = await _dio.get('/admin/families/$id/stats');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminDeleteFamily(int id) async {
    final r = await _dio.delete('/admin/families/$id');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<dynamic>>> adminListErrors() async {
    final r = await _dio.get('/admin/errors');
    // 后端返回 {list:[...], total:...}，取 list 字段
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => (d['list'] as List<dynamic>?) ?? []);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminDeleteError(int id) async {
    final r = await _dio.delete('/admin/errors/$id');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> adminClearErrors() async {
    final r = await _dio.delete('/admin/errors');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<List<dynamic>>> adminListAudit({String? keyword, String? action, String? status, int page = 1, int size = 100}) async {
    final r = await _dio.get('/admin/audit', queryParameters: {
      if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
      if (action != null) 'action': action,
      if (status != null) 'status': status,
      'page': page,
      'size': size,
    });
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => (d['list'] as List<dynamic>?) ?? []);
  }

  // ===== 未来财务 =====
  Future<ApiResponse<FutureFinanceData>> futureFinance({String scope = 'personal'}) async {
    final r = await _dio.get('/future', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => FutureFinanceData.fromJson(d as Map<String, dynamic>));
  }

  Future<ApiResponse<Map<String, dynamic>>> createHousingLoan(Map<String, dynamic> body) async {
    final r = await _dio.post('/future/housing-loans', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> updateHousingLoan(int id, Map<String, dynamic> body) async {
    final r = await _dio.put('/future/housing-loans/$id', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteHousingLoan(int id) async {
    final r = await _dio.delete('/future/housing-loans/$id');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> createCommercialLoan(Map<String, dynamic> body) async {
    final r = await _dio.post('/future/commercial-loans', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> updateCommercialLoan(int id, Map<String, dynamic> body) async {
    final r = await _dio.put('/future/commercial-loans/$id', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteCommercialLoan(int id) async {
    final r = await _dio.delete('/future/commercial-loans/$id');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> createBorrowedMoney(Map<String, dynamic> body) async {
    final r = await _dio.post('/future/borrowed', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> updateBorrowedMoney(int id, Map<String, dynamic> body) async {
    final r = await _dio.put('/future/borrowed/$id', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteBorrowedMoney(int id) async {
    final r = await _dio.delete('/future/borrowed/$id');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> createBenefit(Map<String, dynamic> body) async {
    final r = await _dio.post('/future/benefits', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> updateBenefit(int id, Map<String, dynamic> body) async {
    final r = await _dio.put('/future/benefits/$id', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteBenefit(int id) async {
    final r = await _dio.delete('/future/benefits/$id');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> investmentCheck() async {
    final r = await _dio.get('/future/investment-check');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== 家庭成员管理 =====
  Future<ApiResponse<Map<String, dynamic>>> updateFamilyMember(int id, bool isAdmin) async {
    final r = await _dio.put('/family/members/$id', data: {'isAdmin': isAdmin});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> removeFamilyMember(int id) async {
    final r = await _dio.delete('/family/members/$id');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== 家庭立即删除 =====
  Future<ApiResponse<Map<String, dynamic>>> forceDeleteFamily() async {
    final r = await _dio.post('/family/force-delete');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== 账单编辑 =====
  Future<ApiResponse<Map<String, dynamic>>> updateTx(int id, Map<String, dynamic> body) async {
    final r = await _dio.put('/transactions/$id', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> deleteTxFallback(int id) async {
    final r = await _dio.delete('/transactions/$id');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== 投资桶 =====
  Future<ApiResponse<Map<String, dynamic>>> investmentUpsertFuture(Map<String, dynamic> body) async {
    final r = await _dio.post('/investments', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== 大件规划 =====
  Future<ApiResponse<List<dynamic>>> listPurchasePlans({String scope = 'personal'}) async {
    final r = await _dio.get('/purchase-plans', queryParameters: {'scope': scope});
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => (d as List<dynamic>?) ?? []);
  }

  Future<ApiResponse<Map<String, dynamic>>> createPurchasePlan(Map<String, dynamic> body) async {
    final r = await _dio.post('/purchase-plans', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> updatePurchasePlan(int id, Map<String, dynamic> body) async {
    final r = await _dio.put('/purchase-plans/$id', data: body);
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> deletePurchasePlan(int id) async {
    final r = await _dio.delete('/purchase-plans/$id');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  // ===== 通知 =====
  Future<ApiResponse<Map<String, dynamic>>> listNotifications({int page = 1, int size = 50, bool unreadOnly = false}) async {
    final r = await _dio.get('/notifications', queryParameters: {
      'page': page,
      'size': size,
      if (unreadOnly) 'unread': '1',
    });
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> markNotificationRead(int id) async {
    final r = await _dio.post('/notifications/$id/read');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }

  Future<ApiResponse<Map<String, dynamic>>> markAllNotificationsRead() async {
    final r = await _dio.post('/notifications/read-all');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>, (d) => d as Map<String, dynamic>);
  }
}
