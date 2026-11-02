/// 非 Web 平台的占位实现（保证 `flutter build apk` 能编译）
Future<void> hardReload() async {
  // 移动端没有"网页刷新"这个概念，调用即为空操作
}
