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

  /// 2026-10-18, per a real confirmed crash: a pending entry can carry a
  /// wire value from a kind that's since been REMOVED from
  /// [Worm10EventKind] (e.g. `SELL_CLOSE1`/`BUY_CLOSE1`, retired when the
  /// "weak" close-only variants were removed) - [worm10EventKindFromWire]
  /// correctly throws on that, by design, for a genuinely corrupt value,
  /// but a stale-but-was-once-valid value isn't corrupt, it's just
  /// outdated. Treated as "nothing pending" and cleaned up here, the same
  /// way every other store in this app skips a bad entry rather than
  /// crashing the caller.
  Worm10PendingSignal? get(String key) {
    final raw = _readRaw()[key] as Map<String, dynamic>?;
    if (raw == null) return null;
    try {
      return Worm10PendingSignal(
        kind: worm10EventKindFromWire(raw['kind'] as String),
        barTime: (raw['bar_time'] as num).toInt(),
      );
    } catch (_) {
      clear(key);
      return null;
    }
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
