import '../../core/core_storage.dart';

/// Whether `${category.wireValue}|$tvSymbol` has EVER achieved a real
/// first open — see [CoreStorage.firstOpenFile] for the full spec. A key
/// present here skips the "wait for a confirmed opposite signal" gate
/// entirely; a key absent (with nothing currently running) is still
/// waiting it out via [NewPairWaitStore].
class FirstOpenStore {
  FirstOpenStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() => _storage.readJsonObject(_storage.firstOpenFile) ?? const {};

  void _write(Map<String, dynamic> map) => _storage.writeJson(_storage.firstOpenFile, map);

  bool hasOpened(String key) => _readRaw()[key] == true;

  void markOpened(String key) {
    if (hasOpened(key)) return;
    final map = Map<String, dynamic>.from(_readRaw());
    map[key] = true;
    _write(map);
  }
}
