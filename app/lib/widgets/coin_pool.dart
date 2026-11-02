import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// 金币池动态背景
///
/// 设计要点：
/// * 背景是一整池会流动的金币，物理由自写的简易刚体模拟驱动（重力 / 池壁碰撞 /
///   金币互撞 / 阻尼），静置时自然堆在池底；
/// * 手机倾斜时重力方向随加速度计变化，金币整体向低处滑落；
/// * 摇晃手机时加速度突变给所有金币一个冲量，金币腾空翻面并带出光晕；
/// * 没有传感器（Web / 模拟器 / 浏览器未授权）时退化为缓慢的呼吸式摆动，
///   保证任何平台都不是静止画面；
/// * 金币图形预渲染成 sprite（每种尺寸一张），每帧只做变换贴图，避免逐帧
///   创建渐变 shader 造成掉帧。
class CoinPoolBackground extends StatefulWidget {
  /// 登录后背景变淡（金币透明度下降 + 遮罩加深）
  final bool dimmed;

  /// 金币数量系数，1.0 为默认密度
  final double density;

  const CoinPoolBackground({
    super.key,
    this.dimmed = false,
    this.density = 1.0,
  });

  @override
  State<CoinPoolBackground> createState() => _CoinPoolBackgroundState();
}

class _CoinPoolBackgroundState extends State<CoinPoolBackground>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late final _CoinPoolPhysics _physics = _CoinPoolPhysics();
  late final _CoinPoolPainter _painter = _CoinPoolPainter(_physics);

  StreamSubscription<AccelerometerEvent>? _accSub;
  Duration _lastTick = Duration.zero;
  Timer? _sensorFallbackTimer;
  bool _sensorAlive = false;
  double _time = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    _listenSensors();
    // 1.5s 内没有传感器数据 → 走模拟摆动（Web / 模拟器无传感器）
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
    // 卡顿 / 切后台回来时钳制步长，避免物理爆炸
    final step = dt.clamp(0.0, 1 / 24);
    _time += step;
    _physics.step(step, _time);
  }

  @override
  void didUpdateWidget(covariant CoinPoolBackground old) {
    super.didUpdateWidget(old);
    if (old.density != widget.density) _physics.resetDensity(widget.density);
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
            opacity: dim ? 0.32 : 1.0,
            child: CustomPaint(painter: _painter, isComplex: true),
          ),
        ),
        // 遮罩：保证前景文字可读，登录后更深
        IgnorePointer(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 700),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dim
                    ? const [
                        Color(0x8C0A0A10),
                        Color(0x9E0A0A10),
                        Color(0xB80A0A10),
                      ]
                    : const [
                        Color(0x400A0A10),
                        Color(0x5C0A0A10),
                        Color(0x800A0A10),
                      ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CoinPoolPainter extends CustomPainter {
  final _CoinPoolPhysics _p;
  _CoinPoolPainter(this._p) : super(repaint: _p);

  @override
  void paint(Canvas canvas, Size size) => _p.paint(canvas, size);

  @override
  bool shouldRepaint(covariant _CoinPoolPainter oldDelegate) => false;

  @override
  bool shouldRebuildSemantics(covariant _CoinPoolPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// 物理 + 绘制
// ---------------------------------------------------------------------------

class _Coin {
  _Coin({
    required this.x,
    required this.y,
    required this.r,
    required this.sprite,
    required this.ang,
    required this.flip,
  });

  double x, y;
  double vx = 0, vy = 0;
  final double r;

  /// 贴图下标
  final int sprite;

  /// 平面旋转角
  double ang;

  /// 翻面相位（模拟金币 3D 自转）
  double flip;

  double spin = 0;
  double flipSpeed = 0;
}

class _CoinPoolPhysics extends ChangeNotifier {
  static const double _gravity = 2500;
  static const double _restitution = 0.34;
  static const double _damping = 0.995;

  final _rand = math.Random(7);
  final List<_Coin> _coins = [];
  final List<ui.Image> _sprites = [];

  /// 与 _sprites 一一对应的设计半径（用于按屏幕宽度等比缩放）
  final List<double> _spriteRadius = [];

  /// 重力方向（由加速度计给出，单位化到约 -1..1）
  double _gx = 0;
  double _gy = 0.85;

  /// 摇晃时的高亮脉冲
  double _flash = 0;
  double _flashX = 0.5, _flashY = 0.5;
  DateTime _lastKick = DateTime.fromMillisecondsSinceEpoch(0);

  bool autoSway = false;
  Size _size = Size.zero;
  double _density = 1.0;
  bool _built = false;

  _CoinPoolPhysics() {
    _buildSprites();
  }

  void onAccelerometer(double x, double y, double z) {
    // 屏幕坐标系：x 向右、y 向下；手机竖起时 ay≈9.81 → 金币向下堆
    final mag = math.sqrt(x * x + y * y + z * z);

    // 部分浏览器 / 模拟器会上报 (0,0,0) 之类的空数据，这不是真重力，
    // 直接忽略并切到自动摆动，避免把金币"踢"到屏幕各处。
    if (mag < 1.0) {
      autoSway = true;
      return;
    }
    autoSway = false;

    final now = DateTime.now();
    // 摇晃检测：合加速度明显超过 2g，且距上次冲量 >300ms
    if (mag > 22 && now.difference(_lastKick).inMilliseconds > 300) {
      _lastKick = now;
      _kick(strength: (mag / 34).clamp(0.5, 1.5));
    }

    // 归一化到 -1..1（1g ≈ 9.81），并限制幅度
    var nx = x / 9.81;
    var ny = y / 9.81;
    if (nx.abs() > 1.5) nx = nx.sign * 1.5;
    if (ny.abs() > 1.5) ny = ny.sign * 1.5;
    // 平滑，避免手抖导致画面抖
    _gx += (nx - _gx) * 0.16;
    _gy += (ny - _gy) * 0.16;
  }

  /// 给所有金币一个冲量（摇晃 / 点击）
  void kick({double strength = 0.9}) => _kick(strength: strength);

  void _kick({required double strength}) {
    _flash = 1;
    _flashX = _rand.nextDouble();
    _flashY = _rand.nextDouble() * 0.6 + 0.3;
    for (final c in _coins) {
      c.vx += (_rand.nextDouble() - 0.5) * 900 * strength;
      c.vy += (-_rand.nextDouble() * 900 - 220) * strength;
      c.spin += (_rand.nextDouble() - 0.5) * 9 * strength;
      c.flipSpeed += (_rand.nextDouble() - 0.3) * 12 * strength;
    }
  }

  void resetDensity(double d) {
    _density = d;
    _built = false;
    rebuild();
    notifyListeners();
  }

  // ---------------------------------------------------------------- sprites
  void _buildSprites() {
    // 每种尺寸两种成色（新币 / 略带包浆的旧币），堆在一起更有层次
    for (final r in const [15.0, 19.0, 23.0, 27.0]) {
      for (var tone = 0; tone < 2; tone++) {
        final img = _renderCoin(r, tone);
        if (img != null) {
          _sprites.add(img);
          _spriteRadius.add(r);
        }
      }
    }
  }

  /// 预渲染一枚金币（齿边 + 币面 + 内圈 + 浮雕 ¥ + 高光）
  ui.Image? _renderCoin(double r, int tone) {
    final rim = tone == 0
        ? const [Color(0xFFEFC163), Color(0xFF7E4F0A)]
        : const [Color(0xFFF7D98C), Color(0xFF8E6216)];
    final face = tone == 0
        ? const [
            Color(0xFFFFF6D2),
            Color(0xFFF6CE6F),
            Color(0xFFDCA331),
            Color(0xFFA9741A),
          ]
        : const [
            Color(0xFFFFFBE6),
            Color(0xFFFFDE95),
            Color(0xFFE7B34A),
            Color(0xFFB98422),
          ];
    try {
      const s = 3.0; // 超采样，缩小后边缘更干净
      final box = (r * 2 + 8) * s;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.scale(s);
      final side = box / s;
      final center = Offset(side / 2, side / 2);
      final faceRect = Rect.fromCircle(center: center, radius: r * 0.85);
      final rimRect = Rect.fromCircle(center: center, radius: r);

      // 外圈
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: rim,
          ).createShader(rimRect),
      );

      // 齿纹
      final tick = Paint()
        ..color = const Color(0x55000000)
        ..strokeWidth = r * 0.07
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < 28; i++) {
        final a = i * math.pi * 2 / 28;
        final dir = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(
          center + dir * (r * 0.95),
          center + dir * r,
          tick,
        );
      }

      // 币面
      canvas.drawCircle(
        center,
        r * 0.85,
        Paint()
          ..shader = RadialGradient(
            center: const Alignment(-0.35, -0.45),
            radius: 1.05,
            colors: face,
            stops: const [0.0, 0.42, 0.82, 1.0],
          ).createShader(faceRect),
      );

      // 内圈
      canvas.drawCircle(
        center,
        r * 0.7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.05
          ..color = const Color(0x55A9741A),
      );

      // 浮雕 ¥（浅色错位 + 深色主体，做出倒角）
      _paintGlyph(canvas, center, r, const Color(0x66FFFFFF), -r * 0.035);
      _paintGlyph(canvas, center, r, const Color(0xFF8E6012), 0);

      // 高光弧
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: r * 0.74),
        math.pi * 1.02,
        math.pi * 0.52,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.15
          ..strokeCap = StrokeCap.round
          ..shader = const LinearGradient(
            colors: [Color(0xCCFFFFFF), Color(0x00FFFFFF)],
          ).createShader(faceRect),
      );

      return recorder.endRecording().toImageSync(box.ceil(), box.ceil());
    } catch (_) {
      return null;
    }
  }

  void _paintGlyph(
      Canvas canvas, Offset center, double r, Color color, double dy) {
    final tp = TextPainter(
      text: TextSpan(
        text: '¥',
        style: TextStyle(
          fontSize: r * 0.92,
          height: 1,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      center - Offset(tp.width / 2, tp.height / 2 + dy),
    );
  }

  // ---------------------------------------------------------------- physics
  void rebuild() {
    if (_size.isEmpty || _sprites.isEmpty) return;
    final area = _size.width * _size.height;
    final target = ((area / 5200) * _density).round().clamp(28, 96);
    // 金币大小按屏幕宽度自适应（窄屏也不至于碎成渣）
    final base = (_size.width / 20).clamp(16.0, 34.0);
    _coins.clear();
    for (var i = 0; i < target; i++) {
      final idx = _rand.nextInt(_sprites.length);
      _coins.add(_Coin(
        x: _rand.nextDouble() * _size.width,
        y: _size.height * (0.2 + _rand.nextDouble() * 0.75),
        r: base * (_spriteRadius[idx] / 19.0),
        sprite: idx,
        ang: _rand.nextDouble() * math.pi * 2,
        flip: _rand.nextDouble() * math.pi * 2,
      ));
    }
    _built = true;
  }

  void step(double dt, double time) {
    if (_size.isEmpty) return;
    if (!_built) rebuild();

    // 无传感器：缓慢呼吸式摆动，让画面始终"活着"
    if (autoSway) {
      final sx = math.sin(time * 0.55) * 0.26 + math.sin(time * 0.21) * 0.12;
      _gx += (sx - _gx) * 0.02;
      _gy += (0.9 - _gy) * 0.02;
    }

    final w = _size.width;
    final h = _size.height;
    const margin = 4.0;
    final ax = _gx * _gravity;
    final ay = _gy * _gravity;

    // 子步长提升碰撞稳定性
    final steps = (dt * 120).ceil().clamp(1, 3);
    final sdt = dt / steps;

    for (var s = 0; s < steps; s++) {
      for (final c in _coins) {
        c.vy += ay * sdt;
        c.vx += ax * sdt;
        c.vx *= _damping;
        c.vy *= _damping;
        c.x += c.vx * sdt;
        c.y += c.vy * sdt;
        c.ang += c.spin * sdt;
        c.flip += c.flipSpeed * sdt;

        if (c.x - c.r < margin) {
          c.x = margin + c.r;
          c.vx = c.vx.abs() * _restitution;
          c.spin *= 0.85;
        } else if (c.x + c.r > w - margin) {
          c.x = w - margin - c.r;
          c.vx = -c.vx.abs() * _restitution;
          c.spin *= 0.85;
        }

        if (c.y + c.r > h - margin) {
          c.y = h - margin - c.r;
          if (c.vy > 80) c.spin += c.vx * 0.002;
          c.vy = -c.vy.abs() * _restitution;
          c.vx *= 0.94; // 地面摩擦
          c.flipSpeed *= 0.9;
        } else if (c.y - c.r < -h * 0.12) {
          // 允许稍微溢出池口，溢出过头则夹住
          c.y = -h * 0.12 + c.r;
          c.vy = c.vy.abs() * 0.2;
        }
      }

      // 金币互撞（等质量近似）
      for (var i = 0; i < _coins.length; i++) {
        final a = _coins[i];
        for (var j = i + 1; j < _coins.length; j++) {
          final b = _coins[j];
          final dx = b.x - a.x;
          final dy = b.y - a.y;
          final minD = a.r + b.r;
          final dist2 = dx * dx + dy * dy;
          if (dist2 >= minD * minD || dist2 <= 0.0001) continue;
          final dist = math.sqrt(dist2);
          final nx = dx / dist;
          final ny = dy / dist;
          final push = (minD - dist) / 2;
          a.x -= nx * push;
          a.y -= ny * push;
          b.x += nx * push;
          b.y += ny * push;

          final va = a.vx * nx + a.vy * ny;
          final vb = b.vx * nx + b.vy * ny;
          if (va - vb <= 0) continue;
          final imp = (va - vb) * 0.5 * 1.2;
          a.vx -= imp * nx;
          a.vy -= imp * ny;
          b.vx += imp * nx;
          b.vy += imp * ny;
          a.spin += imp * 0.0012;
          b.spin -= imp * 0.0012;
        }
      }
    }

    if (_flash > 0) _flash = math.max(0, _flash - dt * 1.8);
    notifyListeners();
  }

  // ---------------------------------------------------------------- paint
  void paint(Canvas canvas, Size size) {
    if (size != _size) {
      _size = size;
      _built = false;
    }
    if (!_built) rebuild();

    final rect = Offset.zero & size;

    // 池底氛围光
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF07070B), Color(0xFF12100C), Color(0xFF1C1509)],
          stops: [0.0, 0.55, 1.0],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, 0.95),
          radius: 1.0,
          colors: [
            const Color(0xFFFFC65C).withValues(alpha: 0.22),
            const Color(0x00FFC65C),
          ],
        ).createShader(rect),
    );

    // 摇晃高亮
    if (_flash > 0.01) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = RadialGradient(
            center: Alignment((_flashX - 0.5) * 2, (_flashY - 0.5) * 2),
            radius: 1.1,
            colors: [
              const Color(0xFFFFE7A8).withValues(alpha: 0.22 * _flash),
              const Color(0x00FFE7A8),
            ],
          ).createShader(rect),
      );
    }

    // 金币按 y 排序，下方（靠前）的压在上面
    final sorted = List<_Coin>.from(_coins)..sort((a, b) => a.y.compareTo(b.y));
    for (final c in sorted) {
      _paintCoin(canvas, c);
    }

    _paintGlass(canvas, size);
  }

  void _paintCoin(Canvas canvas, _Coin c) {
    if (_sprites.isEmpty) return;
    final img = _sprites[c.sprite.clamp(0, _sprites.length - 1)];

    // 投影
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(c.x, c.y + c.r * 0.82),
        width: c.r * 1.7,
        height: c.r * 0.46,
      ),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );

    // 翻面：x 方向压缩，模拟金币绕竖轴自转
    final flip = math.cos(c.flip);
    final sx = flip.abs() < 0.14 ? 0.14 : flip.abs();
    final d = (c.r * 2 + 8);

    canvas.save();
    canvas.translate(c.x, c.y);
    canvas.rotate(c.ang);
    canvas.scale(sx, 1.0);
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromCenter(center: Offset.zero, width: d, height: d),
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.restore();
  }

  /// 玻璃池体：斜向反光 + 池口高光 + 暗角
  void _paintGlass(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.05),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.42],
        ).createShader(rect),
    );

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, 2),
      Paint()
        ..shader = const LinearGradient(
          colors: [Color(0x33FFD98A), Color(0x00FFD98A), Color(0x33FFD98A)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, 2)),
    );

    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          radius: 0.95,
          colors: [Color(0x00000000), Color(0x00000000), Color(0x77000000)],
          stops: [0.0, 0.62, 1.0],
        ).createShader(rect),
    );
  }

  @override
  void dispose() {
    for (final s in _sprites) {
      s.dispose();
    }
    _sprites.clear();
    _spriteRadius.clear();
    super.dispose();
  }
}
