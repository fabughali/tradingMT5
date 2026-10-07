import '../../core/core_storage.dart';
import '../models/trade_direction.dart';

/// Per `${category.wireValue}|$tvSymbol`, the direction a never-yet-opened
/// pair is waiting OUT before its first-ever entry — see
/// [CoreStorage.newPairWaitFile] for the full spec.
class NewPairWaitStore {
  NewPairWaitStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() => _storage.readJsonObject(_storage.newPairWaitFile) ?? const {};

  void _write(Map<String, dynamic> map) => _storage.writeJson(_storage.newPairWaitFile, map);

  TradeDirection? get(String key) => tradeDirectionFromString(_readRaw()[key] as String?);

  void set(String key, TradeDirection excluded) {
    final map = Map<String, dynamic>.from(_readRaw());
    map[key] = excluded == TradeDirection.long ? 'long' : 'short';
    _write(map);
  }

  void clear(String key) {
    final map = Map<String, dynamic>.from(_readRaw());
    if (map.remove(key) != null) _write(map);
  }
}
