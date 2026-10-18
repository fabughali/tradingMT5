import '../../core/core_storage.dart';

/// Pairs the user starred via a waiting card's star icon (2026-10-18, per
/// the user: "add a star icon for those waiting/unfilled cards where once
/// this icon is clicked, app will give those pairs priority in filling
/// once margin is okay. now: app choosing to fill pairs randomly"). Unlike
/// [IgnitedPairStore], this is a STANDING preference the user toggles on
/// and off, not a one-shot flag the engine consumes - confirmed with the
/// user: it never bypasses the margin gate, it only changes the ORDER the
/// engine's per-cycle loop checks waiting pairs in, so a starred pair that
/// genuinely still has insufficient margin still waits like any other.
/// Mirrors [IgnitedPairStore]'s own persisted-`Set<String>` shape, just
/// without a `consume()` - starring stays on until the user unstars it.
class FavoritePairStore {
  FavoritePairStore(this._storage);

  final CoreStorage _storage;

  Set<String>? _lastGood;

  Set<String> _readRaw() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.favoritePairsFile);
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CRITICAL] favorite-pairs.json exists but failed to parse ($e) - '
        'keeping the last known-good set rather than treating this as '
        '"nothing is favorited".',
      );
      return _lastGood ?? {};
    }
    final parsed = arr.map((e) => e.toString().toUpperCase()).where((e) => e.isNotEmpty).toSet();
    _lastGood = parsed;
    return parsed;
  }

  Set<String> _write(Iterable<String> bases) {
    final clean = bases.map((b) => b.toUpperCase()).where((b) => b.isNotEmpty).toSet();
    final sorted = clean.toList()..sort();
    _storage.writeJson(_storage.favoritePairsFile, sorted);
    _lastGood = clean;
    return clean;
  }

  Set<String> loadFavorites() => _readRaw();

  bool isFavorite(String base) => loadFavorites().contains(base.toUpperCase());

  void toggleFavorite(String base, bool favorite) {
    final set = loadFavorites();
    final changed = favorite ? set.add(base.toUpperCase()) : set.remove(base.toUpperCase());
    if (changed) _write(set);
  }
}
