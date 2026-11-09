import 'dart:ui' show Size;

import 'package:family_finance_app/widgets/hourglass_physics.dart';
import 'package:flutter_test/flutter_test.dart';

/// 沙漏物理的自动化验收（R-08）：
/// 静置也流动 / 沙量守恒 / 上腔下降 + 下腔锥高单调上升 / 60s 内至少一次翻转复位。
///
/// 传感器恒 0（等价于"手机平放桌面、加速度计不可用"），这正是 v0.3.1 的死区。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 上腔沙面平均高度（无沙列返回 -1，跳过）
  double topLevelMean(HourglassPhysics p) {
    final s = p.topSurface;
    var sum = 0.0;
    var n = 0;
    for (var j = 0; j < kColumns; j++) {
      if (s[j] >= 0) {
        sum += s[j];
        n++;
      }
    }
    return n == 0 ? double.nan : sum / n;
  }

  /// 下腔锥顶（= 最小 y，即最高点）
  double coneApex(HourglassPhysics p) {
    final s = p.bottomSurface;
    var minY = p.geometry!.bottomY;
    for (var j = 0; j < kColumns; j++) {
      if (s[j] < minY) minY = s[j];
    }
    return minY;
  }

  int liveStreamPoints(HourglassPhysics p) {
    final buf = p.pointBuffer;
    var n = 0;
    for (var i = 0; i < buf.length; i += 2) {
      if (buf[i] > -1000 && buf[i + 1] > -1000) n++;
    }
    return n;
  }

  test('静置 60s：持续流动 + 守恒 + 60s 内至少一次翻转复位', () {
    final p = HourglassPhysics();
    p.resize(const Size(400, 800));
    // 传感器不可用（Web / 模拟器 / 放桌面）→ tilt 恒 0，沙漏照样必须流
    p.hasSensor = false;

    const dt = 1 / 60;
    var flips = 0;
    var conserve = true;
    var topMonotonic = true;
    var levelMonotonic = true;
    var coneMonotonic = true;

    var lastTop = p.sTop;
    var lastLevel = topLevelMean(p);
    var lastApex = coneApex(p);
    var streamSeen = 0;
    var maxLevelGain = 0.0;
    var maxApexRise = 0.0;
    var startLevel = lastLevel;
    var startApex = lastApex;

    for (var i = 0; i < 60 * 60; i++) {
      final wasFlipping = p.flipping;
      p.step(dt);
      // 守恒恒等式：sTop + sBottom == 1（浮点精确）
      if ((p.sTop + p.sBottom - 1.0).abs() > 1e-12) conserve = false;
      if (liveStreamPoints(p) > 0) streamSeen++;
      if (p.flipping) continue;
      if (wasFlipping) {
        // 一轮结束（翻转 → 复位）：先用"翻转前最后一帧"结算本轮的位移，
        // 再把物理量回到 sTop=1 的基线继续比
        final levelGain = lastLevel - startLevel;
        final apexRise = startApex - lastApex;
        if (levelGain > maxLevelGain) maxLevelGain = levelGain;
        if (apexRise > maxApexRise) maxApexRise = apexRise;
        flips++;
        lastTop = p.sTop;
        lastLevel = topLevelMean(p);
        lastApex = coneApex(p);
        startLevel = lastLevel;
        startApex = lastApex;
        continue;
      }
      if (p.sTop > lastTop + 1e-12) topMonotonic = false;
      final level = topLevelMean(p);
      if (!level.isNaN && level < lastLevel - 0.25) levelMonotonic = false;
      final apex = coneApex(p);
      if (apex > lastApex + 0.25) coneMonotonic = false;
      lastTop = p.sTop;
      if (!level.isNaN) lastLevel = level;
      lastApex = apex;
    }

    expect(conserve, isTrue, reason: 'sTop + sBottom 必须恒为 1');
    expect(topMonotonic, isTrue, reason: '上腔沙量必须单调减少');
    expect(levelMonotonic, isTrue, reason: '上腔沙面必须持续下降（放平也一样）');
    expect(coneMonotonic, isTrue, reason: '下腔锥顶必须单调上升');
    expect(maxLevelGain, greaterThan(150),
        reason: '一轮内上腔沙面下降 150px 以上（800px 高画布约半腔）');
    expect(maxApexRise, greaterThan(100), reason: '一轮内下腔堆高应上升 100px 以上');
    expect(streamSeen, greaterThan(0), reason: '细颈必须有可见颗粒束');
    expect(flips, greaterThanOrEqualTo(1), reason: '60s 内至少一次翻转复位');
  });

  test('翻转结束后物理量复位（sTop=1, sBottom=0）', () {
    final p = HourglassPhysics();
    p.resize(const Size(360, 640));
    const dt = 1 / 60;
    // 直接把沙量推到见底，省时间
    var guard = 0;
    while (!p.flipping && guard < 60 * 120) {
      p.step(dt);
      guard++;
    }
    expect(p.flipping, isTrue);
    guard = 0;
    while (p.flipping && guard < 60 * 5) {
      p.step(dt);
      guard++;
    }
    expect(p.flipping, isFalse);
    expect(p.sTop, 1.0);
    expect(p.sBottom, 0.0);
    expect((p.sTop + p.sBottom), 1.0);
  });

  test('倾斜只改变流向，不中断流动（排沙率恒定）', () {
    final p = HourglassPhysics();
    p.resize(const Size(400, 800));
    p.tiltTargetX = 0.9;
    p.tiltTargetY = -0.7;

    const dt = 1 / 60;
    final before = p.sTop;
    for (var i = 0; i < 60 * 5; i++) {
      p.step(dt);
      if (p.flipping) fail('5s 内不应发生翻转');
    }
    final dropped = before - p.sTop;
    // 5s / 48s ≈ 0.104，允许尾声加速前的 ±15% 误差
    expect(dropped, closeTo(5 / kCycleSeconds, 5 / kCycleSeconds * 0.15),
        reason: '排沙量必须只由常量排沙率决定，与倾角无关');
  });
}
