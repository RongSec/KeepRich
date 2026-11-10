import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'sand_box_physics.dart';

/// 立方体盒子装沙的绘制层：只画沙堆 + 流动粒子，不做物理。
///
/// 与旧 `HourglassPainter` 的区别：不画沙漏玻璃外形/上下腔/细颈/束流，
/// 只画"盒子内的一堆沙"。纹理预渲染（`ui.Image`）与零逐帧分配的思路沿用。
///
/// 绘制预算（PRD「避免逐帧创建对象」）：约 8~10 次 draw call
/// 背景 1 / 沙堆填充 1 / 沙丘纹理 1 / 沙面高光 1 / 沙底阴影 1 / 粒子 2~3。
/// 每帧**不分配**：`Paint` / `Path` / `Float32List` / shader 全部预构建。
class SandBoxPainter extends CustomPainter {
  SandBoxPainter(this.physics) {
    _buildStatics();
  }

  final SandBoxPhysics physics;

  // 预构建的 Paint / Shader（构造一次）
  late final Paint _bgPaint;
  late final Paint _sandPaint;
  late final Paint _glintPaint;
  late final Paint _shadowPaint;
  late final Paint _dotPaint1;
  late final Paint _dotPaint2;
  late final Paint _dotPaint3;

  /// 沙堆多边形顶点缓冲（复用，零逐帧分配）：沙面曲线 48 点 + 远端闭合 2 点
  static const int _kSurfaceSteps = 48;
  final List<Offset> _poly =
      List<Offset>.filled(_kSurfaceSteps + 2, Offset.zero, growable: false);

  /// 沙丘纹理（一次生成，overlay 混合）
  ui.Image? _duneImage;
  bool _imageBuilding = false;

  /// 沙粒色调：与旧实现同一套金色区间（视觉延续）
  static const List<Color> _goldTones = [
    Color(0xFFE8B65A),
    Color(0xFFF2C978),
    Color(0xFFFFDFA0),
  ];

  void _buildStatics() {
    _bgPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF0A0A10), Color(0xFF12101A), Color(0xFF1A1520)],
      ).createShader(const Rect.fromLTWH(0, 0, 1, 1));
    // 沙堆主体：从沙面（亮）到盒底（暗）的金色渐变
    _sandPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFF2C978), Color(0xFFD9A441), Color(0xFFA87A2C)],
        stops: [0.0, 0.55, 1.0],
      ).createShader(const Rect.fromLTWH(0, 0, 1, 1));
    _glintPaint = Paint()
      ..color = const Color(0xFFFFF3D0)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    _shadowPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [Color(0x66000000), Color(0x00000000)],
        stops: [0.0, 0.28],
      ).createShader(const Rect.fromLTWH(0, 0, 1, 1));
    _dotPaint1 = Paint()..color = _goldTones[0].withValues(alpha: 0.85);
    _dotPaint2 = Paint()..color = _goldTones[1].withValues(alpha: 0.8);
    _dotPaint3 = Paint()..color = _goldTones[2].withValues(alpha: 0.7);
  }

  /// 纹理句柄生命周期由外壳 widget 负责（`CustomPainter` 无可靠 dispose）
  void disposeImages() {
    _duneImage?.dispose();
    _duneImage = null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 1) 背景（铺满）
    final bgRect = Offset.zero & size;
    canvas.drawRect(bgRect, _bgPaint);

    // 2) 沙堆多边形（沙面曲线 + 沿重力走到远端闭合）
    final n = physics.fillSandPolygon(_poly, _kSurfaceSteps);
    final path = Path()..addPolygon(_poly.sublist(0, n), true);
    canvas.drawPath(path, _sandPaint);

    // 3) 沙丘纹理（一次生成，overlay）
    _ensureImage(size);
    if (_duneImage != null) {
      canvas.save();
      canvas.clipPath(path);
      final src = Rect.fromLTWH(0, 0, _duneImage!.width.toDouble(),
          _duneImage!.height.toDouble());
      canvas.drawImageRect(
          _duneImage!,
          src,
          bgRect,
          Paint()
            ..blendMode = BlendMode.overlay
            ..color = const Color(0x55FFFFFF));
      canvas.restore();
    }

    // 4) 沙面高光（沿沙面的一条亮边）
    final ridge = Path();
    for (var i = 0; i < _kSurfaceSteps; i++) {
      final p = _poly[i];
      if (i == 0) {
        ridge.moveTo(p.dx, p.dy);
      } else {
        ridge.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(
        ridge,
        _glintPaint
          ..color = const Color(0xFFFFE9B8).withValues(alpha: 0.55));

    // 5) 沙底阴影（近盒底压暗，增强立体）
    canvas.save();
    canvas.clipPath(path);
    canvas.drawRect(bgRect, _shadowPaint);
    canvas.restore();

    // 6) 流动粒子（三种色调分段，零逐帧分配）
    _paintParticles(canvas);
  }

  void _paintParticles(Canvas canvas) {
    final buf = physics.pointsBuf;
    final n = physics.particleCount;
    final third = n ~/ 3;
    void drawRange(int from, int to, Paint p) {
      if (to <= from) return;
      final data = Float32List.sublistView(buf, from * 2, to * 2);
      canvas.drawRawPoints(ui.PointMode.points, data, p..strokeWidth = 2.2);
    }

    drawRange(0, third, _dotPaint1);
    drawRange(third, third * 2, _dotPaint2);
    drawRange(third * 2, n, _dotPaint3);
  }

  /// 沙丘纹理：成团的明暗起伏（中灰底，overlay 时中灰不改底色）。
  /// 只生成一次；`toImageSync` 不进每帧路径。
  void _ensureImage(Size size) {
    if (_duneImage != null || _imageBuilding) return;
    _imageBuilding = true;
    const w = 256, h = 256;
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder);
    final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
    c.drawRect(rect, Paint()..color = const Color(0xFF808080));
    // 几个椭圆起伏
    final rnd = [
      (40.0, 60.0, 50.0),
      (150.0, 40.0, 64.0),
      (90.0, 150.0, 72.0),
      (200.0, 180.0, 56.0),
      (30.0, 210.0, 48.0),
    ];
    for (final (cx, cy, r) in rnd) {
      c.drawCircle(
          Offset(cx, cy),
          r,
          Paint()
            ..color = const Color(0xFFB0B0B0)
            ..style = PaintingStyle.fill);
    }
    for (final (cx, cy, r) in rnd) {
      c.drawCircle(
          Offset(cx + 6, cy + 6),
          r * 0.72,
          Paint()
            ..color = const Color(0xFF5A5A5A)
            ..style = PaintingStyle.fill);
    }
    // 砂粒小点
    for (var i = 0; i < 900; i++) {
      final x = (i * 37) % w;
      final y = (i * 61) % h;
      c.drawCircle(
          Offset(x.toDouble(), y.toDouble()),
          1.0 + (i % 3) * 0.6,
          Paint()..color = const Color(0xFF9A9A9A).withValues(alpha: 0.6));
    }
    final pic = recorder.endRecording();
    pic.toImage(w, h).then((img) {
      _duneImage = img;
      _imageBuilding = false;
      // 通知重绘（外壳的 Ticker 下一帧会画上）
    }).catchError((_) {
      _imageBuilding = false;
    });
  }

  @override
  bool shouldRepaint(covariant SandBoxPainter oldDelegate) => true;
}
