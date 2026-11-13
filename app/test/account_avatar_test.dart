import 'dart:convert';

import 'package:family_finance_app/widgets/account_avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AccountAvatar：data URI 头像显示图片而非首字', (tester) async {
    // 1x1 红色 PNG
    final red = base64Encode([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
      0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
      0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE, 0x02, 0xFE, 0x00, 0x00,
      0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AccountAvatar(
          avatar: 'data:image/png;base64,$red',
          nickname: '系统管理员',
          username: 'admin',
          size: 60,
        ),
      ),
    ));

    // 应渲染 Image.memory（data URI），而不是首字 Text
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('系'), findsNothing);
  });

  testWidgets('AccountAvatar：无头像时回退首字', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AccountAvatar(
          avatar: '',
          nickname: '系统管理员',
          username: 'admin',
          size: 60,
        ),
      ),
    ));

    expect(find.text('系'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });
}
