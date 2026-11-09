import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart' show ChangeNotifier;

// ---------------------------------------------------------------------------
// 几何常量（全部相对画布归一化，随屏幕自适应 —— 设计 §2.D.2）
// ---------------------------------------------------------------------------

/// 上腔顶
const double kBulbTopRatio = 0.06;

/// 细颈顶
const double kNeckTopRatio = 0.44;

/// 细颈底
const double kNeckBottomRatio = 0.56;

/// 下腔底
const double kBulbBottomRatio = 0.94;

/// 高度场的列数（性能预算：96 列 × 2 张表）
const int kColumns = 96;

/// 体积 → 液位反解表的步数
const int kLevelSteps = 96;

/// 上下腔轮廓的"收/放"指数：越大越像沙漏（颈口更细、腹部更鼓）
const double kBulbShapeExponent = 1.35;

/// 一轮（上腔满 → 流空）的秒数。48s → 满足 PRD「60s 内至少一次循环」
const double kCycleSeconds = 48.0;

/// 翻转复位动画时长（秒）
const double kFlipSeconds = 0.9;

/// 细颈束流槽位数（低端机按 density 缩到 ≥140，见 [HourglassPhysics.setDensity]）
const int kStreamCount = 261;

/// 下腔坡面滑落颗粒槽位数
const int kSlopeCount = 162;

/// 上腔沙面碎粒槽位数
const int kSurfaceCount = 120;

/// 闪光槽位数
const int kSparkCount = 90;

/// 束流 + 坡面 + 表面 的总槽位。必须能被 3 整除 —— 三个色调各占一段，
/// 这样一帧只用 3 次 `drawRawPoints`，且**不需要**任何 `List<Offset>`。
const int kParticleCount = kStreamCount + kSlopeCount + kSurfaceCount;

/// 上腔表面碎粒的起始槽位
const int kStreamStartSurface = kStreamCount + kSlopeCount;

const int _kToneCount = 3;

/// 槽位数 / 3（每段点数，kParticleCount = 543 = 3 × 181）
const int _kToneSlots = kParticleCount ~/ _kToneCount;

/// 空槽位停放的坐标：落在玻璃裁剪区之外，光栅化阶段直接被丢掉
const double _parked = -10000.0;

// ---------------------------------------------------------------------------
// 几何：体积 / 液位 / 每列边界
// ---------------------------------------------------------------------------

/// 沙漏几何（三段结构：上腔 → 细颈 → 下腔），上下腔绕画面中心旋转 180° 自映射。
///
/// 只做纯数学（无 Canvas），构造一次、尺寸变化时重建。
class HourglassGeometry {
  HourglassGeometry({required this.width, required this.height}) {
    glassW = math.min(width * 0.62, height * 0.55);
    neckW = (width * 0.006).clamp(2.0, 4.0).toDouble();
    topY = height * kBulbTopRatio;
    neckTopY = height * kNeckTopRatio;
    neckBottomY = height * kNeckBottomRatio;
    bottomY = height * kBulbBottomRatio;
    dx = glassW / kColumns;
    _dyTop = (neckTopY - topY) / kLevelSteps;
    _dyBottom = (bottomY - neckBottomY) / kLevelSteps;
    _build();
  }

  final double width;
  final double height;

  /// 玻璃最宽处（腹部直径）
  late final double glassW;

  /// 细颈宽度（PRD 4.4：2–4px）
  late final double neckW;

  late final double topY;
  late final double neckTopY;
  late final double neckBottomY;
  late final double bottomY;

  /// 单列宽度
  late final double dx;

  late final double _dyTop;
  late final double _dyBottom;

  /// 画布水平中心
  double get cx => width * 0.5;

  /// 每列中心到中轴的水平距离（0..glassW/2）
  final Float32List colAx = Float32List(kColumns);

