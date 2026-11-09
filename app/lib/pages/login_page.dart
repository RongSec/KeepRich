import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../config.dart';
import '../services/accounts.dart';
import '../services/auth.dart';
import '../services/device_auth.dart';
import '../theme.dart';
import '../widgets/account_card.dart';
import '../widgets/server_address_dialog.dart';
import '../widgets/update_banner.dart';

/// 登录页三态：账号卡 / 纯账号密码表单 / 系统生物识别弹窗中。
enum LoginPageMode { card, form, bio }

const String _idleNotice = '已超过 24 小时未使用，请重新验证身份';

/// 登录页：
/// - 本机有账号卡 → 头像 + 昵称 + 用户名 → 主按钮 → 次按钮「切换用户」；
/// - 本机无账号卡（含 Web）→ 纯账号密码表单，无空头像框、无切换按钮；
/// - 指纹可用 → 主路径走指纹；未开通/不可用/连错 3 次 → 降级密码表单。
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
  final _userFocus = FocusNode();
  final _pwdFocus = FocusNode();

  late AnimationController _anim;

  LoginPageMode _mode = LoginPageMode.form;
  bool _ready = false;
  bool _busy = false;
  bool _showPwd = false;
  String? _err;
  String? _notice;
  bool _noticeIsIdle = false;
  bool _idleExpired = false;
  bool _forcePassword = false;
  bool _formFromCard = false;
  int _loginFails = 0; // 密码登录连续失败次数：≥3 时显示 MFA 输入框

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);
    _load();
  }

  @override
  void dispose() {
    _anim.dispose();
    _user.dispose();
    _pwd.dispose();
    _mfa.dispose();
    _userFocus.dispose();
    _pwdFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final accounts = context.read<AccountsRepo>();
    final deviceAuth = context.read<DeviceAuthService>();
    final auth = context.read<AuthState>();
    await accounts.load();
    await deviceAuth.init();
    // 重新进入登录页（含退出登录后）一律清零指纹失败计数（R-04 ④）。
    deviceAuth.resetFailCount();
    final reason = auth.sessionExpireReason;
    if (!mounted) return;
    setState(() {
      _idleExpired = reason == 'idle';
      if (reason == 'idle') {
        _notice = _idleNotice;
        _noticeIsIdle = true;
      } else if (reason == 'revoked') {
        _notice = '登录已失效，请重新登录';
        _noticeIsIdle = false;
      } else if (reason == 'device') {
        _notice = '设备凭据已失效，请用密码登录';
        _noticeIsIdle = false;
      }
      _mode = (!kIsWeb && accounts.defaultAccount != null)
          ? LoginPageMode.card
          : LoginPageMode.form;
      _ready = true;
    });
    if (reason != null) auth.clearSessionReason();
  }

  bool _canUseBiometric() {
    if (kIsWeb || _forcePassword) return false;
    return context.read<DeviceAuthService>().canUse;
  }

  String _primaryLabel() {
    if (_idleExpired) return '验证并登录';
    return _canUseBiometric() ? '登录' : '输入密码登录';
  }

  void _enterForm({
    required String prefill,
    required bool focusPassword,
    bool showBack = true,
    String? notice,
    bool forcePassword = false,
  }) {
    final hasCard = !kIsWeb && context.read<AccountsRepo>().defaultAccount != null;
    setState(() {
      _mode = LoginPageMode.form;
      _user.text = prefill;
      _formFromCard = showBack && hasCard;
      _forcePassword = forcePassword;
      _busy = false;
      _err = null;
      if (notice != null) {
        _notice = notice;
        _noticeIsIdle = false;
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(focusPassword ? _pwdFocus : _userFocus);
    });
  }

  void _backToCard() {
    setState(() {
      _mode = LoginPageMode.card;
      _formFromCard = false;
      _err = null;
      _notice = _idleExpired ? _idleNotice : null;
      _noticeIsIdle = _idleExpired;
      _busy = false;
    });
  }

  void _onPrimary() {
    final account = context.read<AccountsRepo>().defaultAccount;
    if (account == null) {
      _enterForm(prefill: '', focusPassword: false, showBack: false);
      return;
    }
    final deviceAuth = context.read<DeviceAuthService>();
    if (_canUseBiometric()) {
      _startBiometric();
      return;
    }
    // 指纹未开通 / 不支持 → 展开表单，用户名预填、焦点在密码框。
    _enterForm(
      prefill: account.username,
      focusPassword: true,
      notice: deviceAuth.unavailableHint,
      forcePassword: true,
    );
  }

  void _switchUser() {
    // 只切界面，不写账号卡：默认账号保持不变（R-06 ③）。
    _enterForm(prefill: '', focusPassword: false);
  }

  void _usePassword() {
    final account = context.read<AccountsRepo>().defaultAccount;
    _enterForm(
      prefill: account?.username ?? '',
      focusPassword: true,
    );
  }

  Future<void> _startBiometric() async {
    final account = context.read<AccountsRepo>().defaultAccount;
    if (account == null) return;
    final deviceAuth = context.read<DeviceAuthService>();
    final auth = context.read<AuthState>();
    setState(() {
      _mode = LoginPageMode.bio;
      _busy = true;
      _err = null;
    });
    final result = await deviceAuth.unlock();
    if (!mounted) return;
    switch (result) {
      case UnlockResult.canceled:
        setState(() {
          _mode = LoginPageMode.card;
          _busy = false;
          _notice = '已取消指纹验证';
          _noticeIsIdle = false;
        });
        return;
      case UnlockResult.unavailable:
        _enterForm(
          prefill: account.username,
          focusPassword: true,
          notice: deviceAuth.unavailableHint,
          forcePassword: true,
        );
        return;
      case UnlockResult.failed:
        if (deviceAuth.failCount >= 3) {
          _enterForm(
            prefill: account.username,
            focusPassword: true,
            notice: '指纹连续 3 次未通过，请改用密码登录',
            forcePassword: true,
          );
        } else {
          setState(() {
            _mode = LoginPageMode.card;
            _busy = false;
            _err = '指纹验证失败，请重试';
          });
        }
        return;
      case UnlockResult.success:
        break;
    }

    bool ok = false;
    try {
      final token = await deviceAuth.deviceTokenFor(account.uid);
      if (token != null && token.isNotEmpty) {
        ok = await auth.loginWithDeviceCredential(account);
      } else if (deviceAuth.hasLegacyCredentials) {
        // v0.4.1 升级上来的旧凭据：仅在内存里用一次，成功后由 AuthState
        // 换成服务端设备凭据并立刻删除本机旧密码。
        ok = await auth.login(
            deviceAuth.legacyUsername, deviceAuth.legacyPassword!);
      } else {
        if (!mounted) return;
        _enterForm(
          prefill: account.username,
          focusPassword: true,
          notice: '设备凭据已失效，请用密码登录',
          forcePassword: true,
        );
        return;
      }
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    if (ok) {
      context.go('/overview');
      return;
    }
    setState(() {
      _mode = LoginPageMode.card;
      _busy = false;
      _err = auth.lastLoginError ?? '设备凭据已失效，请用密码登录';
    });
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    final username = _user.text.trim();
    final password = _pwd.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _err = '用户名或密码错误');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final auth = context.read<AuthState>();
      final ok = await auth
          .login(
            username,
            password,
            mfaCode: _mfa.text.trim().isEmpty ? null : _mfa.text.trim(),
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted) return;
      if (ok) {
        _loginFails = 0;
        context.go('/overview');
        return;
      }
      setState(() {
        _err = auth.lastLoginError ?? '用户名或密码错误';
        _busy = false;
        _loginFails++;
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
        _loginFails++;
      });
    }
  }

  Future<void> _removeAccount(LocalAccount account) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('从本机移除「${account.displayName()}」？'),
        content: const Text(
            '移除后该账号下次登录需要重新输入密码，账本数据不受影响。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('移除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final accounts = context.read<AccountsRepo>();
    await accounts.remove(account.uid);
    if (!mounted) return;
    setState(() {
      if (accounts.defaultAccount == null) {
        _mode = LoginPageMode.form;
        _formFromCard = false;
        _user.text = '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final accounts = context.read<AccountsRepo>();
    final defaultAccount = accounts.defaultAccount;
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
                  _glassCard(_buildBody(accounts, defaultAccount)),
                  const SizedBox(height: 14),
                  const _ServerChip(),
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

  Widget _glassCard(Widget child) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(26),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
          decoration: BoxDecoration(
            color: const Color(0xB30E0E14),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
                color: AppTheme.gold.withValues(alpha: 0.22), width: 1),
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
          child: child,
        ),
      ),
    );
  }

  Widget _buildBody(AccountsRepo accounts, LocalAccount? defaultAccount) {
    final isCard = _mode == LoginPageMode.card && defaultAccount != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_mode == LoginPageMode.form && _formFromCard)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : _backToCard,
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text('返回', style: TextStyle(fontSize: 13)),
            ),
          ),
        Center(child: _Logo(anim: _anim)),
        const SizedBox(height: 16),
        _GoldTitle(_mode == LoginPageMode.card
            ? '让财务透明，资产永存'
            : (_formFromCard ? '使用账号密码登录' : '让财务透明，资产永存')),
        const SizedBox(height: 14),
        if (!_ready)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 26),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_mode == LoginPageMode.bio)
          _buildBioWaiting()
        else if (isCard)
          _buildCard(defaultAccount)
        else
          _buildForm(accounts),
      ],
    );
  }

  Widget _buildBioWaiting() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 34),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fingerprint, size: 44, color: AppTheme.gold),
          SizedBox(height: 12),
          CircularProgressIndicator(),
          SizedBox(height: 12),
          Text('正在验证指纹或面容',
              style: TextStyle(fontSize: 13, color: AppTheme.textDim)),
        ],
      ),
    );
  }

  Widget _buildCard(LocalAccount account) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_notice != null) ...[
          _NoticeBanner(text: _notice!, idle: _noticeIsIdle),
          const SizedBox(height: 10),
        ],
        Center(
          child: AccountCard(
              account: account, onLongPress: () => _removeAccount(account)),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 50,
          child: FilledButton(
            onPressed: _busy ? null : _onPrimary,
            child: Text(
              _primaryLabel(),
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, letterSpacing: 2),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 44,
          child: OutlinedButton(
            onPressed: _busy ? null : _switchUser,
            child: const Text('切换用户', style: TextStyle(fontSize: 14)),
          ),
        ),
        if (_canUseBiometric()) ...[
          const SizedBox(height: 8),
          Center(
            child: TextButton(
              onPressed: _busy ? null : _usePassword,
              style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8)),
              child: const Text('用密码登录',
                  style: TextStyle(fontSize: 12, color: AppTheme.textDim)),
            ),
          ),
        ],
        if (_err != null) ...[
          const SizedBox(height: 8),
          _ErrorBox(text: _err!),
        ],
        _footer(),
      ],
    );
  }

  Widget _buildForm(AccountsRepo accounts) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_notice != null) ...[
          _NoticeBanner(text: _notice!, idle: _noticeIsIdle),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _user,
          focusNode: _userFocus,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.next,
          onSubmitted: (_) => FocusScope.of(context).requestFocus(_pwdFocus),
          decoration: const InputDecoration(
            labelText: '用户名',
            hintText: '请输入用户名',
            prefixIcon: Icon(Icons.person_outline),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pwd,
          focusNode: _pwdFocus,
          obscureText: !_showPwd,
          autocorrect: false,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _busy ? null : _submit(),
          decoration: InputDecoration(
            labelText: '密码',
            prefixIcon: const Icon(Icons.lock_outline),
            suffixIcon: IconButton(
              icon: Icon(
                  _showPwd ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _showPwd = !_showPwd),
            ),
          ),
        ),
        if (_loginFails >= 3) ...[
          const SizedBox(height: 12),
          TextField(
            controller: _mfa,
            decoration: const InputDecoration(
              labelText: 'MFA 验证码',
              prefixIcon: Icon(Icons.shield_outlined),
            ),
          ),
        ],
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
                        strokeWidth: 2, color: Color(0xFF231A05)),
                  )
                : const Text('登 录',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 3)),
          ),
        ),
        if (!kIsWeb && accounts.accounts.isNotEmpty) ...[
          const SizedBox(height: 18),
          RememberedAccountsRow(
            accounts: accounts.accounts,
            onTap: (acc) {
              _user.text = acc.username;
              setState(() {});
              FocusScope.of(context).requestFocus(_pwdFocus);
            },
            onLongPress: _removeAccount,
          ),
        ],
        _footer(),
      ],
    );
  }

  Widget _footer() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: _busy ? null : () => context.push('/register'),
            child: const Text('还没有账号？立即注册',
                style: TextStyle(fontSize: 13)),
          ),
        ),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_clock, size: 13, color: AppTheme.textDim),
            SizedBox(width: 4),
            Text('数据加密传输',
                style: TextStyle(fontSize: 11, color: AppTheme.textDim)),
          ],
        ),
      ],
    );
  }
}

