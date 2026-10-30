import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../services/auth.dart';

class SplashPage extends StatefulWidget {
  const SplashPage({super.key});
  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late AnimationController _slideController;
  late AnimationController _orbController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim1;
  late Animation<Offset> _slideAnim2;

  @override
  void initState() {
    super.initState();

    // 文字淡入
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeController, curve: Curves.easeOut);

    // 第一行文字上移
    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _slideAnim1 = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic));
    _slideAnim2 = Tween<Offset>(
      begin: const Offset(0, 0.5),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic));

    // 背景光圈动画
    _orbController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat(reverse: true);

    // 启动动画序列
    _fadeController.forward();
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _slideController.forward();
    });

    // 3.5 秒后跳转
    Timer(const Duration(milliseconds: 3500), () {
      if (!mounted) return;
      final auth = context.read<AuthState>();
      if (auth.isLoggedIn) {
        context.go('/overview');
      } else {
        context.go('/login');
      }
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _slideController.dispose();
    _orbController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Stack(
        children: [
          // 白色背景
          Container(
            color: Colors.white,
          ),
          // 动态光圈（淡色）
          AnimatedBuilder(
            animation: _orbController,
            builder: (_, __) => _buildOrbs(),
          ),
          // 主内容
          Center(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Logo 图标
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          theme.colorScheme.primary,
                          theme.colorScheme.tertiary,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: theme.colorScheme.primary.withValues(alpha: 0.5),
                          blurRadius: 24,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/icon.ico',
                        width: 68,
                        height: 68,
                        fit: BoxFit.cover,
                        errorBuilder: (ctx, err, st) => const Icon(
                          Icons.account_balance_wallet_rounded,
                          size: 44,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  // 第一行：让财务透明
                  SlideTransition(
                    position: _slideAnim1,
                    child: Text(
                      '让财务透明',
                      style: TextStyle(
                        color: Colors.grey.shade800,
                        fontSize: 28,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 第二行：让资产永存
                  SlideTransition(
                    position: _slideAnim2,
                    child: Text(
                      '让资产永存',
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 28,
                        fontWeight: FontWeight.w300,
                        letterSpacing: 8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),
                  // 底部小字
                  FadeTransition(
                    opacity: _fadeAnim,
                    child: Text(
                      'Family Finance',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 13,
                        letterSpacing: 4,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOrbs() {
    return Stack(
      children: [
        Positioned(
          top: -100 + 40 * _orbController.value,
          right: -80,
          child: _orb(240, const Color(0xFF6C63FF).withValues(alpha: 0.08)),
        ),
        Positioned(
          bottom: -120 - 40 * _orbController.value,
          left: -80,
          child: _orb(280, const Color(0xFFE91E63).withValues(alpha: 0.06)),
        ),
        Positioned(
          top: 300 + 30 * _orbController.value,
          right: 100,
          child: _orb(160, const Color(0xFF00BCD4).withValues(alpha: 0.05)),
        ),
      ],
    );
  }

  Widget _orb(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
          stops: const [0.0, 1.0],
        ),
      ),
    );
  }
}