  /// 上腔：该列玻璃区域的**下边界**（y 的最大值；沙面低于它就说明该列没有沙）
  final Float32List topBulbColFloor = Float32List(kColumns);

  /// 下腔：该列玻璃区域的**上边界**（y 的最小值；沙堆不能高于它）
  final Float32List bottomBulbColCeil = Float32List(kColumns);

  /// 上腔累积截面积表：cumTop[i] = 从颈口往上 i 段的面积
  final Float32List cumTop = Float32List(kLevelSteps + 1);

  /// 下腔累积截面积表：cumBottom[i] = 从底部往上 i 段的面积
  final Float32List cumBottom = Float32List(kLevelSteps + 1);

  /// 上腔总容积（2D 面积）
  double get areaTop => cumTop[kLevelSteps];

  /// 下腔总容积（2D 面积）
  double get areaBottom => cumBottom[kLevelSteps];

  /// 第 j 列中心的绝对 x
  double columnX(int j) => cx - glassW * 0.5 + (j + 0.5) * dx;

  /// 上腔在高度 y 处的半宽：顶部最宽 → 颈口最窄
  double halfWidthTopAt(double y) {
    final span = neckTopY - topY;
    if (span <= 0) return neckW * 0.5;
    final t = ((y - topY) / span).clamp(0.0, 1.0).toDouble();
    final k = math.pow(1.0 - t, kBulbShapeExponent).toDouble();
    return neckW * 0.5 + (glassW * 0.5 - neckW * 0.5) * k;
  }

  /// 下腔在高度 y 处的半宽：颈口最窄 → 底部最宽
  double halfWidthBottomAt(double y) {
    final span = bottomY - neckBottomY;
    if (span <= 0) return neckW * 0.5;
    final t = ((y - neckBottomY) / span).clamp(0.0, 1.0).toDouble();
    final k = math.pow(t, kBulbShapeExponent).toDouble();
    return neckW * 0.5 + (glassW * 0.5 - neckW * 0.5) * k;
  }

  /// 上腔剩余比例 [frac]（1=满，0=空）→ 沙面液位 y（像素）
  double levelForTop(double frac) {
    return _invertLevel(
      cumTop,
      (frac.isNaN ? 0.0 : frac.clamp(0.0, 1.0).toDouble()) * areaTop,
      _dyTop,
      true,
    );
  }

  /// 下腔堆积比例 [frac]（0=空，1=满）→ 平坦液位 y（像素）
  double levelForBottom(double frac) {
    return _invertLevel(
      cumBottom,
      (frac.isNaN ? 0.0 : frac.clamp(0.0, 1.0).toDouble()) * areaBottom,
      _dyBottom,
      false,
    );
  }

