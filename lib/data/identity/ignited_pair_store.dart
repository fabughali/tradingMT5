import '../../core/core_storage.dart';

/// "Ignite" a currently-waiting pair so its NEXT real fresh-open signal
/// bypasses the risk gate's margin-level checks (2026-10-17, per the user:
/// "add a thunder icon per each pair .. where user can ignite any waiting
/// pair. once user ignite any pair, it will be filled and gave the
/// priority. margin level has nothing to do with manual ignited pair. so if
/// margin level is less than rule, still this ignited pair will run once it
/// is triggered."). One-shot, per the user's own follow-up confirmation:
/// ignite does NOT force an immediate open - the pair still waits for its
/// own genuine signal, only the margin-level gate is waived for that one
/// resulting open. [EngineService] clears the flag the moment it actually
/// opens (or the attempt is otherwise abandoned), so a stale ignite can
/// never silently keep bypassing margin level forever. Mirrors
/// [PausedPairStore]'s own shape exactly (a persisted `Set<String>` of
/// uppercase bases).
class IgnitedPairStore {
  IgnitedPairStore(this._storage);

  final CoreStorage _storage;

  Set<String>? _lastGood;

  Set<String> _readRaw() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.ignitedPairsFile);
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CRITICAL] ignited-pairs.json exists but failed to parse ($e) - '
        'keeping the last known-good set rather than treating this as '
        '"nothing is ignited".',
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
    _storage.writeJson(_storage.ignitedPairsFile, sorted);
    _lastGood = clean;
    return clean;
  }

  Set<String> loadIgnited() => _readRaw();

  bool isIgnited(String base) => loadIgnited().contains(base.toUpperCase());

  void ignite(String base) {
    final set = loadIgnited();
    if (set.add(base.toUpperCase())) _write(set);
  }

  /// Called once the ignited pair's own signal actually opens a trade (or
  /// the attempt is abandoned) - clears the one-shot flag so it never
  /// silently keeps bypassing margin level on a later, unrelated signal.
  void consume(String base) {
    final set = loadIgnited();
    if (set.remove(base.toUpperCase())) _write(set);
  }
}