/// 黄色（闲置）/ 橙红（其它原因）提示条。
class _NoticeBanner extends StatelessWidget {
  const _NoticeBanner({required this.text, required this.idle});

  final String text;
  final bool idle;

  @override
  Widget build(BuildContext context) {
    final color = idle ? const Color(0xFFFFC65C) : const Color(0xFFFF8A8A);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(idle ? Icons.schedule : Icons.info_outline,
              color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(color: color, fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.text});

  final String text;

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
            fontSize: 19, fontWeight: FontWeight.w800, letterSpacing: 1.0),
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
          width: 72,
          height: 72,
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
                shape: BoxShape.circle, color: Color(0xFFFFC65C)),
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
class _ServerChip extends StatefulWidget {
  const _ServerChip();

  @override
  State<_ServerChip> createState() => _ServerChipState();
}

class _ServerChipState extends State<_ServerChip> {
  @override
  Widget build(BuildContext context) {
    final host = AppConfig.serverHost;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () async {
        await showServerAddressDialog(context);
        if (!mounted) return;
        setState(() {});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xB3000000),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: AppTheme.gold.withValues(alpha: 0.22)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withValues(alpha: 0.35), blurRadius: 10),
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

/// Web 端专属：把当前服务端地址画成二维码，手机 App 扫码即可自动填入。
class _ServerQrCard extends StatelessWidget {
  const _ServerQrCard();

  @override
  Widget build(BuildContext context) {
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
            dataModuleStyle:
                const QrDataModuleStyle(color: Color(0xFF1A1A1A)),
          ),
          const SizedBox(height: 8),
          const Text('手机 App 扫码连接此服务',
              style: TextStyle(fontSize: 12, color: Color(0xFF5A4A22))),
        ],
      ),
    );
  }
}

/// 把登录/网络异常翻译成用户能直接行动的中文提示。
/// 绝不把异常类名、堆栈、HTTP 状态码或英文原句甩给用户（R-14 ②）。
String friendlyLoginError(Object e) {
  final s = e.toString().toLowerCase();
  if (s.contains('timeout') || s.contains('timed out')) {
    return '连接超时，请检查网络或服务端地址';
  }
  if (s.contains('socket') ||
      s.contains('connection') ||
      s.contains('failed host lookup') ||
      s.contains('network is unreachable')) {
    return '网络不可用，请检查网络后重试';
  }
  if (s.contains('type cast') || s.contains('not a subtype')) {
    return '服务端返回异常，请在底部「服务端地址」里确认地址是否正确';
  }
  return '网络不可用，请检查网络后重试';
}
