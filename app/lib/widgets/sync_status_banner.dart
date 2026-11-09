import 'package:flutter/material.dart';

import '../services/sync_status.dart';

/// 顶部「云端同步暂时失败」横条（R-11）
///
/// 只读展示、无按钮、不拦截手势：它唯一的职责是告诉用户"数据在本机是安全的，
/// 只是还没同步到云端"。恢复同步后由 [SyncStatusService] 自动收起。
///
/// 用法：无脑塞进主页面顶部（与 `WebUpdateBanner` 同一位置），
/// 不显示时高度为 0，不占位。
class SyncStatusBanner extends StatelessWidget {
  const SyncStatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: SyncStatusService.instance,
      builder: (ctx, _) {
        final failing = SyncStatusService.instance.failing;
        return AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: failing
              ? IgnorePointer(
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 9),
                    decoration: BoxDecoration(
                      color: const Color(0x33FFB74D),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0x66FFB74D)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.cloud_off_outlined,
                            size: 16, color: Color(0xFFFFCC80)),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '云端同步暂时失败，数据已保存在本机',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Color(0xFFFFE0B2),
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity, height: 0),
        );
      },
    );
  }
}
