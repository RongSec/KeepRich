import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// 金沙流沙背景
///
/// 入场：整片金沙从屏幕上方倾泻而下，在底部堆成一座沙丘，最终停在屏幕一半
/// 左右的高度；落定后沙面随手机倾斜而流动（倾斜侧下沉、沙子沿坡滑落）。
///
/// 结构：
/// 1. **沙堆本体**：一个高度场 surfaceY(x)，从 fill=0 长到 fill=1（半屏）。
///    Path 裁剪后铺金色渐变 + 砂粒纹理，越往深处越暗，形成沙堆的厚度感；
/// 2. **沙脊**：沿 surfaceY 的一条亮线（受光的沙面边缘），沙堆立得住的关键；
/// 3. **表层颗粒**：几千颗细砂贴在沙面上，负责流动、滑落、扬起；
/// 4. **闪光**：沙面各处相位错开的细碎高光。
///
/// 沙量守恒：沙面以屏幕中心为轴倾斜，倾斜侧变低、另一侧变高，总量不变，所以
/// 怎么晃都不会"流干"或"溢出"。
class GoldSandBackground extends StatefulWidget {
  /// 登录后变淡
  final bool dimmed;

  /// 颗粒密度系数，1.0 为默认
  final double density;

  /// 落定后沙面所在的屏幕高度比例（0.5 = 屏幕一半）
  final double fillRatio;

  const GoldSandBackground({
    super.key,
    this.dimmed = false,
    this.density = 1.0,
    this.fillRatio = 0.5,
  });

  @override
  State<GoldSandBackground> createState() => _GoldSandBackgroundState();
}

