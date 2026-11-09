import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'hourglass_physics.dart';

/// 沙漏绘制层：只做绘制 + 纹理预渲染（`ui.Image` 复用），不含任何物理计算。
///
/// 绘制预算（PRD「避免逐帧创建对象」）：约 17 次 draw call
/// 背景 1 / 上腔填充 1 / 上腔砂粒纹理 1 / 上腔沙脊 2 / 束流核心 1 /
/// 下腔填充 1 / 下腔纹理 1 / 锥面高光 1 / 颗粒 3 / 闪光 1 / 玻璃 2 / 颈壁高光 1。
///
/// 每帧**不分配**任何对象：`Paint` / `Path` / `Float32List` / 静态渐变 shader
/// 全部在 [HourglassPainter] 构造与尺寸变化时一次性建好。
class HourglassPainter extends CustomPainter {
  HourglassPainter(this.p) : super(repaint: p);

  final HourglassPhysics p;

  ui.Image? _grainTex;
  ui.Image? _bedTex;

  Size _cachedSize = Size.zero;
  double _dpr = 1.0;

  final Path _glassPath = Path();
  final Path _topSandPath = Path();
  final Path _bottomSandPath = Path();
  final Path _ridgePath = Path();
  final Path _conePath = Path();

  // ---- 预分配的画笔 ----
  final Paint _bgPaint = Paint();
  final Paint _topFillPaint = Paint();
  final Paint _bottomFillPaint = Paint();
  final Paint _grainPaint = Paint();
  final Paint _bedPaint = Paint();
  final Paint _topShadowPaint = Paint();
  final Paint _ridgeGlowPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.6
    ..strokeCap = StrokeCap.round
    ..color = const Color(0x66FFE9B0)
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.0);
  final Paint _ridgePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.9
    ..strokeCap = StrokeCap.round
    ..color = const Color(0x99FFF6D8);
  final Paint _conePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.8
    ..strokeCap = StrokeCap.round
    ..color = const Color(0x77FFE3A3);
  final Paint _streamPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2
    ..strokeCap = StrokeCap.round;
  final Paint _particlePaint = Paint()..strokeCap = StrokeCap.round;
  final Paint _sparkPaint = Paint()..strokeCap = StrokeCap.round;
  final Paint _glassPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.4
    ..color = const Color(0x33FFFFFF);
  final Paint _goldEdgePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 0.9
    ..color = const Color(0xAAFFC65C);
  final Paint _neckPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0
    ..color = const Color(0x66FFE9B0);
  final Paint _flipShadowPaint = Paint();

  /// 沙粒色调：与 `gold_sand.dart` 同一套金色区间（视觉延续）
  static const List<Color> _tones = <Color>[
    Color(0xFFAE8232),
    Color(0xFFD8AB4A),
    Color(0xFFFFE3A3),
  ];

  /// 纹理句柄的生命周期由外壳 widget 负责（`CustomPainter` 没有可靠的 dispose 时机）
  void disposeImages() {
    _grainTex?.dispose();
    _grainTex = null;
    _bedTex?.dispose();
    _bedTex = null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final geo = p.geometry;
    if (geo == null || size.isEmpty) return;

    _ensureImages();
    if (_cachedSize != size) _rebuildCache(geo, size);

    // ① 背景：上部暗处 → 底部暖调，衬出金色玻璃
    canvas.drawRect(Offset.zero & size, _bgPaint);

    canvas.save(); // S1：翻转变换
    final flip = p.flipProgress;
    if (flip > 0) {
      final eased = _easeInOutCubic(flip.clamp(0.0, 1.0).toDouble());
      canvas.translate(geo.cx, size.height * 0.5);
      canvas.rotate(math.pi * eased);
      canvas.translate(-geo.cx, -size.height * 0.5);
    }

    canvas.save(); // S2：玻璃内裁剪
    canvas.clipPath(_glassPath);
    _paintTopBulb(canvas, geo, size);
    _paintBottomBulb(canvas, geo, size);
    _paintStreamCore(canvas, geo);
    _paintParticles(canvas);
    canvas.restore(); // ← S2

    // 玻璃轮廓（两层：冷白内壁 + 金色外缘）
    canvas.drawPath(_glassPath, _glassPaint);
    canvas.drawPath(_glassPath, _goldEdgePaint);
    // 细颈内壁高光
    canvas.drawLine(
      Offset(geo.cx - geo.neckW * 0.32, geo.neckTopY),
      Offset(geo.cx - geo.neckW * 0.32, geo.neckBottomY),
      _neckPaint,
    );

    canvas.restore(); // ← S1

    // 翻转期间的暗场：0 → 0.35 → 0，掩盖颗粒在旋转时的失真
    if (flip > 0) {
      final a = (math.sin(math.pi * flip.clamp(0.0, 1.0).toDouble()) * 0.35)
          .clamp(0.0, 0.35)
          .toDouble();
      _flipShadowPaint.color = const Color(0xFF000000).withValues(alpha: a);
      canvas.drawRect(Offset.zero & size, _flipShadowPaint);
    }
  }

  // ------------------------------------------------------------------ 上腔

  void _paintTopBulb(Canvas canvas, HourglassGeometry geo, Size size) {
    final surface = p.topSurface;
    var first = -1;
    var last = -1;
    for (var j = 0; j < kColumns; j++) {
      if (surface[j] >= 0) {
        if (first < 0) first = j;
        last = j;
      }
    }
    if (first < 0 || last <= first) return;

    _topSandPath.reset();
    _topSandPath.moveTo(geo.columnX(first), surface[first]);
    for (var j = first + 1; j <= last; j++) {
      _topSandPath.lineTo(geo.columnX(j), surface[j]);
    }
    final bottom = geo.neckTopY - geo.neckW * 0.5;
    _topSandPath
      ..lineTo(geo.columnX(last), bottom)
      ..lineTo(geo.columnX(first), bottom)
      ..close();

    // 本体渐变 + 砂粒纹理 + 深处阴影（裁剪一次，画三笔）
    canvas.drawPath(_topSandPath, _topFillPaint);
    canvas.save();
    canvas.clipPath(_topSandPath);
    // 纹理 shader 只在 ImageShader 建成时才有；缺纹理时跳过，绝不画成黑块
    if (_grainPaint.shader != null) {
      canvas.drawRect(Offset.zero & size, _grainPaint);
    }
    if (_bedPaint.shader != null) {
      canvas.drawRect(Offset.zero & size, _bedPaint);
    }
    canvas.drawRect(Offset.zero & size, _topShadowPaint);
    canvas.restore();

    // 沙脊：宽发光 + 细亮线（沙面"立得住"的关键）
    _ridgePath.reset();
    _ridgePath.moveTo(geo.columnX(first), surface[first]);
    for (var j = first + 1; j <= last; j++) {
      _ridgePath.lineTo(geo.columnX(j), surface[j]);
    }
    canvas.drawPath(_ridgePath, _ridgeGlowPaint);
    canvas.drawPath(_ridgePath, _ridgePaint);
  }

  // ------------------------------------------------------------------ 下腔

  void _paintBottomBulb(Canvas canvas, HourglassGeometry geo, Size size) {
    final surface = p.bottomSurface;
    var first = -1;
    var last = -1;
    for (var j = 0; j < kColumns; j++) {
      if (surface[j] < geo.bottomY - 0.5) {
        if (first < 0) first = j;
        last = j;
      }
    }
    if (first < 0 || last <= first) return;

    _bottomSandPath.reset();
    _bottomSandPath.moveTo(geo.columnX(first), surface[first]);
    for (var j = first + 1; j <= last; j++) {
      _bottomSandPath.lineTo(geo.columnX(j), surface[j]);
    }
    _bottomSandPath
      ..lineTo(geo.columnX(last), geo.bottomY)
      ..lineTo(geo.columnX(first), geo.bottomY)
      ..close();

    canvas.drawPath(_bottomSandPath, _bottomFillPaint);
    canvas.save();
    canvas.clipPath(_bottomSandPath);
    if (_grainPaint.shader != null) {
      canvas.drawRect(Offset.zero & size, _grainPaint);
    }
    if (_bedPaint.shader != null) {
      canvas.drawRect(Offset.zero & size, _bedPaint);
    }
    canvas.restore();

    // 锥面高光：沿堆顶的一条亮线，强调"锥形沙丘"
    _conePath.reset();
    _conePath.moveTo(geo.columnX(first), surface[first]);
    for (var j = first + 1; j <= last; j++) {
      _conePath.lineTo(geo.columnX(j), surface[j]);
    }
    canvas.drawPath(_conePath, _conePaint);
  }

  // ------------------------------------------------------------------ 束流

  /// 细颈 → 堆顶的一条实心砂束（颗粒之外的"连续感"来源）
  void _paintStreamCore(Canvas canvas, HourglassGeometry geo) {
    if (p.flowIntensity <= 0.0) return;
    final surface = p.bottomSurface;
    const mid = kColumns >> 1;
    final targetY = math.min(surface[mid], geo.bottomY);
    _streamPaint
      ..strokeWidth = math.max(1.0, geo.neckW * 0.55)
      ..color = const Color(0x88FFE3A3);
    canvas.drawLine(
      Offset(geo.cx, geo.neckTopY - geo.neckW * 0.5),
      Offset(geo.cx, targetY),
      _streamPaint,
    );
  }

  void _paintParticles(Canvas canvas) {
    final tones = p.pointsByTone;
    for (var i = 0; i < tones.length; i++) {
      _particlePaint
        ..color = _tones[i]
        ..strokeWidth = 1.15 + 0.35 * p.density;
      canvas.drawRawPoints(ui.PointMode.points, tones[i], _particlePaint);
    }
    _sparkPaint
      ..color = const Color(0xCCFFF7DE)
      ..strokeWidth = 1.0;
    canvas.drawRawPoints(ui.PointMode.points, p.sparkPoints, _sparkPaint);
  }

  // ------------------------------------------------------------------ 缓存

  /// 纹理只生成一次；`toImageSync` 不放进 paint 的每帧路径
  void _ensureImages() {
    if (_grainTex != null && _bedTex != null) return;
    _grainTex ??= _renderSandNoise(256);
    _bedTex ??= _renderSandBed(320);
  }

  void _rebuildCache(HourglassGeometry geo, Size size) {
    _cachedSize = size;
    final views = ui.PlatformDispatcher.instance.views;
    if (views.isNotEmpty) {
      _dpr = views.first.devicePixelRatio.clamp(1.0, 4.0).toDouble();
    }

    _buildGlassPath(geo);

    // 背景
    _bgPaint.shader = ui.Gradient.linear(
      Offset.zero,
      Offset(0, size.height),
      const [Color(0xFF0B0810), Color(0xFF14100A), Color(0xFF08060A)],
      const [0.0, 0.55, 1.0],
    );

    // 上腔沙体：面亮 → 颈口深
    _topFillPaint.shader = ui.Gradient.linear(
      Offset(0, geo.topY),
      Offset(0, geo.neckTopY),
      const [
        Color(0xFFE0B65A),
        Color(0xFFC79A3B),
        Color(0xFF8E6A22),
        Color(0xFF53360F),
      ],
      const [0.0, 0.34, 0.72, 1.0],
    );
    // 下腔沙体：堆顶亮 → 底部深
    _bottomFillPaint.shader = ui.Gradient.linear(
      Offset(0, geo.neckBottomY),
      Offset(0, geo.bottomY),
      const [
        Color(0xFF6A4712),
        Color(0xFF9C7326),
        Color(0xFFCEA349),
        Color(0xFFE8C372),
      ],
      const [0.0, 0.42, 0.78, 1.0],
    );
    // 上腔深处阴影
    _topShadowPaint.shader = ui.Gradient.linear(
      Offset(0, geo.topY),
      Offset(0, geo.neckTopY),
      const [
        Color(0x00000000),
        Color(0x14000000),
        Color(0x4D000000),
        Color(0x71000000),
      ],
      const [0.0, 0.4, 0.75, 1.0],
    );

    // 砂粒纹理：1 texel = 1 物理像素，平铺即"沙"的密实感
    final grain = _grainTex;
    if (grain != null) {
      _grainPaint.shader = ui.ImageShader(
        grain,
        TileMode.repeated,
        TileMode.repeated,
        _matrix(1.0 / _dpr),
        filterQuality: FilterQuality.low,
      );
    }
    final bed = _bedTex;
    if (bed != null) {
      _bedPaint
        ..shader = ui.ImageShader(
          bed,
          TileMode.repeated,
          TileMode.repeated,
          _matrix(1.0 / _dpr),
          filterQuality: FilterQuality.medium,
        )
        ..blendMode = BlendMode.overlay;
    }
  }

  /// 玻璃外形：上下腔 + 细颈，绕画面中心 180° 自映射
  void _buildGlassPath(HourglassGeometry geo) {
    const steps = 20;
    final halfG = geo.glassW * 0.5;
    final halfNeck = geo.neckW * 0.5;
    final path = _glassPath..reset();

    path.moveTo(geo.cx - halfG, geo.topY);
    // 上腔左壁
    for (var i = 1; i <= steps; i++) {
      final y = geo.topY + (geo.neckTopY - geo.topY) * i / steps;
      path.lineTo(geo.cx - geo.halfWidthTopAt(y), y);
    }
    // 细颈左壁
    path.lineTo(geo.cx - halfNeck, geo.neckBottomY);
    // 下腔左壁
    for (var i = 1; i <= steps; i++) {
      final y = geo.neckBottomY + (geo.bottomY - geo.neckBottomY) * i / steps;
      path.lineTo(geo.cx - geo.halfWidthBottomAt(y), y);
    }
    // 弧底
    path.quadraticBezierTo(
      geo.cx,
      geo.bottomY + geo.glassW * 0.10,
      geo.cx + halfG,
      geo.bottomY,
    );
    // 下腔右壁（上行）
    for (var i = steps - 1; i >= 0; i--) {
      final y = geo.neckBottomY + (geo.bottomY - geo.neckBottomY) * i / steps;
      path.lineTo(geo.cx + geo.halfWidthBottomAt(y), y);
    }
    // 细颈右壁 + 上腔右壁（上行）
    path.lineTo(geo.cx + halfNeck, geo.neckTopY);
    for (var i = steps - 1; i >= 0; i--) {
      final y = geo.topY + (geo.neckTopY - geo.topY) * i / steps;
      path.lineTo(geo.cx + geo.halfWidthTopAt(y), y);
    }
    // 顶部弧
    path.quadraticBezierTo(
      geo.cx,
      geo.topY - geo.glassW * 0.06,
      geo.cx - halfG,
      geo.topY,
    );
    path.close();
  }

  Float64List _matrix(double scale) {
    return Float64List.fromList(<double>[
      scale, 0, 0, 0, //
      0, scale, 0, 0, //
      0, 0, 1, 0, //
      0, 0, 0, 1, //
    ]);
  }

  static double _easeInOutCubic(double t) {
    if (t < 0.5) return 4 * t * t * t;
    final f = -2 * t + 2;
    return 1 - (f * f * f) / 2;
  }

  @override
  bool shouldRepaint(covariant HourglassPainter oldDelegate) => false;

  @override
  bool shouldRebuildSemantics(covariant HourglassPainter oldDelegate) =>
      false;
}

