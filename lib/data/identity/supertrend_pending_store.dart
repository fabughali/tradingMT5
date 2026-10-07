import '../../core/core_storage.dart';

/// One triple-confirmed Supertrend Plus Buy/Sell signal currently being
/// waited out for one full extra candle — see
/// [CoreStorage.supertrendPendingFile] for why this is a separate store
/// from [PendingSignalStore] rather than sharing it. Same shape as
/// `PendingSignal`, kept as its own small type so neither store accidentally
/// becomes interchangeable with the other.
class SupertrendPendingSignal {
  const SupertrendPendingSignal({required this.tag, required this.barTime});

  final String tag;
  final int barTime;
}

class SupertrendPendingStore {
  SupertrendPendingStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() => _storage.readJsonObject(_storage.supertrendPendingFile) ?? const {};

  void _write(Map<String, dynamic> map) => _storage.writeJson(_storage.supertrendPendingFile, map);

  SupertrendPendingSignal? get(String key) {
    final raw = _readRaw()[key] as Map<String, dynamic>?;
    if (raw == null) return null;
    return SupertrendPendingSignal(tag: raw['tag'] as String, barTime: (raw['bar_time'] as num).toInt());
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
