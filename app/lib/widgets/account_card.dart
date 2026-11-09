import 'package:flutter/material.dart';

import '../services/accounts.dart';
import '../theme.dart';
import 'account_avatar.dart';

/// 默认账号卡：头像 + 昵称（或用户名）+ 用户名。
/// 单击无动作（避免误触登录），长按由调用方弹「从本机移除该账号」。
class AccountCard extends StatelessWidget {
  const AccountCard({
    super.key,
    required this.account,
    this.onLongPress,
    this.avatarSize = 72,
  });

  final LocalAccount account;
  final VoidCallback? onLongPress;
  final double avatarSize;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '默认账号 ${account.displayName()}',
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AccountAvatar(
                avatar: account.avatar,
                nickname: account.nickname,
                username: account.username,
                size: avatarSize,
              ),
              const SizedBox(height: 10),
              Text(
                account.displayName(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.gold,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                account.username,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textDim,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 「本机已记住的账号」头像行（≤5，横向可滚动，小屏不溢出）。
/// 点一下预填用户名；长按移除该账号。
class RememberedAccountsRow extends StatelessWidget {
  const RememberedAccountsRow({
    super.key,
    required this.accounts,
    required this.onTap,
    this.onLongPress,
  });

  final List<LocalAccount> accounts;
  final ValueChanged<LocalAccount> onTap;
  final ValueChanged<LocalAccount>? onLongPress;

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) return const SizedBox.shrink();
    final shown = accounts.length > AccountsRepo.maxAccounts
        ? accounts.sublist(0, AccountsRepo.maxAccounts)
        : accounts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '本机已记住的账号',
          style: TextStyle(fontSize: 12, color: AppTheme.textDim),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: shown.map((account) {
              return Padding(
                padding: const EdgeInsets.only(right: 12),
                child: GestureDetector(
                  onTap: () => onTap(account),
                  onLongPress: onLongPress == null
                      ? null
                      : () => onLongPress!(account),
                  child: SizedBox(
                    width: 62,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AccountAvatar(
                          avatar: account.avatar,
                          nickname: account.nickname,
                          username: account.username,
                          size: 42,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          account.displayName(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppTheme.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}
