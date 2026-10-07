import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/core_router.dart';
import 'core/core_storage.dart';
import 'core/core_theme.dart';
import 'data/config/config_loader.dart';
import 'data/control/engine_control_repository.dart';
import 'data/mt5/mt5_launcher.dart';
import 'data/providers/app_providers.dart';
import 'l10n/app_localizations.dart';

/// One instance, reused by every hook below — cheap to construct (just
/// wraps file-backed stores) but no reason to build it twice.
final _controlRepo = EngineControlRepository(CoreStorage.instance);

/// Held in a top-level variable so it isn't garbage-collected the instant
/// [main] returns — [AppLifecycleListener] only fires its callbacks for as
/// long as something keeps it alive. Never read again after [main] sets
/// it; its only job is to keep existing.
// ignore: unused_element
AppLifecycleListener? _exitListener;

void main() {
  runApp(const ProviderScope(child: TradingMt5App()));

  // Fire-and-forget, not awaited before runApp — the UI should show
  // immediately; watchedSymbolsProvider's own resilient poll loop already
  // picks up MT5 the moment it comes up, no need to block startup on a
  // launch that can take 10-20s. Per the user (2026-09-19): MT5 has
  // repeatedly gone down independently of this app during the same
  // session, with no automatic recovery until someone noticed the Market
  // Watch list went empty — this makes the app self-heal on its own start
  // instead.
  unawaited(_ensureMt5OnStartup());

  // 2026-10-05, per the user: "make engine stop if gui is stopped ...
  // trading view/mt5 should not launch unless user open gui" - the engine
  // watches this file's staleness to decide whether the GUI is actually
  // open; while it's fresh (refreshed here every 5s, well inside the
  // engine's own staleness threshold), the engine runs normally, and stops
  // itself outright the moment this stops being touched (GUI closed,
  // crashed, or never opened at all - including right after a system
  // restart) - see EngineService.run's own doc comment.
  final storage = CoreStorage.instance;
  storage.touchFile(storage.guiHeartbeatFile);
  Timer.periodic(const Duration(seconds: 5), (_) {
    storage.touchFile(storage.guiHeartbeatFile);
  });

  // 2026-10-05, per the user: "once user launched the gui after restart,
  // power toggle should be off" - Power no longer persists as "on" across
  // a GUI relaunch (superseding the OLDER 2026-09-27 decision to let it
  // persist, which was about routine same-session redeploys fighting the
  // user, a different scenario). Fire-and-forget is fine: [pause]'s PAUSE-
  // file write happens synchronously before its first `await`, so the
  // toggle's very first read already sees "off" - only the actual
  // `systemctl stop` (defensive, in case something left the engine running
  // from before this GUI launch) finishes slightly later.
  unawaited(_controlRepo.pause());

  // Closing the GUI should always take the engine down with it, under any
  // scenario (2026-10-05, per the user) - this is the fast, graceful path
  // for the common case (window-close button, or a signal sent to this
  // process); an ungraceful loss (a crash, `kill -9`) instead falls back
  // to the engine's OWN stale-heartbeat self-stop above, since nothing
  // here gets a chance to run in that case.
  _exitListener = AppLifecycleListener(
    onExitRequested: () async {
      await _controlRepo.pause();
      return AppExitResponse.exit;
    },
  );
  // sigterm isn't supported on Windows (2026-10-07, Windows port) - only
  // sigint (Ctrl+C/Ctrl+Break) is; watching it there throws.
  final signals = Platform.isWindows
      ? [ProcessSignal.sigint]
      : [ProcessSignal.sigint, ProcessSignal.sigterm];
  for (final signal in signals) {
    signal.watch().listen((_) async {
      await _controlRepo.pause();
      exit(0);
    });
  }
}

Future<void> _ensureMt5OnStartup() async {
  final storage = CoreStorage.instance;
  final config = loadOrInitConfig(storage);
  if (Platform.isWindows) {
    await ensureMt5Running(config.mt5.mcpHost, config.mt5.mcpPort, Mt5LaunchConfig.defaultForWindows());
    return;
  }
  final home = Platform.environment['HOME'] ?? '';
  final defaults = Mt5LaunchConfig.defaultForHome(home);
  await ensureMt5Running(
    config.mt5.mcpHost,
    config.mt5.mcpPort,
    Mt5LaunchConfig(
      winePrefix: defaults.winePrefix,
      terminalPath: defaults.terminalPath,
      desktopFile: defaults.desktopFile,
      display: Platform.environment['DISPLAY'],
      xauthority: Platform.environment['XAUTHORITY'],
    ),
  );
}

class TradingMt5App extends ConsumerWidget {
  const TradingMt5App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      debugShowCheckedModeBanner: false,
      theme: CoreTheme.light(),
      darkTheme: CoreTheme.dark(),
      themeMode: themeMode.flutterThemeMode,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: CoreRouter.router,
    );
  }
}