  /// 二分查累积面积表反解液位（单调，最多 log2(96)≈7 次比较）
  double _invertLevel(
    Float32List cum,
    double target,
    double dy,
    bool fromNeckTop,
  ) {
    if (target <= 0.0) return fromNeckTop ? neckTopY : bottomY;
    if (target >= cum[kLevelSteps]) return fromNeckTop ? topY : neckBottomY;
    var lo = 0;
    var hi = kLevelSteps;
    while (lo + 1 < hi) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= target) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = cum[hi] - cum[lo];
    final t = span <= 1e-9 ? 0.0 : (target - cum[lo]) / span;
    final i = lo + t;
    return fromNeckTop ? neckTopY - i * dy : bottomY - i * dy;
  }

  void _build() {
    final halfG = glassW * 0.5;
    final halfNeck = neckW * 0.5;
    final spanTop = neckTopY - topY;
    final spanBottom = bottomY - neckBottomY;
    const exponentInv = 1.0 / kBulbShapeExponent;

    for (var j = 0; j < kColumns; j++) {
      final ax = cx - glassW * 0.5 + (j + 0.5) * dx;
      final dist = (ax - cx).abs();
      colAx[j] = dist;
      // k = 半宽从颈口长到 dist 的比例（0..1）
      final k = halfG - halfNeck <= 0
          ? 0.0
          : ((dist - halfNeck) / (halfG - halfNeck)).clamp(0.0, 1.0).toDouble();
      // 上腔：半宽随 y 增大而减小 → 该列的玻璃"底"在
      //   y = topY + (1 - k^(1/1.35)) * span（dist 越大，底越靠上）
      topBulbColFloor[j] =
          topY + (1.0 - math.pow(k, exponentInv).toDouble()) * spanTop;
      // 下腔：半宽随 y 增大而增大 → 该列的玻璃"顶"在
      //   y = neckBottomY + k^(1/1.35) * span
      bottomBulbColCeil[j] =
          neckBottomY + math.pow(k, exponentInv).toDouble() * spanBottom;
    }

    cumTop[0] = 0;
    cumBottom[0] = 0;
    for (var i = 1; i <= kLevelSteps; i++) {
      final yTop = neckTopY - (i - 0.5) * _dyTop;
      cumTop[i] = cumTop[i - 1] + 2.0 * halfWidthTopAt(yTop) * _dyTop;
      final yBottom = bottomY - (i - 0.5) * _dyBottom;
      cumBottom[i] = cumBottom[i - 1] + 2.0 * halfWidthBottomAt(yBottom) * _dyBottom;
    }
  }
}

// ---------------------------------------------------------------------------
// 物理 + 高度场 + 粒子池（纯计算，无 Canvas）
// ---------------------------------------------------------------------------

/// 沙漏物理。
///
/// **与 v0.3.1 `gold_sand.dart` 的根本区别**：排沙率是常量
/// （`rate = 1 / kCycleSeconds`），与传感器完全无关 —— 手机放平也一直在流；
/// 传感器只负责三件事：上腔沙面倾角、束流横向漂移、下腔坡面滑落方向，
/// 都不改变排沙量，所以"流动不中断"。
///
/// 沙量守恒用恒等式 [sBottom] == 1 - [sTop]，不做任何粒子计数。
class HourglassPhysics extends ChangeNotifier {
  HourglassPhysics({double density = 1.0}) : _density = density {
    _resetParticles(seedAlongPath: false);
  }

  // ---- 状态 ----

  /// 上腔剩余沙量 0..1
  double sTop = 1.0;

  /// 下腔堆积沙量 0..1；恒有 sTop + sBottom == 1
  double sBottom = 0.0;

  /// 平滑后的传感器值（-1..1）
  double tiltX = 0.0;
  double tiltY = 0.0;

  /// 传感器目标值（由外壳 widget 写入）
  double tiltTargetX = 0.0;
  double tiltTargetY = 0.0;

  /// 传感器是否可用（Web / 部分模拟器为 false；此时 tilt 恒 0，照样流动）
  bool hasSensor = false;

  double _density;
  double get density => _density;

  HourglassGeometry? _geo;
  HourglassGeometry? get geometry => _geo;

  // ---- 高度场 ----

  final Float32List _topSurface = Float32List(kColumns);
  final Float32List _bottomSurface = Float32List(kColumns);

  /// 上腔沙面：每列的 y（-1 = 该列无沙）
  Float32List get topSurface => _topSurface;

  /// 下腔沙堆：每列的 y（== geometry.bottomY 表示该列无沙）
  Float32List get bottomSurface => _bottomSurface;

  // ---- 粒子池（SoA，全部预分配）----

  final Float32List _px = Float32List(kParticleCount);
  final Float32List _py = Float32List(kParticleCount);
  final Float32List _vx = Float32List(kParticleCount);
  final Float32List _vy = Float32List(kParticleCount);
  final Float32List _psize = Float32List(kParticleCount);
  final Float32List _phase = Float32List(kParticleCount);

  /// 绘制用扁平缓冲 [x0,y0,x1,y1,...]；三个色调各占连续 362 个 float
  final Float32List _points = Float32List(kParticleCount * 2);

