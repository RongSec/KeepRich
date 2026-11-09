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

  /// access 的本地过期时刻（由 expiresIn 推算，仅用于前台恢复时提前刷新）。
  DateTime? _accessExpireAt;
  Future<String>? _refreshFuture;
  bool _sessionExpiredNotified = false;

  /// 登录/注册/刷新/设备登录自身的 401 是业务错误，绝不触发 refresh 或踢回登录页。
  /// logout 同理：客户端主动结束会话时返回的 401 不该再弹一次「登录已失效」。
  static const Set<String> _publicAuthPaths = <String>{
    '/auth/login',
    '/auth/register',
    '/auth/refresh',
    '/auth/device-login',
    '/auth/logout',
  };

  bool _isPublicAuthPath(String path) {
    for (final entry in _publicAuthPaths) {
      if (path.contains(entry)) return true;
    }
    return false;
  }

  static int _codeOf(dynamic body) {
    if (body is Map) {
      final raw = body['code'];
      if (raw is num) return raw.toInt();
      return int.tryParse(raw?.toString() ?? '') ?? 0;
    }
    return 0;
  }

  /// 401 code → 客户端会话失效原因（登录页据此选提示条与按钮文案）。
  static String _reasonFromCode(int code) {
    switch (code) {
      case 40110:
        return 'idle';
      case 40111:
        return 'revoked';
      case 40112:
        return 'device';
      default:
        return 'revoked';
    }
  }

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
        // 公开鉴权接口自身返回 401 时由调用方就地提示，不能触发全局失效。
        if (_isPublicAuthPath(req.path)) {
          handler.next(resp);
          return;
        }
        final originalReason = _reasonFromCode(_codeOf(d));
        String reason = originalReason;
        // 并发场景共享同一个刷新 Future，避免 A 刷新时 B 把新 token 清掉
        if (_refreshToken != null && req.extra['retried'] != true) {
          final refreshed = await _refreshAccessToken();
          if (refreshed.isEmpty) {
            req.extra['retried'] = true;
            req.headers['Authorization'] = 'Bearer $_accessToken';
            // 云托管网关会覆盖 Authorization，业务后端优先读这个自定义头。
            req.headers['X-Finance-Token'] = _accessToken ?? '';
            try {
              final clone = await dio.fetch(req);
              handler.resolve(clone);
              return;
            } catch (_) {
              // 重试失败则继续走下面的失效处理
            }
          } else if (originalReason != 'idle') {
            // 闲置判定优先：首个业务 401 的 40110 已经把原因说清楚了。
            // 服务端在标记闲置时会同时撤销会话，随后的 refresh 只会回
            // 40111；若被它覆盖，登录页会错显红条而不是黄色闲置提示条。
            reason = refreshed;
          }
        }
        // 网络错误不清登录态、不跳登录页（设计 §E.6）。
        if (reason == 'network') {
          handler.next(resp);
          return;
        }
        // access + refresh 都不可用：清登录态并跳回登录页
        await clearPersisted();
        clearTokens();
        if (!_sessionExpiredNotified) {
          _sessionExpiredNotified = true;
          onSessionExpired?.call(reason);
        }
        handler.next(resp);
      },
      onError: (e, handler) async {
        handler.next(e);
      },
    ));
    return dio;
  }

  /// 会话已失效（refresh 也失败）回调：由 AuthState 注册。
  /// reason ∈ `idle` / `revoked` / `device`；登录页据此选提示条与按钮文案。
  static void Function(String reason)? onSessionExpired;

  void setTokens({String? access, String? refresh}) {
    if (access != null) _accessToken = access;
    if (refresh != null) _refreshToken = refresh;
    _sessionExpiredNotified = false;
  }

  void clearTokens() {
    _accessToken = null;
    _refreshToken = null;
    _accessExpireAt = null;
  }

  bool get hasToken => _accessToken != null;

  /// 当前 access token（WS 握手等场景用）
  String? get accessToken => _accessToken;

  /// 用 refresh token 换取新 access token，返回值是失效原因（空串 = 成功）。
  /// 并发调用共享同一个 Future，刷新过程中进来的请求会等它，而不是各自判定失败。
  Future<String> _refreshAccessToken() {
    return _refreshFuture ??= _doRefresh().whenComplete(() {
      _refreshFuture = null;
    });
  }

  /// 前台恢复 / 集成测试用：access 剩余不足 5 分钟时主动刷一次（§E.6）。
  Future<String> refreshIfNeeded({bool force = false}) async {
    if (_refreshToken == null || _refreshToken!.isEmpty) return 'revoked';
    if (!force && _accessExpireAt != null) {
      final left = _accessExpireAt!.difference(DateTime.now()).inSeconds;
      if (left > 300) return '';
    }
    return _refreshAccessToken();
  }

  Future<String> _doRefresh() async {
    try {
      final sc = AppConfig.shareCode;
      // Web 端 '/api' 是相对路径；裸 Dio 不走统一拦截器，这里补全 origin。
      final configured = AppConfig.apiBaseUrl;
      final base = configured.startsWith('http')
          ? configured
          : '${Uri.base.origin}$configured';
      final r = await Dio(BaseOptions(
        baseUrl: base,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        // 401 必须当响应处理，才能读到 40110 / 40111 的 code 分流。
        validateStatus: (s) => s != null && s < 500,
      )).post(
        '/auth/refresh',
        queryParameters:
            (sc == null || sc.isEmpty) ? null : {'sharecode': sc},
        data: {'refreshToken': _refreshToken},
      );
      decodeStringResponseBody(r);
      final data = r.data as Map<String, dynamic>?;
      if (r.statusCode == 401) return _reasonFromCode(_codeOf(data));
      if (data != null && data['code'] == 0 && data['data'] != null) {
        final d = data['data'] as Map<String, dynamic>;
        final newAccess = d['accessToken'] as String?;
        if (newAccess == null || newAccess.isEmpty) return 'revoked';
        _accessToken = newAccess;
        // 轮换红线：响应里的新 refreshToken 必须落盘，否则 120s 宽限一过
        // 旧 refresh 判重放，用户杀进程重启就会被踢。
        final newRefresh = d['refreshToken'] as String?;
        if (newRefresh != null && newRefresh.isNotEmpty) {
          _refreshToken = newRefresh;
        }
        final ttl = (d['expiresIn'] as num?)?.toInt() ?? 900;
        _accessExpireAt =
            DateTime.now().add(Duration(seconds: ttl > 0 ? ttl : 900));
        _sessionExpiredNotified = false;
        await persistTokens();
        return '';
      }
      return 'revoked';
    } catch (_) {
      // 网络错误 / 超时：不清登录态，业务页自行重试。
      return 'network';
    }
  }

  Future<void> loadTokens() async {
    _accessToken = await _readStored('access_token');
    _refreshToken = await _readStored('refresh_token');
    final rawExpire = await _readStored('access_expire_at');
    final millis = int.tryParse(rawExpire ?? '');
    _accessExpireAt = millis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis);
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
    final expire = _accessExpireAt;
    if (expire != null) {
      await _writeStored(
          'access_expire_at', expire.millisecondsSinceEpoch.toString());
    }
  }

  Future<void> clearPersisted() async {
    await _deleteStored('access_token');
    await _deleteStored('refresh_token');
    await _deleteStored('access_expire_at');
  }

  /// 登录/注册/设备登录成功后统一落盘（含 expiresIn 推算的过期时刻）。
  Future<void> _applyLoginTokens(LoginResult result) async {
    _accessToken = result.accessToken;
    _refreshToken = result.refreshToken;
    final ttl = result.expiresIn > 0 ? result.expiresIn : 900;
    _accessExpireAt = DateTime.now().add(Duration(seconds: ttl));
    _sessionExpiredNotified = false;
    await persistTokens();
  }

  /// 账号密码登录。`username` 仍是「用户名 或 邮箱」（老账号兼容）。
  /// deviceId/deviceName/platform 是新增可选字段：带上才会建会话并轮换 refresh。
  Future<ApiResponse<LoginResult>> login(
    String username,
    String password, {
    String? mfaCode,
    String? deviceId,
    String? deviceName,
    String? platform,
  }) async {
    final r = await _dio.post('/auth/login', data: <String, dynamic>{
      'username': username,
      'password': password,
      if (mfaCode != null) 'mfaCode': mfaCode,
      if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
      if (deviceName != null && deviceName.isNotEmpty)
        'deviceName': deviceName,
      if (platform != null && platform.isNotEmpty) 'platform': platform,
    });
    final resp = ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => LoginResult.fromJson(d as Map<String, dynamic>));
    if (resp.ok && resp.data != null) {
      await _applyLoginTokens(resp.data!);
    }
    return resp;
  }

  /// 邀请码注册（单页表单，200 直接下发 token，注册成功即已登录）。
  /// 邮箱选填、不验证、不唯一；页面与代码里都没有任何发信链路。
  Future<ApiResponse<LoginResult>> register({
    required String inviteCode,
    required String username,
    required String password,
    required String confirmPassword,
    required String nickname,
    String? email,
    String? deviceId,
    String? deviceName,
    String? platform,
  }) async {
    final r = await _dio.post('/auth/register', data: <String, dynamic>{
      'inviteCode': inviteCode,
      'username': username,
      'password': password,
      'confirmPassword': confirmPassword,
      'nickname': nickname,
      if (email != null && email.isNotEmpty) 'email': email,
      if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
      if (deviceName != null && deviceName.isNotEmpty)
        'deviceName': deviceName,
      if (platform != null && platform.isNotEmpty) 'platform': platform,
    });
    final resp = ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => LoginResult.fromJson(d as Map<String, dynamic>));
    if (resp.ok && resp.data != null) {
      await _applyLoginTokens(resp.data!);
    }
    return resp;
  }

  /// 指纹解锁后凭服务端设备凭据换会话（能力仅限此一个入口）。
  Future<ApiResponse<LoginResult>> deviceLogin({
    required String deviceId,
    required String deviceToken,
    String? deviceName,
  }) async {
    final r = await _dio.post('/auth/device-login', data: <String, dynamic>{
      'deviceId': deviceId,
      'deviceToken': deviceToken,
      if (deviceName != null && deviceName.isNotEmpty)
        'deviceName': deviceName,
    });
    final resp = ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => LoginResult.fromJson(d as Map<String, dynamic>));
    if (resp.ok && resp.data != null) {
      await _applyLoginTokens(resp.data!);
    }
    return resp;
  }

  /// 退出登录：best-effort 通知服务端撤销当前会话（可选择连设备凭据一起撤销）。
  Future<ApiResponse<Map<String, dynamic>>> logout(
      {bool revokeDevice = true}) async {
    final r = await _dio.post(
      '/auth/logout',
      queryParameters: <String, dynamic>{
        'revokeDevice': revokeDevice ? 'true' : 'false',
      },
    );
    return ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => d as Map<String, dynamic>);
  }

  /// 已登录设备列表（同一设备多条会话按最近活跃聚合）。
  Future<ApiResponse<DeviceListData>> listDevices() async {
    final r = await _dio.get('/auth/devices');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => DeviceListData.fromJson(d as Map<String, dynamic>));
  }

  /// 撤销单个设备（id 是会话 ID，同时撤销该设备的凭据）。
  Future<ApiResponse<Map<String, dynamic>>> revokeDevice(int id) async {
    final r = await _dio.post('/auth/devices/$id/revoke');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => d as Map<String, dynamic>);
  }

  /// 一键撤销其他所有设备，当前设备保持登录。
  Future<ApiResponse<Map<String, dynamic>>> revokeOthers() async {
    final r = await _dio.post('/auth/devices/revoke-others');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => d as Map<String, dynamic>);
  }

  /// 云端快照同步状态（R-11，`GET /api/sync/status`）
  Future<ApiResponse<SyncStatusData>> syncStatus() async {
    final r = await _dio.get('/sync/status');
    return ApiResponse.fromJson(r.data as Map<String, dynamic>,
        (d) => SyncStatusData.fromJson(d as Map<String, dynamic>));
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

  /// 客户端错误上报（`POST /api/errors`）
  ///
  /// [errorCode] 是结构化的错误码（如 `permissionDenied`），后端
  /// `ReportErrorReq` 未声明该字段时会被 JSON 解码忽略，不影响入库；
  /// [extra] 是自由格式的 JSON 字符串，后端已入库并在 `/api/admin/errors` 可见。
  ///
  /// 注意：该接口需要登录态（后端 `middleware.MustUID`）。未登录场景
  /// （如登录页扫码前置失败）上报会 401，调用方必须自己 try/catch 静默处理。
  Future<ApiResponse<Map<String, dynamic>>> reportError({
    required String message,
    String? stack,
    String? url,
    String? platform,
    String? app,
    String? version,
    String? errorCode,
    String? extra,
  }) async {
    final r = await _dio.post('/errors', data: {
      'message': message,
      if (stack != null) 'stack': stack,
      if (url != null) 'url': url,
      'platform': platform ?? 'web',
      'app': app ?? 'client',
      'version': version ?? '',
      if (errorCode != null && errorCode.isNotEmpty) 'errorCode': errorCode,
      if (extra != null && extra.isNotEmpty) 'extra': extra,
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
