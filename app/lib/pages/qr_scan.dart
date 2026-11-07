/// 扫码入口按平台拆分：
///   - 移动端：mobile_scanner 实现页
///   - Web：占位实现 —— mobile_scanner 7.x 的 web 代码与当前 SDK 的
///     dart:js_interop 类型不兼容编译不过，且 Web 登录页本身就显示二维码
///
/// dart.library.io 在 Web 上也有 stub（恒为 true），不能用作条件；
/// dart.library.html 只在 Web 为 true —— 条件命中时用占位实现。
export 'qr_scan_mobile.dart' if (dart.library.html) 'qr_scan_none.dart';
