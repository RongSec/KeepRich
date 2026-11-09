import 'package:flutter/material.dart';

import '../theme.dart';
import '../utils/display_name.dart';

/// 账号头像：有 avatar 用网络图；没有或加载失败则取昵称首字（英文首字母大写）
/// 的金色圆底，不显示灰色占位图（PRD R-02 ③ / R-18 ①）。
class AccountAvatar extends StatelessWidget {
  const AccountAvatar({
    super.key,
    required this.avatar,
    required this.nickname,
    required this.username,
    this.size = 72,
  });

  final String avatar;
  final String nickname;
  final String username;
  final double size;

  /// 昵称优先，空昵称回落用户名；取首字并大写（中文不受影响）。
  static String initialOf(String nickname, String username) =>
      avatarInitial(nickname, username);

  @override
  Widget build(BuildContext context) {
    final initial = initialOf(nickname, username);
    final showNetworkImage =
        avatar.trim().toLowerCase().startsWith('http');
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [Color(0xFFFFE9B8), Color(0xFFD79A32)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: AppTheme.gold.withValues(alpha: 0.85), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppTheme.gold.withValues(alpha: 0.22),
            blurRadius: 18,
            spreadRadius: -4,
          ),
        ],
      ),
      padding: const EdgeInsets.all(2.5),
      child: ClipOval(
        child: showNetworkImage
            ? Image.network(
                avatar,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _InitialGlyph(
                    initial: initial, size: size),
              )
            : _InitialGlyph(initial: initial, size: size),
      ),
    );
  }
}

class _InitialGlyph extends StatelessWidget {
  const _InitialGlyph({required this.initial, required this.size});

  final String initial;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFFFFD980), Color(0xFFC8912F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        maxLines: 1,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: const Color(0xFF231A05),
          fontSize: size * 0.42,
          fontWeight: FontWeight.w800,
          height: 1,
        ),
      ),
    );
  }
}
