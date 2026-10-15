import '../../core/core_storage.dart';

/// Queue the GUI appends to and the engine drains every cycle (2026-10-15,
/// per the user's multiplier-column spec: "once user click on it ... a new
/// trade opens with same tp/sl open signal"). Same one-shot request shape
/// as [TerminateRequestStore] - a click is a command, not a standing flag,
/// so `take()`-style clearing applies once the engine has actually acted
/// on it (or found nothing to copy).
class AddCopyRequestStore {
  AddCopyRequestStore(this._storage);

  final CoreStorage _storage;

  Set<String> _readRaw() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.addCopyRequestsFile);
    } catch (_) {
      return {};
    }
    return arr.map((e) => e.toString().toUpperCase()).where((e) => e.isNotEmpty).toSet();
  }

  Set<String> loadPending() => _readRaw();

  void request(String base) {
    final set = _readRaw()..add(base.toUpperCase());
    _storage.writeJson(_storage.addCopyRequestsFile, set.toList()..sort());
  }

  void clear(String base) {
    final set = _readRaw();
    if (set.remove(base.toUpperCase())) {
      _storage.writeJson(_storage.addCopyRequestsFile, set.toList()..sort());
    }
  }
}
