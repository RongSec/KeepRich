import 'package:flutter/widgets.dart';

/// 对话框里的 TextEditingController 不能"一关就 dispose"。
///
/// `showDialog` 的 Future 在路由 pop 时就完成了，但对话框还有约 200ms 的退场
/// 动画，期间 TextField 仍会对 controller 调用 addListener，于是抛出：
///   A TextEditingController was used after being disposed.
/// 紧接着框架还会连带抛 `_dependents.isEmpty` 断言，整屏变红。
///
/// 这里延后到退场动画彻底结束后再释放。延迟期内的重复调用由 try/catch 兜住。
void disposeDialogController(TextEditingController? c) {
  if (c == null) return;
  Future<void>.delayed(const Duration(milliseconds: 600), () {
    try {
      c.dispose();
    } catch (_) {
      // 已释放：忽略
    }
  });
}
