import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../services/auth.dart';
import '../theme.dart';
import '../widgets/server_address_dialog.dart';
import 'login_page.dart' show friendlyLoginError;

/// 注册页（R-05 / R-09）
///
/// 邮箱 + 密码 + 确认密码 + 昵称（选填），**没有任何验证码/邮件激活环节**；
/// 注册成功直接进 `/overview`（后端注册接口直接下发 token）。
///
/// 校验规则与后端完全一致（PRD 4.1）：
/// - 邮箱：必填、形如 `a@b.c`、长度 ≤128，提交前 trim + 转小写；
/// - 密码：≥8 位且同时含字母与数字；
/// - 确认密码：与密码一致；
/// - 昵称：≤32 字，留空取邮箱 @ 前部分（由后端兜底，前端不传）。
///
/// 错误一律就地提示（字段下方 / 按钮上方），不整页刷新。
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _pwd = TextEditingController();
  final _pwd2 = TextEditingController();
  final _nick = TextEditingController();

  bool _busy = false;
  bool _showPwd = false;
  bool _showPwd2 = false;

  /// 服务端返回的、可定位到具体字段的错误（409「该邮箱已注册」等）
  String? _emailServerError;
  String? _pwdServerError;
  String? _pwd2ServerError;

  /// 无法定位到字段的错误（网络异常 / 其他后端文案）
  String? _err;

  /// 与后端一致的邮箱规则：`a@b.c`（不允许多个 @、不允许空白）
  static final RegExp _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void dispose() {
    _email.dispose();
    _pwd.dispose();
    _pwd2.dispose();
    _nick.dispose();
    super.dispose();
  }

  String _normEmail() => _email.text.trim().toLowerCase();

  // ------------------------------------------------------------------ 校验

  String? _validateEmail(String? v) {
    if (_emailServerError != null) return _emailServerError;
    final s = (v ?? '').trim().toLowerCase();
    if (s.isEmpty) return '请输入邮箱';
    if (s.length > 128) return '邮箱长度不能超过 128 个字符';
    if (!_emailRe.hasMatch(s)) return '邮箱格式不正确';
    return null;
  }

  String? _validatePwd(String? v) {
    if (_pwdServerError != null) return _pwdServerError;
    final s = v ?? '';
    if (s.isEmpty) return '请输入密码';
    if (s.length < 8) return '密码至少 8 位';
    final hasLetter = RegExp(r'[A-Za-z]').hasMatch(s);
    final hasDigit = RegExp(r'[0-9]').hasMatch(s);
    if (!hasLetter || !hasDigit) return '密码需同时包含字母和数字';
    return null;
  }

  String? _validatePwd2(String? v) {
    if (_pwd2ServerError != null) return _pwd2ServerError;
    if ((v ?? '').isEmpty) return '请再次输入密码';
    if (v != _pwd.text) return '两次输入的密码不一致';
    return null;
  }

  String? _validateNick(String? v) {
    final s = (v ?? '').trim();
    if (s.length > 32) return '昵称不能超过 32 个字符';
    return null;
  }

  // ------------------------------------------------------------------ 提交

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _emailServerError = null;
      _pwdServerError = null;
      _pwd2ServerError = null;
      _err = null;
    });
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    final nick = _nick.text.trim();
    try {
      final ok = await context.read<AuthState>().register(
            _normEmail(),
            _pwd.text,
            nickname: nick.isEmpty ? null : nick,
          ).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (ok) {
        // 注册接口已下发 token，AuthState 也已拉到 /auth/me → 直接进概览
        context.go('/overview');
        return;
      }
      setState(() {
        _applyServerMessage(
            context.read<AuthState>().lastLoginError ?? '注册失败，请稍后重试');
        _busy = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _err = '请求超时：请确认服务端地址可用（可点下方「服务端地址」修改）';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = friendlyLoginError(e);
        _busy = false;
      });
    }
  }

  /// 后端 message → 就地字段提示（无法定位的走顶部提示条）
  void _applyServerMessage(String msg) {
    final m = msg.trim();
    if (m.isEmpty) {
      _err = '注册失败，请稍后重试';
      return;
    }
    if (m.contains('已注册') || m.contains('邮箱')) {
      _emailServerError = m;
      return;
    }
    if (m.contains('密码') && m.contains('不一致')) {
      _pwd2ServerError = m;
      return;
    }
    if (m.contains('密码')) {
      _pwdServerError = m;
      return;
    }
    _err = m;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: AppTheme.text,
        elevation: 0,
        title: const Text('注册账号'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(22, 24, 22, 18),
                    decoration: BoxDecoration(
                      color: const Color(0xB30E0E14),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(
                        color: AppTheme.gold.withValues(alpha: 0.22),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.55),
                          blurRadius: 40,
                          offset: const Offset(0, 14),
                        ),
                      ],
                    ),
                    child: Form(
                      key: _formKey,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _GoldTitle('创建你的账本'),
                          const SizedBox(height: 6),
                          const Text(
                            '填好邮箱和密码就能开始记账',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.textDim),
                          ),
                          const SizedBox(height: 20),
                          TextFormField(
                            controller: _email,
                            keyboardType: TextInputType.emailAddress,
                            autocorrect: false,
                            textCapitalization: TextCapitalization.none,
                            textInputAction: TextInputAction.next,
                            // 输入即转小写（小写不改变长度，光标位置不受影响）；
                            // 空白在提交/校验时 trim —— 后端也会归一化，双保险
                            inputFormatters: [_LowerCaseFormatter()],
                            validator: _validateEmail,
                            onChanged: (_) {
                              if (_emailServerError != null) {
                                setState(() => _emailServerError = null);
                              }
                            },
                            decoration: const InputDecoration(
                              labelText: '邮箱',
                              hintText: 'you@example.com',
                              prefixIcon: Icon(Icons.alternate_email),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _pwd,
                            obscureText: !_showPwd,
                            autocorrect: false,
                            textInputAction: TextInputAction.next,
                            validator: _validatePwd,
                            onChanged: (_) {
                              if (_pwdServerError != null) {
                                setState(() => _pwdServerError = null);
                              }
                            },
                            decoration: InputDecoration(
                              labelText: '密码',
                              hintText: '至少 8 位，含字母和数字',
                              prefixIcon: const Icon(Icons.lock_outline),
                              suffixIcon: IconButton(
                                tooltip: _showPwd ? '隐藏密码' : '显示密码',
                                icon: Icon(_showPwd
                                    ? Icons.visibility
                                    : Icons.visibility_off),
                                onPressed: () =>
                                    setState(() => _showPwd = !_showPwd),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _pwd2,
                            obscureText: !_showPwd2,
                            autocorrect: false,
                            textInputAction: TextInputAction.next,
                            validator: _validatePwd2,
                            onChanged: (_) {
                              if (_pwd2ServerError != null) {
                                setState(() => _pwd2ServerError = null);
                              }
                            },
                            decoration: InputDecoration(
                              labelText: '确认密码',
                              prefixIcon: const Icon(Icons.lock_reset),
                              suffixIcon: IconButton(
                                tooltip: _showPwd2 ? '隐藏密码' : '显示密码',
                                icon: Icon(_showPwd2
                                    ? Icons.visibility
                                    : Icons.visibility_off),
                                onPressed: () =>
                                    setState(() => _showPwd2 = !_showPwd2),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _nick,
                            autocorrect: false,
                            textInputAction: TextInputAction.done,
                            validator: _validateNick,
                            onFieldSubmitted: (_) =>
                                _busy ? null : _submit(),
                            decoration: const InputDecoration(
                              labelText: '昵称（选填）',
                              hintText: '留空默认取邮箱 @ 前部分',
                              prefixIcon: Icon(Icons.badge_outlined),
                            ),
                          ),
                          const SizedBox(height: 14),
                          // 服务端地址：与登录页同一入口（本地联调 / 切云托管地址）
                          _ServerRow(),
                          if (_err != null) ...[
                            const SizedBox(height: 12),
                            _ErrorBox(text: _err!),
                          ],
                          const SizedBox(height: 18),
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
                                      '注册并进入',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.5,
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Center(
                            child: TextButton(
                              onPressed: _busy
                                  ? null
                                  : () {
                                      if (context.canPop()) {
                                        context.pop();
                                      } else {
                                        context.go('/login');
                                      }
                                    },
                              child: const Text(
                                '已有账号？返回登录',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 输入即转小写的格式化器（只用于邮箱框）
///
/// `toLowerCase()` 不会改变字符串长度，所以 [TextEditingValue.selection]
/// 仍然有效，光标不会跳。
class _LowerCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final lower = newValue.text.toLowerCase();
    if (lower == newValue.text) return newValue;
    return newValue.copyWith(text: lower);
  }
}

/// 金色渐变标题（与登录页同款视觉）
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

/// 服务端地址入口：点一下打开现有对话框（含扫码）
class _ServerRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final host = AppConfig.serverHost;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => showServerAddressDialog(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        ),
        child: Row(
          children: [
            const Icon(Icons.dns_outlined, size: 16, color: AppTheme.gold),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                host.replaceFirst(RegExp(r'^https?://'), ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, color: AppTheme.text),
              ),
            ),
            const Icon(Icons.edit_outlined, size: 14, color: AppTheme.textDim),
          ],
        ),
      ),
    );
  }
}

/// 无法定位到字段的错误提示条
class _ErrorBox extends StatelessWidget {
  final String text;
  const _ErrorBox({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0x26FF6B6B),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0x55FF6B6B)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFFF8A8A), size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Color(0xFFFFB4B4), fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
