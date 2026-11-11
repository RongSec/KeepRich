import 'package:family_finance_app/widgets/hourglass_sand.dart';
import 'package:family_finance_app/widgets/star_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 静态金色星空背景的验收。
///
/// 核心：确定性星表（固定 seed）、坐标归一化、无 NaN、
/// `shouldRepaint` 恒 false（纯静态）、`dimmed` 影响整体透明度。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('buildStars 确定性星表', () {
    test('星星数量随 density 变化，默认约 90~140 颗', () {
      final base = buildStars(density: 1.0);
      final low = buildStars(density: 0.5);
      final high = buildStars(density: 1.5);
      expect(base.length, inInclusiveRange(90, 140),
          reason: '默认密度应约 90~140 颗');
      expect(low.length, lessThan(base.length), reason: 'density 越低星越少');
      expect(high.length, greaterThan(base.length), reason: 'density 越高星越多');
    });

    test('坐标均在 [0,1]，数值有限无 NaN，半径/亮度有效', () {
      for (final s in buildStars(density: 1.0)) {
        expect(s.x, inInclusiveRange(0.0, 1.0), reason: 'x 应归一化到 [0,1]');
        expect(s.y, inInclusiveRange(0.0, 1.0), reason: 'y 应归一化到 [0,1]');
        expect(s.x.isFinite && s.y.isFinite, isTrue, reason: '坐标不得为 NaN/Inf');
        expect(s.radius.isFinite, isTrue, reason: '半径不得为 NaN/Inf');
        expect(s.radius, greaterThan(0.0));
        expect(s.brightness, inInclusiveRange(0.0, 1.0));
        expect(s.tone, inInclusiveRange(0, 2));
      }
    });

    test('固定 seed：两次生成星表完全一致（确定性）', () {
      final a = buildStars(density: 1.0);
      final b = buildStars(density: 1.0);
      expect(a.length, b.length);
      for (var i = 0; i < a.length; i++) {
        expect(a[i].x, b[i].x);
        expect(a[i].y, b[i].y);
        expect(a[i].radius, b[i].radius);
        expect(a[i].brightness, b[i].brightness);
      }
    });

    test('存在少量带柔光晕的大星，大多数是小星', () {
      final stars = buildStars(density: 1.0);
      final haloCount = stars.where((s) => s.halo).length;
      expect(haloCount, greaterThan(0), reason: '应有少数大星带光晕');
      expect(haloCount, lessThan(stars.length ~/ 4),
          reason: '光晕大星只占少数，保持安静');
    });
  });

  group('StarFieldPainter 静态绘制', () {
    test('shouldRepaint 恒为 false（纯静态，无逐帧重绘）', () {
      final a = StarFieldPainter(stars: buildStars(density: 1.0));
      final b = StarFieldPainter(stars: buildStars(density: 1.0));
      expect(a.shouldRepaint(b), isFalse);
      expect(a.shouldRebuildSemantics(b), isFalse);
    });

    test('disposeImages 可调用（兼容保留成员，空实现）', () {
      final p = StarFieldPainter(stars: buildStars(density: 1.0));
      p.disposeImages(); // 不应抛异常
    });
  });

  group('HourglassSandBackground 外壳', () {
    testWidgets('dimmed 影响透明度：登录后 0.65、登录前 1.0', (tester) async {
      AnimatedOpacity opacityOf() => tester.widget<AnimatedOpacity>(
            find.descendant(
              of: find.byType(HourglassSandBackground),
              matching: find.byType(AnimatedOpacity),
            ),
          );

      await tester.pumpWidget(
        const MaterialApp(home: HourglassSandBackground(dimmed: false)),
      );
      expect(opacityOf().opacity, 1.0);

      await tester.pumpWidget(
        const MaterialApp(home: HourglassSandBackground(dimmed: true)),
      );
      await tester.pump(const Duration(milliseconds: 700));
      expect(opacityOf().opacity, 0.65, reason: '登录后变淡沿用 0.65 口径');
    });

    testWidgets('density 变化时星数随之变化（外壳正确传递）', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: HourglassSandBackground(density: 0.5)),
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(
        const MaterialApp(home: HourglassSandBackground(density: 1.5)),
      );
      expect(tester.takeException(), isNull);
    });
  });
}
