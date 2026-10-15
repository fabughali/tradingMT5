import '../../core/core_storage.dart';

/// The engine's answer to a manual "+" click, once known (2026-10-15, per
/// the user, after a copy's pending fallback order was rejected by MT5
/// itself for insufficient margin ("no money") — the app's OWN margin-tiered
/// gate is deliberately bypassed for a manual copy, but MT5's own broker-
/// side margin check can't be bypassed by anything this app does, so the
/// user still needs to be told when it happens). Same one-shot request/
/// response shape as [SymbolResolveStore] - the GUI polls after a
/// [AddCopyRequestStore.request], shows a SnackBar once a result lands, then
/// clears it.
class AddCopyResultStore {
  AddCopyResultStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() =>
      _storage.readJsonObject(_storage.addCopyResultsFile) ?? const {};

  void _write(Map<String, dynamic> map) =>
      _storage.writeJson(_storage.addCopyResultsFile, map);

  /// Engine side: records a genuine, known failure reason for [tvSymbol]'s
  /// most recent manual copy attempt (e.g. MT5's own "no money" rejection
  /// text). Deliberately never called for the ambiguous "pending order not
  /// yet triggered" case - that one might still succeed on its own once the
  /// next cycle sees it.
  void recordFailure(String tvSymbol, String reason) {
    final map = Map<String, dynamic>.from(_readRaw());
    map[tvSymbol.toUpperCase()] = {
      'status': 'failed',
      'reason': reason,
      'at': DateTime.now().toUtc().toIso8601String(),
    };
    _write(map);
  }

  void recordSuccess(String tvSymbol) {
    final map = Map<String, dynamic>.from(_readRaw());
    map[tvSymbol.toUpperCase()] = {
      'status': 'opened',
      'at': DateTime.now().toUtc().toIso8601String(),
    };
    _write(map);
  }

  /// GUI side: polls for the outcome of a prior add-copy click. Null means
  /// nothing to show (no attempt yet, or already shown/cleared).
  Map<String, dynamic>? peek(String tvSymbol) =>
      _readRaw()[tvSymbol.toUpperCase()] as Map<String, dynamic>?;

  /// GUI side: every outcome currently sitting in the store, across all
  /// symbols - the Dashboard polls this once per tick rather than once per
  /// row, same "poll the whole file, not per-key" shape as every other
  /// multi-row identity store here.
  Map<String, Map<String, dynamic>> peekAll() =>
      _readRaw().map((k, v) => MapEntry(k, v as Map<String, dynamic>));

  /// GUI side: dismisses a result once it's been shown as a SnackBar (or the
  /// dashboard is closed) - this store is a transient scratch pad, not a
  /// permanent record.
  void clear(String tvSymbol) {
    final map = Map<String, dynamic>.from(_readRaw());
    if (map.remove(tvSymbol.toUpperCase()) != null) _write(map);
  }
}
