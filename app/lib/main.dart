import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'pages/admin/admin_home_page.dart';
import 'pages/admin/admin_login_page.dart';
import 'pages/big_purchase_page.dart';
import 'pages/family_page.dart';
import 'pages/home_page.dart';
import 'pages/login_page.dart';
import 'pages/plan_page.dart';
import 'pages/security_page.dart';
import 'pages/settings_page.dart' show UserManagementPage;
import 'pages/splash_page.dart';
import 'services/auth.dart';
import 'services/biometric.dart';
import 'services/notify.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AppRoot());
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  final _auth = AuthState();
  final _notify = NotifyService();
  final _biometric = BiometricService();

  @override
  void initState() {
    super.initState();
    _auth.bootstrap();
    _biometric.init();
    _notify.initLocalNotifications();
    _auth.addListener(_onAuthChanged);
  }

  void _onAuthChanged() {
    if (_auth.isLoggedIn) {
      _notify.connect();
      _notify.loadUnreadCount();
    } else {
      _notify.disconnect();
    }
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _notify.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _auth),
        ChangeNotifierProvider.value(value: _notify),
        ChangeNotifierProvider.value(value: _biometric),
      ],
      child: _AppShell(auth: _auth),
    );
  }
}

class _AppShell extends StatelessWidget {
  final AuthState auth;
  const _AppShell({required this.auth});

  @override
  Widget build(BuildContext context) {
    final router = GoRouter(
      refreshListenable: auth,
      initialLocation: '/splash',
      redirect: (ctx, state) {
        if (auth.loading) return null;
        final loc = state.matchedLocation;
        // 开屏页不重定向
        if (loc == '/splash') return null;
        // 管理后台区域独立鉴权
        if (loc.startsWith('/admin')) {
          if (loc == '/admin/login') return null;
          if (!auth.isLoggedIn) return '/admin/login';
          if (auth.user?.role != 'admin') return '/admin/login';
          return null;
        }
        if (!auth.isLoggedIn && loc != '/login') return '/login';
        if (auth.isLoggedIn && loc == '/login') return '/overview';
        return null;
      },
      routes: [
        GoRoute(path: '/splash', builder: (_, __) => const SplashPage()),
        GoRoute(path: '/login', builder: (_, __) => const LoginPage()),
        GoRoute(path: '/admin/login', builder: (_, __) => const AdminLoginPage()),
        GoRoute(path: '/admin', builder: (_, __) => const AdminShell()),
        GoRoute(path: '/overview', builder: (_, __) => const HomePage(tab: 0)),
        GoRoute(path: '/future', builder: (_, __) => const HomePage(tab: 1)),
        GoRoute(path: '/bookkeeping', builder: (_, __) => const HomePage(tab: 2)),
        GoRoute(path: '/settings', builder: (_, __) => const HomePage(tab: 3)),
        GoRoute(path: '/family', builder: (_, __) => const FamilyManagePage()),
        GoRoute(path: '/plan', builder: (_, __) => const PlanPage()),
        GoRoute(path: '/big-purchase', builder: (_, __) => const BigPurchasePage()),
        GoRoute(path: '/security', builder: (_, __) => const SecurityPage()),
        GoRoute(path: '/users', builder: (_, __) => const UserManagementPage()),
      ],
    );

    return MaterialApp.router(
      title: '永远富裕',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
    );
  }
}
