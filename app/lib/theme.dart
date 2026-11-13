import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// 全局主题：支持「浅色 / 深色 / 跟随系统」三档。
///
/// 设计令牌（text/textDim/glass/line/bg 等）是**亮度感知**的运行时 getter：
/// 由 `MaterialApp.builder` 在每次构建时调用 [AppTheme.setBrightness] 注入当前亮度，
/// 因此旧的 `AppTheme.text` 用法无需改写即可随主题切换。品牌金 [gold] 系列保持
/// 常量（两套主题通用的强调色）。
class AppTheme {
  AppTheme._();

  // ---------------------------------------------------------------- 亮度状态
  static Brightness _brightness = Brightness.dark;

  /// 由 MaterialApp.builder 在构建期注入；主题切换后整树重建，令牌随之刷新。
  static void setBrightness(Brightness b) {
    _brightness = b;
  }

  static Brightness get brightness => _brightness;
  static bool get isDark => _brightness == Brightness.dark;

  // ------------------------------------------------------------ 品牌色（常量）
  /// 主金色（两套主题通用强调色）
  static const Color gold = Color(0xFFFFC65C);

  /// 浅金（高光）
  static const Color goldLight = Color(0xFFFFE3A3);

  /// 深金（描边 / 图标）
  static const Color goldDeep = Color(0xFFC8912F);

  // -------------------------------------------------- 设计令牌（亮度感知）
  /// 页面底色
  static Color get bg =>
      _isDark ? const Color(0xFF07070B) : const Color(0xFFF4F4F7);

  /// 卡片底色
  static Color get glass =>
      _isDark ? const Color(0xD912121A) : const Color(0xFFFFFFFF);

  /// 次级玻璃（输入框 / chip / 开关轨）
  static Color get glassSoft =>
      _isDark ? const Color(0x1AFFFFFF) : const Color(0xFFF0F0F4);

  /// 主文字
  static Color get text =>
      _isDark ? const Color(0xFFF3EFE6) : const Color(0xFF17171C);

  /// 次文字
  static Color get textDim =>
      _isDark ? const Color(0xFFA9A498) : const Color(0xFF77777F);

  /// 分割线
  static Color get line =>
      _isDark ? const Color(0x1FFFFFFF) : const Color(0xFFE4E4EA);

  /// 卡片边框
  static Color get cardBorder =>
      _isDark ? Colors.white.withValues(alpha: 0.08) : const Color(0xFFE8E8EE);

  static bool get _isDark => _brightness == Brightness.dark;

