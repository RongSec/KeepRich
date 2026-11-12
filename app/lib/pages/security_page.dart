import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../services/api.dart';
import '../utils/dialog_dispose.dart';
import '../services/auth.dart';
import '../widgets/account_avatar.dart';
import '../utils/display_name.dart';

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
        content: TextField(
            controller: code,
            decoration: const InputDecoration(labelText: '6 位验证码')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('启用')),
        ],
      ),
    );
    if (ok != true) {
      disposeDialogController(code);
      return;
    }
    final codeText = code.text.trim();
    disposeDialogController(code);
    final r = await ApiClient.instance.mfaEnable(codeText);
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
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('MFA 已启用')));
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
            TextField(
                controller: old,
                obscureText: true,
                decoration: const InputDecoration(labelText: '原密码')),
            TextField(
                controller: nw,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新密码（至少 8 位）')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) {
      disposeDialogController(old);
      disposeDialogController(nw);
      return;
    }
    final oldText = old.text;
    final nwText = nw.text;
    disposeDialogController(old);
    disposeDialogController(nw);
    final r = await ApiClient.instance.changePassword(oldText, nwText);
    if (!mounted) return;
    if (!r.ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              r.message.isEmpty ? '修改失败，请稍后再试' : r.message)));
      return;
    }
    // 后端改密会撤销全部会话与设备凭据，必须主动回登录页重新验证身份，
    // 否则用户会卡在已失效的页面上（T05 / DESIGN §6 T05 ③）。
    await context.read<AuthState>().passwordChanged();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('登录已失效，请重新登录')));
    context.go('/login');
  }

  Future<void> _editProfile() async {
    final u = context.read<AuthState>().user;
    if (u == null) return;
    final nickname = TextEditingController(text: u.nickname);
    // 头像改为相册上传：不再用 URL 文本框。pickedAvatar 存 data URI（base64）。
    String pickedAvatar = u.avatar;
    final email = TextEditingController(text: u.email);
    final phone = TextEditingController(text: u.phone);
    final formKey = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('编辑资料'),
        content: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // 头像：从相册上传（不再手输 URL）
              Center(
                child: Column(children: [
                  AccountAvatar(
                      avatar: pickedAvatar,
                      nickname: nickname.text,
                      username: u.username,
                      size: 72),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    OutlinedButton.icon(
                      onPressed: () async {
                        // 相册选图，压到 256px/质量 75，转 data URI 存库
                        final x = await ImagePicker().pickImage(
                            source: ImageSource.gallery,
                            maxWidth: 256,
                            maxHeight: 256,
                            imageQuality: 75);
                        if (x == null) return;
                        final bytes = await x.readAsBytes();
                        if (bytes.lengthInBytes > 400 * 1024) {
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(
                                content:
                                    Text('头像图片过大，请换一张较小的图片')));
                          }
                          return;
                        }
                        final mime = x.mimeType == null || x.mimeType!.isEmpty
                            ? 'image/jpeg'
                            : x.mimeType!;
                        setDialogState(() => pickedAvatar =
                            'data:$mime;base64,${base64Encode(bytes)}');
                      },
                      icon: const Icon(Icons.photo_library_outlined, size: 18),
                      label: const Text('从相册选择'),
                    ),
                    if (pickedAvatar.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () =>
                            setDialogState(() => pickedAvatar = ''),
                        child: const Text('移除'),
                      ),
                    ],
                  ]),
                ]),
              ),
              const SizedBox(height: 8),
              // 存量 >16 字昵称不截断不报错，只有主动编辑提交时才按 16 字校验。
              TextFormField(
                  controller: nickname,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (v) => nicknameError(v, required: false),
                  decoration: const InputDecoration(
                      labelText: '昵称', helperText: '最多 16 个字')),
              const SizedBox(height: 8),
              TextFormField(
                  controller: email,
                  decoration: const InputDecoration(labelText: '邮箱')),
              const SizedBox(height: 8),
              TextFormField(
                  controller: phone,
                  decoration: const InputDecoration(labelText: '手机')),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.pop(ctx, true);
                }
              },
              child: const Text('保存')),
        ],
      ),
      ),
    );
    if (ok != true) {
      disposeDialogController(nickname);
      disposeDialogController(email);
      disposeDialogController(phone);
      return;
    }
    final nicknameText = nickname.text;
    final avatarText = pickedAvatar;
    final emailText = email.text;
    final phoneText = phone.text;
    disposeDialogController(nickname);
    disposeDialogController(email);
    disposeDialogController(phone);
    final r = await ApiClient.instance.updateProfile({
      'nickname': nicknameText,
      'avatar': avatarText,
      'email': emailText,
      'phone': phoneText,
    });
    if (!mounted) return;
    if (r.ok) {
      context.read<AuthState>().setUser(UserProfile(
            id: u.id,
            username: u.username,
            nickname: nicknameText,
            avatar: avatarText,
            email: emailText,
            phone: phoneText,
            role: u.role,
            mfaEnabled: u.mfaEnabled,
          ));
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已保存')));
    } else {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(r.message)));
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
            subtitle: Text(
                mfaEnabled ? '登录与敏感操作需输入一次性验证码' : '使用 Authenticator 等 App 扫码'),
            trailing: mfaEnabled
                ? const Icon(Icons.check_circle, color: Colors.green)
                : FilledButton(
                    onPressed: _busy ? null : _enableMfa,
                    child: const Text('设置')),
          ),
          if (_otpAuth != null) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  QrImageView(data: _otpAuth!, size: 200),
                  const SizedBox(height: 12),
                  SelectableText('密钥：$_secret',
                      style: const TextStyle(fontFamily: 'monospace')),
                  const SizedBox(height: 12),
                  FilledButton(
                      onPressed: _confirmMfa, child: const Text('下一步：输入验证码')),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
