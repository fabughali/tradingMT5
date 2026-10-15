import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/providers/app_providers.dart';
import '../utilities/util_responsive.dart';

/// Persistent navigation shell — a [NavigationRail] on wide (desktop)
/// windows and a [NavigationBar] on narrow ones, wrapping go_router's
/// [StatefulShellRoute] so each tab keeps its own state.
class ReuseNavShell extends ConsumerWidget {
  const ReuseNavShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  static const _destinations = [
    (
      icon: Icons.dashboard_outlined,
      selectedIcon: Icons.dashboard,
      label: 'Dashboard',
    ),
    (icon: Icons.history_outlined, selectedIcon: Icons.history, label: 'History'),
    (icon: Icons.article_outlined, selectedIcon: Icons.article, label: 'Logs'),
    (
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings,
      label: 'Settings',
    ),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 2026-10-15, per the user ("first one but with snackbar"), after a
    // manual copy's pending fallback order was rejected by MT5 itself for
    // insufficient margin ("no money") with nothing shown beyond
    // engine.log — see [addCopyResultsProvider]'s own doc comment.
    // Deliberately registered HERE, on the persistent shell's own
    // Scaffold, rather than on the Dashboard tab's nested one - go_router's
    // StatefulShellRoute.indexedStack keeps every tab's widget tree (and
    // its own Scaffold) mounted simultaneously even while hidden, so a
    // SnackBar fired from an inactive tab's Scaffold isn't reliably the one
    // actually on screen (confirmed live: the engine-side write/clear cycle
    // completed correctly every time, but the user never saw a toast).
    // This shell Scaffold is the one always-visible regardless of which
    // tab is selected, so firing it here is the only placement guaranteed
    // to be on screen. Only the failure case gets a SnackBar; a successful
    // copy is already visible as a new grouped row on the Dashboard, so
    // toasting that too would just be noise.
    ref.listen<AsyncValue<Map<String, Map<String, dynamic>>>>(addCopyResultsProvider, (
      previous,
      next,
    ) {
      final results = next.asData?.value;
      if (results == null || results.isEmpty) return;
      final repo = ref.read(controlRepositoryProvider);
      for (final entry in results.entries) {
        final tvSymbol = entry.key;
        final status = entry.value['status'] as String?;
        if (status == 'failed') {
          final reason = entry.value['reason'] as String?;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '$tvSymbol: copy failed${reason != null ? ' — $reason' : ''}',
              ),
              duration: const Duration(seconds: 8),
            ),
          );
        }
        repo.clearAddCopyResult(tvSymbol);
      }
    });

    if (UtilResponsive.isCompact(context)) {
      return Scaffold(
        body: navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (i) => navigationShell.goBranch(
            i,
            initialLocation: i == navigationShell.currentIndex,
          ),
          destinations: [
            for (final d in _destinations)
              NavigationDestination(
                icon: Icon(d.icon),
                selectedIcon: Icon(d.selectedIcon),
                label: d.label,
              ),
          ],
        ),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: (i) => navigationShell.goBranch(
              i,
              initialLocation: i == navigationShell.currentIndex,
            ),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.asset(
                  'assets/icons/icon_64.png',
                  width: 32,
                  height: 32,
                ),
              ),
            ),
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: Text(d.label),
                ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: navigationShell),
        ],
      ),
    );
  }
}