  /// 卡片统一形状
  static BoxDecoration glassCard({double radius = 20, Color? color}) =>
      BoxDecoration(
        color: color ?? glass,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: cardBorder, width: 1),
        boxShadow: [
          BoxShadow(
            color: _isDark
                ? Colors.black.withValues(alpha: 0.45)
                : const Color(0xFF9A9AA8).withValues(alpha: 0.16),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      );

  // ---------------------------------------------------------------- 主题构建
  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      primary: gold,
      onPrimary: Color(0xFF231A05),
      primaryContainer: Color(0xFF3A2A08),
      onPrimaryContainer: goldLight,
      secondary: goldLight,
      onSecondary: Color(0xFF231A05),
      tertiary: goldDeep,
      onTertiary: Color(0xFF231A05),
      surface: Color(0xFF12121A),
      onSurface: Color(0xFFF3EFE6),
      surfaceContainerHighest: Color(0xFF1C1C26),
      outline: Color(0xFF6F6A5E),
      error: Color(0xFFFF6B6B),
      onError: Colors.white,
    );

    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: Brightness.dark,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      // 半透明暗底：列表文字要有落脚处，同时让金沙隐约透上来。
      // 登录页/开屏页需要全透明，自己用 Scaffold(backgroundColor: transparent) 覆盖。
      scaffoldBackgroundColor: const Color(0xB80A0A10),
      canvasColor: const Color(0xB80A0A10),
    );

    return base.copyWith(
      textTheme: GoogleFonts.notoSansScTextTheme(base.textTheme).apply(
        bodyColor: const Color(0xFFF3EFE6),
        displayColor: const Color(0xFFF3EFE6),
      ),
      iconTheme: const IconThemeData(color: Color(0xFFA9A498)),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: const Color(0xFFF3EFE6),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.notoSansSc(
          color: const Color(0xFFF3EFE6),
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: const Color(0xD912121A),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF17171F),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: GoogleFonts.notoSansSc(
          color: const Color(0xFFF3EFE6),
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: GoogleFonts.notoSansSc(
            color: const Color(0xFFA9A498), fontSize: 14),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF15151D),
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Color(0xFF15151D),
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0x1FFFFFFF),
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: gold,
          foregroundColor: const Color(0xFF231A05),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: gold),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: goldLight,
          side: BorderSide(color: gold.withValues(alpha: 0.45)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0x1AFFFFFF),
        labelStyle: const TextStyle(color: Color(0xFFA9A498)),
        hintStyle: const TextStyle(color: Color(0x66A9A498)),
        prefixIconColor: const Color(0xFFA9A498),
        suffixIconColor: const Color(0xFFA9A498),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: gold, width: 1.6),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xE60C0C12),
        surfaceTintColor: Colors.transparent,
        indicatorColor: gold.withValues(alpha: 0.18),
        height: 70,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(color: Color(0xFFA9A498), fontSize: 12),
        ),
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Color(0xE60C0C12),
        indicatorColor: Color(0x2EFFC65C),
        selectedIconTheme: IconThemeData(color: gold),
        unselectedIconTheme: IconThemeData(color: Color(0xFFA9A498)),
        selectedLabelTextStyle: TextStyle(color: gold, fontSize: 12),
        unselectedLabelTextStyle:
            TextStyle(color: Color(0xFFA9A498), fontSize: 12),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF25252F),
        contentTextStyle: const TextStyle(color: Color(0xFFF3EFE6)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: const Color(0x1AFFFFFF),
        selectedColor: gold.withValues(alpha: 0.25),
        labelStyle: const TextStyle(color: Color(0xFFF3EFE6), fontSize: 13),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) ? gold : const Color(0xFF6B6B72),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? gold.withValues(alpha: 0.35)
              : Colors.white.withValues(alpha: 0.12),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: gold),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF25252F),
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: const TextStyle(color: Color(0xFFF3EFE6), fontSize: 12),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: Color(0xFFA9A498),
        textColor: Color(0xFFF3EFE6),
      ),
    );
  }

  /// 浅色主题：结构与深色一致，表面/文字换浅色系，品牌金保留。
  static ThemeData light() {
    const scheme = ColorScheme.light(
      primary: Color(0xFFB7851F),
      onPrimary: Colors.white,
      primaryContainer: Color(0xFFFFF3D9),
      onPrimaryContainer: Color(0xFF6B4A08),
      secondary: Color(0xFFB7851F),
      onSecondary: Colors.white,
      tertiary: goldDeep,
      onTertiary: Colors.white,
      surface: Color(0xFFFFFFFF),
      onSurface: Color(0xFF17171C),
      surfaceContainerHighest: Color(0xFFF4F4F8),
      outline: Color(0xFFB9B9C2),
      error: Color(0xFFD5303B),
      onError: Colors.white,
    );

    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: Brightness.light,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      scaffoldBackgroundColor: const Color(0xFFF4F4F7),
      canvasColor: const Color(0xFFF4F4F7),
    );

    return base.copyWith(
      textTheme: GoogleFonts.notoSansScTextTheme(base.textTheme).apply(
        bodyColor: const Color(0xFF17171C),
        displayColor: const Color(0xFF17171C),
      ),
      iconTheme: const IconThemeData(color: Color(0xFF77777F)),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: const Color(0xFF17171C),
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.notoSansSc(
          color: const Color(0xFF17171C),
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFE8E8EE)),
        ),
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: GoogleFonts.notoSansSc(
          color: const Color(0xFF17171C),
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: GoogleFonts.notoSansSc(
            color: const Color(0xFF77777F), fontSize: 14),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Colors.white,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFFE4E4EA),
        thickness: 1,
        space: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFB7851F),
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: const Color(0xFFB7851F)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF8A6413),
          side: const BorderSide(color: Color(0xFFD9BC7F)),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFF0F0F4),
        labelStyle: const TextStyle(color: Color(0xFF77777F)),
        hintStyle: const TextStyle(color: Color(0x8C77777F)),
        prefixIconColor: const Color(0xFF77777F),
        suffixIconColor: const Color(0xFF77777F),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFE4E4EA)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFE4E4EA)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFFB7851F), width: 1.6),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xF7FFFFFF),
        surfaceTintColor: Colors.transparent,
        indicatorColor: const Color(0xFFB7851F).withValues(alpha: 0.16),
        height: 70,
        labelTextStyle: WidgetStateProperty.all(
          const TextStyle(color: Color(0xFF77777F), fontSize: 12),
        ),
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Color(0xF7FFFFFF),
        indicatorColor: Color(0x2EB7851F),
        selectedIconTheme: IconThemeData(color: Color(0xFFB7851F)),
        unselectedIconTheme: IconThemeData(color: Color(0xFF77777F)),
        selectedLabelTextStyle:
            TextStyle(color: Color(0xFFB7851F), fontSize: 12),
        unselectedLabelTextStyle:
            TextStyle(color: Color(0xFF77777F), fontSize: 12),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF2B2B33),
        contentTextStyle: const TextStyle(color: Colors.white),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: const Color(0xFFF0F0F4),
        selectedColor: const Color(0xFFB7851F).withValues(alpha: 0.18),
        labelStyle: const TextStyle(color: Color(0xFF17171C), fontSize: 13),
        side: const BorderSide(color: Color(0xFFE4E4EA)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? const Color(0xFFB7851F)
              : const Color(0xFF9A9AA6),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? const Color(0xFFB7851F).withValues(alpha: 0.35)
              : const Color(0xFFDDDEE4),
        ),
      ),
      progressIndicatorTheme:
          const ProgressIndicatorThemeData(color: Color(0xFFB7851F)),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: const Color(0xFF2B2B33),
          borderRadius: BorderRadius.circular(10),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: Color(0xFF77777F),
        textColor: Color(0xFF17171C),
      ),
    );
  }
}