// ---------------------------------------------------------------------------
// 纹理预渲染（从 gold_sand.dart 迁移，行为保持一致）
// ---------------------------------------------------------------------------

/// 沙丘纹理：成团的明暗起伏（中灰底，overlay 时中灰不改变底色）
ui.Image? _renderSandBed(int side) {
  try {
    final s = side.toDouble();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, Rect.fromLTWH(0, 0, s, s));
    final rnd = math.Random(4471);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, s, s),
      Paint()..color = const Color(0xFF808080),
    );

    for (var i = 0; i < 68; i++) {
      final px = rnd.nextDouble() * s;
      final py = rnd.nextDouble() * s;
      final rx = s * (0.05 + rnd.nextDouble() * 0.20);
      final ry = rx * (0.22 + rnd.nextDouble() * 0.55);
      final bright = rnd.nextBool();
      final a = 0.12 + rnd.nextDouble() * 0.22;
      final col = bright ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
      final paint = Paint()
        ..shader = ui.Gradient.radial(
          Offset(px, py),
          rx,
          [col.withValues(alpha: a), col.withValues(alpha: 0)],
          const [0.0, 1.0],
        );
      for (var ox = -1; ox <= 1; ox++) {
        for (var oy = -1; oy <= 1; oy++) {
          canvas.save();
          canvas.translate(ox * s, oy * s);
          canvas.translate(px, py);
          canvas.scale(1.0, ry / rx);
          canvas.drawCircle(Offset.zero, rx, paint);
          canvas.restore();
        }
      }
    }

    final pic = rec.endRecording();
    final img = pic.toImageSync(side, side);
    pic.dispose();
    return img;
  } catch (_) {
    return null;
  }
}

