import '../../core/core_storage.dart';

/// Order tickets for a manual Multiplier "+" click's pending-order
/// fallback, tracked ONLY long enough to exempt them from the margin
/// gate's own resting-order cancellation sweep (2026-10-15, per the user:
/// "manual copies done by user: has nothing to do with margin level" -
/// confirmed live that a manual copy's pending fallback order could
/// otherwise be cancelled by [EngineService._cancelAllRestingPendingOrders]
/// within seconds of being placed, since it shares the exact same comment
/// tag as every other pending order and the sweep had no other way to
/// single it out - ticket 1660701907 on LTCUSD.lv was caught exactly this
/// way while margin sat at 92.9%). Deliberately NOT used for the automated
/// +$5 milestone path - that one fully respects the margin gate by design
/// ([EngineService._processAutoCopyMilestones] already refuses to even
/// attempt a new copy once [RiskGate.positionCapFor] hits 0), so its own
/// pending orders are left exposed to the normal sweep on purpose.
class ManualCopyPendingOrderStore {
  ManualCopyPendingOrderStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() =>
      _storage.readJsonObject(_storage.manualCopyPendingOrdersFile) ?? const {};

  void _write(Map<String, dynamic> map) =>
      _storage.writeJson(_storage.manualCopyPendingOrdersFile, map);

  /// Marks [orderTicket] as a manual copy's own pending order, right after
  /// it's placed.
  void markPending(int orderTicket) {
    final map = Map<String, dynamic>.from(_readRaw());
    map['$orderTicket'] = DateTime.now().toUtc().toIso8601String();
    _write(map);
  }

  bool isPending(int orderTicket) => _readRaw().containsKey('$orderTicket');

  /// Called once the order is resolved one way or another (triggered into
  /// a position, or confirmed rejected/deleted by MT5) - it no longer
  /// needs protecting. Deliberately NOT called on an ambiguous "still
  /// resting after the poll window" timeout - that one stays exempted
  /// until [pruneOlderThan] eventually drops it or it resolves on a later
  /// cycle.
  void clear(int orderTicket) {
    final map = Map<String, dynamic>.from(_readRaw());
    if (map.remove('$orderTicket') != null) _write(map);
  }

  /// Drops any entry older than [maxAge] - a manual copy's pending order
  /// always resolves (triggers, is rejected, or is abandoned) within
  /// minutes at most, so anything older than that is stale bookkeeping for
  /// an order that's long gone, not a real exemption still in use. Called
  /// once per margin-gate sweep so this file never grows unbounded.
  void pruneOlderThan(Duration maxAge) {
    final raw = _readRaw();
    final cutoff = DateTime.now().toUtc().subtract(maxAge);
    final map = Map<String, dynamic>.from(raw);
    final before = map.length;
    map.removeWhere((k, v) {
      final at = DateTime.tryParse(v as String? ?? '');
      return at == null || at.isBefore(cutoff);
    });
    if (map.length != before) _write(map);
  }
}
