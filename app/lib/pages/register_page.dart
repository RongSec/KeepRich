import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../services/auth.dart';
import '../theme.dart';
import '../utils/display_name.dart';
import '../widgets/server_address_dialog.dart';
import 'login_page.dart' show friendlyLoginError;

/// 邀请码归一化：trim → 去所有空白与连字符 → 全大写。
/// `k7qx-9mrt` 与 `K7QX9MRT` 等价（PRD R-08 ② / 后端 NormalizeInviteCode）。
String normalizeInviteCode(String input) =>
    input.toUpperCase().replaceAll(RegExp(r'[\s\-]'), '');

/// 注册页（v0.5.0 单页表单）：邀请码 → 用户名 → 昵称 → 密码 → 确认密码 → 邮箱（选填）。
///
/// 单页提交、没有任何发信或二次确认环节；成功后后端直接下发 token，
/// `AuthState.register` 已拉到 /auth/me，因此直接 `context.go('/overview')`。
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _invite = TextEditingController();
  final _username = TextEditingController();
  final _nick = TextEditingController();
  final _pwd = TextEditingController();
  final _pwd2 = TextEditingController();
  final _email = TextEditingController();

  bool _busy = false;
  bool _showPwd = false;
  bool _showPwd2 = false;

  // 服务端返回、可定位到具体字段的错误（一次只提示一个字段，不叠加红字）。
  String? _inviteServerError;
  String? _usernameServerError;
  String? _nickServerError;
  String? _pwdServerError;
  String? _pwd2ServerError;
  String? _emailServerError;

  /// 无法定位到字段的错误（频控 / 网络 / 兜底）。
  String? _err;

  /// 与后端 `inviteCodeAlphabet` 完全一致（剔除 0/O/1/I/L）。
  static const String _inviteAlphabet =
      '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  static final RegExp _emailRe =
      RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  static final RegExp _usernameRe =
      RegExp(r'^[A-Za-z][A-Za-z0-9_]{3,19}$');

  @override
  void dispose() {
    _invite.dispose();
    _username.dispose();
    _nick.dispose();
    _pwd.dispose();
    _pwd2.dispose();
    _email.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ 校验

  String? _validateInvite(String? v) {
    if (_inviteServerError != null) return _inviteServerError;
    final s = normalizeInviteCode(v ?? '');
    if (s.isEmpty) return '请输入邀请码';
    if (s.length != 8) return '邀请码格式不正确';
    for (final unit in s.codeUnits) {
      if (!_inviteAlphabet.codeUnits.contains(unit)) {
        return '邀请码格式不正确';
      }
    }
    return null;
  }

  String? _validateUsername(String? v) {
    if (_usernameServerError != null) return _usernameServerError;
    final s = (v ?? '').trim().toLowerCase();
    if (s.isEmpty) return '请输入用户名';
    if (s.runes.any((r) => r > 127)) {
      return '用户名只能使用英文字母、数字和下划线，不能用中文';
    }
    if (s.length < 4 || s.length > 20) return '用户名需要 4 到 20 位';
    if (!s.startsWith(RegExp(r'[A-Za-z]'))) {
      return '用户名必须以英文字母开头';
    }
    if (!_usernameRe.hasMatch(s)) {
      return '用户名只能使用英文字母、数字和下划线';
    }
    return null;
  }

  String? _validateNick(String? v) {
    if (_nickServerError != null) return _nickServerError;
    // 与后端 ValidateNickname 及账号安全页共用同一条规则，避免文案漂移。
    return nicknameError(v);
  }

  String? _validatePwd(String? v) {
    if (_pwdServerError != null) return _pwdServerError;
    final s = v ?? '';
    if (s.isEmpty) return '请输入密码';
    if (s.length < 8) return '密码至少 8 位';
    if (!RegExp(r'[A-Za-z]').hasMatch(s) ||
        !RegExp(r'[0-9]').hasMatch(s)) {
      return '密码需同时包含字母和数字';
    }
    return null;
  }

  String? _validatePwd2(String? v) {
    if (_pwd2ServerError != null) return _pwd2ServerError;
    if ((v ?? '').isEmpty) return '请再次输入密码';
    if (v != _pwd.text) return '两次输入的密码不一致';
    return null;
  }

  String? _validateEmail(String? v) {
    if (_emailServerError != null) return _emailServerError;
    final s = (v ?? '').trim().toLowerCase();
    if (s.isEmpty) return null; // 选填
    if (s.length > 128) return '邮箱长度不能超过 128 个字符';
    if (!_emailRe.hasMatch(s)) return '邮箱格式不正确';
    return null;
  }

  // ------------------------------------------------------------------ 提交

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _inviteServerError = null;
      _usernameServerError = null;
      _nickServerError = null;
      _pwdServerError = null;
      _pwd2ServerError = null;
      _emailServerError = null;
      _err = null;
    });
    // 先清掉旧错误再重新校验，避免上一次的错误挡住本次提交。
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    final emailText = _email.text.trim().toLowerCase();
    try {
      final auth = context.read<AuthState>();
      final ok = await auth
          .register(
            inviteCode: normalizeInviteCode(_invite.text),
            username: _username.text.trim().toLowerCase(),
            password: _pwd.text,
            confirmPassword: _pwd2.text,
            nickname: _nick.text.trim(),
            email: emailText.isEmpty ? null : emailText,
          )
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (ok) {
        context.go('/overview');
        return;
      }
      setState(() {
        _applyServerMessage(
            auth.lastLoginError ?? '注册失败，请稍后再试');
        _busy = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _err = '连接超时，请检查网络或服务端地址';
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

  /// 后端 message → 就地字段提示；无法定位的走顶部提示条（全中文）。
  void _applyServerMessage(String msg) {
    final m = msg.trim();
    if (m.isEmpty) {
      _err = '注册失败，请稍后再试';
      return;
    }
    if (m.contains('邀请码')) {
      _inviteServerError = m;
      return;
    }
    if (m.contains('用户名')) {
      _usernameServerError = m;
      return;
    }
    if (m.contains('昵称')) {
      _nickServerError = m;
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
    if (m.contains('邮箱')) {
      _emailServerError = m;
      return;
    }
    _err = m;
  }

  // ------------------------------------------------------------------ 视图

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
                    padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                    decoration: BoxDecoration(
                      color: const Color(0xB30E0E14),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(
                          color: AppTheme.gold.withValues(alpha: 0.22)),
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
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const _GoldTitle('创建你的账本'),
                          const SizedBox(height: 6),
                          const Text(
                            '需要管理员提供的邀请码才能注册',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12, color: AppTheme.textDim),
                          ),
                          const SizedBox(height: 18),
                          _field(
                            controller: _invite,
                            label: '邀请码',
                            hint: 'ABCD2345',
                            icon: Icons.confirmation_number_outlined,
                            validator: _validateInvite,
                            formatters: const [_InviteCodeFormatter()],
                            helper: '8 位字母数字，向家庭管理员索取',
                            clearError: () =>
                                setState(() => _inviteServerError = null),
                            next: true,
                          ),
                          _field(
                            controller: _username,
                            label: '用户名',
                            hint: 'alice_lin',
                            icon: Icons.person_outline,
                            validator: _validateUsername,
                            formatters: const [_LowerCaseFormatter()],
                            helper:
                                '4~20 位，字母开头，只能是英文字母、数字和下划线',
                            goldHelper: '登录时使用「用户名 + 密码」，请记牢',
                            clearError: () =>
                                setState(() => _usernameServerError = null),
                            next: true,
                          ),
                          _field(
                            controller: _nick,
                            label: '昵称',
                            hint: '林小满',
                            icon: Icons.badge_outlined,
                            validator: _validateNick,
                            helper:
                                '昵称会显示在 App 和家庭成员列表里，可以用中文',
                            clearError: () =>
                                setState(() => _nickServerError = null),
                            next: true,
                          ),
                          _passwordField(
                            controller: _pwd,
                            label: '密码',
                            hint: '至少 8 位，含字母和数字',
                            icon: Icons.lock_outline,
                            visible: _showPwd,
                            validator: _validatePwd,
                            helper: '至少 8 位，同时含字母和数字',
                            toggle: () =>
                                setState(() => _showPwd = !_showPwd),
                            clearError: () =>
                                setState(() => _pwdServerError = null),
                            next: true,
                          ),
                          _passwordField(
                            controller: _pwd2,
                            label: '确认密码',
                            hint: '再输入一次密码',
                            icon: Icons.lock_reset,
                            visible: _showPwd2,
                            validator: _validatePwd2,
                            toggle: () =>
                                setState(() => _showPwd2 = !_showPwd2),
                            clearError: () =>
                                setState(() => _pwd2ServerError = null),
                            next: true,
                          ),
                          _field(
                            controller: _email,
                            label: '邮箱（选填）',
                            hint: 'you@example.com',
                            icon: Icons.alternate_email,
                            keyboardType: TextInputType.emailAddress,
                            validator: _validateEmail,
                            helper: '仅用于接收通知，不作为登录凭证',
                            clearError: () =>
                                setState(() => _emailServerError = null),
                            next: false,
                            onSubmitted: () => _busy ? null : _submit(),
                          ),
                          const SizedBox(height: 12),
                          const _ServerRow(),
                          if (_err != null) ...[
                            const SizedBox(height: 12),
                            _ErrorBox(text: _err!),
                          ],
                          const SizedBox(height: 16),
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
                                          color: Color(0xFF231A05)),
                                    )
                                  : const Text('注册并进入',
                                      style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 1.5)),
                            ),
                          ),
                          const SizedBox(height: 4),
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
                              child: const Text('已有账号？返回登录',
                                  style: TextStyle(fontSize: 13)),
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

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required String? Function(String?) validator,
    required String helper,
    required VoidCallback clearError,
    required bool next,
    String? goldHelper,
    List<TextInputFormatter> formatters = const [],
    TextInputType keyboardType = TextInputType.text,
    VoidCallback? onSubmitted,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: controller,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.none,
            keyboardType: keyboardType,
            inputFormatters: formatters,
            textInputAction:
                next ? TextInputAction.next : TextInputAction.done,
            validator: validator,
            onChanged: (_) => clearError(),
            onFieldSubmitted: (_) => onSubmitted?.call(),
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              prefixIcon: Icon(icon),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Text(helper,
                style: const TextStyle(
                    fontSize: 11, color: AppTheme.textDim)),
          ),
          if (goldHelper != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
              child: Text(goldHelper,
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.goldLight)),
            ),
        ],
      ),
    );
  }

  Widget _passwordField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required bool visible,
    required String? Function(String?) validator,
    required VoidCallback toggle,
    required VoidCallback clearError,
    required bool next,
    String? helper,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: controller,
            obscureText: !visible,
            autocorrect: false,
            textInputAction:
                next ? TextInputAction.next : TextInputAction.done,
            validator: validator,
            onChanged: (_) => clearError(),
            decoration: InputDecoration(
              labelText: label,
              hintText: hint,
              prefixIcon: Icon(icon),
              suffixIcon: IconButton(
                tooltip: visible ? '隐藏密码' : '显示密码',
                icon: Icon(
                    visible ? Icons.visibility : Icons.visibility_off),
                onPressed: toggle,
              ),
            ),
          ),
          if (helper != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
              child: Text(helper,
                  style: const TextStyle(
                      fontSize: 11, color: AppTheme.textDim)),
            ),
        ],
      ),
    );
  }
}

/// 邀请码输入：自动大写、自动去空格与连字符。
class _InviteCodeFormatter extends TextInputFormatter {
  const _InviteCodeFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final normalized = normalizeInviteCode(newValue.text);
    if (normalized == newValue.text) return newValue;
    return TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
  }
}

/// 用户名输入即转小写（不改变长度，光标不跳）。
class _LowerCaseFormatter extends TextInputFormatter {
  const _LowerCaseFormatter();

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
            fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: 1.0),
      ),
    );
  }
}

/// 服务端地址入口：点一下打开现有对话框（含扫码）
class _ServerRow extends StatelessWidget {
  const _ServerRow();

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
            child: Text(text,
                style:
                    const TextStyle(color: Color(0xFFFFB4B4), fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
