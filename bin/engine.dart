import 'dart:async';
import 'dart:io';

import 'package:trading_mt5/core/core_storage.dart';
import 'package:trading_mt5/data/config/config_loader.dart';
import 'package:trading_mt5/data/engine/engine_service.dart';
import 'package:trading_mt5/data/logging/app_logger.dart';
import 'package:trading_mt5/data/models/app_config.dart';
import 'package:trading_mt5/data/platform/engine_process.dart';

// The long-lived engine process — mirrors tradingPionex's bin/engine.dart.
// Start it once and leave it running on the same machine as MT5 (Wine),
// since that access must stay local. The Flutter GUI never embeds this
// class — it only reads the status/log files this process writes and
// toggles the PAUSE/STOP/CHECKNOW control files.
//
// Run with: dart run bin/engine.dart
// Configure the data directory with TRADING_MT5_HOME (defaults to
// ~/.tradingmt5).

// The PID-reuse-safe liveness check this file's single-instance lock uses
// moved to lib/data/platform/engine_process.dart (2026-10-20) so the GUI's
// own "is the engine running" check shares the exact same definition - see
// [isEngineProcessAliveSync]'s doc comment for the full history.

void main() async {
  final storage = CoreStorage.instance;
  final logger = AppLogger(storage);

  final AppConfig config;
  final EngineService engine;
  try {
    config = loadOrInitConfig(storage);
    engine = EngineService(config: config, storage: storage, logger: logger);
  } catch (e, st) {
    logger.log(
      'CRITICAL: engine failed to start - could not load config.json or '
      'logs/state.json ($e). Check those files for corruption/bad hand-edits '
      'and fix or delete them, then restart.',
      level: 'CRITICAL',
    );
    logger.log(st.toString(), level: 'CRITICAL');
    exit(1);
  }

  // Single-instance lock: two engine processes against the same data
  // directory would be two brains fighting over the same trades.
  final existingPidRaw = storage.readString(storage.pidFile);
  final existingPid = int.tryParse((existingPidRaw ?? '').trim());
  if (existingPid != null &&
      existingPid != pid &&
      isEngineProcessAliveSync(existingPid)) {
    logger.log(
      'REFUSING TO START: engine already running as PID $existingPid '
      'against this data directory (${storage.rootDir}). Stop it first if '
      'you really want to replace it.',
      level: 'CRITICAL',
    );
    exit(1);
  }

  storage.writeString(storage.pidFile, '$pid\n');
  // A shutdown request left behind by an earlier stop that ended in a hard
  // kill (or a request that raced a fresh Power-on) was meant for THAT
  // process, not this one - never let it stop a brand-new engine.
  storage.deleteFileIfExists(storage.shutdownRequestFile);

  // Hard watchdog added 2026-10-05, per the user ("make app closing engine
  // instantly once power toggle off and once gui closed"): engine.stop()
  // only sets a flag [run] checks at the TOP of its loop, so a genuinely
  // stuck iteration (the exact failure mode the same request's bug-fix
  // part addressed) could otherwise still delay shutdown by however long
  // that iteration takes. Every long-running step in engine_service.dart
  // is now bounded to well under this, so in practice this should never
  // fire - it exists purely as a guaranteed ceiling: no matter what,
  // `systemctl --user stop` (or any SIGTERM/SIGINT) gets this process
  // gone within _forceExitAfter of being sent, full stop.
  const forceExitAfter = Duration(seconds: 10);
  var stopping = false;
  void onStopSignal(String signal) {
    // Several stop sources now exist (signals + [shutdownRequestFile]) and
    // can overlap - only the first one runs the shutdown sequence.
    if (stopping) return;
    stopping = true;
    logger.log('$signal received — shutting down.');
    engine.stop();
    // 2026-10-18, per the user, after a real incident: Power toggled off
    // but the Dashboard's Engine/MT5/TradingView lights stayed green.
    // Root cause (two-layered, this is the second layer - see
    // [EngineControlRepository.status]'s own doc comment for the first):
    // this force-exit watchdog firing is actually the COMMON case, not a
    // rare edge case (confirmed live, repeatedly, across this whole
    // session's own deploy cycles) - and `exit(0)` terminates the process
    // immediately, so the ONLY cleanup that used to run on a clean
    // `engine.run()` return (deleting [pidFile]/[heartbeatFile] below)
    // almost never actually executed in practice. [heartbeatFile]'s
    // staleness is exactly what [EngineControlRepository.engineRunning]
    // uses to decide whether the Dashboard's lights should show live data
    // at all - a file that outlives the process it claims to represent
    // defeats that check entirely. Deleting both files HERE, the instant
    // the signal is caught (not after whatever's left of the current
    // cycle iteration finishes, and not gated on the graceful path
    // succeeding), guarantees a stop is reflected immediately regardless
    // of which of the two exit paths below actually ends up firing.
    storage.deleteFileIfExists(storage.pidFile);
    storage.deleteFileIfExists(storage.heartbeatFile);
    storage.deleteFileIfExists(storage.shutdownRequestFile);
    Timer(forceExitAfter, () {
      logger.log(
        'Graceful shutdown did not finish within '
        '${forceExitAfter.inSeconds}s — forcing exit.',
        level: 'ERROR',
      );
      exit(0);
    });
  }

  ProcessSignal.sigint.watch().listen((_) => onStopSignal('SIGINT'));
  // sigterm isn't supported on Windows (2026-10-07, Windows port) - watching
  // it there throws.
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => onStopSignal('SIGTERM'));
  }
  // Windows graceful stop (2026-10-20, per the user, after confirming live
  // that `taskkill` - the old Windows stop path - runs NO handlers at all:
  // 51 Power-offs, zero "shutting down" lines, pid/heartbeat files left
  // behind every time). With no SIGTERM on Windows, the GUI now asks for a
  // stop by writing [CoreStorage.shutdownRequestFile] and only hard-kills
  // after ~10s. Polled on a timer rather than at the top of [EngineService.run]'s
  // loop, since one full sweep iteration can run 10+ minutes; timers fire
  // between the engine's awaits, so this lands within about a second.
  // Harmless on Linux (nothing writes the file there).
  Timer.periodic(const Duration(seconds: 1), (_) {
    if (storage.fileExists(storage.shutdownRequestFile)) {
      onStopSignal('SHUTDOWN_REQUEST');
    }
  });

  await engine.run();

  storage.deleteFileIfExists(storage.pidFile);
  storage.deleteFileIfExists(storage.heartbeatFile);
  storage.deleteFileIfExists(storage.shutdownRequestFile);
  logger.log('Engine stopped cleanly.');

  // The ProcessSignal.watch() subscriptions above keep the isolate's event
  // loop alive even after main() returns — without this, the OS process
  // never actually exits despite having logged a clean shutdown and deleted
  // its own lock files. Confirmed live 2026-09-12: `kill -TERM` produced
  // exactly that (log + files gone, process still resident).
  exit(0);
}
