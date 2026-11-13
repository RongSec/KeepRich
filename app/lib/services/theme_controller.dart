import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式（用户可选三档）：跟随系统 / 浅色 / 深色。
enum AppThemeMode {
  system('跟随系统', Icons.brightness_auto_outlined),
  light('浅色', Icons.light_mode_outlined),
  dark('深色', Icons.dark_mode_outlined);

  const AppThemeMode(this.label, this.icon);

  final String label;
  final IconData icon;

  ThemeMode get themeMode => switch (this) {
        AppThemeMode.system => ThemeMode.system,
        AppThemeMode.light => ThemeMode.light,
        AppThemeMode.dark => ThemeMode.dark,
      };

  static AppThemeMode fromName(String? v) => switch (v) {
        'light' => AppThemeMode.light,
        'dark' => AppThemeMode.dark,
        _ => AppThemeMode.system,
      };
}

/// 主题偏好控制器：保存/恢复三档主题选择（shared_preferences）。
class ThemeController extends ChangeNotifier {
  static const _kThemeMode = 'app_theme_mode';

  AppThemeMode _mode = AppThemeMode.system;

  AppThemeMode get mode => _mode;
  ThemeMode get themeMode => _mode.themeMode;

  /// 启动时读一次持久化值。读取失败（如 Web 无插件）保持默认不抛。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _mode = AppThemeMode.fromName(prefs.getString(_kThemeMode));
      notifyListeners();
    } catch (_) {
      // 持久化不可用时静默使用默认值
    }
  }

  Future<void> setMode(AppThemeMode m) async {
    if (_mode == m) return;
    _mode = m;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kThemeMode, m.name);
    } catch (_) {
      // 忽略持久化失败，仅本次会话生效
    }
  }
}
