import 'dart:io';

/// Whether [candidatePid] is genuinely OUR engine process - shared by the
/// engine's own single-instance lock (bin/engine.dart) and the GUI's
/// "is the engine actually running" check
/// ([EngineControlRepository.isEngineRunning]), moved here verbatim from
/// bin/engine.dart 2026-10-20 so both sides use one definition.
///
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
bool isEngineProcessAliveSync(int candidatePid) {
  if (Platform.isWindows) {
    try {
      final result = Process.runSync('tasklist', _tasklistArgs(candidatePid));
      return _tasklistShowsEngine(result.stdout.toString());
    } catch (_) {
      return false;
    }
  }
  return _linuxCmdlineIsEngine(candidatePid);
}

/// Async twin of [isEngineProcessAliveSync] for the GUI isolate - on
/// Windows `tasklist` takes a noticeable fraction of a second, and the GUI
/// polls this every few seconds, so it must not block the UI thread.
Future<bool> isEngineProcessAlive(int candidatePid) async {
  if (Platform.isWindows) {
    try {
      final result = await Process.run('tasklist', _tasklistArgs(candidatePid));
      return _tasklistShowsEngine(result.stdout.toString());
    } catch (_) {
      return false;
    }
  }
  return _linuxCmdlineIsEngine(candidatePid);
}

/// Windows port (2026-10-07) of the same PID-reuse guard - no /proc on
/// Windows, so ask `tasklist` for that specific PID and check the image
/// name it reports matches ours, same "don't trust a bare PID match"
/// reasoning as above.
List<String> _tasklistArgs(int candidatePid) => ['/FI', 'PID eq $candidatePid', '/FO', 'CSV', '/NH'];

bool _tasklistShowsEngine(String stdout) => stdout.toLowerCase().contains('tradingmt5_engine.exe');

bool _linuxCmdlineIsEngine(int candidatePid) {
  try {
    final cmdlineFile = File('/proc/$candidatePid/cmdline');
    if (!cmdlineFile.existsSync()) return false;
    final cmdline = cmdlineFile.readAsStringSync();
    return cmdline.contains('tradingmt5_engine');
  } catch (_) {
    return false;
  }
}
