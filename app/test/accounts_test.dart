import 'dart:convert';

import 'package:family_finance_app/services/accounts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本机多账号仓库规则（T03 / R-06）：≤5、最近使用倒序、默认账号、
/// 淘汰与移除时删设备凭据、切换用户不改默认。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  LocalAccount acc(int uid, int at) => LocalAccount(
        uid: uid,
        username: 'user$uid',
        nickname: '用户$uid',
        lastLoginAt: at,
      );

  test('按最近成功登录倒序，默认账号 = 最近一次成功登录', () async {
    final repo = AccountsRepo();
    await repo.load();
    for (var i = 1; i <= 4; i++) {
      await repo.upsertOnLogin(acc(i, 1000 + i));
    }
    expect(repo.length, 4);
    expect(repo.defaultAccount?.uid, 4);
    expect(repo.accounts.map((e) => e.uid).toList(), <int>[4, 3, 2, 1]);

    // 点开「切换用户」又返回不写仓库 → 默认账号不变
    expect(repo.defaultAccount?.uid, 4);

    // 冷启动恢复
    final restored = AccountsRepo();
    await restored.load();
    expect(restored.length, 4);
    expect(restored.defaultAccount?.uid, 4);
  });

  test('第 6 个账号静默淘汰末位，并删掉被淘汰者的设备凭据', () async {
    final repo = AccountsRepo();
    final cleaned = <int>[];
    repo.onAccountRemoved = (uid) async => cleaned.add(uid);
    await repo.load();
    for (var i = 1; i <= 6; i++) {
      await repo.upsertOnLogin(acc(i, 1000 + i));
    }
    expect(repo.length, AccountsRepo.maxAccounts);
    expect(repo.accounts.map((e) => e.uid).toList(), <int>[6, 5, 4, 3, 2]);
    expect(cleaned, <int>[1]);
  });

  test('remove / clearAll 都会回调删除对应设备凭据', () async {
    final repo = AccountsRepo();
    final cleaned = <int>[];
    repo.onAccountRemoved = (uid) async => cleaned.add(uid);
    await repo.load();
    await repo.upsertOnLogin(acc(1, 1000));
    await repo.upsertOnLogin(acc(2, 2000));

    await repo.remove(2);
    expect(repo.accounts.map((e) => e.uid).toList(), <int>[1]);
    expect(cleaned, <int>[2]);

    await repo.clearAll();
    expect(repo.isEmpty, isTrue);
    expect(cleaned, <int>[2, 1]);
  });

  test('标记设备凭据有/无会持久化，损坏数据按「本机无账号」降级', () async {
    final repo = AccountsRepo();
    await repo.load();
    await repo.upsertOnLogin(acc(9, 1234));
    await repo.markCredential(9, true);
    expect(repo.byUid(9)?.hasDeviceCredential, isTrue);
    final raw = (await SharedPreferences.getInstance())
        .getString(AccountsRepo.storageKey);
    expect(jsonDecode(raw!) is List, isTrue);

    await repo.markCredential(9, false);
    expect(repo.byUid(9)?.hasDeviceCredential, isFalse);

    SharedPreferences.setMockInitialValues(<String, Object>{
      AccountsRepo.storageKey: 'not-a-json',
    });
    final broken = AccountsRepo();
    await broken.load();
    expect(broken.isEmpty, isTrue);
  });
}
