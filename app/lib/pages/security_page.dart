import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../services/api.dart';
import '../services/auth.dart';

class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key});
  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  bool _busy = false;
  String? _otpAuth;
  String? _secret;

  Future<void> _enableMfa() async {
    setState(() => _busy = true);
    final r = await ApiClient.instance.mfaSetup();
    if (r.ok && r.data != null) {
      setState(() {
        _otpAuth = r.data!['otpauth'] as String?;
        _secret = r.data!['secret'] as String?;
      });
    }
    setState(() => _busy = false);
  }

  Future<void> _confirmMfa() async {
    final code = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('输入验证码'),
        content: TextField(controller: code, decoration: const InputDecoration(labelText: '6 位验证码')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('启用')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.mfaEnable(code.text.trim());
    if (r.ok && mounted) {
      setState(() {
        _otpAuth = null;
        _secret = null;
      });
      final u = context.read<AuthState>().user;
      if (u != null) {
        context.read<AuthState>().setUser(UserProfile(
              id: u.id,
              username: u.username,
              nickname: u.nickname,
              avatar: u.avatar,
              email: u.email,
              phone: u.phone,
              role: u.role,
              mfaEnabled: true,
            ));
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('MFA 已启用')));
    }
  }

  Future<void> _changePassword() async {
    final old = TextEditingController();
    final nw = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: old, obscureText: true, decoration: const InputDecoration(labelText: '原密码')),
            TextField(controller: nw, obscureText: true, decoration: const InputDecoration(labelText: '新密码（至少 8 位）')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.changePassword(old.text, nw.text);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.message)));
    }
  }

  Future<void> _editProfile() async {
    final u = context.read<AuthState>().user;
    if (u == null) return;
    final nickname = TextEditingController(text: u.nickname);
    final avatar = TextEditingController(text: u.avatar);
    final email = TextEditingController(text: u.email);
    final phone = TextEditingController(text: u.phone);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('编辑资料'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nickname, decoration: const InputDecoration(labelText: '昵称')),
            const SizedBox(height: 8),
            TextField(controller: avatar, decoration: const InputDecoration(labelText: '头像 URL')),
            const SizedBox(height: 8),
            TextField(controller: email, decoration: const InputDecoration(labelText: '邮箱')),
            const SizedBox(height: 8),
            TextField(controller: phone, decoration: const InputDecoration(labelText: '手机')),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final r = await ApiClient.instance.updateProfile({
      'nickname': nickname.text,
      'avatar': avatar.text,
      'email': email.text,
      'phone': phone.text,
    });
    if (!mounted) return;
    if (r.ok) {
      context.read<AuthState>().setUser(UserProfile(
            id: u.id,
            username: u.username,
            nickname: nickname.text,
            avatar: avatar.text,
            email: email.text,
            phone: phone.text,
            role: u.role,
            mfaEnabled: u.mfaEnabled,
          ));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final mfaEnabled = context.watch<AuthState>().user?.mfaEnabled ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('账号与安全')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.badge),
            title: const Text('编辑资料'),
            subtitle: const Text('昵称、头像、邮箱、手机号'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _editProfile,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.password),
            title: const Text('修改密码'),
            onTap: _changePassword,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.security),
            title: Text(mfaEnabled ? '已启用 MFA' : '启用 MFA 多因子认证'),
            subtitle: Text(mfaEnabled ? '登录与敏感操作需输入一次性验证码' : '使用 Authenticator 等 App 扫码'),
            trailing: mfaEnabled
                ? const Icon(Icons.check_circle, color: Colors.green)
                : FilledButton(onPressed: _busy ? null : _enableMfa, child: const Text('设置')),
          ),
          if (_otpAuth != null) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  QrImageView(data: _otpAuth!, size: 200),
                  const SizedBox(height: 12),
                  SelectableText('密钥：$_secret', style: const TextStyle(fontFamily: 'monospace')),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _confirmMfa, child: const Text('下一步：输入验证码')),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
