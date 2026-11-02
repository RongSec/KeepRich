import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web 端硬刷新：清空 CacheStorage + 注销 Service Worker 后重新加载页面
///
/// Flutter Web 的产物默认会被 Service Worker / HTTP 缓存兜住，直接 reload
/// 可能仍然加载旧代码。这里把缓存与 SW 都清掉，确保拿到服务端最新构建。
Future<void> hardReload() async {
  // 1) 清空所有 CacheStorage（Service Worker 缓存的主要载体）
  try {
    final cacheStorage = web.window.caches;
    final keys = (await cacheStorage.keys().toDart).toDart;
    for (final key in keys) {
      await cacheStorage.delete(key.toDart).toDart;
    }
  } catch (_) {
    // 浏览器不支持 CacheStorage 时忽略
  }

  // 2) 注销 Service Worker，避免它继续返回旧资源
  try {
    final regs =
        (await web.window.navigator.serviceWorker.getRegistrations().toDart)
            .toDart;
    for (final reg in regs) {
      await reg.unregister().toDart;
    }
  } catch (_) {
    // 无 SW 或浏览器不支持时忽略
  }

  // 3) 重新加载（带上时间戳，绕过 index.html 的自身缓存）
  try {
    final uri = Uri.parse(web.window.location.href);
    final busted = uri.replace(queryParameters: {
      ...uri.queryParameters,
      '_v': DateTime.now().millisecondsSinceEpoch.toString(),
    });
    web.window.location.replace(busted.toString());
  } catch (_) {
    web.window.location.reload();
  }
}
