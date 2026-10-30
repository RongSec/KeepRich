import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

class ApiClient {
  ApiClient._() {
    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
      headers: {'Content-Type': 'application/json'},
      // 接受所有状态码，不抛异常
      validateStatus: (status) => true,
    ));
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (_accessToken != null) {
          options.headers['Authorization'] = 'Bearer $_accessToken';
        }
        handler.next(options);
      },
    ));
  }
  static final ApiClient instance = ApiClient._();

  late final Dio _dio;
  String? _accessToken;
  String? _refreshToken;

  bool get hasToken => _accessToken != null;
  String? get accessToken => _accessToken;

  Future<void> loadTokens() async {
    final p = await SharedPreferences.getInstance();
    _accessToken = p.getString('admin_access_token');
    _refreshToken = p.getString('admin_refresh_token');
  }

  Future<void> setTokens(String access, String refresh) async {
    _accessToken = access;
    _refreshToken = refresh;
    final p = await SharedPreferences.getInstance();
    await p.setString('admin_access_token', access);
    await p.setString('admin_refresh_token', refresh);
  }

  Future<void> clear() async {
    _accessToken = null;
    _refreshToken = null;
    final p = await SharedPreferences.getInstance();
    await p.remove('admin_access_token');
    await p.remove('admin_refresh_token');
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final r = await _dio.post('/auth/login', data: {'username': username, 'password': password});
    final d = r.data as Map<String, dynamic>;
    if (d['code'] == 0) {
      await setTokens(d['data']['accessToken'], d['data']['refreshToken']);
    }
    return d;
  }

  Future<Map<String, dynamic>> get(String path, {Map<String, dynamic>? query}) async {
    final r = await _dio.get(path, queryParameters: query);
    return r.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> post(String path, {Object? data}) async {
    final r = await _dio.post(path, data: data);
    return r.data as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> delete(String path) async {
    final r = await _dio.delete(path);
    return r.data as Map<String, dynamic>;
  }
}
