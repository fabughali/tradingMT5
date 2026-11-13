import 'dart:io';

/// Whether [candidatePid] is genuinely OUR engine process - shared by the
/// engine's own single-instance lock (bin/engine.dart) and the GUI's
/// "is the engine actually running" check
/// ([EngineControlRepository.isEngineRunning]).
///
/// A bare PID match isn't enough: the OS recycles PIDs, and after an unclean
/// shutdown a stale pid file can point at some unrelated process (seen live
/// 2026-10-04). So `tasklist` is asked for that PID and its image name must
/// be `tradingmt5_engine.exe`. Windows only (2026-11-13).
bool isEngineProcessAliveSync(int candidatePid) {
  try {
    final result = Process.runSync('tasklist', _tasklistArgs(candidatePid));
    return _tasklistShowsEngine(result.stdout.toString());
  } catch (_) {
    return false;
  }
}

/// Async twin of [isEngineProcessAliveSync] for the GUI isolate - `tasklist`
/// takes a noticeable fraction of a second, and the GUI polls this every few
/// seconds, so it must not block the UI thread.
Future<bool> isEngineProcessAlive(int candidatePid) async {
  try {
    final result = await Process.run('tasklist', _tasklistArgs(candidatePid));
    return _tasklistShowsEngine(result.stdout.toString());
  } catch (_) {
    return false;
  }
}

List<String> _tasklistArgs(int candidatePid) => ['/FI', 'PID eq $candidatePid', '/FO', 'CSV', '/NH'];

bool _tasklistShowsEngine(String stdout) => stdout.toLowerCase().contains('tradingmt5_engine.exe');