class _GoldSandBackgroundState extends State<GoldSandBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final _SandPhysics _physics = _SandPhysics();
  late final _SandPainter _painter = _SandPainter(_physics);

  StreamSubscription<AccelerometerEvent>? _accSub;
  Duration _lastTick = Duration.zero;
  Timer? _sensorFallbackTimer;
  bool _sensorAlive = false;
  double _time = 0;

  @override
  void initState() {
    super.initState();
    _physics.fillRatio = widget.fillRatio;
    _ticker = createTicker(_onTick)..start();
    _listenSensors();
    _sensorFallbackTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!_sensorAlive) _physics.autoSway = true;
    });
  }

  void _listenSensors() {
    try {
      _accSub = accelerometerEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen(
        (e) {
          _sensorAlive = true;
          _physics.onAccelerometer(e.x, e.y, e.z);
        },
        onError: (Object _) => _physics.autoSway = true,
        cancelOnError: false,
      );
    } catch (_) {
      _physics.autoSway = true;
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _lastTick == Duration.zero
        ? 1 / 60
        : (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    final step = dt.clamp(0.0, 1 / 24);
    _time += step;
    _physics.step(step, _time);
  }

  @override
  void didUpdateWidget(covariant GoldSandBackground old) {
    super.didUpdateWidget(old);
    if (old.density != widget.density) _physics.resetDensity(widget.density);
    if (old.fillRatio != widget.fillRatio) {
      _physics.fillRatio = widget.fillRatio;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _accSub?.cancel();
    _sensorFallbackTimer?.cancel();
    _physics.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dim = widget.dimmed;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeOutCubic,
            opacity: dim ? 0.20 : 1.0,
            child: CustomPaint(painter: _painter, isComplex: true),
          ),
        ),
        // 遮罩：上半屏本来是空的暗处，这里主要压住底部与状态栏
        IgnorePointer(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 700),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dim
                    ? const [
                        Color(0xC80A0A10),
                        Color(0xB40A0A10),
                        Color(0xC40A0A10),
                      ]
                    : const [
                        Color(0x4A0A0A10),
                        Color(0x330A0A10),
                        Color(0x660A0A10),
                      ],
                stops: const [0.0, 0.42, 1.0],
              ),
            ),
          ),
        ),
        // 顶部 / 底部渐隐：状态栏、标题、底部导航区域保持干净
        Positioned.fill(
          child: IgnorePointer(
            child: Column(
              children: [
                Container(
                  height: 150,
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
                  height: 140,
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
  }
}

class _SandPainter extends CustomPainter {
  final _SandPhysics _p;
  _SandPainter(this._p) : super(repaint: _p);

  @override
  void paint(Canvas canvas, Size size) => _p.paint(canvas, size);

  @override
  bool shouldRepaint(covariant _SandPainter oldDelegate) => false;

  @override
  bool shouldRebuildSemantics(covariant _SandPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// 颗粒
// ---------------------------------------------------------------------------

/// 沙粒
class _Grain {
  _Grain({
    required this.x,
    required this.y,
    required this.vy,
    required this.size,
    required this.tone,
    required this.phase,
    required this.swirl,
    required this.depth,
  });

  double x, y;

  /// 下落速度（入场阶段）
  double vy;

  /// 已经落到沙面上
  bool landed = false;

  /// 扬起高度
  double z = 0;
  double vz = 0;

  double vx = 0;

  final double size;
  final int tone;
  double phase;
  final double swirl;

  /// 在沙面下方的深度（0 = 最表层）
  final double depth;

  /// 已经并入沙堆：不再单独绘制（沙堆本体由纹理负责）
  bool merged = false;
}

/// 闪光点
class _Spark {
  _Spark({
    required this.x,
    required this.offset,
    required this.phase,
    required this.speed,
    required this.scale,
  });

  double x;

  /// 相对沙面的高度偏移（负值在沙面上方）
  double offset;
  final double phase;
  final double speed;
  final double scale;
}

class _SandPhysics extends ChangeNotifier {
  /// 扬起后落回的重力
  static const double _gravity = 1500;

  /// 入场下落的重力：比自由落体慢，沙帘才看得清（真实沙子有空气阻力+颗粒互撞）
  static const double _fallGravity = 620;

  final math.Random _rand = math.Random(0x5A4D);

  final List<_Grain> _grains = [];
  final List<_Spark> _sparks = [];

  ui.Image? _bed;
  ui.Image? _grainTex;

  Size _size = Size.zero;
  double _density = 1.0;
  double _dpr = 1.0;
  bool _built = false;

  /// 落定后沙面所在的屏幕高度比例
  double fillRatio = 0.5;

  /// 已落地的沙粒数（沙面高度由它决定，沙量和画面才对得上）
  int _landed = 0;

  /// 沙量进度：0 = 空的，1 = 堆到 fillRatio
  double get _fill =>
      _grains.isEmpty ? 0.0 : (_landed / _grains.length).clamp(0.0, 1.0);

  /// 沙面坡度（由倾斜驱动）
  double _slope = 0;

  /// 沙丘起伏的推移相位（只在倾斜时推进）
  double _flow = 0;

  /// 上一帧坡度，用来判断沙面是否还在动
  double _prevSlope = 0;

  double _gx = 0, _gy = 0;
  double _tx = 0, _ty = 0;

  bool autoSway = false;
  double _swayPhase = 0;
  double _t = 0;

  DateTime _lastKick = DateTime.fromMillisecondsSinceEpoch(0);

  final List<List<Offset>> _buckets =
      List.generate(_SandPalette.grains.length, (_) => <Offset>[]);
  final Paint _pointPaint = Paint()..strokeCap = StrokeCap.round;
  final Paint _sparkPaint = Paint();
  final Paint _crossPaint = Paint()
    ..strokeWidth = 0.9
    ..strokeCap = StrokeCap.round;

  // ---------------------------------------------------------------- 传感器

  void onAccelerometer(double x, double y, double z) {
    final mag = math.sqrt(x * x + y * y + z * z);
    final now = DateTime.now();

    if ((mag > 20 || mag < 3.6) &&
        now.difference(_lastKick).inMilliseconds > 240) {
      _lastKick = now;
      final strength = mag > 20 ? (mag / 28).clamp(0.5, 1.6) : 0.45;
      _shake(strength: strength);
    }

    var nx = x / 9.81;
    var ny = y / 9.81;
    if (nx.abs() > 1.4) nx = nx.sign * 1.4;
    if (ny.abs() > 1.4) ny = ny.sign * 1.4;
    _tx = nx;
    _ty = ny;
  }

  // ---------------------------------------------------------------- 初始化

  void resetDensity(double d) {
    _density = d;
    _built = false;
    rebuild();
  }

  /// [notify] = false 用于 paint 期间重建（此时不能再 notifyListeners，
  /// 否则会触发 markNeedsPaint 断言：'!owner!.debugDoingPaint'）
  void rebuild({bool notify = true}) {
    if (_size.isEmpty) return;
    _ensureSprites();

    final views = ui.PlatformDispatcher.instance.views;
    if (views.isNotEmpty) {
      _dpr = views.first.devicePixelRatio.clamp(1.0, 4.0);
    }

    final area = _size.width * _size.height;
    final grainCount = ((area / 46) * _density).round().clamp(2500, 12000);
    final sparkCount = (grainCount / 7).round().clamp(60, 420);

    _grains.clear();
    _sparks.clear();

    // 初始全部悬在屏幕上方：一打开就是"从头顶倾泻"的姿态
    for (var i = 0; i < grainCount; i++) {
      _grains.add(_Grain(
        x: _rand.nextDouble() * _size.width,
        // 高度按 t² 分布：自由落体里 d ∝ t²，这样落地速率才是均匀的
        // （否则大部分沙粒挤在头一秒落完，沙面会"先猛涨再慢慢补"）
        y: -20 -
            _rand.nextDouble() *
                _rand.nextDouble() *
                _size.height *
                1.45,
        vy: 10 + _rand.nextDouble() * 60,
        size: 0.8 + _rand.nextDouble() * 1.1,
        tone: _rand.nextInt(_SandPalette.grains.length),
        phase: _rand.nextDouble() * math.pi * 2,
        swirl: 3 + _rand.nextDouble() * 8,
        depth: _rand.nextDouble() * 10,
      ));
    }
    for (var i = 0; i < sparkCount; i++) {
      _sparks.add(_Spark(
        x: _rand.nextDouble() * _size.width,
        offset: -_rand.nextDouble() * 14,
        phase: _rand.nextDouble() * math.pi * 2,
        speed: 0.9 + _rand.nextDouble() * 2.2,
        scale: 0.5 + _rand.nextDouble() * 0.9,
      ));
    }

    _landed = 0;
    _built = true;
    if (notify) notifyListeners();
  }

  void _ensureSprites() {
    _bed ??= _renderSandBed(320);
    _grainTex ??= _renderSandNoise(256);
  }

  // ---------------------------------------------------------------- 沙面

  /// 沙面高度：屏幕底为 H，fill=1 时升到 (1-fillRatio)*H
  double surfaceY(double x) {
    final h = _size.height;
    final w = _size.width;
    if (h <= 0 || w <= 0) return 0;
    final ease = _fill;
    final base = h - ease * fillRatio * h;

    final nx = (x / w - 0.5) * 2; // -1..1
    // 倾斜：向右倾（gx>0）沙往右下堆，右侧沙面更低（y 更大）
    final tilt = -_slope * nx * h * 0.16;
    // 沙丘起伏：两组低频正弦，随 _flow 缓慢推移
    final ripple = (math.sin(nx * 2.6 + _flow) * 0.62 +
            math.sin(nx * 5.7 - _flow * 0.7 + 1.3) * 0.38) *
        h *
        0.020 *
        ease;
    return base + tilt + ripple;
  }

  // ---------------------------------------------------------------- 扰动

  void _shake({required double strength}) {
    for (final g in _grains) {
      if (!g.landed) continue;
      if (_rand.nextDouble() < 0.5) {
        final v = (25 + _rand.nextDouble() * 120) * strength;
        g.vx += (_rand.nextBool() ? 1 : -1) * v * 0.4;
        if (_rand.nextDouble() < 0.55) {
          g.vz += (50 + _rand.nextDouble() * 190) * strength;
          g.z += _rand.nextDouble() * 1.5;
        }
      }
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- 步进

  void step(double dt, double t) {
    if (_size.isEmpty) return;
    if (!_built) rebuild();
    _t = t;

    if (autoSway) {
      _swayPhase += dt * 0.30;
      _tx = math.sin(_swayPhase) * 0.30;
      _ty = math.sin(_swayPhase * 0.71 + 1.2) * 0.12;
    }

    final k = math.min(1.0, dt * 5.0);
    _gx += (_tx - _gx) * k;
    _gy += (_ty - _gy) * k;

    // 入场：沙面高度由落地的沙粒数决定，不需要额外的计时
    final landing = _landed < _grains.length;

    // 坡度追随倾斜：慢一点，沙子有惯性
    final targetSlope = (-_gx).clamp(-1.0, 1.0) * 0.62;
    _slope += (targetSlope - _slope) * math.min(1.0, dt * 2.6);

    // 沙丘起伏只在倾斜时推移：手机放平就完全静止
    final tiltMag = _gx.abs() + (_gy.abs() - 1.0).abs() * 0.35;
    _flow += dt * tiltMag * 1.3;

    var active = landing || _gx.abs() > 0.02 || (_slope - _prevSlope).abs() > 0.0008;
    _prevSlope = _slope;

    final w = _size.width;
    final h = _size.height;
    final dampFast = math.pow(0.02, dt).toDouble();

    for (final g in _grains) {
      if (g.merged) continue;
      final sy = surfaceY(g.x) - g.depth * 0.35;

      if (!g.landed) {
        // 下落：越来越快，触到沙面就并入沙堆
        g.vy += _fallGravity * dt;
        g.y += g.vy * dt;
        g.x += _gx * 22 * dt;
        if (g.y >= sy) {
          g.y = sy;
          g.vy = 0;
          g.landed = true;
          _landed++;
          // 大部分沙粒落到沙面就并入沙堆，只留少数在表面继续流动
          g.merged = _rand.nextDouble() < 0.80;
        }
        active = true;
      } else {
        // 落在沙面上：沿坡滑落 + 局部涡流
        g.phase += dt * tiltMag * 2.6;
        final slide = -_slope * 26; // 坡度越大滑得越快
        g.x += (slide + math.sin(g.phase) * g.swirl + g.vx) * dt;
        g.vx *= dampFast;
        if (g.vx.abs() < 0.25) g.vx = 0;

        // 贴回沙面（沙面在长高/倾斜，颗粒必须跟着走）
        g.y = surfaceY(g.x) - g.depth * 0.35 - g.z;

        if (g.z > 0 || g.vz > 0) {
          g.vz -= _gravity * dt;
          g.z += g.vz * dt;
          if (g.z <= 0) {
            g.z = 0;
            g.vz = 0;
          }
          active = true;
        }
      }

      // 横向绕回：从一侧滑出就从另一侧流进来
      if (g.x < -10) {
        g.x += w + 20;
        if (g.landed) g.y = surfaceY(g.x) - g.depth * 0.35 - g.z;
      } else if (g.x > w + 10) {
        g.x -= w + 20;
        if (g.landed) g.y = surfaceY(g.x) - g.depth * 0.35 - g.z;
      }

      // 视口剔除
      if (g.y > h + 40) g.y = h + 40;
    }

    for (final s in _sparks) {
      s.x += (-_slope * 14) * dt;
      if (s.x < -10) {
        s.x += w + 20;
      } else if (s.x > w + 10) {
        s.x -= w + 20;
      }
    }

    // 只在真的动的时候重绘：沙面落定且手机不动 → 一帧都不再画
    if (active) {
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- 绘制

  void paint(Canvas canvas, Size size) {
    if (size != _size) {
      _size = size;
      _built = false;
      // paint 中不能 notifyListeners（会触发 markNeedsPaint 断言）
      rebuild(notify: false);
    }

    final rect = Offset.zero & size;
    final w = size.width;
    final h = size.height;

    // ---- 1. 背景：上部是空的暗处（沙还没堆到这里）
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, h),
          const [Color(0xFF0E0904), Color(0xFF140D05), Color(0xFF0A0603)],
          const [0.0, 0.5, 1.0],
        ),
    );

    if (_fill <= 0.001) return;

    // ---- 2. 沙堆轮廓
    final path = Path()..moveTo(-2, h + 2);
    const step = 6.0;
    for (var x = -2.0; x <= w + 2; x += step) {
      path.lineTo(x, surfaceY(x));
    }
    path
      ..lineTo(w + 2, h + 2)
      ..close();

    canvas.save();
    canvas.clipPath(path);

    // 沙堆本体：沙面亮、越深越暗
    final topY = surfaceY(w / 2) - 30;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, topY),
          Offset(0, h),
          const [
            Color(0xFFD8AB4A),
            Color(0xFFB98C31),
            Color(0xFF8A6520),
            Color(0xFF4E3410),
          ],
          const [0.0, 0.30, 0.66, 1.0],
        ),
    );

    // 砂粒纹理：这是"沙"的本体，1 texel = 1 物理像素
    final gtex = _grainTex;
    if (gtex != null) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.ImageShader(
            gtex,
            TileMode.repeated,
            TileMode.repeated,
            _textureMatrix(_flow * 26 * _dpr, 0, 1.0 / _dpr),
            filterQuality: FilterQuality.low,
          ),
      );
    }

    // 沙丘内部的大尺度明暗（横向拉长的斑，像被冲刷出的沙棱）
    final bed = _bed;
    if (bed != null) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.ImageShader(
            bed,
            TileMode.repeated,
            TileMode.repeated,
            _textureMatrix(_flow * 10 * _dpr, 0, 1.0 / _dpr),
            filterQuality: FilterQuality.medium,
          )
          ..blendMode = BlendMode.overlay,
      );
    }

    // 深处的阴影：越靠下越暗，沙堆才有厚度
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, topY),
          Offset(0, h),
          const [
            Color(0x00000000),
            Color(0x1A000000),
            Color(0x59000000),
            Color(0x8A000000),
          ],
          const [0.0, 0.35, 0.72, 1.0],
        ),
    );
    canvas.restore();

    // ---- 3. 沙脊：沿沙面的亮边（受光面），沙堆立得住就靠它
    final ridge = Path();
    var first = true;
    for (var x = -2.0; x <= w + 2; x += step) {
      final y = surfaceY(x);
      if (first) {
        ridge.moveTo(x, y);
        first = false;
      } else {
        ridge.lineTo(x, y);
      }
    }
    canvas.drawPath(
      ridge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..color = const Color(0x66FFE9B0)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.2),
    );
    canvas.drawPath(
      ridge,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..strokeCap = StrokeCap.round
        ..color = const Color(0x99FFF6D8),
    );

    // ---- 4. 沙粒：按色分批，每批一次 drawPoints
    for (final b in _buckets) {
      b.clear();
    }
    for (final g in _grains) {
      if (g.merged) continue;
      if (g.x < -6 || g.x > w + 6) continue;
      if (g.y < -60 || g.y > h + 10) continue;
      _buckets[g.tone].add(Offset(g.x, g.y));
    }
    for (var i = 0; i < _buckets.length; i++) {
      final pts = _buckets[i];
      if (pts.isEmpty) continue;
      _pointPaint
        ..color = _SandPalette.grains[i]
        ..strokeWidth = 1.35;
      canvas.drawPoints(ui.PointMode.points, pts, _pointPaint);
    }

    // ---- 5. 闪光：贴在沙面上，各自相位闪烁
    final t = _t;
    for (final s in _sparks) {
      final wave = math.sin(t * s.speed + s.phase);
      if (wave < 0.45) continue;
      final v = (wave - 0.45) / 0.55;
      final a = 0.20 + v * 0.80;
      final pos = Offset(s.x, surfaceY(s.x) + s.offset);
      _sparkPaint.color = const Color(0xFFFFF7DE).withValues(alpha: a);
      canvas.drawCircle(pos, (0.5 + v * 0.9) * s.scale, _sparkPaint);
      if (v > 0.88) {
        _crossPaint.color = const Color(0xFFFFF3CC).withValues(alpha: a * 0.65);
        final len = (1.1 + v * 1.6) * s.scale;
        canvas.drawLine(
            pos.translate(-len, 0), pos.translate(len, 0), _crossPaint);
        canvas.drawLine(
            pos.translate(0, -len), pos.translate(0, len), _crossPaint);
      }
    }

    // ---- 6. 沙面上方的暖光：让沙堆"发光"而不是死贴
    final sy = surfaceY(w / 2);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, sy - h * 0.22),
          Offset(0, sy + h * 0.05),
          const [Color(0x00FFC65C), Color(0x14FFD27A), Color(0x00FFC65C)],
          const [0.0, 0.6, 1.0],
        ),
    );
  }

  Float64List _textureMatrix(double tx, double ty, [double scale = 1.0]) {
    return Float64List.fromList(<double>[
      scale, 0, 0, 0, //
      0, scale, 0, 0, //
      0, 0, 1, 0, //
      tx, ty, 0, 1, //
    ]);
  }

  @override
  void dispose() {
    _bed?.dispose();
    _grainTex?.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// 调色
// ---------------------------------------------------------------------------

class _SandPalette {
  /// 沙粒：全部落在金色区间，靠明暗微差形成颗粒感
  static const List<Color> grains = [
    Color(0xFF6B4A12),
    Color(0xFF8A6520),
    Color(0xFFAE8232),
    Color(0xFFC9A24E),
    Color(0xFFE2C078),
  ];
}

// ---------------------------------------------------------------------------
// 纹理
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

    // 横向拉长的斑块（像沙面上被冲刷出的棱），四边复制保证无缝
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
///
/// 几百个动态粒子画不出沙的密实感（覆盖率不到 3%），真实的"沙"必须靠这种
/// 高频颗粒纹理。1 texel 对齐 1 物理像素，缩放时颗粒不会糊成一片。
ui.Image? _renderSandNoise(int side) {
  try {
    final s = side.toDouble();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, Rect.fromLTWH(0, 0, s, s));
    final rnd = math.Random(99173);

    // 贴边时在对侧补一份，保证平铺无缝
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

    // 主体颗粒：明暗交错，靠 alpha 叠出砂面的细密起伏
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

    // 亮砂：金沙的"亮"，少量但关键
    final n2 = (s * s / 95).round();
    for (var i = 0; i < n2; i++) {
      final x = rnd.nextDouble() * s;
      final y = rnd.nextDouble() * s;
      light.color = const Color(0xFFFFF8E0)
          .withValues(alpha: 0.32 + rnd.nextDouble() * 0.34);
      dot(x, y, 0.65 + rnd.nextDouble() * 1.0, light);
    }

    // 砂粒之间的缝隙：压暗的小坑，让颗粒之间有层次
    final n3 = (s * s / 130).round();
    for (var i = 0; i < n3; i++) {
      final x = rnd.nextDouble() * s;
      final y = rnd.nextDouble() * s;
      dark.color = const Color(0xFF150C02)
          .withValues(alpha: 0.16 + rnd.nextDouble() * 0.22);
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
