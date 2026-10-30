import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../api.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _u = TextEditingController();
  final _p = TextEditingController();
  String? _err;
  bool _busy = false;

  Future<void> _submit() async {
    setState(() {
      _err = null;
      _busy = true;
    });
    try {
      final r = await ApiClient.instance.login(_u.text.trim(), _p.text);
      if (r['code'] == 0) {
        if (mounted) context.go('/dashboard');
      } else {
        setState(() => _err = r['message'] ?? '登录失败');
      }
    } catch (e) {
      setState(() => _err = '网络错误：$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Card(
            margin: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.admin_panel_settings, size: 48, color: Colors.indigo),
                  const SizedBox(height: 12),
                  Text('家庭财务 · 管理后台', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 24),
                  TextField(controller: _u, decoration: const InputDecoration(labelText: '管理员账号')),
                  const SizedBox(height: 12),
                  TextField(controller: _p, obscureText: true, decoration: const InputDecoration(labelText: '密码')),
                  if (_err != null) ...[
                    const SizedBox(height: 8),
                    Text(_err!, style: const TextStyle(color: Colors.red)),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('登录'),
                    ),
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
