import 'package:go_router/go_router.dart';

import '../screens/app/dashboard_screen.dart';
import '../screens/app/history_screen.dart';
import '../screens/app/logs_screen.dart';
import '../screens/app/settings_screen.dart';
import '../screens/app/splash_screen.dart';
import '../widgets/reuse_nav_shell.dart';

/// go_router setup: a splash route, then a persistent nav shell (dashboard/
/// history/logs/settings) built with StatefulShellRoute so each tab keeps
/// its own state when switching. The Controls tab (Resume/Pause/Check
/// now/Stop buttons) was removed 2026-09-30, per the user ("delete
/// controls screen. not required") - Resume/Pause duplicated the
/// Dashboard's own Power toggle; Check now/Stop had no equivalent
/// elsewhere and were simply dropped, not relocated.
class CoreRouter {
  CoreRouter._();

  static final router = GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            ReuseNavShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/dashboard',
                builder: (context, state) => const DashboardScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/history',
                builder: (context, state) => const HistoryScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/logs',
                builder: (context, state) => const LogsScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (context, state) => const SettingsScreen(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
