import '../../core/core_storage.dart';

/// Which currently-tracked ticket numbers are Multiplier copies (manual
/// "+" or automated +$5 milestone), as opposed to the PARENT/ORIGINAL
/// trade (2026-10-16, per the user: "once copied trade is terminated (any
/// type of termination) it is not repeated == no auto listed anymore ...
/// that's applied for copied only not for parent/original"). Confirmed
/// live as a real bug: [EngineService._reconcileClosedPositions] treats
/// EVERY closed ticket as if it were the pair's own main position - a
/// copy's own tight -$1 SL hitting twice was silently counted toward the
/// "2 baseline-SL strikes blocks this pair until signal flips" mechanism,
/// and ANY copy closing while "Last" was toggled ON retired the whole
/// base from auto-management - both meant for the ORIGINAL's own
/// lifecycle only. Marked the moment
/// [EngineService._openCopyPosition] confirms a real position; forgotten
/// alongside every other per-ticket store once that ticket closes.
class CopyPositionStore {
  CopyPositionStore(this._storage);

  final CoreStorage _storage;

  Set<int> _readRaw() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.copyPositionsFile);
    } catch (_) {
      return {};
    }
    return arr.map((e) => int.tryParse(e.toString())).whereType<int>().toSet();
  }

  bool isCopy(int ticket) => _readRaw().contains(ticket);

  void markCopy(int ticket) {
    final set = _readRaw()..add(ticket);
    _storage.writeJson(_storage.copyPositionsFile, set.toList()..sort());
  }

  void forget(int ticket) {
    final set = _readRaw();
    if (set.remove(ticket)) {
      _storage.writeJson(_storage.copyPositionsFile, set.toList()..sort());
    }
  }
}
