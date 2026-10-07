import '../../core/core_storage.dart';

/// One triple-confirmed candidate signal a symbol/category is currently
/// waiting out — see [PendingSignalStore]'s doc / [CoreStorage.pendingSignalsFile].
class PendingSignal {
  const PendingSignal({required this.tag, required this.barTime});

  /// Wire-format tag ('HH'/'LL'/'BUY'/'SELL') — see signalTagToWire/FromWire.
  final String tag;

  /// The candidate signal's own bar open time (epoch seconds) — NOT the
  /// candle being waited out (that's always `barTime + candlePeriod`,
  /// derivable on demand, so it isn't stored separately).
  final int barTime;
}

/// Per (category, tvSymbol) - keyed by `${category.wireValue}|$tvSymbol` -
/// the signal currently mid-wait for the "survive one full extra candle"
/// confirmation rule (2026-09-29, per the user - see
/// [CoreStorage.pendingSignalsFile] for the full spec). A symbol with no
/// entry here has nothing pending; [EngineService] treats that as "the
/// next triple-confirmed signal starts a fresh wait."
class PendingSignalStore {
  PendingSignalStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() => _storage.readJsonObject(_storage.pendingSignalsFile) ?? const {};

  void _write(Map<String, dynamic> map) => _storage.writeJson(_storage.pendingSignalsFile, map);

  PendingSignal? get(String key) {
    final raw = _readRaw()[key] as Map<String, dynamic>?;
    if (raw == null) return null;
    return PendingSignal(tag: raw['tag'] as String, barTime: (raw['bar_time'] as num).toInt());
  }

  void set(String key, String tag, int barTime) {
    final map = Map<String, dynamic>.from(_readRaw());
    map[key] = {'tag': tag, 'bar_time': barTime};
    _write(map);
  }

  void clear(String key) {
    final map = Map<String, dynamic>.from(_readRaw());
    if (map.remove(key) != null) _write(map);
  }
}
