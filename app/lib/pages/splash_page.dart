import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../services/auth.dart';
import '../theme.dart';

/// 开屏页：金币池全景 + 金色标语（背景由全局 CoinPoolBackground 提供）
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});
  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late AnimationController _slideController;
  late AnimationController _ringController;
  late Animation<double> _fadeAnim;
  late Animation<Offset> _slideAnim1;
  late Animation<Offset> _slideAnim2;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeController, curve: Curves.easeOut);

    _slideController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _slideAnim1 = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(
        CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic));
    _slideAnim2 = Tween<Offset>(
      begin: const Offset(0, 0.5),
      end: Offset.zero,
    ).animate(
        CurvedAnimation(parent: _slideController, curve: Curves.easeOutCubic));

    _ringController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();

    _fadeController.forward();
    Future.delayed(const Duration(milliseconds: 300), () {
      if (mounted) _slideController.forward();
    });

    // 3.2 秒后跳转
    Timer(const Duration(milliseconds: 3200), () {
      if (!mounted) return;
      final auth = context.read<AuthState>();
      context.go(auth.isLoggedIn ? '/overview' : '/login');
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _slideController.dispose();
    _ringController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 中心压暗，保证金色标语在金币堆上依然可读
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 0.8,
                colors: [
                  Color(0xC407070B),
                  Color(0x8C07070B),
                  Color(0x0007070B),
                ],
                stops: [0.0, 0.55, 1.0],
              ),
            ),
          ),
          Center(
            child: FadeTransition(
              opacity: _fadeAnim,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedBuilder(
                    animation: _ringController,
                    builder: (_, __) => Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SweepGradient(
                          transform:
                              GradientRotation(_ringController.value * 6.283),
                          colors: const [
                            Color(0xFFFFE9B8),
                            Color(0xFFC8912F),
                            Color(0xFFFFC65C),
                            Color(0xFFC8912F),
                            Color(0xFFFFE9B8),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppTheme.gold.withValues(alpha: 0.45),
                            blurRadius: 30,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(3),
                      child: Container(
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Color(0xFF101018),
                        ),
                        padding: const EdgeInsets.all(12),
                        // 图标解码完成前先垫一个金色存钱罐，避免出现黑圈
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const Icon(Icons.savings_rounded,
                                color: AppTheme.goldDeep),
                            Image.asset(
                              'assets/images/icon.png',
                              fit: BoxFit.contain,
                              errorBuilder: (ctx, err, st) =>
                                  const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  SlideTransition(
                    position: _slideAnim1,
                    child: _goldText('让财务透明', 28),
                  ),
                  const SizedBox(height: 10),
                  SlideTransition(
                    position: _slideAnim2,
                    child: _goldText('让资产永存', 28),
                  ),
                  const SizedBox(height: 46),
                  FadeTransition(
                    opacity: _fadeAnim,
                    child: Text(
                      'F A M I L Y   F I N A N C E',
                      style: TextStyle(
                        color: AppTheme.gold.withValues(alpha: 0.55),
                        fontSize: 11,
                        letterSpacing: 4,
                        fontWeight: FontWeight.w500,
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

  Widget _goldText(String text, double size) {
    // 继承主题字体（Noto Sans SC），否则首帧可能回退成无中文字形的字体
    final base = Theme.of(context).textTheme.headlineMedium;
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => const LinearGradient(
        colors: [Color(0xFFFFEFC8), Color(0xFFFFC65C), Color(0xFFD9A03A)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(rect),
      child: Text(
        text,
        style: base?.copyWith(
              fontSize: size,
              fontWeight: FontWeight.w300,
              letterSpacing: 8,
            ) ??
            TextStyle(fontSize: size, letterSpacing: 8),
      ),
    );
  }
}
