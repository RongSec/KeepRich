import 'dart:convert';

import 'package:flutter/foundation.dart' show ChangeNotifier, kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

/// 本机记住的一个账号。
///
/// 红线：这里**只有展示信息与账号标识**，绝不保存密码、密码哈希或任何
/// 可逆密文。指纹登录用的是 `device_cred_<uid>` 里的服务端设备凭据，
/// 由 [hasDeviceCredential] 仅记录「有没有」这一个布尔值。
class LocalAccount {
  final int uid;
  final String username;
  final String nickname;
  final String avatar;
  final int lastLoginAt;
  final bool hasDeviceCredential;

  const LocalAccount({
    required this.uid,
    required this.username,
    this.nickname = '',
    this.avatar = '',
    this.lastLoginAt = 0,
    this.hasDeviceCredential = false,
  });

  /// 昵称优先，空昵称回落用户名（R-10 ⑤ / R-13 ⑤）。
  String displayName() =>
      nickname.trim().isNotEmpty ? nickname.trim() : username;

  LocalAccount copyWith({
    int? uid,
    String? username,
    String? nickname,
    String? avatar,
    int? lastLoginAt,
    bool? hasDeviceCredential,
  }) =>
      LocalAccount(
        uid: uid ?? this.uid,
        username: username ?? this.username,
        nickname: nickname ?? this.nickname,
        avatar: avatar ?? this.avatar,
        lastLoginAt: lastLoginAt ?? this.lastLoginAt,
        hasDeviceCredential: hasDeviceCredential ?? this.hasDeviceCredential,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'uid': uid,
        'username': username,
        'nickname': nickname,
        'avatar': avatar,
        'lastLoginAt': lastLoginAt,
        'hasDeviceCredential': hasDeviceCredential,
      };

  factory LocalAccount.fromJson(Map<String, dynamic> json) => LocalAccount(
        uid: (json['uid'] as num?)?.toInt() ?? 0,
        username: json['username'] as String? ?? '',
        nickname: json['nickname'] as String? ?? '',
        avatar: json['avatar'] as String? ?? '',
        lastLoginAt: (json['lastLoginAt'] as num?)?.toInt() ?? 0,
        hasDeviceCredential: json['hasDeviceCredential'] == true,
      );
}

/// 本机多账号仓库：最多 5 个、按最近一次**成功登录**倒序、首项即默认账号。
///
/// [onAccountRemoved] 由 `main.dart` 注入，用来在移除/淘汰账号时同步删掉
/// 该账号的 `device_cred_<uid>`，避免仓库反向依赖设备凭据服务。
class AccountsRepo extends ChangeNotifier {
  static const int maxAccounts = 5;
  static const String storageKey = 'accounts_v1';

  AccountsRepo();

  List<LocalAccount> _accounts = <LocalAccount>[];

  /// 对外只给只读视图，排序与容量规则由本仓库独占。
  List<LocalAccount> get accounts =>
      List<LocalAccount>.unmodifiable(_accounts);

  LocalAccount? get defaultAccount =>
      _accounts.isEmpty ? null : _accounts.first;

  bool get isEmpty => _accounts.isEmpty;
  int get length => _accounts.length;

  Future<void> Function(int uid)? onAccountRemoved;

  LocalAccount? byUid(int uid) {
    for (final account in _accounts) {
      if (account.uid == uid) return account;
    }
    return null;
  }

  /// 从本地偏好里恢复账号卡。Web 端按产品口径恒空（PRD §0.3 / §3.6）。
  Future<void> load() async {
    if (kIsWeb) {
      _accounts = <LocalAccount>[];
      notifyListeners();
      return;
    }
    final restored = <LocalAccount>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              final account =
                  LocalAccount.fromJson(Map<String, dynamic>.from(item));
              if (account.uid > 0 && account.username.isNotEmpty) {
                restored.add(account);
              }
            }
          }
        }
      }
    } catch (_) {
      // 旧数据损坏不能让登录页打不开：按「本机无账号」降级。
      restored.clear();
    }
    _sortByRecent(restored);
    _accounts = restored.length > maxAccounts
        ? restored.sublist(0, maxAccounts)
        : restored;
    notifyListeners();
  }

  /// 登录成功后调用：同 uid 覆盖、时间刷新、倒序、超出 5 个静默淘汰末位。
  /// 淘汰者只删本机账号卡与其设备凭据，不动服务端任何数据（R-06 ②）。
  Future<void> upsertOnLogin(LocalAccount account) async {
    if (kIsWeb || account.uid <= 0) return;
    final LocalAccount? previous = byUid(account.uid);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final updated = <LocalAccount>[
      ..._accounts.where((e) => e.uid != account.uid),
      LocalAccount(
        uid: account.uid,
        username: account.username.isNotEmpty
            ? account.username
            : (previous?.username ?? ''),
        nickname: account.nickname,
        avatar: account.avatar,
        lastLoginAt:
            account.lastLoginAt > 0 ? account.lastLoginAt : now,
        hasDeviceCredential: account.hasDeviceCredential ||
            (previous?.hasDeviceCredential ?? false),
      ),
    ];
    _sortByRecent(updated);
    final evicted = updated.length > maxAccounts
        ? updated.sublist(maxAccounts)
        : <LocalAccount>[];
    _accounts = updated.length > maxAccounts
        ? updated.sublist(0, maxAccounts)
        : updated;
    await _persist();
    for (final item in evicted) {
      await onAccountRemoved?.call(item.uid);
    }
    notifyListeners();
  }

  /// 同步设备凭据「有/无」标志，供登录页判断能否走指纹主路径。
  Future<void> markCredential(int uid, bool value) async {
    if (kIsWeb) return;
    final index = _accounts.indexWhere((e) => e.uid == uid);
    if (index < 0 || _accounts[index].hasDeviceCredential == value) return;
    final updated = List<LocalAccount>.of(_accounts);
    updated[index] = updated[index].copyWith(hasDeviceCredential: value);
    _accounts = updated;
    await _persist();
    notifyListeners();
  }

  /// 长按移除 / 退出登录：删卡 + 删本机凭据。
  Future<void> remove(int uid) async {
    if (kIsWeb) return;
    _accounts = _accounts.where((e) => e.uid != uid).toList();
    await _persist();
    await onAccountRemoved?.call(uid);
    notifyListeners();
  }

  /// 清空本机所有账号（卸载重装等价效果）。
  Future<void> clearAll() async {
    final uids = _accounts.map((e) => e.uid).toList();
    _accounts = <LocalAccount>[];
    if (!kIsWeb) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(storageKey);
      } catch (_) {}
    }
    for (final uid in uids) {
      await onAccountRemoved?.call(uid);
    }
    notifyListeners();
  }

  static void _sortByRecent(List<LocalAccount> list) {
    list.sort((a, b) {
      final byTime = b.lastLoginAt.compareTo(a.lastLoginAt);
      return byTime != 0 ? byTime : a.uid.compareTo(b.uid);
    });
  }

  Future<void> _persist() async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        storageKey,
        jsonEncode(_accounts.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      // 写失败只影响「下次是否还记得账号」，不影响本次登录。
    }
  }
}
