import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../services/auth.dart';

class AdminLoginPage extends StatefulWidget {
  const AdminLoginPage({super.key});
  @override
  State<AdminLoginPage> createState() => _AdminLoginPageState();
}

class _AdminLoginPageState extends State<AdminLoginPage> {
  final _user = TextEditingController();
  final _pwd = TextEditingController();
  final _mfa = TextEditingController();
  bool _busy = false;
  String? _err;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    final ok = await context.read<AuthState>().login(
          _user.text.trim(),
          _pwd.text,
          mfaCode: _mfa.text.trim().isEmpty ? null : _mfa.text.trim(),
        );
    if (!mounted) return;
    if (ok) {
      final me = context.read<AuthState>().user;
      if (me?.role == 'admin') {
        context.go('/admin');
      } else {
        setState(() => _err = '当前账号不是管理员');
        context.read<AuthState>().logout();
      }
    } else {
      setState(() => _err = '登录失败，请检查账号、密码或 MFA');
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.admin_panel_settings, size: 56, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text('管理页面', textAlign: TextAlign.center, style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  Text('系统管理员登录', textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 32),
                  TextField(controller: _user, decoration: const InputDecoration(labelText: '管理员账号', prefixIcon: Icon(Icons.person_outline))),
                  const SizedBox(height: 12),
                  TextField(controller: _pwd, obscureText: true, decoration: const InputDecoration(labelText: '密码', prefixIcon: Icon(Icons.lock_outline))),
                  const SizedBox(height: 12),
                  TextField(controller: _mfa, decoration: const InputDecoration(labelText: 'MFA 验证码（可选）', prefixIcon: Icon(Icons.security))),
                  if (_err != null) ...[
                    const SizedBox(height: 12),
                    Text(_err!, style: TextStyle(color: theme.colorScheme.error)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('登录'),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => context.go('/login'),
                    child: const Text('返回普通登录'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
