import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// 立方体盒子装沙的物理模型（v0.5.2，替代沙漏）。
///
/// 用户口径：**屏幕是正立方体盒子的正面投影，下半部分（约 50%）是金沙；
/// 手机旋转（重力方向变化）时沙子流动、重新堆积，沙面始终相对重力保持水平**
/// —— 完全模拟沙子在一个正立方体盒子内随盒子角度变化的动态物理行为。
///
/// 模型：**盒子固定在屏幕**（矩形 `[0,W]×[0,H]`），重力 `g` 随手机倾角变化。
/// 沙子是盒子内沿 `g` 的"下半空间"（`g·p ≥ c`），沙面是一条**垂直于 g 的直线**
/// （相对重力水平），位置 `c` 由沙量守恒反解。手机转 90° → `g` 转 90° →
/// 沙子流到盒子新低端，沙面始终垂直重力 —— 这就是"沙子随盒子角度流动"。
///
/// - **沙量守恒**：沙区面积恒定（初始 = 盒子面积 × 50%），每帧由目标面积反解 `c`。
/// - **流动（平滑）**：`c` 向目标值指数过渡（约 1~2 秒走完一次 90° 旋转），
///   沙子"缓慢流淌"而不是瞬间跳过去。
/// - **沙面起伏（堆积角）**：沙面叠加沿 u 的低频起伏，表现沙堆的自然坡面/休止角。
/// - **粒子**：沙面附近 [kParticleCount] 颗金色小粒沿 `g` 滑落，表现流动感。
///
/// 与旧 `HourglassPhysics` 的区别：没有上腔/细颈/下腔几何，只有"盒子 + 沙堆"；
/// 与"盒子随坐标系旋转"的错误模型的区别：**盒子固定在屏幕**，沙子相对盒子流动。
class SandBoxPhysics extends ChangeNotifier {
  SandBoxPhysics({double density = 1.0}) : _density = density {
    _initParticles();
  }

  /// 流动粒子数（低端机按 [setDensity] 降到 ≥80）
  static const int kParticleCount = 180;

  /// 沙面起伏的样条点数（决定坡面平滑度）
  static const int kBumpCount = 12;

  double _density = 1.0;

  /// 盒子尺寸（屏幕像素）——固定，不随重力转
  Size _size = Size.zero;

  /// 沙量（面积）恒定值
  double _sandArea = 0;

  /// 当前沙面位置 `c`：沙区 = {(x,y) : g·p ≥ c}（p 为屏幕坐标）
  double _c = 0;

  /// 目标沙面位置（由沙量反解），[c] 向它指数过渡
  double _cTarget = 0;

  /// 平滑后的倾角（-1..1），外壳 widget 每帧写入目标值
  double _tilt = 0;
  double _tiltTarget = 0;

  /// 沙面起伏（沿 u 的低频噪声，表现堆积角），每帧轻微演化
  Float64List _bump = Float64List(kBumpCount);
  double _bumpPhase = 0;

  /// 粒子（屏幕坐标 + 速度 + 寿命）
  Float32List _px = Float32List(kParticleCount);
  Float32List _py = Float32List(kParticleCount);
  Float32List _pvx = Float32List(kParticleCount);
  Float32List _pvy = Float32List(kParticleCount);
  Float32List _plife = Float32List(kParticleCount);

  /// 粒子扁平缓冲 [x0,y0,x1,y1,...]（`drawRawPoints`，零逐帧分配）
  Float32List _pointsBuf = Float32List(kParticleCount * 2);

  double _time = 0;
  bool _seeded = false;

  // ===== 对外只读 =====

  Size get size => _size;
  double get sandArea => _sandArea;
  double get c => _c;
  double get tilt => _tilt;

  /// 重力单位向量（屏幕坐标，y 向下）
  ({double x, double y}) get gravity {
    final t = _tilt.clamp(-1.0, 1.0);
    // tilt=0 → (0,1) 向下；tilt=1 → (1,0) 向右；tilt=-1 → (-1,0) 向左
    return (x: t, y: math.sqrt(math.max(0, 1 - t * t)));
  }

  /// 沙面法向 = g；u 轴 = 垂直于 g（沿沙面方向）
  ({double x, double y}) get uAxis {
    final g = gravity;
    return (x: -g.y, y: g.x);
  }

