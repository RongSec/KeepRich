import 'package:flutter/foundation.dart';

class AppConfig {
  static String get apiBaseUrl => kIsWeb ? '/api' : 'http://10.0.2.2:8080/api';
}
