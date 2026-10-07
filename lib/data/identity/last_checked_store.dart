import '../../core/core_storage.dart';

/// When each base was last genuinely re-evaluated - past the retry
/// cooldown, a real chart read attempted (2026-09-29, per the user's
/// Dashboard "Check" column: "if pair checked in current candle cycle or
/// not"). Keyed by uppercase tvSymbol -> ISO timestamp string. Deliberately
/// no explicit per-cycle reset: the GUI derives "checked THIS cycle" by
/// comparing this timestamp's UTC hour against the current UTC hour, so a
/// stale timestamp from a previous hour naturally reads as "not checked"
/// without the engine needing to clear anything.
class LastCheckedStore {
  LastCheckedStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() => _storage.readJsonObject(_storage.lastCheckedFile) ?? const {};

  void record(String tvSymbol) {
    final map = Map<String, dynamic>.from(_readRaw());
    map[tvSymbol.toUpperCase()] = DateTime.now().toUtc().toIso8601String();
    _storage.writeJson(_storage.lastCheckedFile, map);
  }

  DateTime? lastCheckedAt(String tvSymbol) {
    final raw = _readRaw()[tvSymbol.toUpperCase()] as String?;
    return raw == null ? null : DateTime.tryParse(raw);
  }
}
