import '../../core/core_storage.dart';

/// Remembers which app-opened positions had the 60/40 range-widen
/// adjustment (see data/technique/liquidation.dart) applied at open time —
/// MT5's own position data has no such field, so this is purely the app's
/// own record of a decision it made once, at open. Manual positions (never
/// opened by the app) are never in this set — "widen applied" doesn't apply
/// to them, they always read as neutral. Persisted to
/// logs/widen-applied-bots.json, same shape/pattern as [OpenPositionStore].
class WidenAppliedStore {
  WidenAppliedStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Set<int> _tickets = {};

  Set<int> load() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.widenAppliedBotsFile);
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CRITICAL] widen-applied-bots.json exists but failed to parse ($e) - '
        'keeping the last known-good in-memory set instead of resetting it.',
      );
      return _tickets;
    }
    _tickets.clear();
    for (final ticket in arr) {
      if (ticket == null) continue;
      final parsed = ticket is int ? ticket : int.tryParse(ticket.toString());
      if (parsed != null) _tickets.add(parsed);
    }
    return _tickets;
  }

  void _persist() =>
      _storage.writeJson(_storage.widenAppliedBotsFile, _tickets.toList());

  bool isWidenApplied(int? positionTicket) =>
      positionTicket != null && _tickets.contains(positionTicket);

  bool markWidened(int? positionTicket) {
    if (positionTicket == null) return false;
    _tickets.add(positionTicket);
    _persist();
    return true;
  }

  bool forget(int? positionTicket) {
    if (positionTicket == null) return false;
    final removed = _tickets.remove(positionTicket);
    if (removed) _persist();
    return removed;
  }
}