  /// 闪光用扁平缓冲
  final Float32List _sparkPoints = Float32List(kSparkCount * 2);
  final Float32List _sparkX = Float32List(kSparkCount);
  final Float32List _sparkY = Float32List(kSparkCount);
  final Float32List _sparkPhase = Float32List(kSparkCount);
  final Float32List _sparkSpeed = Float32List(kSparkCount);

  late final Float32List _tone0 =
      Float32List.sublistView(_points, 0, _kToneSlots * 2);
  late final Float32List _tone1 =
      Float32List.sublistView(_points, _kToneSlots * 2, _kToneSlots * 4);
  late final Float32List _tone2 =
      Float32List.sublistView(_points, _kToneSlots * 4, _kToneSlots * 6);

  /// 三个色调的点缓冲（各 181 个点，一帧 3 次 drawRawPoints，用到时不再分配）
  late final List<Float32List> pointsByTone = <Float32List>[
    _tone0,
    _tone1,
    _tone2,
  ];

  /// 闪光点缓冲
  Float32List get sparkPoints => _sparkPoints;

  /// 闪光的相位 / 频率（绘制时做闪烁）
  Float32List get sparkPhase => _sparkPhase;
  Float32List get sparkSpeed => _sparkSpeed;

  /// 束流/坡面/表面的点缓冲（供需要按类型裁剪的绘制使用）
  Float32List get pointBuffer => _points;

  // ---- 运行时 ----

  final math.Random _rnd = math.Random(0x5A4D1);

  /// 全局时间（驱动表面波纹与闪光相位；**与传感器无关**，永不停）
  double _t = 0.0;
  double get time => _t;

  /// 翻转进度 0..1
  double _flip = 0.0;
  double get flipProgress => _flip;

  bool _flipping = false;
  bool get flipping => _flipping;

  int _activeStream = kStreamCount;
  int _activeSlope = kSlopeCount;
  int _activeSurface = kSurfaceCount;
  int _activeSpark = kSparkCount;

  int _streamCursor = 0;
  double _spawnAcc = 0.0;

  /// 束流出生率（颗/秒）：槽位 261 个 × 单颗约 0.8s 走完 → ~320/s 才连续
  double get _spawnRate => 320.0 * _density;

  /// 下腔锥面在水平方向的半宽（像素），用于坡面碎粒的回收判定
  double _pileHalfW = 1.0;

  /// 上腔沙面弦长的半宽（像素）
  double _topHalfW = 1.0;

  /// 当前排沙强度（0..1），供绘制做亮度调制
  double get flowIntensity => sTop > 0.001 ? 1.0 : 0.0;

  // ---- 尺寸 / 密度 ----

  /// 画布尺寸变化时重建几何与高度场（在 build 阶段调用，不 notify）
  void resize(Size size) {
    if (size.isEmpty) return;
    final g = _geo;
    if (g != null && g.width == size.width && g.height == size.height) return;
    final first = g == null;
    _geo = HourglassGeometry(width: size.width, height: size.height);
    _buildSurfaceFields();
    if (first) {
      _resetParticles(seedAlongPath: true);
      return;
    }
    // 只是尺寸变了（旋转/窗口缩放）：保留沙量与粒子，重算高度场即可
    _syncAnchors();
    _writePoints();
  }

  /// 低端机降密度（PRD R-13 预留）：束流不缩到 140 以下，否则束流会断
  void setDensity(double value) {
    final d = value.clamp(0.45, 1.0).toDouble();
    if ((d - _density).abs() < 0.001) return;
    _density = d;
    _activeStream = (kStreamCount * d).round().clamp(140, kStreamCount);
    _activeSlope = (kSlopeCount * d).round().clamp(60, kSlopeCount);
    _activeSurface = (kSurfaceCount * d).round().clamp(48, kSurfaceCount);
    _activeSpark = (kSparkCount * d).round().clamp(30, kSparkCount);
    if (_streamCursor >= _activeStream) _streamCursor = 0;
  }

