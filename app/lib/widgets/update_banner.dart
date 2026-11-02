import 'package:flutter/material.dart';

import '../services/web_updater.dart';
import '../theme.dart';

/// Web 端"有新版本"提示条
///
/// 没有新版本时不占位（SizedBox.shrink），所以可以无脑塞进页面顶部。
class WebUpdateBanner extends StatelessWidget {
  const WebUpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<WebUpdateInfo?>(
      valueListenable: WebUpdater.instance.available,
      builder: (ctx, info, _) {
        if (info == null) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppTheme.gold.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.gold.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              const Icon(Icons.system_update_alt,
                  size: 18, color: AppTheme.gold),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '新版本 v${info.version} 已发布',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppTheme.goldLight,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: WebUpdater.instance.dismiss,
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.textDim,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('忽略', style: TextStyle(fontSize: 12)),
              ),
              FilledButton(
                onPressed: WebUpdater.instance.applyUpdate,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                child: const Text('立即刷新', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }
}
