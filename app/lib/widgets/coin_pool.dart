import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// 金币池动态背景
///
/// 物理模型参考刚体圆盘（薄圆柱）而不是球：
/// * 每枚金币有倾角 tilt（0 = 平躺，π/2 = 立在边缘），投影短轴 = R·|cos tilt|
///   （mzaiss/rolling_coin 的正交投影做法），因此倾斜时是真的"椭圆 + 厚度带"，
///   而不是把正圆压扁冒充；
/// * 立在边缘滚动时按欧拉盘（Euler's Disk）规律：进动角速度随倾角减小而急剧
///   增大 Ω² = (4g/3R)/sin α，倾角加速衰减，最后"啪"一下躺平并立刻静止；
/// * 平躺时有库仑摩擦（不是指数阻尼），速度被直接吃掉归零，所以静置画面完全
///   静止 —— 金币不会自己一直转；
/// * 摇晃时一部分金币被掀起、抛起、翻滚，落下后少数会立起来滚一小段再倒下；
/// * 没有传感器（Web / 模拟器 / 浏览器拒绝授权）时只做极缓慢的重力摆动，不
///   凭空制造旋转。
///
/// 渲染：金币正面/背面各 3 种成色预渲染成 sprite（齿边 + 台阶 + 环境反射 +
/// 浮雕 + 划痕），运行时只做 transform + drawImageRect。
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
            opacity: dim ? 0.30 : 1.0,
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
                        Color(0xA80A0A10),
                        Color(0x930A0A10),
                        Color(0xA80A0A10),
                      ]
                    : const [
                        Color(0x3C0A0A10),
                        Color(0x460A0A10),
                        Color(0x6A0A0A10),
                      ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
        ),
        // 顶部/底部渐隐：状态栏、标题、底部导航这些地方要干净，
        // 否则亮金币会直接糊在文字上
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

/// 一枚硬币（薄圆盘）
class _Coin {
  _Coin({
    required this.x,
    required this.y,
    required this.r,
    required this.z,
    required this.tone,
    required this.heads,
    required this.yaw,
    required this.spin,
    required this.variant,
    required this.baseTilt,
  })  : homeX = x,
        homeY = y,
        tilt = baseTilt;

  /// 压在别的金币上的自然倾角（0~20°）：真实钱堆里没有一枚是完全平的，
  /// 少了这个平铺感就会像贴纸
  final double baseTilt;

  /// 各自的"坑位"：金币池是满的，倾斜后松手要能回到原位，
  /// 否则整池金币会被重力推到屏幕一角，上半屏空一片。
  final double homeX;
  final double homeY;

  double x, y;

  /// 堆叠高度（像素）：下层金币被遮住一部分，层次感来自这里
  double z;

  double vx = 0, vy = 0, vz = 0;

  /// 倾角：baseTilt = 稳稳躺着，π/2 = 立在边缘
  double tilt = 0;

  /// 倾角角速度（rad/s），负值表示正在倒下
  double tiltVel = 0;

  /// 币面朝向（决定椭圆长轴 / 侧壁方向）
  double yaw;

  /// 平躺时的面内自旋
  double spin;

  /// 自旋角速度，靠库仑摩擦吃掉
  double spinVel = 0;

  final double r;
  final int tone;
  bool heads;

  /// 磨损变体（0..2）：同成色同面的金币用不同包浆图案，避免整屏重复
  final int variant;

  /// 每枚金币的亮度微扰，进一步打散"复制粘贴"感
  final double lustre = 0.94 + math.Random().nextDouble() * 0.12;

  /// 落地闪光：1 → 0
  double clink = 0;

  /// 是否还在动（用于静止后停止重绘）
  bool get moving =>
      tiltVel != 0 ||
      (tilt - baseTilt).abs() > 0.001 ||
      vx.abs() > 0.4 ||
      vy.abs() > 0.4 ||
      vz.abs() > 0.4 ||
      spinVel.abs() > 0.05 ||
      clink > 0.01;

  /// 投影压扁系数：平躺时略小于 1，做出一点俯视透视
  double get squash {
    final c = math.cos(tilt).abs();
    return math.max(c * 0.955, 0.035);
  }
}

class _CoinPoolPhysics extends ChangeNotifier {
  // 相机略俯视：平躺的币画成轻微椭圆，倾斜时短轴按 cos(tilt) 收缩
  static const double _baseSquash = 0.955;

  // 重力像素当量（px/s²），1g 折算成这个值
  static const double _gravity = 1500;

  final math.Random _rand = math.Random(0x5EED11);
  final List<_Coin> _coins = [];

  /// 索引：tone * 6 + (heads ? 0 : 3) + variant —— 3 成色 × 正反 × 3 种磨损
  final List<ui.Image?> _sprites = List<ui.Image?>.filled(18, null);
  ui.Image? _shadowSprite;

  Size _size = Size.zero;
  double _density = 1.0;
  bool _built = false;

