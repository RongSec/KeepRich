import 'package:family_finance_app/models.dart';
import 'package:family_finance_app/pages/security_page.dart';
import 'package:family_finance_app/pages/settings_page.dart'
    show UserManagementPage;
import 'package:family_finance_app/services/auth.dart';
import 'package:family_finance_app/utils/display_name.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

FamilyMember _member(int id, String nickname, String username) => FamilyMember(
      id: id,
      familyId: 1,
      userId: id,
      isAdmin: false,
      status: 'active',
      username: username,
      nickname: nickname,
      avatar: '',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('昵称显示口径', () {
    test('昵称优先，无昵称老账号回落用户名', () {
      expect(displayName('小满', 'alice'), '小满');
      expect(displayName('  ', 'alice'), 'alice');
      expect(displayName('', 'bob'), 'bob');
    });

    test('两个用户同昵称「小满」→ 各自补用户名，不重名不补', () {
      final members = <FamilyMember>[
        _member(1, '小满', '账号A'),
        _member(2, '小满', '账号B'),
        _member(3, '阿福', 'afu'),
      ];
      final labels = memberLabels(
        members,
        nickname: (m) => m.nickname,
        username: (m) => m.username,
      );
      expect(labels, <String>['小满（账号A）', '小满（账号B）', '阿福']);
      expect(memberLabel('小满', '账号A', duplicated: true), '小满（账号A）');
      expect(memberLabel('小满', '账号A', duplicated: false), '小满');
    });

    test('重名判定按 trim 归一，空昵称不参与', () {
      final dups = duplicatedNicknames(<String>[
        ' 小满 ',
        '小满',
        '',
        '   ',
        '阿福',
      ]);
      expect(dups, <String>{'小满'});
    });

    test('头像首字母取昵称首字，英文首字母大写，无昵称回落用户名', () {
      expect(avatarInitial('小满', 'alice'), '小');
      expect(avatarInitial('alice', 'alice_01'), 'A');
      expect(avatarInitial('', 'bob'), 'B');
      expect(avatarInitial('', ''), 'U');
    });

    test('存量超长昵称不截断不报错，只在展示侧省略', () {
      const long = '这是一个非常非常长的昵称超过十六个字啦';
      expect(displayName(long, 'alice'), long);
      expect(displayName(long, 'alice').length, long.length);
      expect(nicknameError(long, required: false), '昵称最多 16 个字');
    });

    test('昵称校验中文文案（注册必填 / 编辑资料可清空）', () {
      expect(nicknameError(''), '请输入昵称');
      expect(nicknameError('   '), '昵称不能只包含空格');
      expect(nicknameError('一二三四五六七八九十一二三四五六七'),
          '昵称最多 16 个字');
      expect(nicknameError('一二三四五六七八九十一二三四五六'), isNull);
      expect(nicknameError('', required: false), isNull);
      expect(nicknameError('   ', required: false), isNull);
    });
  });

  group('页面接入口径', () {
    testWidgets('家庭成员列表：同昵称两人显示「小满（账号A/B）」', (tester) async {
      final auth = AuthState();
      auth.setUser(UserProfile(
        id: 999,
        username: 'nobody',
        nickname: '',
        avatar: '',
        email: '',
        phone: '',
        role: 'user',
        mfaEnabled: false,
      ));
      // 通过测试注入成员，避免 fake-async 下真实网络请求的不确定性。
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthState>.value(value: auth),
        ],
        child: MaterialApp(
          home: UserManagementPage(
            initialMembers: <FamilyMember>[
              _member(1, '小满', '账号A'),
              _member(2, '小满', '账号B'),
              _member(3, '阿福', 'afu'),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('小满（账号A）'), findsOneWidget);
      expect(find.text('小满（账号B）'), findsOneWidget);
      expect(find.text('阿福'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('编辑资料：昵称 17 字被拦且提示中文文案', (tester) async {
      final auth = AuthState();
      auth.setUser(UserProfile(
        id: 1,
        username: 'alice',
        nickname: '小满',
        avatar: '',
        email: '',
        phone: '',
        role: 'user',
        mfaEnabled: false,
      ));
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthState>.value(value: auth),
        ],
        child: const MaterialApp(home: SecurityPage()),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('编辑资料').first);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byType(TextFormField).at(0), '一二三四五六七八九十一二三四五六七');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(find.text('昵称最多 16 个字'), findsOneWidget);
      // 校验不通过时对话框不关闭，已填内容不丢。
      expect(find.text('编辑资料'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });
}
