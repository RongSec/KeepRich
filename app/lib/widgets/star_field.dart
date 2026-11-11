import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 一颗星（归一化坐标，与画布尺寸无关）。
@immutable
class Star {
  const Star({
    required this.x,
    required this.y,
    required this.radius,
    required this.brightness,
    required this.tone,
    required this.halo,
  });

  /// 归一化横坐标（0..1，乘画布宽得像素位置）
  final double x;

  /// 归一化纵坐标（0..1，乘画布高得像素位置）
  final double y;

  /// 星核半径（逻辑像素）
  final double radius;

  /// 亮度（0..1），映射为不透明度分层
  final double brightness;

  /// 金色色调档位：0 暗金 / 1 中金 / 2 亮金
  final int tone;

  /// 是否带柔光晕（少数大星）
  final bool halo;
}

/// 默认密度（density=1.0）下的星星数量基准
const int kStarBaseCount = 110;

/// 生成确定性星表（固定 seed，每次结果一致）。
///
/// - 数量随 [density] 缩放（默认约 90~140 颗）
/// - 位置归一化到 0..1，大小不一、疏密自然（约 1/3 成小簇）、明暗有层次
/// - 约 6% 是带柔光晕的大星
List<Star> buildStars({double density = 1.0, int seed = 20240101}) {
  final rnd = math.Random(seed);
  final count =
      (kStarBaseCount * density.clamp(0.2, 2.0)).clamp(35, 160).round();

  // 簇中心：部分星星聚在小簇里，疏密才自然（不是均匀撒点）
  final clusters = List<(double, double)>.generate(
    10,
    (_) => (rnd.nextDouble(), rnd.nextDouble()),
    growable: false,
  );

  final stars = <Star>[];
  for (var i = 0; i < count; i++) {
    final double x, y;
    if (rnd.nextDouble() < 0.32) {
      final c = clusters[rnd.nextInt(clusters.length)];
      x = (c.$1 + (rnd.nextDouble() - 0.5) * 0.12).clamp(0.0, 1.0);
      y = (c.$2 + (rnd.nextDouble() - 0.5) * 0.12).clamp(0.0, 1.0);
    } else {
      x = rnd.nextDouble();
      y = rnd.nextDouble();
    }

    // 大小分层：多数小星、少数中星、极少数带光晕的大星
    final t = rnd.nextDouble();
    final double radius;
    final bool halo;
    if (t < 0.72) {
      radius = 0.6 + rnd.nextDouble() * 0.8;
      halo = false;
    } else if (t < 0.94) {
      radius = 1.3 + rnd.nextDouble() * 0.9;
      halo = false;
    } else {
      radius = 2.1 + rnd.nextDouble() * 1.3;
      halo = true;
    }

    stars.add(Star(
      x: x,
      y: y,
      radius: radius,
      brightness: 0.35 + rnd.nextDouble() * 0.65,
      tone: rnd.nextInt(3),
      halo: halo,
    ));
  }
  return List<Star>.unmodifiable(stars);
}

/// 静态金色星空绘制层：一次画完，零逐帧分配、零重绘。
///
/// - 深色渐变底（沿用旧背景同色系）
/// - 每颗星一个星核小圆点（金色三档色调，按亮度分层）
/// - 少数大星带 [ui.Gradient.radial] 柔光晕
///
/// [shouldRepaint] 恒为 `false`：星空是纯静态的，星表变化由外壳换
/// `CustomPaint` 的 key 强制重建，不走重绘路径。
class StarFieldPainter extends CustomPainter {
  StarFieldPainter({required this.stars}) {
    // 星核 Paint 预构建一次，paint 时零分配
    _corePaints = List<Paint>.unmodifiable([
      for (final s in stars)
        Paint()
          ..color = toneColor(s.tone)
              .withValues(alpha: (0.25 + s.brightness * 0.75).clamp(0.0, 1.0)),
    ]);
  }

  final List<Star> stars;
  late final List<Paint> _corePaints;

  /// 金色星色调：三档由暗到亮（与旧金沙同一金色区间）
  static const List<Color> _tones = [
    Color(0xFFE8B65A),
    Color(0xFFFFC65C),
    Color(0xFFFFD27A),
  ];

  static Color toneColor(int tone) => _tones[tone.clamp(0, _tones.length - 1)];

  /// 兼容保留的生命周期成员：星空无图片资源需要释放（空实现），
  /// 保证旧外壳/调用方的 `_painter.disposeImages()` 编译通过。
  void disposeImages() {}

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // 1) 深色渐变底（与旧背景同色系）
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0A0A10), Color(0xFF12101A), Color(0xFF1A1520)],
        ).createShader(rect),
    );

    final w = size.width;
    final h = size.height;

    // 2) 大星柔光晕（只画少数几颗；paint 单次执行，shader 按需创建）
    for (var i = 0; i < stars.length; i++) {
      final s = stars[i];
      if (!s.halo) continue;
      final c = Offset(s.x * w, s.y * h);
      final haloRadius = s.radius * 4.5;
      final color = toneColor(s.tone);
      canvas.drawCircle(
        c,
        haloRadius,
        Paint()
          ..shader = ui.Gradient.radial(
            c,
            haloRadius,
            [
              color.withValues(alpha: 0.28 + s.brightness * 0.22),
              color.withValues(alpha: 0),
            ],
            const [0.0, 1.0],
          ),
      );
    }

    // 3) 星核：一次性画完
    for (var i = 0; i < stars.length; i++) {
      final s = stars[i];
      canvas.drawCircle(Offset(s.x * w, s.y * h), s.radius, _corePaints[i]);
    }
  }

  @override
  bool shouldRepaint(covariant StarFieldPainter oldDelegate) => false;

  @override
  bool shouldRebuildSemantics(covariant StarFieldPainter oldDelegate) => false;
}
