import 'dart:ui';

import 'package:family_finance_app/widgets/sand_box_physics.dart';
import 'package:flutter_test/flutter_test.dart';

/// 立方体盒子装沙的物理验收（v0.5.2，替代沙漏）。
///
/// 核心：盒子固定在屏幕，沙面垂直重力；手机旋转 → 重力变 → 沙子流到盒子新低端。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SandBoxPhysics 盒子装沙', () {
    test('初始：沙量约 50%，沙面垂直重力（重力向下时沙在下半）', () {
      final p = SandBoxPhysics();
      p.resize(const Size(393, 873));
      p.setTilt(0.0);
      for (var f = 0; f < 30; f++) {
        p.step(1 / 60);
      }
      final g = p.gravity;
      final top = const Offset(196, 100);
      final bottom = const Offset(196, 800);
      expect(p.sandDepthAt(top), lessThan(0), reason: '上半应是空的');
      expect(p.sandDepthAt(bottom), greaterThan(0), reason: '下半应是沙');
      // 沙面垂直重力：沙面线上的点 g·p ≈ c（含起伏容差）
      final pts = List<Offset>.filled(24, Offset.zero);
      final n = p.fillSandSurface(pts, 24);
      for (var i = 0; i < n; i++) {
        final dot = g.x * pts[i].dx + g.y * pts[i].dy;
        expect(dot, closeTo(p.c, 25.0),
            reason: '沙面点应满足 g·p ≈ c');
      }
    });

    test('沙量守恒：流动后沙区面积不变（约 50%）', () {
      final p = SandBoxPhysics();
      p.resize(const Size(393, 873));
      p.setTilt(0.0);
      p.step(1 / 60);
      p.setTilt(1.0);
      for (var f = 0; f < 120; f++) {
        p.step(1 / 60);
      }
      var inside = 0;
      const n = 40;
      for (var i = 0; i < n; i++) {
        for (var j = 0; j < n; j++) {
          final pt = Offset(393 * (i + 0.5) / n, 873 * (j + 0.5) / n);
          if (p.sandDepthAt(pt) >= 0) inside++;
        }
      }
      final frac = inside / (n * n);
      expect(frac, closeTo(0.5, 0.06),
          reason: '沙区面积应守恒（约 50%），实测 ${(frac * 100).toStringAsFixed(1)}%');
    });

    test('手机横放 90°：沙子流到右侧', () {
      final p = SandBoxPhysics();
      p.resize(const Size(393, 873));
      p.setTilt(0.0);
      for (var f = 0; f < 30; f++) {
        p.step(1 / 60);
      }
      p.setTilt(1.0);
      for (var f = 0; f < 180; f++) {
        p.step(1 / 60);
      }
      final right = const Offset(380, 436);
      final left = const Offset(10, 436);
      expect(p.sandDepthAt(right), greaterThan(0), reason: '右倾后右侧应是沙');
      expect(p.sandDepthAt(left), lessThan(0), reason: '右倾后左侧应是空的');
    });

    test('粒子缓冲：长度 = 粒子数×2，位置有限（非 NaN）', () {
      final p = SandBoxPhysics();
      p.resize(const Size(393, 873));
      p.step(1 / 60);
      final buf = p.pointsBuf;
      expect(buf.length, p.particleCount * 2);
      for (var i = 0; i < buf.length; i++) {
        expect(buf[i].isFinite, isTrue, reason: '粒子坐标必须有限');
      }
    });

    test('沙面起伏：沿 u 轴有变化（表现堆积角/坡面）', () {
      final p = SandBoxPhysics();
      p.resize(const Size(393, 873));
      p.setTilt(0.0);
      for (var f = 0; f < 60; f++) {
        p.step(1 / 60);
      }
      final pts = List<Offset>.filled(24, Offset.zero);
      final n = p.fillSandSurface(pts, 24);
      final g = p.gravity;
      final dots = <double>[];
      for (var i = 0; i < n; i++) {
        dots.add(g.x * pts[i].dx + g.y * pts[i].dy);
      }
      var minV = dots.first, maxV = dots.first;
      for (final v in dots) {
        if (v < minV) minV = v;
        if (v > maxV) maxV = v;
      }
      expect(maxV - minV, greaterThan(1.0),
          reason: '沙面应有起伏（坡面/休止角），不是纯直线');
    });
  });
}
