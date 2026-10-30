import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'api.dart';
import 'pages/audit_page.dart';
import 'pages/dashboard_page.dart';
import 'pages/errors_page.dart';
import 'pages/families_page.dart';
import 'pages/login_page.dart';
import 'pages/users_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AdminApp());
}

class AdminApp extends StatefulWidget {
  const AdminApp({super.key});
  @override
  State<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends State<AdminApp> {
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await ApiClient.instance.loadTokens();
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const MaterialApp(home: Scaffold(body: Center(child: CircularProgressIndicator())));
    }
    return MaterialApp.router(
      title: '家庭财务 · 管理后台',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5B6CFF)),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF5B6CFF), brightness: Brightness.dark),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      routerConfig: _router,
    );
  }

  late final GoRouter _router = GoRouter(
    initialLocation: '/dashboard',
    redirect: (ctx, state) {
      if (!ApiClient.instance.hasToken && state.matchedLocation != '/login') return '/login';
      if (ApiClient.instance.hasToken && state.matchedLocation == '/login') return '/dashboard';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginPage()),
      ShellRoute(
        builder: (ctx, state, child) => AdminShell(child: child),
        routes: [
          GoRoute(path: '/dashboard', builder: (_, __) => const DashboardPage()),
          GoRoute(path: '/users', builder: (_, __) => const UsersPage()),
          GoRoute(path: '/families', builder: (_, __) => const FamiliesPage()),
          GoRoute(path: '/audit', builder: (_, __) => const AuditPage()),
          GoRoute(path: '/errors', builder: (_, __) => const ErrorsPage()),
        ],
      ),
    ],
  );
}

class AdminShell extends StatelessWidget {
  final Widget child;
  const AdminShell({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final loc = GoRouterState.of(context).matchedLocation;
    int idx = 0;
    if (loc.startsWith('/users')) idx = 1;
    if (loc.startsWith('/families')) idx = 2;
    if (loc.startsWith('/audit')) idx = 3;
    if (loc.startsWith('/errors')) idx = 4;
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            extended: true,
            selectedIndex: idx,
            onDestinationSelected: (i) {
              switch (i) {
                case 0: context.go('/dashboard'); break;
                case 1: context.go('/users'); break;
                case 2: context.go('/families'); break;
                case 3: context.go('/audit'); break;
                case 4: context.go('/errors'); break;
              }
            },
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('管理后台', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            ),
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.dashboard), label: Text('总览')),
              NavigationRailDestination(icon: Icon(Icons.people), label: Text('用户')),
              NavigationRailDestination(icon: Icon(Icons.family_restroom), label: Text('家庭')),
              NavigationRailDestination(icon: Icon(Icons.assignment), label: Text('审计')),
              NavigationRailDestination(icon: Icon(Icons.bug_report), label: Text('错误')),
            ],
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: TextButton.icon(
                    onPressed: () async {
                      await ApiClient.instance.clear();
                      if (context.mounted) context.go('/login');
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text('退出'),
                  ),
                ),
              ),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: child),
        ],
      ),
    );
  }
}
