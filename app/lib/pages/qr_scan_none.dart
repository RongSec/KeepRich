import 'package:flutter/material.dart';

/// Web 端占位实现：浏览器里不需要扫码（登录页自己就会显示二维码）。
Future<String?> scanServerQr(BuildContext context) async {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Web 端无需扫码：本页已显示服务端二维码')),
  );
  return null;
}
