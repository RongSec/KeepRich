import 'package:flutter/material.dart';

import 'star_field.dart';

/// 静态金色星空背景（v0.5.3，替代金沙盒子 / 沙漏）。
///
/// 用户口径：**「就用现在这样的状态，星空式，不需要各种动态了，就一个星空就好了，
/// 金色的星星」** —— 无 Ticker、无传感器、无粒子物理，纯静态一次绘制：
///
/// - [StarFieldPainter]：深色渐变底 + 金色星星（大小不一、疏密自然、明暗分层，
///   少数大星带柔光晕），`shouldRepaint => false`，零逐帧分配；
/// - 本文件：只负责遮罩 / `dimmed`（登录后变淡）/ `density`（低端机降密度）
///   与顶层底部渐隐，和旧背景完全同一套口径。
///
/// 回退：`main.dart` 把这里换回 `GoldSandBackground` 即可（`gold_sand.dart` 未改动）。
class HourglassSandBackground extends StatefulWidget {
  /// 登录后变淡
  final bool dimmed;

  /// 星星密度系数，1.0 为默认（低端机会在此基础上再按屏幕面积降档）
  final double density;

  const HourglassSandBackground({
    super.key,
    this.dimmed = false,
    this.density = 1.0,
  });

  @override
  State<HourglassSandBackground> createState() =>
      _HourglassSandBackgroundState();
}

class _HourglassSandBackgroundState extends State<HourglassSandBackground> {
  StarFieldPainter? _painter;
  double? _painterDensity;

  /// 兼容保留的生命周期成员：星空是纯矢量绘制，无图片资源需要释放（空实现）。
  void disposeImages() => _painter?.disposeImages();

  /// 星表按密度生成一次并缓存复用（不进 build 热路径的重复分配）。
  StarFieldPainter _painterFor(double effDensity) {
    final cached = _painter;
    if (cached != null && _painterDensity == effDensity) return cached;
    final painter = StarFieldPainter(stars: buildStars(density: effDensity));
    _painter = painter;
    _painterDensity = effDensity;
    return painter;
  }

  @override
  void dispose() {
    disposeImages();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dim = widget.dimmed;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final area = constraints.maxWidth *
            constraints.maxHeight *
            dpr *
            dpr; // 物理像素面积
        // 低端降级：小屏/低 dpi 设备自动降密度（沿用旧口径，R-13 预留档位）
        final effDensity =
            widget.density * (area / 900000).clamp(0.45, 1.0);
        final painter = _painterFor(effDensity);
        return Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                // 登录后变淡的强度（0.65 口径，与旧背景一致，不要随手调小）：
                // 页面 Scaffold 底色 0xB8 叠加后星空仍肉眼可辨（QA 实测口径）。
                opacity: dim ? 0.65 : 1.0,
                child: CustomPaint(
                  // 星空是纯静态的（shouldRepaint 恒 false）；密度变化时换 key
                  // 强制重建绘制层，保证星数随 density 正确变化。
                  key: ValueKey<double>(effDensity),
                  painter: painter,
                  isComplex: true,
                ),
              ),
            ),
            // 遮罩：压住底部与状态栏，让星空与内容层级分明
            IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 700),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    // 登录后只保留一层很薄的压暗（页面底色 0xB8 已压过一轮），
                    // 负责压住状态栏/底部导航区域。
                    colors: dim
                        ? const [
                            Color(0x260A0A10),
                            Color(0x1A0A0A10),
                            Color(0x260A0A10),
                          ]
                        : const [
                            Color(0x4A0A0A10),
                            Color(0x1F0A0A10),
                            Color(0x660A0A10),
                          ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
            ),
            // 顶部 / 底部渐隐
            Positioned.fill(
              child: IgnorePointer(
                child: Column(
                  children: [
                    Container(
                      height: 140,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0xE60A0A10),
                            Color(0x8C0A0A10),
                            Color(0x000A0A10),
                          ],
                          stops: [0.0, 0.58, 1.0],
                        ),
                      ),
                    ),
                    const Spacer(),
                    Container(
                      height: 130,
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.bottomCenter,
                          end: Alignment.topCenter,
                          colors: [Color(0xD90A0A10), Color(0x000A0A10)],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