  // ---- 步进 ----

  /// 每帧步进：O(列数 + 粒子数)，无任何堆分配。
  void step(double dt) {
    final geo = _geo;
    if (geo == null) return;

    var d = dt;
    if (d.isNaN || d <= 0) d = 1 / 60;
    if (d > 1 / 24) d = 1 / 24; // 掉帧保护：不允许一次积分太远
    _t += d;

    _smoothTilt(d);

    if (_flipping) {
      _advanceFlip(d);
      notifyListeners();
      return;
    }

    // ① 排沙率：**与传感器无关** → 放平也在流（v0.3.1 的根因就是这条绑了传感器）
    const rate = 1.0 / kCycleSeconds;
    final tail = sTop < 0.08 ? 1.6 : 1.0; // 尾声加速收口
    sTop = (sTop - rate * tail * d).clamp(0.0, 1.0).toDouble();
    sBottom = 1.0 - sTop; // ← 守恒恒等式（PRD 4.4「上腔减少量 = 下腔增加量」）

    // ② 高度场：体积 → 液位（二分查累积面积表）
    _buildSurfaceFields();

    // ③ 束流：从颈口出生，落到下腔表面即回收（视觉层，不参与守恒计算）
    _spawnAcc += _spawnRate * d;
    var guard = 0;
    while (_spawnAcc >= 1.0 && guard < 64) {
      _spawnAcc -= 1.0;
      guard++;
      _emitStreamParticle();
    }
    _integrate(d);

    // ④ 循环：上腔见底 → 翻转复位
    if (sTop <= 0.0005) {
      sTop = 0.0;
      sBottom = 1.0;
      _flipping = true;
      _flip = 0.0;
      _spawnAcc = 0.0;
    }

    _writePoints();
    notifyListeners(); // 恒真：永远在动，不需要 active 判据
  }

  void _smoothTilt(double dt) {
    final k = math.min(1.0, dt * 4.0); // 一阶平滑：沙子有惯性
    tiltX += (tiltTargetX - tiltX) * k;
    tiltY += (tiltTargetY - tiltY) * k;
  }

  void _advanceFlip(double dt) {
    _flip += dt / kFlipSeconds;
    if (_flip < 1.0) {
      _buildSurfaceFields();
      _writePoints();
      return;
    }
    // 复位：物理状态只重置这一次（旋转是纯绘制期变换）
    _flip = 0.0;
    _flipping = false;
    sTop = 1.0;
    sBottom = 0.0;
    _resetParticles(seedAlongPath: false);
    _buildSurfaceFields();
    _writePoints();
  }

  // ---- 高度场 ----

  void _buildSurfaceFields() {
    _buildTopSurface();
    _buildBottomSurface();
  }

  void _buildTopSurface() {
    final geo = _geo!;
    final level = geo.levelForTop(sTop);
    final halfW = geo.halfWidthTopAt(level);
    _topHalfW = math.max(0.5, halfW);
    final tiltAmp = geo.glassW * 0.16;
    final rippleAmp = math.max(0.6, geo.height * 0.006);
    final funnelAmp = geo.height * 0.012;
    final nearest = geo.neckTopY - geo.neckW * 0.5;
    for (var j = 0; j < kColumns; j++) {
      final ax = geo.colAx[j];
      if (sTop <= 0.0008 || ax > halfW) {
        _topSurface[j] = -1.0; // 该列无沙
        continue;
      }
      final u = ax / halfW; // 0 = 中轴，1 = 沙面边缘
      final side = geo.columnX(j) >= geo.cx ? 1.0 : -1.0;
      final tilt = tiltX * tiltAmp * u * side;
      final ripple = rippleAmp *
          (math.sin(u * 4.1 + _t * 1.7) * 0.62 +
              math.sin(u * 8.3 - _t * 2.4 + 1.3) * 0.38);
      // 排沙口在下腔中轴 → 上腔沙面中间略凹（漏斗）
      final funnel = funnelAmp * (1.0 - u * u);
      var y = level + tilt + ripple + funnel;
      if (y > nearest) y = nearest;
      // 沙面已低于该列玻璃底（y 超过 floor）→ 这一列根本没有沙，
      // 交给玻璃 path 裁剪即可，不能把沙面"往上推"（那会把整片沙压到颈口）
      if (y > geo.topBulbColFloor[j]) {
        _topSurface[j] = -1.0;
        continue;
      }
      _topSurface[j] = y;
    }
  }

