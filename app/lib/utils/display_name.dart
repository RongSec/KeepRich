// 昵称显示口径的统一实现（DESIGN §2.E.5 / PRD R-10 ⑤⑥、R-11、§5.3）。
//
// - 昵称非空用昵称，否则用用户名；
// - 同一列表里昵称重复（>=2 次）时补「（用户名）」区分，不重名只显示昵称；
// - 存量 >16 字昵称不截断不报错，由展示侧 maxLines: 1 + ellipsis 省略；
// - 头像首字母取昵称首字，英文首字母大写。

/// 昵称优先，空昵称回落用户名。
String displayName(String nickname, String username) =>
    nickname.trim().isNotEmpty ? nickname.trim() : username;

/// 家庭成员 / 记账人列表标签：重名时补用户名，不重名只显示昵称。
String memberLabel(String nickname, String username,
        {required bool duplicated}) =>
    duplicated
        ? '${displayName(nickname, username)}（$username）'
        : displayName(nickname, username);

/// 找出出现 >=2 次的昵称（trim 后比较），空昵称不参与重名判定。
Set<String> duplicatedNicknames(Iterable<String> nicknames) {
  final counts = <String, int>{};
  for (final raw in nicknames) {
    final key = raw.trim();
    if (key.isEmpty) continue;
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts.entries
      .where((e) => e.value >= 2)
      .map((e) => e.key)
      .toSet();
}

/// 一次性给整组对象算好展示标签，自动处理重名。
///
/// 泛型写法让记账页（FamilyMember / TxRecord）与设置页共用同一条口径，
/// 工具层不依赖任何业务 model。
List<String> memberLabels<T>(
  Iterable<T> members, {
  required String Function(T) nickname,
  required String Function(T) username,
}) {
  final duplicates = duplicatedNicknames(members.map(nickname));
  return members
      .map((m) => memberLabel(nickname(m), username(m),
          duplicated: duplicates.contains(nickname(m).trim())))
      .toList();
}

/// 头像占位字符：昵称首字（英文首字母大写），无昵称取用户名首字母。
String avatarInitial(String nickname, String username) {
  final label = displayName(nickname, username);
  if (label.isEmpty) return 'U';
  return String.fromCharCode(label.runes.first).toUpperCase();
}

/// 昵称校验文案（与后端 utils.ValidateNickname 完全一致）。
///
/// [required] = true 用于注册（空 / 全空格都拦）；= false 用于编辑资料，
/// 与后端 UpdateProfile 一致：允许清空昵称，只校验 16 字上限。
/// 返回 null 表示通过。
String? nicknameError(String? value, {bool required = true}) {
  final raw = value ?? '';
  if (required) {
    if (raw.isEmpty) return '请输入昵称';
    if (raw.trim().isEmpty) return '昵称不能只包含空格';
  }
  if (raw.trim().runes.length > 16) return '昵称最多 16 个字';
  return null;
}
