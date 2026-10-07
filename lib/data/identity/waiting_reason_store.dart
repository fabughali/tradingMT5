import '../../core/core_storage.dart';

/// The literal, unparaphrased reason a symbol is currently sitting
/// "Waiting" with nothing open (2026-09-29, per the user: "waiting pairs
/// should reflect exact reason ... not guess ... for example (not enough
/// margin)"). [reason] is always the real text MT5/the broker returned
/// (e.g. "deleted [no money]", "order rejected: retcode=10018") - never a
/// guess or a paraphrase.
class WaitingReasonStore {
  WaitingReasonStore(this._storage);

  final CoreStorage _storage;

  Map<String, Map<String, dynamic>> _readRaw() {
    final raw = _storage.readJsonObject(_storage.waitingReasonsFile) ?? const {};
    return raw.map((k, v) => MapEntry(k.toUpperCase(), (v as Map<String, dynamic>)));
  }

  void _write(Map<String, Map<String, dynamic>> map) =>
      _storage.writeJson(_storage.waitingReasonsFile, map);

  /// [reason] should be the exact text from MT5/the broker, not a summary.
  void record(String tvSymbol, String reason) {
    final map = _readRaw();
    map[tvSymbol.toUpperCase()] = {
      'reason': reason,
      'at': DateTime.now().toIso8601String(),
    };
    _write(map);
  }

  /// Called once [tvSymbol] successfully opens - a stale reason from a
  /// PREVIOUS failed attempt should never keep showing once the symbol is
  /// actually running.
  void clear(String tvSymbol) {
    final map = _readRaw();
    if (map.remove(tvSymbol.toUpperCase()) != null) _write(map);
  }

  String? reasonFor(String tvSymbol) => _readRaw()[tvSymbol.toUpperCase()]?['reason'] as String?;
}