  void _buildBottomSurface() {
    final geo = _geo!;
    final level = geo.levelForBottom(sBottom);
    final halfW = geo.halfWidthBottomAt(level);
    _pileHalfW = math.max(1.0, halfW);
    final ampMax = math.min(geo.glassW * 0.16, geo.height * 0.075);
    // 堆得越满，锥顶越扁（满的时候应该是接近平坦的沙面）
    final amp = ampMax * (1.0 - 0.85 * sBottom);
    final tiltAmp = geo.glassW * 0.10;
    final wobbleAmp = geo.height * 0.0025;
    for (var j = 0; j < kColumns; j++) {
      final ax = geo.colAx[j];
      // 只在"超出玻璃最宽处"时判定该列无沙：锥体两侧的裙边允许落在
      // 玻璃斜壁上（u > 1 时按抛物线自然下探），这样沙堆不会被切成直边
      if (sBottom <= 0.0008 || ax > geo.glassW * 0.5) {
        _bottomSurface[j] = geo.bottomY;
        continue;
      }
      final u = ax / halfW;
      // 锥形（顶点在细颈正下方）+ **零均值** 调制：中轴抬高的量与边缘压低的量抵消，
      // 所以"画出来的沙量"与平坦液位算出的体积一致 → 视觉总量恒定
      var y = level - amp * (2.0 / 3.0 - 2.0 * u * u);
      final side = (geo.columnX(j) - geo.cx) / halfW;
      y += tiltX * tiltAmp * side * 0.5;
      y += math.sin(u * 6.0 - _t * 2.1) * wobbleAmp * (0.4 + 0.6 * sBottom);
      if (y < geo.bottomBulbColCeil[j]) y = geo.bottomBulbColCeil[j];
      if (y > geo.bottomY) y = geo.bottomY;
      _bottomSurface[j] = y;
    }
  }

  /// 某绝对 x 处的下腔沙堆表面 y（列索引近似，够用且 O(1)）
  double _bottomSurfaceAt(double x) {
    final geo = _geo!;
    var idx = ((x - (geo.cx - geo.glassW * 0.5)) / geo.dx).floor();
    if (idx < 0) idx = 0;
    if (idx >= kColumns) idx = kColumns - 1;
    return _bottomSurface[idx];
  }

  /// 某绝对 x 处的上腔沙面 y（-1 表示该处没有沙）
  double _topSurfaceAt(double x) {
    final geo = _geo!;
    var idx = ((x - (geo.cx - geo.glassW * 0.5)) / geo.dx).floor();
    if (idx < 0) idx = 0;
    if (idx >= kColumns) idx = kColumns - 1;
    return _topSurface[idx];
  }

  // ---- 粒子 ----

