import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 生物识别服务
class BiometricService extends ChangeNotifier {
  final LocalAuthentication _auth = LocalAuthentication();
  bool _canCheckBiometrics = false;
  bool _hasEnrolledBiometrics = false;
  bool _isBiometricEnabled = false;
  String _lastUsername = '';
  String _lastPassword = '';
  String _errorMessage = '';

  bool get canCheckBiometrics => _canCheckBiometrics && _hasEnrolledBiometrics;
  bool get isBiometricEnabled => _isBiometricEnabled;
  bool get hasSavedCredentials => _lastUsername.isNotEmpty && _lastPassword.isNotEmpty;
  String get errorMessage => _errorMessage;

  /// 初始化：检查设备是否支持生物识别
  Future<void> init() async {
    try {
      // 检查设备是否支持生物识别
      _canCheckBiometrics = await _auth.canCheckBiometrics;
      debugPrint('[biometric] canCheckBiometrics: $_canCheckBiometrics');

      if (_canCheckBiometrics) {
        // 检查是否有已注册的生物识别
        final availableBiometrics = await _auth.getAvailableBiometrics();
        debugPrint('[biometric] availableBiometrics: $availableBiometrics');
        _hasEnrolledBiometrics = availableBiometrics.isNotEmpty;
      }

      // 读取已保存的设置
      final prefs = await SharedPreferences.getInstance();
      _isBiometricEnabled = prefs.getBool('biometric_enabled') ?? false;
      _lastUsername = prefs.getString('biometric_username') ?? '';
      _lastPassword = prefs.getString('biometric_password') ?? '';

      // 如果设备不支持生物识别但之前启用了，自动禁用
      if (!canCheckBiometrics && _isBiometricEnabled) {
        _isBiometricEnabled = false;
        await prefs.setBool('biometric_enabled', false);
      }

      notifyListeners();
    } catch (e) {
      debugPrint('[biometric] init error: $e');
      _errorMessage = '初始化生物识别失败: $e';
    }
  }

  /// 启用生物识别
  Future<bool> enable(String username, String password) async {
    try {
      _errorMessage = '';

      // 先检查设备是否支持
      if (!_canCheckBiometrics) {
        _errorMessage = '设备不支持生物识别';
        notifyListeners();
        return false;
      }

      if (!_hasEnrolledBiometrics) {
        _errorMessage = '请先在系统设置中注册指纹或人脸';
        notifyListeners();
        return false;
      }

      // 调用系统验证
      final didAuthenticate = await _auth.authenticate(
        localizedReason: '验证身份以启用生物识别登录',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false, // 允许 PIN 作为备选
        ),
      );

      if (didAuthenticate) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('biometric_enabled', true);
        await prefs.setString('biometric_username', username);
        await prefs.setString('biometric_password', password);
        _isBiometricEnabled = true;
        _lastUsername = username;
        _lastPassword = password;
        notifyListeners();
        return true;
      } else {
        _errorMessage = '验证失败';
        notifyListeners();
        return false;
      }
    } catch (e) {
      debugPrint('[biometric] enable error: $e');
      _errorMessage = '启用失败: $e';
      notifyListeners();
      return false;
    }
  }

  /// 禁用生物识别
  Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('biometric_enabled', false);
    await prefs.remove('biometric_username');
    await prefs.remove('biometric_password');
    _isBiometricEnabled = false;
    _lastUsername = '';
    _lastPassword = '';
    _errorMessage = '';
    notifyListeners();
  }

  /// 使用生物识别登录
  Future<Map<String, String>?> authenticate() async {
    if (!_isBiometricEnabled || !hasSavedCredentials) return null;
    try {
      _errorMessage = '';
      final didAuthenticate = await _auth.authenticate(
        localizedReason: '使用指纹或人脸登录',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false, // 允许 PIN 作为备选
        ),
      );
      if (didAuthenticate) {
        return {
          'username': _lastUsername,
          'password': _lastPassword,
        };
      }
    } catch (e) {
      debugPrint('[biometric] authenticate error: $e');
      _errorMessage = '验证失败: $e';
      notifyListeners();
    }
    return null;
  }

  /// 更新保存的密码（登录成功后调用）
  Future<void> updateCredentials(String username, String password) async {
    if (_isBiometricEnabled) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('biometric_username', username);
      await prefs.setString('biometric_password', password);
      _lastUsername = username;
      _lastPassword = password;
    }
  }

  /// 获取设备支持的生物识别类型
  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _auth.getAvailableBiometrics();
    } catch (e) {
      return [];
    }
  }

  /// 获取状态描述
  String getStatusDescription() {
    if (!_canCheckBiometrics) {
      return '设备不支持生物识别';
    }
    if (!_hasEnrolledBiometrics) {
      return '请先在系统设置中注册指纹或人脸';
    }
    if (_isBiometricEnabled) {
      return '已启用指纹/人脸登录';
    }
    return '可启用指纹/人脸登录';
  }
}