  // 平滑后的重力方向（屏幕坐标系，-1..1），以及传感器目标值
  double _gx = 0, _gy = 0;
  double _tx = 0, _ty = 0;

  bool autoSway = false;
  double _swayPhase = 0;

  DateTime _lastKick = DateTime.fromMillisecondsSinceEpoch(0);

  // 缓存的绘制对象，避免每帧新建
  final Paint _imgPaint = Paint()..filterQuality = FilterQuality.medium;
  final Paint _shadowPaint = Paint()..filterQuality = FilterQuality.low;
  final Paint _sidePaint = Paint();
  final Paint _sideDark = Paint();
  final Paint _rimPaint = Paint()..style = PaintingStyle.stroke;

  // ---------------------------------------------------------------- 传感器

  void onAccelerometer(double x, double y, double z) {
    // 屏幕坐标系：x 向右、y 向下；手机竖起时 ay ≈ 9.81
    final mag = math.sqrt(x * x + y * y + z * z);
    final now = DateTime.now();

    // 摇晃：合加速度明显偏离 1g，且距上次冲量 > 260ms
    final shaken = mag > 21 || mag < 3.4;
    if (shaken && now.difference(_lastKick).inMilliseconds > 260) {
      _lastKick = now;
      final strength = mag > 21 ? (mag / 30).clamp(0.55, 1.6) : 0.5;
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

  void rebuild() {
    if (_size.isEmpty) return;
    _ensureSprites();

    // 抖动网格铺满：比纯随机更均匀，不会出现大块空洞或挤成一堆
    final cell = 42.0 / math.sqrt(_density.clamp(0.6, 2.0));
    final cols = (_size.width / cell).ceil();
    final rows = (_size.height / cell).ceil();
    _coins.clear();
    for (var gy = 0; gy < rows; gy++) {
      for (var gx = 0; gx < cols; gx++) {
        // 留一点空隙，避免像贴图
        if (_rand.nextDouble() < 0.055) continue;
        final px = gx * cell + cell * 0.5 + (_rand.nextDouble() - 0.5) * cell * 0.62;
        final py = gy * cell + cell * 0.5 + (_rand.nextDouble() - 0.5) * cell * 0.62;
        _coins.add(_Coin(
          x: px,
          y: py,
          r: cell * (0.40 + _rand.nextDouble() * 0.34),
          z: _pileHeight(px, py) + _rand.nextDouble() * 1.6,
          tone: _rand.nextInt(3),
          heads: _rand.nextBool(),
          yaw: _rand.nextDouble() * math.pi * 2,
          spin: _rand.nextDouble() * math.pi * 2,
          variant: _rand.nextInt(3),
          baseTilt: 0.02 + _rand.nextDouble() * 0.26,
        ));
      }
    }
    // 极少数金币一开始就立着滚（真实的池子里也会有）
    for (var i = 0; i < math.max(1, _coins.length ~/ 60); i++) {
      final c = _coins[_rand.nextInt(_coins.length)];
      c.tilt = 0.55 + _rand.nextDouble() * 0.75;
      c.tiltVel = -0.12;
    }
    _built = true;
    notifyListeners();
  }

  /// 金币堆的高度场：几组低频正弦叠加，做出成堆起伏而不是平板一片
  double _pileHeight(double x, double y) {
    final h = math.sin(x * 0.0130 + 1.7) * math.cos(y * 0.0110 - 0.6) +
        math.sin(x * 0.0260 - 0.9) * math.cos(y * 0.0230 + 1.9) * 0.55 +
        math.sin(x * 0.0410 + 2.4) * math.cos(y * 0.0370 + 0.3) * 0.28;
    return (h + 1.83) * 2.9;
  }

  void _ensureSprites() {
    if (_shadowSprite != null) return;
    for (var tone = 0; tone < 3; tone++) {
      for (var face = 0; face < 2; face++) {
        for (var v = 0; v < 3; v++) {
          _sprites[tone * 6 + face * 3 + v] =
              _renderCoin(72, tone, face == 0, v);
        }
      }
    }
    _shadowSprite = _renderShadow(56);
  }

  // ---------------------------------------------------------------- 扰动

  void _shake({required double strength}) {
    for (final c in _coins) {
      final roll = _rand.nextDouble();
      // 水平冲量：不是所有金币都动，避免整片一起平移像贴图
      if (roll < 0.62) {
        final a = _rand.nextDouble() * math.pi * 2;
        final v = (55 + _rand.nextDouble() * 190) * strength;
        c.vx += math.cos(a) * v;
        c.vy += math.sin(a) * v;
      }
      // 抛起：少数金币腾空
      if (roll > 0.80) {
        c.vz += (70 + _rand.nextDouble() * 210) * strength;
        c.z += _rand.nextDouble() * 2.5 * strength;
      }
      // 掀起：少数金币被立起来（真实摇晃后会有硬币立着打转然后倒下）
      if (roll > 0.90) {
        c.tilt = 0.75 + _rand.nextDouble() * 0.65;
        c.tiltVel = -_rand.nextDouble() * 0.15;
        c.spinVel += (_rand.nextDouble() - 0.5) * 7 * strength;
      } else if (roll < 0.45) {
        // 平躺被推动时只是小幅自转，靠摩擦快速停下
        c.spinVel += (_rand.nextDouble() - 0.5) * 3.2 * strength;
      }
      c.clink = math.min(1.0, c.clink + 0.5 * strength);
    }
    notifyListeners();
  }

  // ---------------------------------------------------------------- 步进

  void step(double dt, double t) {
    if (_size.isEmpty) return;
    if (!_built) rebuild();

    // 缓慢的模拟摆动（无传感器时）：只是轻微改变重力方向，不制造旋转
    if (autoSway) {
      _swayPhase += dt * 0.42;
      _tx = math.sin(_swayPhase) * 0.20;
      _ty = math.sin(_swayPhase * 0.73 + 1.1) * 0.14;
    }

    // 重力方向平滑（传感器有噪声，直接跟随会抖）
    final k = math.min(1.0, dt * 7.0);
    _gx += (_tx - _gx) * k;
    _gy += (_ty - _gy) * k;

    // 只有金币真的在动才重绘：整池静止时完全不再画，省电也不掉帧
    var active = false;

    for (final c in _coins) {
      if (c.moving) active = true;
      _stepCoin(c, dt);
    }

    if (active) {
      _resolveOverlap();
      notifyListeners();
    }
  }

  void _stepCoin(_Coin c, double dt) {
    // ---- 垂直：抛起 + 落回（z 只用于视觉层次与阴影）
    if (c.z > 0 || c.vz > 0) {
      c.vz -= 1900 * dt;
      c.z += c.vz * dt;
      if (c.z <= 0) {
        final impact = -c.vz;
        c.z = 0;
        c.vz = 0;
        // 落地：撞出一点自旋和闪光，但立刻被摩擦吃掉
        if (impact > 120) {
          c.clink = math.min(1.0, c.clink + impact / 520);
          c.spinVel += (_rand.nextDouble() - 0.5) * impact * 0.010;
          if (c.tilt < 0.2 && _rand.nextDouble() < 0.10) {
            // 平摔下去偶尔会被掀起来一点
            c.tilt = 0.30;
            c.tiltVel = 0;
          }
        }
      }
    }

    // ---- 倾斜 / 边缘滚动（欧拉盘）
    if (c.tilt > c.baseTilt + 0.0015) {
      final sinT = math.max(math.sin(c.tilt), 0.045);
      // 欧拉盘约束：倾角越小，进动越快（Ω² = 4g / (3R sin α)）
      final omega = math.sqrt(4 * _gravity / (3 * c.r)) / math.sqrt(sinT);
      final omegaClamped = omega.clamp(0.0, 46.0);

      // 进动带动币面朝向转动 —— 真币倒下前会越转越急促
      c.yaw += omegaClamped * dt * 0.22;

      // 倾角衰减：滚动摩擦为主，越立越快倒
      final drain = 1.35 + omegaClamped * 0.075;
      c.tiltVel -= drain * dt;
      c.tilt += c.tiltVel * dt;

      // 边缘滚动时质心会小幅漂移（不是直线滑）
      final drift = omegaClamped * c.r * 0.035;
      c.vx += math.cos(c.yaw + math.pi / 2) * drift * dt * 8;
      c.vy += math.sin(c.yaw + math.pi / 2) * drift * dt * 8;

      if (c.tilt <= c.baseTilt + 0.0015) {
        // 躺平：一次小小的撞击 + 面朝随机翻面，然后彻底静止
        c.tilt = c.baseTilt;
        c.tiltVel = 0;
        c.clink = 1.0;
        if (_rand.nextBool()) c.heads = !c.heads;
        c.spinVel = (_rand.nextDouble() - 0.5) * 2.2;
        c.vx *= 0.45;
        c.vy *= 0.45;
      }
    } else {
      c.tilt = c.baseTilt;
      c.tiltVel = 0;
    }

    // ---- 面内自旋：库仑摩擦，直接被吃掉归零（关键：不会永远转）
    if (c.spinVel != 0) {
      final dec = (c.tilt > 0.05 ? 2.2 : 5.5) * dt;
      if (c.spinVel.abs() <= dec) {
        c.spinVel = 0;
      } else {
        c.spinVel -= c.spinVel.sign * dec;
      }
      c.spin += c.spinVel * dt;
    }

    // ---- 平移：重力 + 回位弹簧 + 库仑摩擦
    final grounded = c.z <= 0.02;
    if (grounded) {
      // 立着的金币更容易被带动（接触面积小）
      final grip = c.tilt > 0.25 ? 0.40 : 1.0;
      // 重力只做轻微推动：金币池是"满"的，不能被推到一角
      c.vx += _gx * _gravity * 0.22 * dt * grip;
      c.vy += _gy * _gravity * 0.22 * dt * grip;

      // 回位弹簧：倾斜松开后各回各位，画面始终铺满
      c.vx += (c.homeX - c.x) * 11.0 * dt;
      c.vy += (c.homeY - c.y) * 11.0 * dt;

      final sp = math.sqrt(c.vx * c.vx + c.vy * c.vy);
      if (sp > 0) {
        // 库仑摩擦：减去固定量，能真正停住（指数阻尼永远停不下来）
        final mu = c.tilt > 0.25 ? 150.0 : 210.0;
        final dec = mu * dt;
        if (sp <= dec) {
          c.vx = 0;
          c.vy = 0;
        } else {
          final f = (sp - dec) / sp;
          c.vx *= f;
          c.vy *= f;
        }
      }
    } else {
      // 空中只有空气阻力
      final f = math.pow(0.35, dt).toDouble();
      c.vx *= f;
      c.vy *= f;
    }

    // 位置积分
    c.x += c.vx * dt;
    c.y += c.vy * dt;

    // 池壁：弹性一般，撞墙损失能量
    final m = c.r * 0.72;
    if (c.x < m) {
      c.x = m;
      c.vx = c.vx.abs() * 0.28;
      c.clink = math.min(1.0, c.clink + 0.25);
    } else if (c.x > _size.width - m) {
      c.x = _size.width - m;
      c.vx = -c.vx.abs() * 0.28;
      c.clink = math.min(1.0, c.clink + 0.25);
    }
    if (c.y < m) {
      c.y = m;
      c.vy = c.vy.abs() * 0.28;
      c.clink = math.min(1.0, c.clink + 0.25);
    } else if (c.y > _size.height - m) {
      c.y = _size.height - m;
      c.vy = -c.vy.abs() * 0.28;
      c.clink = math.min(1.0, c.clink + 0.25);
    }

    // 闪光衰减
    if (c.clink > 0) {
      c.clink = math.max(0, c.clink - dt * 2.4);
    }
  }

  /// 圆盘互撞：只分开重叠 + 传递一部分速度，不做旋转（真币平躺相撞不会打转）
  void _resolveOverlap({bool force = false}) {
    final n = _coins.length;
    for (var i = 0; i < n; i++) {
      final a = _coins[i];
      for (var j = i + 1; j < n; j++) {
        final b = _coins[j];
        // 高度差太大就不算撞（一层压一层）
        if ((a.z - b.z).abs() > 3.5) continue;

        final dx = b.x - a.x;
        final dy = b.y - a.y;
        final ra = a.r * 0.80;
        final rb = b.r * 0.80;
        final minD = ra + rb;
        final d2 = dx * dx + dy * dy;
        if (d2 >= minD * minD || d2 < 1e-6) continue;

        final d = math.sqrt(d2);
        final overlap = minD - d;
        final nx = dx / d;
        final ny = dy / d;

        // 位置分离：重的（大的）少动一点
        final wa = a.r / (a.r + b.r);
        final wb = 1 - wa;
        a.x -= nx * overlap * wa;
        a.y -= ny * overlap * wa;
        b.x += nx * overlap * wb;
        b.y += ny * overlap * wb;

        // 相对法向速度 → 交换一部分（恢复系数 0.25，像金属）
        final rvx = b.vx - a.vx;
        final rvy = b.vy - a.vy;
        final vn = rvx * nx + rvy * ny;
        if (vn < 0) {
          final imp = -(1.25) * vn * 0.5;
          a.vx -= nx * imp * wa * 2;
          a.vy -= ny * imp * wa * 2;
          b.vx += nx * imp * wb * 2;
          b.vy += ny * imp * wb * 2;
          // 被撞的金币可能被掀起来
          if (imp > 40 && force == false && _rand.nextDouble() < 0.06) {
            a.tilt = math.max(a.tilt, 0.35);
            a.tiltVel = -0.05;
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- 绘制

  void paint(Canvas canvas, Size size) {
    if (size != _size) {
      _size = size;
      _built = false;
      rebuild();
    }
    if (_coins.isEmpty) return;

    // 池底：缝隙不能是纯黑，否则整片像贴纸
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, size.height),
          const [Color(0xFF241808), Color(0xFF170F06), Color(0xFF0D0703)],
          const [0.0, 0.55, 1.0],
        ),
    );

    final shadow = _shadowSprite;

    // 按高度排序：z 低的先画，高的盖在上面
    _coins.sort((a, b) => a.z.compareTo(b.z));

    for (final c in _coins) {
      final squash = math.max(c.squash, 0.035);

      // ---- 地面阴影（贴地的那些几乎看不见，直接跳过）
      if (shadow != null && c.z > 0.55) {
        final lift = c.z;
        final sw = c.r * (2.18 + lift * 0.05);
        final sh = c.r * 2.55 * (_baseSquash * 0.62 + squash * 0.38);
        final alpha = (0.66 - lift * 0.030).clamp(0.14, 0.66);
        _shadowPaint.color = const Color(0xFF000000).withValues(alpha: alpha);
        canvas.save();
        canvas.translate(c.x + c.r * 0.10, c.y + c.r * 0.17 + lift * 1.05);
        canvas.scale(1.0, sh / sw);
        canvas.drawImageRect(
          shadow,
          Rect.fromLTWH(0, 0, shadow.width.toDouble(), shadow.height.toDouble()),
          Rect.fromCenter(center: Offset.zero, width: sw, height: sw),
          _shadowPaint,
        );
        canvas.restore();
      }

      // ---- 硬币本体
      canvas.save();
      canvas.translate(c.x, c.y - c.z * 0.55);
      canvas.rotate(c.yaw);

      // 侧壁厚度：立起来时才明显（真实俯视看立着的硬币就是一条窄边）
      final thickness = c.r * (0.035 + 0.155 * math.sin(c.tilt));
      final rx = c.r;
      final ry = c.r * squash;

      if (thickness > 0.6) {
        // 圆柱侧面：下椭圆 + 中间矩形（被上表面前一层的椭圆盖住）
        final sideGrad = ui.Gradient.linear(
          Offset(-rx, 0),
          Offset(rx, 0),
          [
            const Color(0xFF6E4A12),
            const Color(0xFFC79A45),
            const Color(0xFF8A6018),
            const Color(0xFFE8C377),
            const Color(0xFF6E4A12),
          ],
          const [0.0, 0.22, 0.5, 0.78, 1.0],
        );
        _sidePaint.shader = sideGrad;
        canvas.drawOval(
          Rect.fromCenter(
              center: Offset(0, thickness), width: rx * 2, height: ry * 2),
          _sidePaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(-rx, 0, rx, thickness),
          _sidePaint,
        );
        // 齿边：侧壁上的细密竖纹（滚动的硬币最容易被认出来的细节）
        if (thickness > 1.6) {
          _sideDark
            ..shader = null
            ..color = const Color(0x33200F00)
            ..strokeWidth = 0.7;
          final ridges = (rx * 1.2).round().clamp(10, 44);
          for (var i = 0; i < ridges; i++) {
            final px = -rx + rx * 2 * (i + 0.5) / ridges;
            canvas.drawLine(
                Offset(px, 0), Offset(px, thickness * 0.92), _sideDark);
          }
        }
      }

      // ---- 币面（正圆 sprite 按 squash 压扁 → 真椭圆，不是假翻转）
      final img = _sprites[c.tone * 6 + (c.heads ? 0 : 3) + c.variant];
      if (img != null) {
        canvas.save();
        canvas.scale(1.0, squash);
        // 立起来时币面背光；再叠加每枚金币自己的亮度微扰
        final shade = (1.0 - 0.30 * math.sin(c.tilt)) * c.lustre;
        final v = (255 * shade).clamp(0, 255).round();
        _imgPaint.color = Color.fromRGBO(v, v, v, 1.0);
        canvas.drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          Rect.fromCenter(center: Offset.zero, width: c.r * 2.10, height: c.r * 2.10),
          _imgPaint,
        );
        canvas.restore();
      }

      // ---- 落地闪光：一圈金色高光迅速散开
      if (c.clink > 0.02) {
        final a = c.clink * 0.5;
        _rimPaint
          ..color = const Color(0xFFFFE7A8).withValues(alpha: a)
          ..strokeWidth = 1.4 + c.clink * 1.6;
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset.zero,
            width: rx * 2 * (1 + (1 - c.clink) * 0.35),
            height: ry * 2 * (1 + (1 - c.clink) * 0.35),
          ),
          _rimPaint,
        );
      }

      canvas.restore();
    }

    // 池底暗角：让金币池有"深度"而不是平铺的贴图
    final vignette = ui.Gradient.radial(
      Offset(size.width * 0.5, size.height * 0.52),
      size.longestSide * 0.72,
      const [
        Color(0x00000000),
        Color(0x00000000),
        Color(0x2E000000),
        Color(0x70000000),
      ],
      const [0.0, 0.45, 0.80, 1.0],
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = vignette,
    );

    // 左上光源的整体环境光，避免画面死黑
    final glow = ui.Gradient.radial(
      Offset(size.width * 0.18, -size.height * 0.08),
      size.longestSide * 0.75,
      const [Color(0x1AFFD98A), Color(0x00FFD98A)],
      const [0.0, 1.0],
    );
    canvas.drawRect(Offset.zero & size, Paint()..shader = glow);
  }

  @override
  void dispose() {
    for (final i in _sprites) {
      i?.dispose();
    }
    _shadowSprite?.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// 金币 / 阴影 sprite 预渲染
// ---------------------------------------------------------------------------

/// 阴影贴图：软椭圆（预渲染一次，避免每帧 MaskFilter.blur）
ui.Image? _renderShadow(double r) {
  try {
    final side = r * 4;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, Rect.fromLTWH(0, 0, side, side));
    final c = Offset(side / 2, side / 2);
    canvas.drawCircle(
      c,
      side * 0.42,
      Paint()
        ..shader = ui.Gradient.radial(
          c,
          side * 0.42,
          const [
            Color(0xFF000000),
            Color(0xCC000000),
            Color(0x40000000),
            Color(0x00000000),
          ],
          const [0.0, 0.45, 0.75, 1.0],
        ),
    );
    final pic = rec.endRecording();
    final img = pic.toImageSync(side.ceil(), side.ceil());
    pic.dispose();
    return img;
  } catch (_) {
    return null;
  }
}

/// 预渲染一枚金币：齿边 / 倒角 / 币面 / 环境反射 / 浮雕 / 岁月痕迹
///
/// "旧"主要来自最后那层痕迹：
/// * 边缘氧化暗环 —— 币面外圈长期接触空气最先发暗；
/// * 不规则暖褐包浆 + 少量灰绿锈斑 —— 不是均匀加暗，而是成团分布；
/// * 被磨亮的凸起 —— 高点露出一小块新金属，和暗部形成对比；
/// * 方向集中的划痕 —— 真硬币的划痕有主方向（口袋/钱包摩擦），不是乱撒；
/// * 边缘磕碰缺口 + 磨白弧 —— 齿边被磕掉几块、外缘磨得发白；
/// * 浮雕凹槽积垢 —— 字口里更暗。
ui.Image? _renderCoin(double r, int tone, bool heads, int variant) {
  // 三种成色：足金、老金、暗金
  const rims = <List<Color>>[
    [Color(0xFFFFF6D8), Color(0xFFF3C25A), Color(0xFFA9741F), Color(0xFF6E4A12)],
    [Color(0xFFF6EBC8), Color(0xFFD9AE55), Color(0xFF8E6420), Color(0xFF5A3C0E)],
    [Color(0xFFE8DCB8), Color(0xFFB98F42), Color(0xFF6F4B16), Color(0xFF422C08)],
  ];
  const faces = <List<Color>>[
    [Color(0xFFFFFBE8), Color(0xFFFFD874), Color(0xFFE8AE33), Color(0xFF8E5E12)],
    [Color(0xFFFFF3D0), Color(0xFFE8C264), Color(0xFFC08F2E), Color(0xFF754E12)],
    [Color(0xFFF3E8C6), Color(0xFFC9A253), Color(0xFF96702A), Color(0xFF553A0C)],
  ];

  try {
    final rim = rims[tone];
    final face = faces[tone];
    final pad = r * 0.10;
    final side = (r + pad) * 2;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, Rect.fromLTWH(0, 0, side, side));
    final c = Offset(side / 2, side / 2);
    final rnd = math.Random(
        9173 + tone * 131 + (heads ? 0 : 7) + variant * 977);

    final faceRect = Rect.fromCircle(center: c, radius: r * 0.845);

    // ---------------------------------------------------------------- 基础
    // 1) 外圈底色
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(c.dx - r, c.dy - r),
          Offset(c.dx + r, c.dy + r),
          rim,
          const [0.0, 0.42, 0.78, 1.0],
        ),
    );

