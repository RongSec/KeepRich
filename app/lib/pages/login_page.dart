import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../config.dart';
import '../services/auth.dart';
import '../services/biometric.dart';
import '../theme.dart';
import '../widgets/server_address_dialog.dart';
import '../widgets/update_banner.dart';

/// 登录页：一块金边玻璃卡片浮在金币池上
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  final _user = TextEditingController();
  final _pwd = TextEditingController();
  final _mfa = TextEditingController();
  bool _busy = false;
  bool _showPwd = false;
  String? _err;
  int _loginFails = 0; // 连续失败次数：≥3 时显示 MFA 验证码输入框
  late AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);
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
      final ok = await context
          .read<AuthState>()
          .login(
            _user.text.trim(),
            _pwd.text,
            mfaCode: _mfa.text.trim().isEmpty ? null : _mfa.text.trim(),
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (ok) {
        // 登录成功，保存凭据供生物识别使用
        final biometric = context.read<BiometricService>();
        await biometric.updateCredentials(_user.text.trim(), _pwd.text);
        _loginFails = 0;
        context.go('/overview');
        return;
      }
      setState(() {
        _err = context.read<AuthState>().lastLoginError ??
            '登录失败，请检查账号、密码或 MFA';
        _busy = false;
        _loginFails++;
      });
    } on TimeoutException {
      // 超时后不再等待迟到的登录结果，避免状态被覆盖（竞态）
      if (!mounted) return;
      setState(() {
        _err = '登录超时，请检查网络或服务端地址';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = friendlyLoginError(e);
        _busy = false;
        _loginFails++;
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

      final ok = await context
          .read<AuthState>()
          .login(
            credentials['username']!,
            credentials['password']!,
          )
          .timeout(
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
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const WebUpdateBanner(),
                  const SizedBox(height: 8),
                  // 玻璃卡片
                  ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(24, 30, 24, 22),
                        decoration: BoxDecoration(
                          color: const Color(0xB30E0E14),
                          borderRadius: BorderRadius.circular(26),
                          border: Border.all(
                            color: AppTheme.gold.withValues(alpha: 0.22),
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.55),
                              blurRadius: 40,
                              offset: const Offset(0, 14),
                            ),
                            BoxShadow(
                              color: AppTheme.gold.withValues(alpha: 0.10),
                              blurRadius: 60,
                              spreadRadius: -12,
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Center(child: _Logo(anim: _anim)),
                            const SizedBox(height: 20),
                            _GoldTitle('让财务透明，资产永存'),
                            const SizedBox(height: 22),
                            TextField(
                              controller: _user,
                              autocorrect: false,
                              textInputAction: TextInputAction.next,
                              decoration: const InputDecoration(
                                labelText: '账号',
                                hintText: '用户名 / 邮箱',
                                prefixIcon: Icon(Icons.person_outline),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _pwd,
                              obscureText: !_showPwd,
                              textInputAction: TextInputAction.next,
                              decoration: InputDecoration(
                                labelText: '密码',
                                prefixIcon: const Icon(Icons.lock_outline),
                                suffixIcon: IconButton(
                                  icon: Icon(_showPwd
                                      ? Icons.visibility
                                      : Icons.visibility_off),
                                  onPressed: () =>
                                      setState(() => _showPwd = !_showPwd),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            // MFA 验证码：默认不出现，连续登录失败 3 次后才要求
                            if (_loginFails >= 3)
                              TextField(
                                controller: _mfa,
                                decoration: const InputDecoration(
                                  labelText: 'MFA 验证码',
                                  prefixIcon: Icon(Icons.shield_outlined),
                                ),
                              ),
                            if (_err != null) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 9),
                                decoration: BoxDecoration(
                                  color: const Color(0x26FF6B6B),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: const Color(0x55FF6B6B),
                                  ),
                                ),
                                child: Row(children: [
                                  const Icon(Icons.error_outline,
                                      color: Color(0xFFFF8A8A), size: 18),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _err!,
                                      style: const TextStyle(
                                          color: Color(0xFFFFB4B4),
                                          fontSize: 13),
                                    ),
                                  ),
                                ]),
                              ),
                            ],
                            const SizedBox(height: 22),
                            SizedBox(
                              height: 50,
                              child: FilledButton(
                                onPressed: _busy ? null : _submit,
                                child: _busy
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Color(0xFF231A05),
                                        ),
                                      )
                                    : const Text(
                                        '登 录',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 3,
                                        ),
                                      ),
                              ),
                            ),
                            // 生物识别登录
                            Consumer<BiometricService>(
                              builder: (ctx, biometric, _) {
                                if (!biometric.canCheckBiometrics ||
                                    !biometric.hasSavedCredentials) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: InkWell(
                                    onTap: _busy ? null : _biometricLogin,
                                    borderRadius: BorderRadius.circular(14),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(14),
                                        border: Border.all(
                                          color: Colors.white
                                              .withValues(alpha: 0.12),
                                        ),
                                      ),
                                      child: const Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.fingerprint,
                                              color: AppTheme.gold, size: 22),
                                          SizedBox(width: 8),
                                          Text(
                                            '指纹 / 人脸登录',
                                            style: TextStyle(
                                              color: AppTheme.goldLight,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.lock_clock,
                                    size: 13, color: AppTheme.textDim),
                                const SizedBox(width: 4),
                                Text(
                                  '数据加密传输',
                                  style: const TextStyle(
                                      fontSize: 11, color: AppTheme.textDim),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  // 服务端地址（本地联调时点这里切换）
                  _ServerChip(),
                  // Web 端展示服务端二维码：手机 App 扫码即可自动填入地址
                  if (kIsWeb) ...[
                    const SizedBox(height: 16),
                    const _ServerQrCard(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 金色渐变标题
class _GoldTitle extends StatelessWidget {
  final String text;
  const _GoldTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (rect) => const LinearGradient(
        colors: [Color(0xFFFFE9B8), Color(0xFFFFC65C), Color(0xFFD79A32)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(rect),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 19,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

/// 旋转光环 + 图标
class _Logo extends StatelessWidget {
  final Animation<double> anim;
  const _Logo({required this.anim});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: anim,
      builder: (_, __) {
        return Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              transform: GradientRotation(anim.value * 6.283),
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
                color: AppTheme.gold.withValues(alpha: 0.35),
                blurRadius: 22,
                spreadRadius: -2,
              ),
            ],
          ),
          padding: const EdgeInsets.all(3),
          child: Container(
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              // 金色底：图标圆形裁剪后贴满，方形位图不再露出深色圆底"黑边"
              color: Color(0xFFFFC65C),
            ),
            padding: const EdgeInsets.all(8),
            child: ClipOval(
              child: Image.asset(
                'assets/images/icon.png',
                fit: BoxFit.cover,
                errorBuilder: (ctx, err, st) => const SizedBox.shrink(),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 底部服务端地址指示（点击修改）
class _ServerChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final host = AppConfig.serverHost;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => showServerAddressDialog(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xB3000000),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.gold.withValues(alpha: 0.22)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 10,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.dns_outlined, size: 14, color: AppTheme.gold),
            const SizedBox(width: 6),
            Text(
              host.replaceFirst(RegExp(r'^https?://'), ''),
              style: const TextStyle(fontSize: 11, color: AppTheme.text),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.edit_outlined, size: 12, color: AppTheme.textDim),
          ],
        ),
      ),
    );
  }
}

/// Web 端专属：把当前服务端地址（含分享码）画成二维码，
/// 手机 App 在「服务端地址 → 扫码」里扫一下即可自动填入。
class _ServerQrCard extends StatelessWidget {
  const _ServerQrCard();

  @override
  Widget build(BuildContext context) {
    // 完整 URL（含 ?sharecode=），去掉路由 hash 让二维码内容干净：
    // App 扫码后会截断 query 取地址、单独提取 sharecode
    var data = Uri.base.toString();
    final hashIdx = data.indexOf('#');
    if (hashIdx >= 0) data = data.substring(0, hashIdx);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          QrImageView(
            data: data,
            size: 132,
            backgroundColor: Colors.white,
            eyeStyle: const QrEyeStyle(color: Color(0xFF1A1A1A)),
            dataModuleStyle: const QrDataModuleStyle(color: Color(0xFF1A1A1A)),
          ),
          const SizedBox(height: 8),
          const Text(
            '手机 App 扫码连接此服务',
            style: TextStyle(fontSize: 12, color: Color(0xFF5A4A22)),
          ),
        ],
      ),
    );
  }
}

/// 把登录异常翻译成用户能直接行动的提示。
///
/// 实测两类高频坑：
/// 1. 服务端地址连不上（默认 10.0.2.2:28080 在真机上无意义）
/// 2. 云托管地址缺 ?sharecode= → 网关返回 403 的 HTML 页 → dio 把 body
///    落成 String → type cast 错误（对用户完全不可读）
String friendlyLoginError(Object e) {
  final s = e.toString();
  if (s.contains('Connection refused') ||
      s.contains('Failed host lookup') ||
      s.contains('Network is unreachable') ||
      s.contains('connection error') ||
      s.contains('Connection timed out')) {
    return '无法连接服务端：请点击底部地址栏确认服务端地址'
        '（真机上默认的 10.0.2.2 不可用，请填云托管地址或电脑局域网 IP）';
  }
  if (s.contains('not a subtype') || s.contains('type cast')) {
    return '服务端返回异常：云托管地址必须附带 ?sharecode=分享码，'
        '请在「服务端地址」里填入完整地址，或直接扫描 Web 端登录页的二维码';
  }
  return '登录失败: $e';
}
