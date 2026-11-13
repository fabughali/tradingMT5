import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/core_router.dart';
import 'core/core_storage.dart';
import 'core/core_theme.dart';
import 'core/gui_instance_lock.dart';
import 'data/config/config_loader.dart';
import 'data/control/engine_control_repository.dart';
import 'data/logging/app_logger.dart';
import 'data/models/power_health.dart';
import 'data/mt5/mt5_launcher.dart';
import 'data/providers/app_providers.dart';
import 'l10n/app_localizations.dart';
import 'widgets/power_off_confirm.dart';

/// One instance, reused by every hook below — cheap to construct (just
/// wraps file-backed stores) but no reason to build it twice.
final _controlRepo = EngineControlRepository(CoreStorage.instance);

/// Held in a top-level variable so it isn't garbage-collected the instant
/// [main] returns — [AppLifecycleListener] only fires its callbacks for as
/// long as something keeps it alive. Never read again after [main] sets
/// it; its only job is to keep existing.
// ignore: unused_element
AppLifecycleListener? _exitListener;

Future<void> main() async {
  // MUST stay first (2026-10-20) - see [GuiInstanceLock]: everything below
  // (forcing Power OFF, the GUI heartbeat, the engine watchdog) would
  // otherwise run a second time from a duplicate launch and stop a live
  // engine out from under the window that started it.
  if (!GuiInstanceLock.acquire(CoreStorage.instance)) {
    AppLogger(CoreStorage.instance).log(
      'GUI already running - this second launch is exiting without touching '
      'Power/engine state (focusing the existing window instead).',
      level: 'WARNING',
    );
    await GuiInstanceLock.focusExisting(CoreStorage.instance);
    exit(0);
  }

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

  // Engine-process watchdog (2026-10-17) - found live, a real incident: the
  // engine process self-stopped twice within a few hours (its own GUI
  // heartbeat staleness check - [EngineService.run]'s own doc comment -
  // mistakenly concluded the GUI had closed, even though this process was
  // still alive and running the whole time, most likely from the main
  // isolate's event loop getting busy enough to miss the 20s staleness
  // window at least once). Power ("on" = no PAUSE file) and the actual
  // engine OS process are two separate things with nothing previously
  // reconciling them: the Dashboard's Power toggle kept showing ON (the
  // PAUSE file was never touched by that self-stop) while the real engine
  // process was dead and trading was silently offline, with no automatic
  // recovery - exactly the self-healing gap the user has repeatedly asked
  // this app to close for MT5/TradingView themselves ("once tradingMT5
  // on, mt5 should be running"). Checked every 15s: if Power is on but the
  // engine process genuinely isn't running, restart it - [resume]'s own
  // PAUSE-file delete is a harmless no-op when it's already absent, so
  // this is safe to call unconditionally whenever this condition is true.
  final watchdogLogger = AppLogger(storage);
  // 2026-10-20: now asks whether the engine PROCESS is alive
  // ([EngineControlRepository.isEngineRunning]) instead of whether the
  // heartbeat file exists - on Windows that file outlived every stop/crash,
  // so this watchdog could never fire there (see PRD §20).
  var watchdogBusy = false;
  Timer.periodic(const Duration(seconds: 15), (_) async {
    if (watchdogBusy) return;
    watchdogBusy = true;
    try {
      if (!_controlRepo.isPowerOn || await _controlRepo.isEngineRunning()) return;
      // Re-checked after the async process query: Power may have been
      // switched off while it ran.
      if (!_controlRepo.isPowerOn) return;
      // Logged distinctly from resume()'s own "[USER] Power turned ON" -
      // this is the watchdog acting automatically, not a real user click,
      // and that distinction matters for anyone reading the log later to
      // understand what actually happened.
      watchdogLogger.log(
        'ENGINE WATCHDOG: Power is on but the engine process isn\'t running - '
        'restarting it automatically.',
        level: 'WARNING',
      );
      unawaited(_controlRepo.resume());
    } finally {
      watchdogBusy = false;
    }
  });

  // 2026-11-13, per the user (relayed from TradingPionex): "make tradingMT5
  // start with Windows and power on by itself" - after a Windows restart this
  // app's engine is what starts TradingView (port 9222) for both apps.
  // Supersedes the 2026-10-05 "Power always starts OFF" rule. Any leftover
  // engine is still stopped first; Auto keeps its saved state.
  unawaited(_autoPowerOnAtLaunch());

  // Closing the GUI should always take the engine down with it, under any
  // scenario (2026-10-05, per the user) - this is the fast, graceful path
  // for the common case (window-close button, or a signal sent to this
  // process); an ungraceful loss (a crash, `kill -9`) instead falls back
  // to the engine's OWN stale-heartbeat self-stop above, since nothing
  // here gets a chance to run in that case.
  _exitListener = AppLifecycleListener(
    onExitRequested: () async {
      if (!await _confirmCloseWhilePowerOn()) return AppExitResponse.cancel;
      await _controlRepo.pause();
      GuiInstanceLock.release();
      return AppExitResponse.exit;
    },
  );
  // Windows only: sigterm isn't supported there (watching it throws);
  // sigint (Ctrl+C/Ctrl+Break) is.
  for (final signal in [ProcessSignal.sigint]) {
    signal.watch().listen((_) async {
      await _controlRepo.pause();
      GuiInstanceLock.release();
      exit(0);
    });
  }
}

