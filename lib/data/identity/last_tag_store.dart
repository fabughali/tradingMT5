import '../../core/core_storage.dart';

/// "Finish this one, then stop" flag per base (2026-09-29, per the user's
/// Dashboard-table spec: "another toggle switch for Last. once it is
/// toggle on, then current trade is the last trade, once this trade is
/// closed/terminated. pair will not managed auto."). Purely a PENDING
/// marker on a still-running trade - the actual "stop auto-managing"
/// outcome is [RetiredStore], which [EngineService] adds the base to once
/// a Last-tagged trade closes (by any path). Toggling this off just clears
/// the pending flag; it never un-retires a base already retired. Mirrors
/// [RetiredStore]'s own shape exactly.
class LastTagStore {
  LastTagStore(this._storage);

  final CoreStorage _storage;

  Set<String>? _lastGood;

  Set<String> _readRaw() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.lastTaggedPairsFile);
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CRITICAL] last-tagged-pairs.json exists but failed to parse ($e) '
        '- keeping the last known-good set instead of treating this as '
        '"nothing is Last-tagged".',
      );
      return _lastGood ?? {};
    }
    final parsed = arr
        .map((e) => e.toString().toUpperCase())
        .where((e) => e.isNotEmpty)
        .toSet();
    _lastGood = parsed;
    return parsed;
  }

  Set<String> _write(Iterable<String> bases) {
    final clean = bases
        .map((b) => b.toUpperCase())
        .where((b) => b.isNotEmpty)
        .toSet();
    final sorted = clean.toList()..sort();
    _storage.writeJson(_storage.lastTaggedPairsFile, sorted);
    _lastGood = clean;
    return clean;
  }

  Set<String> loadLastTagged() => _readRaw();

  bool isLastTagged(String base) => loadLastTagged().contains(base.toUpperCase());

  void setLastTagged(String base, bool on) {
    final set = loadLastTagged();
    final changed = on ? set.add(base.toUpperCase()) : set.remove(base.toUpperCase());
    if (changed) _write(set);
  }
}
