import '../../core/core_storage.dart';
import '../engine/worm10_decision.dart';

/// One triple-confirmed candidate event the third decision technique
/// (worm_10_26 + spy_9_26) is currently waiting out, for one
/// (category, tvSymbol) pair - same "survive one full extra candle" role
/// as [PendingSignalStore]/`supertrend-pending.json`, just storing a
/// [Worm10EventKind] wire string instead of a 4-way HH/LL/BUY/SELL tag
/// (2026-10-14, per the user's third decision technique).
class Worm10PendingSignal {
  const Worm10PendingSignal({required this.kind, required this.barTime});
  final Worm10EventKind kind;
  final int barTime;
}

/// Keyed by `${category.wireValue}|$tvSymbol` - see
/// [CoreStorage.worm10PendingFile].
class Worm10PendingSignalStore {
  Worm10PendingSignalStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() => _storage.readJsonObject(_storage.worm10PendingFile) ?? const {};

  void _write(Map<String, dynamic> map) => _storage.writeJson(_storage.worm10PendingFile, map);

  Worm10PendingSignal? get(String key) {
    final raw = _readRaw()[key] as Map<String, dynamic>?;
    if (raw == null) return null;
    return Worm10PendingSignal(
      kind: worm10EventKindFromWire(raw['kind'] as String),
      barTime: (raw['bar_time'] as num).toInt(),
    );
  }

  void set(String key, Worm10EventKind kind, int barTime) {
    final map = Map<String, dynamic>.from(_readRaw());
    map[key] = {'kind': worm10EventKindToWire(kind), 'bar_time': barTime};
    _write(map);
  }

  void clear(String key) {
    final map = Map<String, dynamic>.from(_readRaw());
    if (map.remove(key) != null) _write(map);
  }
}