/// 砂粒纹理：密集的明暗小点，平铺后就是沙面的颗粒质感
ui.Image? _renderSandNoise(int side) {
  try {
    final s = side.toDouble();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, Rect.fromLTWH(0, 0, s, s));
    final rnd = math.Random(99173);

    void dot(double x, double y, double r, Paint p) {
      canvas.drawCircle(Offset(x, y), r, p);
      if (x < r) canvas.drawCircle(Offset(x + s, y), r, p);
      if (x > s - r) canvas.drawCircle(Offset(x - s, y), r, p);
      if (y < r) canvas.drawCircle(Offset(x, y + s), r, p);
      if (y > s - r) canvas.drawCircle(Offset(x, y - s), r, p);
      if (x < r && y < r) canvas.drawCircle(Offset(x + s, y + s), r, p);
      if (x > s - r && y < r) canvas.drawCircle(Offset(x - s, y + s), r, p);
      if (x < r && y > s - r) canvas.drawCircle(Offset(x + s, y - s), r, p);
      if (x > s - r && y > s - r) canvas.drawCircle(Offset(x - s, y - s), r, p);
    }

    final light = Paint();
    final dark = Paint();

    final n = (s * s / 6.2).round();
    for (var i = 0; i < n; i++) {
      final x = rnd.nextDouble() * s;
      final y = rnd.nextDouble() * s;
      final bright = rnd.nextDouble() < 0.56;
      final r = 0.42 + rnd.nextDouble() * 0.80;
      final a = 0.10 + rnd.nextDouble() * 0.30;
      final p = bright ? light : dark;
      p.color = (bright ? const Color(0xFFFFF3D2) : const Color(0xFF2A1A06))
          .withValues(alpha: a);
      dot(x, y, r, p);
    }

    final n2 = (s * s / 95).round();
    for (var i = 0; i < n2; i++) {
      final x = rnd.nextDouble() * s;
      final y = rnd.nextDouble() * s;
      light.color =
          const Color(0xFFFFF8E0).withValues(alpha: 0.32 + rnd.nextDouble() * 0.34);
      dot(x, y, 0.65 + rnd.nextDouble() * 1.0, light);
    }

    final n3 = (s * s / 130).round();
    for (var i = 0; i < n3; i++) {
      final x = rnd.nextDouble() * s;
      final y = rnd.nextDouble() * s;
      dark.color =
          const Color(0xFF150C02).withValues(alpha: 0.16 + rnd.nextDouble() * 0.22);
      dot(x, y, 0.9 + rnd.nextDouble() * 1.3, dark);
    }

    final pic = rec.endRecording();
    final img = pic.toImageSync(side, side);
    pic.dispose();
    return img;
  } catch (_) {
    return null;
  }
}
