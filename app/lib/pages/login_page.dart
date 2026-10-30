import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../services/auth.dart';
import '../services/biometric.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with SingleTickerProviderStateMixin {
  final _user = TextEditingController();
  final _pwd = TextEditingController();
  final _mfa = TextEditingController();
  bool _busy = false;
  bool _showPwd = false;
  String? _err;
  late AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _anim.dispose();
    _user.dispose();
    _pwd.dispose();
    _mfa.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final ok = await context.read<AuthState>().login(
            _user.text.trim(),
            _pwd.text,
            mfaCode: _mfa.text.trim().isEmpty ? null : _mfa.text.trim(),
          ).timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (ok) {
        // 登录成功，保存凭据供生物识别使用
        final biometric = context.read<BiometricService>();
        await biometric.updateCredentials(_user.text.trim(), _pwd.text);
        context.go('/overview');
        return;
      }
      setState(() {
        _err = '登录失败，请检查账号、密码或 MFA';
        _busy = false;
      });
    } on TimeoutException {
      // 超时后不再等待迟到的登录结果，避免状态被覆盖（竞态）
      if (!mounted) return;
      setState(() {
        _err = '登录超时，请检查网络连接';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '登录失败: $e';
        _busy = false;
      });
    }
  }

  Future<void> _biometricLogin() async {
    final biometric = context.read<BiometricService>();
    if (!biometric.canCheckBiometrics || !biometric.hasSavedCredentials) return;

    setState(() {
      _busy = true;
      _err = null;
    });

    try {
      final credentials = await biometric.authenticate();
      if (credentials == null) {
        setState(() => _busy = false);
        return;
      }

      _user.text = credentials['username']!;
      _pwd.text = credentials['password']!;

      final ok = await context.read<AuthState>().login(
            credentials['username']!,
            credentials['password']!,
          ).timeout(
            const Duration(seconds: 15),
            onTimeout: () {
              if (mounted) {
                setState(() {
                  _err = '登录超时，请检查网络连接';
                  _busy = false;
                });
              }
              return false;
            },
          );

      if (!mounted) return;
      if (ok) {
        context.go('/overview');
      } else {
        setState(() => _err = '生物识别登录失败，请使用密码登录');
      }
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = '生物识别失败: $e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Stack(
        children: [
          // 渐变背景
          const _GradientBackground(),
          // 装饰光圈（动画）
          AnimatedBuilder(
            animation: _anim,
            builder: (_, __) {
              return _Orbs(anim: _anim);
            },
          ),
          // 登录主体
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 440),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 玻璃卡片
                      ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(28, 32, 28, 24),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.78),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: Colors.white.withValues(alpha: 0.6), width: 1),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.08),
                                  blurRadius: 30,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Center(
                                  child: Container(
                                    width: 80,
                                    height: 80,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: LinearGradient(
                                        colors: [theme.colorScheme.primary, theme.colorScheme.secondary],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: theme.colorScheme.primary.withValues(alpha: 0.4),
                                          blurRadius: 18,
                                          spreadRadius: 1,
                                        ),
                                      ],
                                    ),
                                    child: ClipOval(
                                      child: Image.asset(
                                        'assets/images/icon.ico',
                                        width: 60,
                                        height: 60,
                                        fit: BoxFit.cover,
                                        errorBuilder: (ctx, err, st) => const Icon(Icons.account_balance_wallet_rounded, size: 40, color: Colors.white),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 18),
                                Text('噜噜和噜妹的小金库',
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.2,
                                    )),
                                const SizedBox(height: 4),
                                Text('让每一分储蓄都看得见',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyMedium?.copyWith(color: Colors.black54)),
                                const SizedBox(height: 28),
                                TextField(
                                  controller: _user,
                                  decoration: InputDecoration(
                                    labelText: '账号',
                                    hintText: '用户名 / 邮箱',
                                    prefixIcon: const Icon(Icons.person_outline),
                                    filled: true,
                                    fillColor: Colors.white,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _pwd,
                                  obscureText: !_showPwd,
                                  decoration: InputDecoration(
                                    labelText: '密码',
                                    prefixIcon: const Icon(Icons.lock_outline),
                                    suffixIcon: IconButton(
                                      icon: Icon(_showPwd ? Icons.visibility : Icons.visibility_off),
                                      onPressed: () => setState(() => _showPwd = !_showPwd),
                                    ),
                                    filled: true,
                                    fillColor: Colors.white,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextField(
                                  controller: _mfa,
                                  decoration: InputDecoration(
                                    labelText: 'MFA 验证码（可选）',
                                    prefixIcon: const Icon(Icons.shield_outlined),
                                    filled: true,
                                    fillColor: Colors.white,
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(14),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                                if (_err != null) ...[
                                  const SizedBox(height: 12),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: Colors.red.withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Row(children: [
                                      const Icon(Icons.error_outline, color: Colors.red, size: 18),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text(_err!, style: const TextStyle(color: Colors.red))),
                                    ]),
                                  ),
                                ],
                                const SizedBox(height: 24),
                                FilledButton(
                                  onPressed: _busy ? null : _submit,
                                  style: FilledButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                    backgroundColor: theme.colorScheme.primary,
                                  ),
                                  child: _busy
                                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                      : const Text('登 录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, letterSpacing: 2)),
                                ),
                                // 生物识别登录按钮
                                Consumer<BiometricService>(
                                  builder: (ctx, biometric, _) {
                                    if (!biometric.canCheckBiometrics || !biometric.hasSavedCredentials) {
                                      return const SizedBox.shrink();
                                    }
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 16),
                                      child: InkWell(
                                        onTap: _busy ? null : _biometricLogin,
                                        borderRadius: BorderRadius.circular(12),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                                          decoration: BoxDecoration(
                                            border: Border.all(color: Colors.grey.shade300),
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              Icon(Icons.fingerprint, color: theme.colorScheme.primary, size: 24),
                                              const SizedBox(width: 8),
                                              Text('指纹 / 人脸登录', style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w500)),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                                const SizedBox(height: 12),
                                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                                  Icon(Icons.lock_clock, size: 14, color: theme.colorScheme.outline),
                                  const SizedBox(width: 4),
                                  Text('所有数据加密传输，登录即可访问', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                                ]),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GradientBackground extends StatelessWidget {
  const _GradientBackground();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFEEF2FF), Color(0xFFFAE8FF), Color(0xFFFCE7F3)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
    );
  }
}

class _Orbs extends StatelessWidget {
  final Animation<double> anim;
  const _Orbs({required this.anim});
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: -80 - 30 * anim.value,
          right: -60,
          child: _orb(180, const Color(0xFFA78BFA).withValues(alpha: 0.4)),
        ),
        Positioned(
          bottom: -100 + 30 * anim.value,
          left: -60,
          child: _orb(220, const Color(0xFFF472B6).withValues(alpha: 0.35)),
        ),
        Positioned(
          top: 200 - 20 * anim.value,
          right: 80,
          child: _orb(120, const Color(0xFF60A5FA).withValues(alpha: 0.3)),
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
