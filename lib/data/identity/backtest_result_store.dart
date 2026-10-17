import '../../core/core_storage.dart';
import '../models/backtest_row.dart';

/// The engine's answer to a [BacktestRequestStore] request, once known -
/// see that store's own doc comment. `status` is 'running' while the
/// engine is mid-computation (a multi-day history pull can genuinely take
/// a while), then 'done' with the full [BacktestResult] once finished.
class BacktestResultStore {
  BacktestResultStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic>? _readRaw() => _storage.readJsonObject(_storage.backtestResultFile);

  /// Engine side: marks the run as started, so the GUI can show a spinner
  /// instead of a stale previous result while it waits.
  void recordRunning(String tvSymbol) {
    _storage.writeJson(_storage.backtestResultFile, {
      'status': 'running',
      'tv_symbol': tvSymbol,
      'started_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  void recordDone(BacktestResult result) {
    _storage.writeJson(_storage.backtestResultFile, {
      'status': 'done',
      'result': result.toJson(),
      'finished_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// GUI side: null means no run has ever been requested (or the result
  /// was cleared). `status` is 'running' or 'done'; `result` is only
  /// present once 'done'.
  ({String status, BacktestResult? result})? peek() {
    final raw = _readRaw();
    if (raw == null) return null;
    final status = raw['status'] as String? ?? 'running';
    final resultJson = raw['result'] as Map<String, dynamic>?;
    return (
      status: status,
      result: resultJson != null ? BacktestResult.fromJson(resultJson) : null,
    );
  }

  void clear() => _storage.deleteFileIfExists(_storage.backtestResultFile);
}
