import '../../core/core_storage.dart';

/// Per-ticket "highest SL ratchet rung already locked" state (2026-10-13,
/// per the user). Keyed by MT5 position ticket, not by base/symbol, since a
/// recycled/reopened trade on the same pair is a genuinely new position
/// that must start the ladder fresh from zero — mirrors
/// tradingPionex's own `TpSlRatchetStore`, keyed by that app's equivalent
/// per-trade identity (`buOrderId`).
///
/// Only ever records a HIGHER threshold than whatever's already stored —
/// see [EngineService]'s own ratchet-sweep logic for the "only ever
/// tightens, never loosens" enforcement (this store itself doesn't refuse a
/// lower write, the caller is responsible for only ever calling
/// [recordLock] with a threshold it already confirmed is higher).
class SlRatchetStore {
  SlRatchetStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() =>
      _storage.readJsonObject(_storage.slRatchetStateFile) ?? const {};

  void _write(Map<String, dynamic> map) =>
      _storage.writeJson(_storage.slRatchetStateFile, map);

  /// Highest rung (5/10/15/.../25/...) already locked for [ticket], or null
  /// if this position has never crossed the first rung.
  int? highestThreshold(int ticket) {
    final entry = _readRaw()['$ticket'] as Map<String, dynamic>?;
    return (entry?['threshold'] as num?)?.toInt();
  }

  void recordLock(int ticket, int threshold) {
    final map = Map<String, dynamic>.from(_readRaw());
    map['$ticket'] = {
      'threshold': threshold,
      'locked_at': DateTime.now().toUtc().toIso8601String(),
    };
    _write(map);
  }

  /// Drops state for any ticket not in [stillOpenTickets] — keeps this file
  /// from growing forever with closed positions' old entries. Called once
  /// per sweep with the live open-positions ticket set.
  void pruneClosed(Set<int> stillOpenTickets) {
    final raw = _readRaw();
    final map = Map<String, dynamic>.from(raw);
    final before = map.length;
    map.removeWhere((k, _) => !stillOpenTickets.contains(int.tryParse(k)));
    if (map.length != before) _write(map);
  }
}
