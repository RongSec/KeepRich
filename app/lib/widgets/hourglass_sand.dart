import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'sand_box_painter.dart';
import 'sand_box_physics.dart';

/// 金沙盒子背景（v0.5.2 重做，替代沙漏造型）
///
/// 用户口径：**屏幕是正立方体盒子的正面投影，下半部分（约 50%）是金沙；
/// 手机旋转（重力方向变化）时沙子流动、重新堆积，沙面始终相对重力保持水平**
/// —— 完全模拟沙子在正立方体盒子内随盒子角度变化的动态物理行为。
///
/// 结构：
/// - [SandBoxPhysics]：高度场 + 松弛流动 + 休止角 + 粒子 / `step(dt)`（纯计算）
/// - [SandBoxPainter]：沙堆 + 纹理 + 粒子（约 8~10 次 draw call、零逐帧分配）
/// - 本文件：Ticker、传感器订阅、生命周期、遮罩层
///
/// 与旧沙漏的区别：没有上腔/细颈/下腔几何，只有"盒子 + 沙堆"；传感器只改变
/// 重力方向（沙流向哪），流动本身由高度场松弛驱动、永不停。
///
/// 回退：`main.dart` 把这里换回 `GoldSandBackground` 即可（`gold_sand.dart` 未改动）。
class HourglassSandBackground extends StatefulWidget {
  /// 登录后变淡
  final bool dimmed;

  /// 颗粒密度系数，1.0 为默认（低端机会在此基础上再按屏幕面积降档）
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

class _HourglassSandBackgroundState extends State<HourglassSandBackground>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _ticker;
  late final SandBoxPhysics _physics = SandBoxPhysics();
  late final SandBoxPainter _painter = SandBoxPainter(_physics);

  StreamSubscription<AccelerometerEvent>? _accSub;
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_onTick)..start();
    _listenSensors();
  }

  void _listenSensors() {
    try {
      _accSub = accelerometerEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen(
        (AccelerometerEvent e) {
          // 只更新重力方向：沙面流动由高度场松弛驱动，传感器不参与"流不流"。
          // 重力在屏幕平面内的水平分量 → tilt（右倾为正，沙流向右）。
          // 手机竖直 → tilt=0（沙在底）；横放 90° → tilt=±1（沙在左/右）。
          _physics.setTilt((-e.x / 9.81).clamp(-1.0, 1.0).toDouble());
        },
        // Web / 模拟器没有加速度计 → tilt 恒 0，沙堆照样松弛流动
        onError: (Object _) {},
        cancelOnError: false,
      );
    } catch (_) {
      // 传感器不可用：保持 tilt=0，沙堆仍在底部缓慢流动
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    _physics.step(dt);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 后台不耗电：暂停时静音 Ticker（PRD 性能预算）
    _ticker.muted = state != AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) _lastTick = Duration.zero;
  }

  @override
  void didUpdateWidget(covariant HourglassSandBackground old) {
    super.didUpdateWidget(old);
    if (old.density != widget.density) {
      _physics.setDensity(widget.density);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _accSub?.cancel();
    _painter.disposeImages();
    _physics.dispose();
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
        // 低端降级：小屏/低 dpi 设备自动降密度（R-13 预留档位）
        _physics.setDensity(widget.density * (area / 900000).clamp(0.45, 1.0));
        _physics.resize(Size(constraints.maxWidth, constraints.maxHeight));
        return Stack(
          fit: StackFit.expand,
          children: [
            RepaintBoundary(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 700),
                curve: Curves.easeOutCubic,
                // 登录后变淡的强度。**不要随手调小**：页面自己的 Scaffold 底色是
                // 0xB8（72% 不透明，见 theme.dart scaffoldBackgroundColor），
                // 沙漏最终亮度 ≈ 230 × 本值 × (1 - 遮罩) × 0.28。
                // 实测（393×873，叠加页面底色后，峰值/运动区帧间 Δ）：
                //   0.22 + 0xCC 遮罩 → 13/255、Δ1.7（QA 报"看不见"）
                // 真机（Pixel 7 AVD，概览页，去掉了 home_page 容器 Scaffold 的
                // 第二层底色之后）实测上腔峰值亮度 / 帧间 Δ≥3 像素占比：
                //   0.22 + 0xCC 遮罩 → 13/255、0.0%（QA 报"看不见"的原始状态）
                //   0.45 + 0x33 遮罩 → 30/255、5.2%（可辨但偏暗）
                //   0.65 + 0x26 遮罩 → 约 43/255、约 7.5%（当前值，肉眼明显）
                opacity: dim ? 0.65 : 1.0,
                child: CustomPaint(painter: _painter, isComplex: true),
              ),
            ),
            // 遮罩：压住底部与状态栏，让玻璃沙漏与内容层级分明
            IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 700),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    // 登录后不再叠 0.72~0.80 的厚遮罩：页面底色（0xB8）
                    // 已经把沙漏压到 28% 以下，遮罩再盖一层就彻底看不见了
                    // （QA 实测两帧仅 1.6% 像素变化就是这个原因）。
                    // 这里只保留一层很薄的压暗，负责压住状态栏/底部导航区域。
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