  void _resetParticles({required bool seedAlongPath}) {
    final geo = _geo;
    for (var i = 0; i < kParticleCount; i++) {
      _psize[i] = 0.9 + _rnd.nextDouble() * 0.9;
      _phase[i] = _rnd.nextDouble();
      _vx[i] = 0.0;
      _vy[i] = 0.0;
      if (geo == null) {
        _px[i] = 0.0;
        _py[i] = 0.0;
      } else if (i < kStreamCount) {
        // 束流：让颗粒一开始就分布在颈口 → 堆顶的整条路径上（打开就有连续砂束）
        _px[i] = geo.cx + (_rnd.nextDouble() - 0.5) * geo.neckW * 1.6;
        _py[i] = seedAlongPath
            ? geo.neckTopY +
                _rnd.nextDouble() * (geo.bottomY - geo.neckTopY) * 0.9
            : geo.neckTopY + _rnd.nextDouble() * 4.0;
        _vy[i] = 60.0 + _rnd.nextDouble() * 120.0;
      } else if (i < kStreamCount + kSlopeCount) {
        // 坡面：随机落在下腔的横向范围内，y 由沙堆高度场决定
        _px[i] = geo.cx + (_rnd.nextDouble() - 0.5) * geo.glassW;
        _py[i] = geo.bottomY;
      } else {
        // 上腔表面
        _px[i] = geo.cx + (_rnd.nextDouble() - 0.5) * geo.glassW;
        _py[i] = geo.topY;
      }
    }
    for (var i = 0; i < kSparkCount; i++) {
      _sparkPhase[i] = _rnd.nextDouble();
      _sparkSpeed[i] = 0.9 + _rnd.nextDouble() * 2.2;
      _sparkX[i] = geo == null
          ? 0.0
          : geo.cx + (_rnd.nextDouble() - 0.5) * geo.neckW * 5.0;
      _sparkY[i] = geo == null
          ? 0.0
          : geo.neckBottomY +
              _rnd.nextDouble() * (geo.bottomY - geo.neckBottomY) * 0.8;
    }
    _streamCursor = 0;
    _spawnAcc = 0.0;
    _syncAnchors();
    _writePoints();
  }

  /// 按当前高度场刷新非束流颗粒的位置（初始/复位后用，避免第一帧跳到别处）
  void _syncAnchors() {
    final geo = _geo;
    if (geo == null) return;
    for (var i = kStreamCount; i < kStreamCount + kSlopeCount; i++) {
      _py[i] = _bottomSurfaceAt(_px[i]) - 0.5;
    }
    for (var i = kStreamCount + kSlopeCount; i < kParticleCount; i++) {
      final y = _topSurfaceAt(_px[i]);
      _py[i] = y < 0 ? geo.neckTopY : y + (_phase[i] - 0.5) * 2.0;
    }
  }

  void _emitStreamParticle() {
    final geo = _geo;
    if (geo == null) return;
    final i = _streamCursor;
    _streamCursor = (_streamCursor + 1) % _activeStream;
    _px[i] = geo.cx + (_rnd.nextDouble() - 0.5) * geo.neckW * 1.6;
    _py[i] = geo.neckTopY + _rnd.nextDouble() * 2.0;
    _vy[i] = 40.0 + _rnd.nextDouble() * 40.0;
    _vx[i] = tiltX * 14.0 + (_rnd.nextDouble() - 0.5) * 4.0;
  }

