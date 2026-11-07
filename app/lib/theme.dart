import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// 全局主题：深色 + 金色，界面元素以「半透明玻璃」浮在金币池背景之上
class AppTheme {
  AppTheme._();

  // ---------------------------------------------------------------- 设计令牌
  /// 主金色
  static const Color gold = Color(0xFFFFC65C);

  /// 浅金（高光）
  static const Color goldLight = Color(0xFFFFE3A3);

  /// 深金（描边 / 图标）
  static const Color goldDeep = Color(0xFFC8912F);

  /// 页面底色（与金币池背景同色，保证过渡没有色块）
  static const Color bg = Color(0xFF07070B);

  /// 玻璃卡片底色
  static const Color glass = Color(0xD912121A);

  /// 次级玻璃（输入框 / chip）
  static const Color glassSoft = Color(0x1AFFFFFF);

  /// 主文字
  static const Color text = Color(0xFFF3EFE6);

  /// 次文字
  static const Color textDim = Color(0xFFA9A498);

  /// 分割线
  static const Color line = Color(0x1FFFFFFF);

  /// 卡片统一形状
  static BoxDecoration glassCard({double radius = 20, Color? color}) =>
      BoxDecoration(
        color: color ?? glass,
        borderRadius: BorderRadius.circular(radius),
        border:
            Border.all(color: Colors.white.withValues(alpha: 0.08), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      );

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
      onSurface: text,
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
        bodyColor: text,
        displayColor: text,
      ),
      iconTheme: const IconThemeData(color: textDim),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: text,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.notoSansSc(
          color: text,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: glass,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        margin: EdgeInsets.zero,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: const Color(0xFF17171F),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: GoogleFonts.notoSansSc(
          color: text,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: GoogleFonts.notoSansSc(color: textDim, fontSize: 14),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF15151D),
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: Color(0xFF15151D),
      ),
      dividerTheme: const DividerThemeData(color: line, thickness: 1, space: 1),
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
        fillColor: glassSoft,
        labelStyle: const TextStyle(color: textDim),
        hintStyle: const TextStyle(color: Color(0x66A9A498)),
        prefixIconColor: textDim,
        suffixIconColor: textDim,
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
          const TextStyle(color: textDim, fontSize: 12),
        ),
      ),
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: Color(0xE60C0C12),
        indicatorColor: Color(0x2EFFC65C),
        selectedIconTheme: IconThemeData(color: gold),
        unselectedIconTheme: IconThemeData(color: textDim),
        selectedLabelTextStyle: TextStyle(color: gold, fontSize: 12),
        unselectedLabelTextStyle: TextStyle(color: textDim, fontSize: 12),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xFF25252F),
        contentTextStyle: const TextStyle(color: text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      chipTheme: base.chipTheme.copyWith(
        backgroundColor: glassSoft,
        selectedColor: gold.withValues(alpha: 0.25),
        labelStyle: const TextStyle(color: text, fontSize: 13),
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
        textStyle: const TextStyle(color: text, fontSize: 12),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: textDim,
        textColor: text,
      ),
    );
  }

  /// 兼容旧调用（早期版本有 light/dark 两套，现在统一深色）
  static ThemeData light() => dark();
}