/// Automatic Power ON at every launch (2026-11-13, per the user): stop any
/// leftover engine first, then the normal Power ON, re-checked every 30s
/// until the engine reports Ready. A message shows only on the first failed
/// check; later ones are only logged. Stops for good the moment the user
/// flips Power themselves ([EngineControlRepository.userSwitchedPower]).
Future<void> _autoPowerOnAtLaunch() async {
  final logger = AppLogger(CoreStorage.instance);
  await _controlRepo.pause(auto: 'launch - stopping any leftover engine first');
  if (EngineControlRepository.userSwitchedPower) return;
  final startedAt = DateTime.now();
  await _controlRepo.resume(auto: 'automatic at launch');
  var failures = 0;
  Timer.periodic(const Duration(seconds: 30), (timer) async {
    if (EngineControlRepository.userSwitchedPower) {
      timer.cancel();
      logger.log('AUTO POWER: the user switched Power - automatic Power ON stops.');
      return;
    }
    final status = await _controlRepo.status();
    final fresh = status.lastCycleAt != null && status.lastCycleAt!.isAfter(startedAt);
    if (_controlRepo.isPowerOn && status.health == PowerHealthState.ready && fresh) {
      timer.cancel();
      logger.log('AUTO POWER: checks passed - engine Ready.');
      return;
    }
    failures++;
    final why = 'health ${status.health.name}${status.message == null ? '' : ' (${status.message})'}';
    logger.log('AUTO POWER: not Ready yet ($why) - retrying in 30s (check $failures).', level: 'WARNING');
    if (failures == 1) {
      final context = CoreRouter.router.routerDelegate.navigatorKey.currentContext;
      if (context != null && context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(content: Text('Automatic Power ON: not ready yet ($why) - retrying every 30 s.')),
        );
      }
    }
    if (!_controlRepo.isPowerOn || !await _controlRepo.isEngineRunning()) {
      if (EngineControlRepository.userSwitchedPower) return;
      await _controlRepo.resume(auto: 'automatic retry');
    }
  });
}

/// The prompt showing now, so a second close click waits on it instead of
/// stacking another dialog.
Future<bool>? _closePrompt;

/// True if the window may close. Power off needs no prompt, so the silent
/// installer's close still works. Each answer is logged, because the log alone
/// couldn't tell a window close from a Power click on 2026-11-01.
Future<bool> _confirmCloseWhilePowerOn() {
  if (!_controlRepo.isPowerOn) return Future.value(true);
  return _closePrompt ??= () async {
    try {
      final context = CoreRouter.router.routerDelegate.navigatorKey.currentContext;
      if (context == null) return true;
      final confirmed = await confirmPowerOff(context, closingApp: true);
      AppLogger(CoreStorage.instance).log(
        confirmed
            ? '[USER] Window close confirmed with Power on.'
            : '[USER] Window close cancelled - Power stays on.',
      );
      return confirmed;
    } finally {
      _closePrompt = null;
    }
  }();
}

Future<void> _ensureMt5OnStartup() async {
  // 2026-10-18, per the user, after repeatedly finding MT5 open on
  // launch with Power showing off: this self-heal launch had NO Power
  // check at all - it fired unconditionally on every GUI start,
  // completely independent of whether the user actually wants trading
  // active. The self-heal intent above only makes sense while Power is
  // on - that's the only time anything is actually relying on MT5 being
  // up. Checked fresh here (not cached) since this runs once at startup,
  // same instant as the Power toggle's own read.
  if (!_controlRepo.isPowerOn) return;
  final storage = CoreStorage.instance;
  final config = loadOrInitConfig(storage);
  await ensureMt5Running(config.mt5.mcpHost, config.mt5.mcpPort, Mt5LaunchConfig.defaultForWindows());
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