  void _integrate(double dt) {
    final geo = _geo!;
    const gravity = 640.0; // 比真实重力慢，才看得清颗粒（空气阻力 + 颗粒互撞）

    // ── 束流：颈口出生 → 落到下腔堆顶即回收重生 ──
    for (var i = 0; i < _activeStream; i++) {
      var x = _px[i] + _vx[i] * dt;
      var y = _py[i] + _vy[i] * dt;
      var vx = _vx[i] + tiltX * 26.0 * dt;
      var vy = _vy[i] + gravity * dt;
      // 横向限幅：束流不能被倾斜吹出颈口外（PRD 4.4「中段加速、可见少量散落」）
      final maxDrift = geo.neckW * 0.6;
      final drift = (x - geo.cx).clamp(-maxDrift, maxDrift).toDouble();
      x = geo.cx + drift;
      final surface = _bottomSurfaceAt(x);
      if (y >= surface || y > geo.bottomY) {
        x = geo.cx + (_rnd.nextDouble() - 0.5) * geo.neckW * 1.6;
        y = geo.neckTopY + _rnd.nextDouble() * 2.0;
        vy = 40.0 + _rnd.nextDouble() * 40.0;
        vx = tiltX * 14.0 + (_rnd.nextDouble() - 0.5) * 4.0;
      }
      _px[i] = x;
      _py[i] = y;
      _vx[i] = vx;
      _vy[i] = vy;
    }

    // ── 坡面碎粒：沿下腔锥面向外下滑，滑出锥面就回到锥顶 ──
    for (var i = kStreamCount; i < kStreamCount + _activeSlope; i++) {
      final dir = _px[i] >= geo.cx ? 1.0 : -1.0;
      final speed = 10.0 + 26.0 * _phase[i];
      var x = _px[i] + dir * speed * dt + tiltX * 9.0 * dt;
      if ((x - geo.cx).abs() > _pileHalfW * 0.98 || sBottom <= 0.001) {
        x = geo.cx + (_rnd.nextDouble() - 0.5) * geo.neckW * 2.2;
      }
      _px[i] = x;
      _py[i] = _bottomSurfaceAt(x) - 0.5;
    }

    // ── 上腔沙面碎粒：随倾斜方向漂移，漂出沙面就回到弦内 ──
    for (var i = kStreamCount + kSlopeCount; i < kParticleCount; i++) {
      final drift = tiltX * 12.0 + (_phase[i] - 0.5) * 6.0;
      var x = _px[i] + drift * dt;
      var y = _topSurfaceAt(x);
      if (y < 0) {
        x = geo.cx + (_rnd.nextDouble() - 0.5) * _topHalfW * 1.8;
        y = _topSurfaceAt(x);
      }
      _px[i] = x;
      _py[i] = y < 0 ? geo.neckTopY : y + (_phase[i] - 0.5) * 2.0;
    }

    // ── 闪光：贴着束流与堆顶的细小高光 ──
    for (var i = 0; i < _activeSpark; i++) {
      var y = _sparkY[i] + (40.0 + 120.0 * _sparkPhase[i]) * dt;
      final surface = _bottomSurfaceAt(_sparkX[i]);
      if (y >= surface) {
        _sparkX[i] = geo.cx + (_rnd.nextDouble() - 0.5) * geo.neckW * 5.0;
        y = geo.neckBottomY + _rnd.nextDouble() * 8.0;
      }
      _sparkY[i] = y;
    }
  }

  /// 把粒子位置写进扁平缓冲（零分配；空槽位停放画外）
  void _writePoints() {
    final geo = _geo;
    if (geo == null) {
      for (var k = 0; k < _points.length; k++) {
        _points[k] = _parked;
      }
      for (var k = 0; k < _sparkPoints.length; k++) {
        _sparkPoints[k] = _parked;
      }
      return;
    }
    for (var i = 0; i < kParticleCount; i++) {
      final o = i * 2;
      final live = (i < _activeStream) ||
          (i >= kStreamCount && i < kStreamCount + _activeSlope) ||
          (i >= kStreamStartSurface && i < kStreamStartSurface + _activeSurface);
      if (!live) {
        _points[o] = _parked;
        _points[o + 1] = _parked;
        continue;
      }
      _points[o] = _px[i];
      _points[o + 1] = _py[i];
    }
    for (var i = 0; i < kSparkCount; i++) {
      final o = i * 2;
      if (i >= _activeSpark) {
        _sparkPoints[o] = _parked;
        _sparkPoints[o + 1] = _parked;
        continue;
      }
      _sparkPoints[o] = _sparkX[i];
      _sparkPoints[o + 1] = _sparkY[i];
    }
  }

  /// 颗粒预设半径（绘制时按批次取，不逐点设置）
  Float32List get particleSize => _psize;
}
