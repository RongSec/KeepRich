import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'config.dart';
import 'pages/admin/admin_home_page.dart';
import 'pages/admin/admin_login_page.dart';
import 'pages/big_purchase_page.dart';
import 'pages/devices_page.dart';
import 'pages/family_page.dart';
import 'pages/home_page.dart';
import 'pages/login_page.dart';
import 'pages/plan_page.dart';
import 'pages/register_page.dart';
import 'pages/security_page.dart';
import 'pages/settings_page.dart' show UserManagementPage;
import 'pages/splash_page.dart';
import 'services/accounts.dart';
import 'services/api.dart';
import 'services/auth.dart';
import 'services/device_auth.dart';
import 'services/notify.dart';
import 'services/sync_status.dart';
import 'services/web_updater.dart';
import 'theme.dart';
import 'widgets/hourglass_sand.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 全局错误兜底：框架异常与未捕获异步错误（如托管网关不支持 WebSocket 时
  // 浏览器抛的 onerror）记录即止，绝不让它们打断 UI 或冒成页面级错误
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
  };
  runZonedGuarded(() async {
    // 先读本地保存的服务端地址，再建连接（否则会先连到默认地址）
    await AppConfig.init();
    runApp(const AppRoot());
  }, (e, s) {
    assert(() {
      // ignore: avoid_print
      print('[uncaught] $e');
      return true;
    }());
  });
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> with WidgetsBindingObserver {
  final _accounts = AccountsRepo();
  final _deviceAuth = DeviceAuthService();
  final _notify = NotifyService();
  late final AuthState _auth;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 双向同步：账号被移除/淘汰时删设备凭据；凭据写/删时更新账号卡标志。
    _accounts.onAccountRemoved = _deviceAuth.clearDeviceToken;
    _deviceAuth.onCredentialChanged = _accounts.markCredential;
    _auth = AuthState(accounts: _accounts, deviceAuth: _deviceAuth);

    // 会话过期（refresh 也失败）→ 跳回登录页，带上 idle/revoked/device 原因。
    // 同时清掉上一页残留的报错，免得登录页顶上还挂着旧的英文错误。
    ApiClient.onSessionExpired = (reason) {
      _auth.sessionExpired(reason);
      _AppShell.scaffoldMessengerKey.currentState?.clearSnackBars();
    };
    _bootstrap();
    _notify.initLocalNotifications();
    _auth.addListener(_onAuthChanged);
    // Web 端：检查是否有新的前端构建，有则提示刷新
    WebUpdater.instance.start();
  }

  /// 本机账号仓库与设备能力先就绪，再恢复会话（冷启动 ≤1.5s 纯本地渲染）。
  Future<void> _bootstrap() async {
    await _accounts.load();
    await _deviceAuth.init();
    await _auth.bootstrap();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回前台主动刷一次（access 剩余 <5 分钟才真发请求），避免第一屏先吃 401。
    if (state == AppLifecycleState.resumed && _auth.isLoggedIn) {
      _auth.refreshIfIdle();
    }
  }

  void _onAuthChanged() {
    if (_auth.isLoggedIn) {
      _notify.connect();
      _notify.loadUnreadCount();
      // 云端快照同步状态：登录后开始 60s 轮询（R-11）
      SyncStatusService.instance.start();
    } else {
      _notify.disconnect();
      SyncStatusService.instance.stop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
        ChangeNotifierProvider.value(value: _accounts),
        ChangeNotifierProvider.value(value: _deviceAuth),
      ],
      child: _AppShell(auth: _auth),
    );
  }
}

class _AppShell extends StatelessWidget {
  final AuthState auth;
  const _AppShell({required this.auth});

  /// 用来在跳登录页前清掉上一页残留的错误提示
  static final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

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
        // 未登录可进：登录页 + 注册页
        final openWhenLoggedOut = loc == '/login' || loc == '/register';
        if (!auth.isLoggedIn) return openWhenLoggedOut ? null : '/login';
        // 已登录还停在登录/注册页 → 直接进概览
        if (openWhenLoggedOut) return '/overview';
        return null;
      },
      routes: [
        GoRoute(path: '/splash', builder: (_, __) => const SplashPage()),
        GoRoute(path: '/login', builder: (_, __) => const LoginPage()),
        GoRoute(path: '/register', builder: (_, __) => const RegisterPage()),
        GoRoute(
            path: '/admin/login', builder: (_, __) => const AdminLoginPage()),
        GoRoute(path: '/admin', builder: (_, __) => const AdminShell()),
        GoRoute(path: '/overview', builder: (_, __) => const HomePage(tab: 0)),
        GoRoute(path: '/future', builder: (_, __) => const HomePage(tab: 1)),
        GoRoute(
            path: '/bookkeeping', builder: (_, __) => const HomePage(tab: 2)),
        GoRoute(path: '/settings', builder: (_, __) => const HomePage(tab: 3)),
        GoRoute(path: '/family', builder: (_, __) => const FamilyManagePage()),
        GoRoute(path: '/plan', builder: (_, __) => const PlanPage()),
        GoRoute(
            path: '/big-purchase', builder: (_, __) => const BigPurchasePage()),
        GoRoute(path: '/security', builder: (_, __) => const SecurityPage()),
        GoRoute(path: '/users', builder: (_, __) => const UserManagementPage()),
        GoRoute(path: '/devices', builder: (_, __) => const DevicesPage()),
      ],
    );

    return MaterialApp.router(
      scaffoldMessengerKey: scaffoldMessengerKey,
      title: '永远富裕',
      debugShowCheckedModeBanner: false,
      // 全程深色（不跟随系统亮度，避免与金沙背景冲突）
      themeMode: ThemeMode.dark,
      theme: AppTheme.dark(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
      // 沙漏背景铺在最底层：登录前饱满、登录后变淡
      builder: (ctx, child) => Stack(
        fit: StackFit.expand,
        children: [
          HourglassSandBackground(dimmed: auth.isLoggedIn, density: 1.0),
          if (child != null) child,
        ],
      ),
    );
  }
}
