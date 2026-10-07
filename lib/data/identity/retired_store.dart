import '../../core/core_storage.dart';

/// Persistent "never auto-recreate this pair" store — ported 1:1 from
/// lib/retired.js. Backs the /last-equivalent control: the user picks running
/// AUTO grids that should finish their current run and then never be
/// re-created automatically. An explicit selection (the pending-create file)
/// or an explicit unretire can still re-enable a retired pair.
/// Persisted to logs/retired-pairs.json as uppercase BASE names (e.g. "ETH").
class RetiredStore {
  RetiredStore(this._storage);

  final CoreStorage _storage;

  /// The last successfully-parsed read, kept so a corrupt/unparseable file
  /// doesn't collapse into "nothing is retired" - a pair the operator
  /// explicitly retired (finish naturally, never auto-recreate) would
  /// otherwise become eligible for auto-trading again on the very next
  /// cycle, silently undoing an explicit safety decision. Null only before
  /// the first-ever successful read.
  Set<String>? _lastGood;

  Set<String> _readRaw() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.retiredPairsFile);
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CRITICAL] retired-pairs.json exists but failed to parse ($e) - '
        'keeping the last known-good retired set instead of treating this '
        'as "nothing is retired".',
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

  Set<String> writeRetiredBases(Iterable<String> bases) {
    final clean = bases
        .map((b) => b.toUpperCase())
        .where((b) => b.isNotEmpty)
        .toSet();
    final sorted = clean.toList()..sort();
    _storage.writeJson(_storage.retiredPairsFile, sorted);
    _lastGood = clean;
    return clean;
  }

  Set<String> loadRetiredBases() => _readRaw();

  bool isRetiredBase(String base) =>
      loadRetiredBases().contains(base.toUpperCase());

  Set<String> addRetiredBases(Iterable<String> bases) {
    final set = loadRetiredBases();
    set.addAll(bases.map((b) => b.toUpperCase()));
    return writeRetiredBases(set);
  }

  Set<String> removeRetiredBases(Iterable<String> bases) {
    final set = loadRetiredBases();
    for (final b in bases) {
      set.remove(b.toUpperCase());
    }
    return writeRetiredBases(set);
  }
}
