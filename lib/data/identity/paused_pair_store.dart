import '../../core/core_storage.dart';

/// "This is still an auto pair, but the engine must not act on it" flag per
/// base (2026-10-09, per the user: "once user off this toggle then this
/// pair stays in auto but paused ... paused pair is still an auto pair but
/// the current status is paused so engine will not take any action to this
/// paired pair unless it is unpaused. if it is currently waiting, it stays
/// waiting. if it is currently running, it stays running once it is
/// paused"). Replaces the former behavior of the Dashboard's per-row Auto
/// toggle, which used to REMOVE the base from [AutoManagedStore] entirely
/// (unlisting it from the table) - this store instead sits ALONGSIDE
/// [AutoManagedStore]: a base stays in `auto-managed-bases.json` (still
/// genuinely auto-managed) and also, independently, in here (paused right
/// now). [EngineService._runCycle]'s main loop skips any paused base
/// exactly like it already skips a retired one, leaving whatever state it
/// was in (running or waiting) completely untouched - no close, no open, no
/// flip, nothing. Mirrors [LastTagStore]'s own shape exactly (a persisted
/// `Set<String>` of uppercase bases).
class PausedPairStore {
  PausedPairStore(this._storage);

  final CoreStorage _storage;

  Set<String>? _lastGood;

  Set<String> _readRaw() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.pausedPairsFile);
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CRITICAL] paused-pairs.json exists but failed to parse ($e) - '
        'keeping the last known-good set instead of treating this as '
        '"nothing is paused" (which would silently resume live management '
        'of a pair the user deliberately paused).',
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
    _storage.writeJson(_storage.pausedPairsFile, sorted);
    _lastGood = clean;
    return clean;
  }

  Set<String> loadPaused() => _readRaw();

  bool isPaused(String base) => loadPaused().contains(base.toUpperCase());

  void setPaused(String base, bool on) {
    final set = loadPaused();
    final changed = on ? set.add(base.toUpperCase()) : set.remove(base.toUpperCase());
    if (changed) _write(set);
  }
}
