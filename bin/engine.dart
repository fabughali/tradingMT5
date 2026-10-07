import 'dart:async';
import 'dart:io';

import 'package:trading_mt5/core/core_storage.dart';
import 'package:trading_mt5/data/config/config_loader.dart';
import 'package:trading_mt5/data/engine/engine_service.dart';
import 'package:trading_mt5/data/logging/app_logger.dart';
import 'package:trading_mt5/data/models/app_config.dart';

// The long-lived engine process — mirrors tradingPionex's bin/engine.dart.
// Start it once and leave it running on the same machine as MT5 (Wine),
// since that access must stay local. The Flutter GUI never embeds this
// class — it only reads the status/log files this process writes and
// toggles the PAUSE/STOP/CHECKNOW control files.
//
// Run with: dart run bin/engine.dart
// Configure the data directory with TRADING_MT5_HOME (defaults to
// ~/.tradingmt5).

/// Confirmed live 2026-10-04, after a sudden power loss: `kill -0 <pid>`
/// alone only proves SOME process currently holds that PID, not that it's
/// OUR process - the OS recycles PIDs, and after an unclean shutdown (the
/// crashed engine never got to delete its own pid file) the very next boot
/// handed PID 4706 to `pipewire`, which made this check report "alive"
/// forever and permanently refuse to start (every single restart attempt
/// re-read the same stale pid file and hit the same false positive -
/// confirmed via journalctl showing an unbroken crash-restart loop since
/// boot). Checking `/proc/<pid>/cmdline` for our own binary name closes
/// this: a process reusing the PID almost certainly isn't named
/// `tradingmt5_engine`, so this can only match the real thing.
bool _isProcessAlive(int candidatePid) {
  try {
    final cmdlineFile = File('/proc/$candidatePid/cmdline');
    if (!cmdlineFile.existsSync()) return false;
    final cmdline = cmdlineFile.readAsStringSync();
    return cmdline.contains('tradingmt5_engine');
  } catch (_) {
    return false;
  }
}

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
      _isProcessAlive(existingPid)) {
    logger.log(
      'REFUSING TO START: engine already running as PID $existingPid '
      'against this data directory (${storage.rootDir}). Stop it first if '
      'you really want to replace it.',
      level: 'CRITICAL',
    );
    exit(1);
  }

  storage.writeString(storage.pidFile, '$pid\n');

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
  void onStopSignal(String signal) {
    logger.log('$signal received — shutting down.');
    engine.stop();
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
  ProcessSignal.sigterm.watch().listen((_) => onStopSignal('SIGTERM'));

  await engine.run();

  storage.deleteFileIfExists(storage.pidFile);
  storage.deleteFileIfExists(storage.heartbeatFile);
  logger.log('Engine stopped cleanly.');

  // The ProcessSignal.watch() subscriptions above keep the isolate's event
  // loop alive even after main() returns — without this, the OS process
  // never actually exits despite having logged a clean shutdown and deleted
  // its own lock files. Confirmed live 2026-09-12: `kill -TERM` produced
  // exactly that (log + files gone, process still resident).
  exit(0);
}