    // 2) 齿边：挤压成型的齿深浅不一，有的被磨平
    const teeth = 84;
    for (var i = 0; i < teeth; i++) {
      final a0 = i * math.pi * 2 / teeth;
      final worn = rnd.nextDouble() < 0.18;
      final light = i.isEven;
      final alpha = worn ? 0.05 : (light ? 0.17 : 0.15);
      final outer = worn ? r * 0.95 : r * 0.995;
      canvas.drawLine(
        Offset(c.dx + math.cos(a0) * r * 0.905,
            c.dy + math.sin(a0) * r * 0.905),
        Offset(c.dx + math.cos(a0) * outer, c.dy + math.sin(a0) * outer),
        Paint()
          ..color =
              (light ? Colors.white : Colors.black).withValues(alpha: alpha)
          ..strokeWidth = r * 0.028,
      );
    }

    // 3) 倒角环 + 台阶凹陷
    canvas.drawCircle(
      c,
      r * 0.905,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(c.dx - r, c.dy - r),
          Offset(c.dx + r, c.dy + r),
          [rim[0], rim[1], rim[3]],
          const [0.0, 0.55, 1.0],
        ),
    );
    canvas.drawCircle(
      c,
      r * 0.865,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(c.dx, c.dy - r * 0.9),
          Offset(c.dx, c.dy + r * 0.9),
          const [Color(0x4D000000), Color(0x00000000), Color(0x33FFF6D0)],
          const [0.0, 0.55, 1.0],
        ),
    );

    // 4) 币面主色（光源在左上）
    canvas.drawCircle(
      c,
      r * 0.845,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(c.dx - r * 0.34, c.dy - r * 0.42),
          r * 1.38,
          face,
          const [0.0, 0.26, 0.62, 1.0],
        ),
    );

    // 5) 环境反射带：上方映亮处、下方映暗处，金属感的主要来源
    canvas.drawCircle(
      c,
      r * 0.845,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(c.dx, c.dy - r * 0.85),
          Offset(c.dx, c.dy + r * 0.85),
          const [
            Color(0x70FFFFFF),
            Color(0x0DFFFFFF),
            Color(0x14000000),
            Color(0x4A000000),
            Color(0x24FFE9B0),
          ],
          const [0.0, 0.32, 0.55, 0.80, 1.0],
        ),
    );

    // 6) 内圈浮雕环
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r * 0.70),
      math.pi * 1.05,
      math.pi * 0.90,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.045
        ..color = Colors.white.withValues(alpha: 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8),
    );
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r * 0.70),
      math.pi * 0.05,
      math.pi * 0.90,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.045
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8),
    );

    // 7) 中央浮雕（阴刻：暗影在下、亮边在上）+ 凹槽积垢
    final glyph = heads ? '¥' : '福';
    final fs = r * (heads ? 0.92 : 0.74);

    TextPainter mk(String t, TextStyle st) => TextPainter(
          text: TextSpan(text: t, style: st),
          textDirection: TextDirection.ltr,
        )..layout();

    final tpDark = mk(
      glyph,
      TextStyle(
        fontSize: fs,
        fontWeight: FontWeight.w700,
        height: 1.0,
        color: const Color(0xB32A1A00),
        shadows: const [
          Shadow(color: Color(0x33140C00), blurRadius: 1.2, offset: Offset(0, 0.6)),
        ],
      ),
    );
    final origin = Offset(
      c.dx - tpDark.width / 2,
      c.dy - tpDark.height / 2 - (heads ? r * 0.02 : 0),
    );
    tpDark.paint(canvas, origin.translate(0, r * 0.045));

    mk(
      glyph,
      TextStyle(
        fontSize: fs,
        fontWeight: FontWeight.w700,
        height: 1.0,
        foreground: Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.05
          ..color = const Color(0x55281200),
      ),
    ).paint(canvas, origin.translate(0, r * 0.035));

    mk(
      glyph,
      TextStyle(
        fontSize: fs,
        fontWeight: FontWeight.w700,
        height: 1.0,
        color: rim[0].withValues(alpha: 0.88),
      ),
    ).paint(canvas, origin.translate(0, -r * 0.012));

    // ------------------------------------------------------------ 岁月痕迹
    canvas.save();
    canvas.clipPath(Path()..addOval(faceRect));

    void blob(Offset p, double rad, Color col, double a) {
      canvas.drawCircle(
        p,
        rad,
        Paint()
          ..shader = ui.Gradient.radial(
            p,
            rad,
            [
              col.withValues(alpha: a),
              col.withValues(alpha: a * 0.5),
              col.withValues(alpha: 0),
            ],
            const [0.0, 0.55, 1.0],
          ),
      );
    }

    // a. 边缘氧化暗环
    canvas.drawCircle(
      c,
      r * 0.845,
      Paint()
        ..shader = ui.Gradient.radial(
          c,
          r * 0.845,
          const [
            Color(0x00000000),
            Color(0x00000000),
            Color(0x3D150D02),
            Color(0x66150D02),
          ],
          const [0.0, 0.78, 0.95, 1.0],
        ),
    );

    // b. 大块包浆 / 氧化（暖褐，成团分布）
    for (var i = 0; i < 9; i++) {
      final a = rnd.nextDouble() * math.pi * 2;
      final d = rnd.nextDouble() * r * 0.72;
      blob(
        Offset(c.dx + math.cos(a) * d, c.dy + math.sin(a) * d),
        r * (0.16 + rnd.nextDouble() * 0.40),
        const Color(0xFF2B1B09),
        0.05 + rnd.nextDouble() * 0.10,
      );
    }

    // c. 灰绿锈斑（少数几处即可，多了就脏了）
    for (var i = 0; i < 5; i++) {
      final a = rnd.nextDouble() * math.pi * 2;
      final d = rnd.nextDouble() * r * 0.70;
      blob(
        Offset(c.dx + math.cos(a) * d, c.dy + math.sin(a) * d),
        r * (0.05 + rnd.nextDouble() * 0.13),
        const Color(0xFF4A4034),
        0.05 + rnd.nextDouble() * 0.07,
      );
    }

    // d. 被磨亮的凸起（高点抛光露出新金属）
    for (var i = 0; i < 4; i++) {
      final a = rnd.nextDouble() * math.pi * 2;
      final d = r * (0.30 + rnd.nextDouble() * 0.45);
      blob(
        Offset(c.dx + math.cos(a) * d, c.dy + math.sin(a) * d),
        r * (0.10 + rnd.nextDouble() * 0.22),
        const Color(0xFFFFF3CE),
        0.10 + rnd.nextDouble() * 0.17,
      );
    }

    // e. 方向集中的划痕
    final mainDir = rnd.nextDouble() * math.pi;
    for (var i = 0; i < 34; i++) {
      final a = mainDir + (rnd.nextDouble() - 0.5) * 0.7;
      final start = Offset(
        c.dx + (rnd.nextDouble() - 0.5) * r * 1.6,
        c.dy + (rnd.nextDouble() - 0.5) * r * 1.6,
      );
      final len = r * (0.10 + rnd.nextDouble() * 0.55);
      final dir = Offset(math.cos(a), math.sin(a));
      final bright = rnd.nextBool();
      canvas.drawLine(
        start,
        start + dir * len,
        Paint()
          ..color = (bright ? Colors.white : Colors.black).withValues(
            alpha: bright
                ? 0.05 + rnd.nextDouble() * 0.10
                : 0.06 + rnd.nextDouble() * 0.12,
          )
          ..strokeWidth = r * (0.008 + rnd.nextDouble() * 0.014)
          ..strokeCap = StrokeCap.round,
      );
    }

    // f. 指纹 / 油污：极淡的大面积弧
    for (var i = 0; i < 3; i++) {
      final p = Offset(
        c.dx + (rnd.nextDouble() - 0.5) * r,
        c.dy + (rnd.nextDouble() - 0.5) * r,
      );
      canvas.drawCircle(
        p,
        r * (0.18 + rnd.nextDouble() * 0.22),
        Paint()
          ..color = const Color(0x0DFFF3D0)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }

    canvas.restore();

    // 保底金色：痕迹之后压一层极淡暖金，保证整体读起来是"金"而不是"铜"
    canvas.drawCircle(
      c,
      r * 0.845,
      Paint()
        ..blendMode = BlendMode.overlay
        ..shader = ui.Gradient.radial(
          Offset(c.dx - r * 0.30, c.dy - r * 0.36),
          r * 1.10,
          const [Color(0x40FFC65C), Color(0x18FFB347), Color(0x00E09420)],
          const [0.0, 0.60, 1.0],
        ),
    );

    // g. 边缘磕碰缺口：沿圆周崩掉几小块
    final dents = 2 + rnd.nextInt(4);
    for (var i = 0; i < dents; i++) {
      final a = rnd.nextDouble() * math.pi * 2;
      final rad = r * (0.022 + rnd.nextDouble() * 0.035);
      final p = Offset(
        c.dx + math.cos(a) * r * 0.985,
        c.dy + math.sin(a) * r * 0.985,
      );
      canvas.drawCircle(p, rad, Paint()..color = const Color(0xCC160C02));
      canvas.drawCircle(
        p.translate(-rad * 0.35, -rad * 0.35),
        rad * 0.45,
        Paint()..color = const Color(0x66FFEBB4),
      );
    }

    // h. 凸边磨白弧：外缘被磨得发亮，旧金币最典型的特征
    for (var i = 0; i < 2; i++) {
      final a0 = rnd.nextDouble() * math.pi * 2;
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r * 0.925),
        a0,
        math.pi * (0.12 + rnd.nextDouble() * 0.30),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.05
          ..strokeCap = StrokeCap.round
          ..color = const Color(0x59FFF6D6)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6),
      );
    }

    // 8) 镜面高光
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r * 0.95)));
    canvas.drawCircle(
      Offset(c.dx - r * 0.42, c.dy - r * 0.48),
      r * 0.36,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(c.dx - r * 0.42, c.dy - r * 0.48),
          r * 0.36,
          const [Color(0x8CFFFFFF), Color(0x1AFFFFFF), Color(0x00FFFFFF)],
          const [0.0, 0.55, 1.0],
        ),
    );
    canvas.restore();

    // 一圈极细的亮边：金属倒角总有一圈反光，轮廓才立得住
    canvas.drawCircle(
      c,
      r * 0.965,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.016
        ..color = const Color(0x2EFFF4D2),
    );

    // 9) 边缘光：左上亮弧 + 右下暗弧
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r * 0.955),
      math.pi * 1.02,
      math.pi * 0.62,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.030
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.62)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.1),
    );
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r * 0.955),
      math.pi * 0.06,
      math.pi * 0.55,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.030
        ..strokeCap = StrokeCap.round
        ..color = Colors.black.withValues(alpha: 0.32)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.1),
    );

    final pic = rec.endRecording();
    final img = pic.toImageSync(side.ceil(), side.ceil());
    pic.dispose();
    return img;
  } catch (_) {
    return null;
  }
}