  int get particleCount =>
      (kParticleCount * _density).clamp(80, kParticleCount).round();

  Float32List get pointsBuf => _pointsBuf;

  // ===== 沙面几何 =====

  /// 第 i 个起伏样条点在 u 轴上的位置（0..1 归一化到盒子对角线）
  double _bumpAt(double uNorm) {
    final x = uNorm.clamp(0.0, 1.0) * (kBumpCount - 1);
    final i = x.floor().clamp(0, kBumpCount - 2);
    final t = x - i;
    return _bump[i] * (1 - t) + _bump[i + 1] * t;
  }

  /// 沙面：给定屏幕点 p，返回沿 g 方向到沙面的有符号距离（正=在沙内）
  double sandDepthAt(Offset p) {
    final g = gravity;
    final dot = g.x * p.dx + g.y * p.dy;
    return dot - _c;
  }

  /// 沙面线（含起伏）：返回 [out] 中的屏幕坐标点列，供绘制画多边形上边界。
  int fillSandSurface(List<Offset> out, int steps) {
    final g = gravity;
    final ua = uAxis;
    final cx = _size.width / 2;
    final cy = _size.height / 2;
    // u 轴覆盖盒子对角线，保证旋转时沙面横跨整个盒子
    final halfDiag =
        math.sqrt(_size.width * _size.width + _size.height * _size.height) / 2;
    for (var i = 0; i < steps; i++) {
      final t = i / (steps - 1); // 0..1
      final u = (t - 0.5) * 2 * halfDiag; // -halfDiag..halfDiag
      final bump = _bumpAt(t) * 18; // 起伏幅度（像素）
      final d = _c + bump;
      // 沙面上的点：g·p = d，且沿 u 距离中心 u
      final gDotCenter = g.x * cx + g.y * cy;
      final along = d - gDotCenter;
      out[i] = Offset(
        cx + ua.x * u + g.x * along,
        cy + ua.y * u + g.y * along,
      );
    }
    return steps;
  }

  /// 供绘制：沙堆多边形（沙面曲线 + 沿 g 走到盒子远端闭合）。
  /// 返回点数。[out] 需要 ≥ [steps] + 2 个 Offset。
  int fillSandPolygon(List<Offset> out, int steps) {
    final n = fillSandSurface(out, steps);
    final g = gravity;
    final far = 2000.0;
    out[n] = Offset(out[0].dx + g.x * far, out[0].dy + g.y * far);
    out[n + 1] = Offset(out[n - 1].dx + g.x * far, out[n - 1].dy + g.y * far);
    return n + 2;
  }

  // ===== 生命周期 =====

  /// 画布尺寸变化时重建（build 阶段调用，不 notify）
  void resize(Size size) {
    if (size == _size) return;
    _size = size;
    // 沙量 = 盒子面积 × 50%（用户：下半部分是金沙）
    _sandArea = size.width * size.height * 0.5;
    _cTarget = _solveC(gravity, _sandArea);
    if (!_seeded) {
      _c = _cTarget;
      _seeded = true;
    }
    _initParticles();
  }

  /// 低端机降密度
  void setDensity(double value) {
    _density = value.clamp(0.35, 1.0);
    _initParticles();
  }

  /// 外壳写入传感器目标倾角（-1..1）
  void setTilt(double value) {
    _tiltTarget = value.clamp(-1.0, 1.0);
  }

  /// 由沙量反解沙面位置 c：使 {p : g·p ≥ c} 的面积 = targetArea。
  /// 矩形内 g·p 的分布是分段线性，用二分反解。
  double _solveC(({double x, double y}) g, double targetArea) {
    final w = _size.width, h = _size.height;
    if (w <= 0 || h <= 0) return 0;
    final v1 = 0.0;
    final v2 = g.x * w;
    final v3 = g.y * h;
    final v4 = g.x * w + g.y * h;
    var lo = math.min(math.min(v1, v2), math.min(v3, v4)) - 1;
    var hi = math.max(math.max(v1, v2), math.max(v3, v4)) + 1;
    for (var iter = 0; iter < 20; iter++) {
      final mid = (lo + hi) / 2;
      final area = _areaAbove(g, mid, w, h);
      if (area > targetArea) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return (lo + hi) / 2;
  }

  /// 矩形 [0,w]×[0,h] 内 g·p ≥ c 的面积（48×48 采样，够准且不进每帧热路径）
  double _areaAbove(({double x, double y}) g, double c, double w, double h) {
    const n = 48;
    final dx = w / n, dy = h / n;
    var count = 0;
    for (var i = 0; i < n; i++) {
      final x = (i + 0.5) * dx;
      for (var j = 0; j < n; j++) {
        final y = (j + 0.5) * dy;
        if (g.x * x + g.y * y >= c) count++;
      }
    }
    return count * dx * dy;
  }

  void _initParticles() {
    final n = particleCount;
    _px = Float32List(n);
    _py = Float32List(n);
    _pvx = Float32List(n);
    _pvy = Float32List(n);
    _plife = Float32List(n);
    _pointsBuf = Float32List(n * 2);
    for (var i = 0; i < n; i++) {
      _spawnParticle(i, randomizeLife: true);
    }
    _writePoints();
  }

  // ===== 每帧步进 =====

  void step(double dt) {
    if (_size == Size.zero) return;
    final h = dt.clamp(0.0, 0.05);
    _time += h;
    _smoothTilt(h);
    _relaxC(h);
    _evolveBump(h);
    _integrateParticles(h);
    _writePoints();
  }

  void _smoothTilt(double dt) {
    const k = 6.0;
    _tilt += (_tiltTarget - _tilt) * math.min(1.0, k * dt);
    if ((_tiltTarget - _tilt).abs() < 1e-4) _tilt = _tiltTarget;
    _cTarget = _solveC(gravity, _sandArea);
  }

  /// 沙面位置向目标指数过渡（流动感）
  void _relaxC(double dt) {
    const k = 2.2;
    _c += (_cTarget - _c) * math.min(1.0, k * dt);
  }

  /// 沙面起伏缓慢演化（表现沙堆微动/休止角）
  void _evolveBump(double dt) {
    _bumpPhase += dt * 0.35;
    for (var i = 0; i < kBumpCount; i++) {
      final t = i / (kBumpCount - 1);
      _bump[i] = math.sin(t * math.pi * 2.2 + _bumpPhase) * 0.55 +
          math.sin(t * math.pi * 4.7 - _bumpPhase * 0.7) * 0.22;
    }
  }

  // ===== 粒子 =====

  void _spawnParticle(int i, {bool randomizeLife = false}) {
    if (_size == Size.zero) return;
    final r = math.Random(i * 7919 + _time.toInt() * 31);
    final x = r.nextDouble() * _size.width;
    final y = r.nextDouble() * _size.height;
    final p = Offset(x, y);
    // 让出生点靠近沙面：沿 g 把点拉到沙面附近
    final depth = sandDepthAt(p);
    final g = gravity;
    final pull = depth * (0.15 + r.nextDouble() * 0.5);
    _px[i] = x - g.x * pull;
    _py[i] = y - g.y * pull;
    final speed = 25 + r.nextDouble() * 85;
    _pvx[i] = g.x * speed;
    _pvy[i] = g.y * speed;
    _plife[i] = randomizeLife ? r.nextDouble() * 1.6 : 0.5 + r.nextDouble() * 1.1;
  }

  void _integrateParticles(double dt) {
    final n = particleCount;
    final g = gravity;
    for (var i = 0; i < n; i++) {
      _plife[i] -= dt;
      if (_plife[i] <= 0) {
        _spawnParticle(i);
        continue;
      }
      _pvx[i] += g.x * 300 * dt;
      _pvy[i] += g.y * 300 * dt;
      _pvx[i] *= (1 - 1.5 * dt);
      _pvy[i] *= (1 - 1.5 * dt);
      _px[i] += _pvx[i] * dt;
      _py[i] += _pvy[i] * dt;

      final p = Offset(_px[i], _py[i]);
      final out = _px[i] < -20 ||
          _px[i] > _size.width + 20 ||
          _py[i] < -20 ||
          _py[i] > _size.height + 20;
      if (out || sandDepthAt(p) > 40) {
        _spawnParticle(i);
      }
    }
  }

  void _writePoints() {
    final n = particleCount;
    for (var i = 0; i < n; i++) {
      _pointsBuf[i * 2] = _px[i];
      _pointsBuf[i * 2 + 1] = _py[i];
    }
  }
}
