import '../../core/core_storage.dart';

/// Per-ticket "how many +$5 auto-copy milestones already consumed" state
/// (2026-10-15, per the user: "auto copy... applied each time P&L has +5$
/// more"). Keyed by the ORIGINAL position's own ticket (never a copy's -
/// milestones are tracked against the parent, not any individual copy),
/// same per-ticket-not-per-symbol reasoning as [SlRatchetStore]: a
/// recycled/reopened trade on the same pair is a genuinely new position
/// that starts the ladder fresh from zero.
class AutoCopyMilestoneStore {
  AutoCopyMilestoneStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() =>
      _storage.readJsonObject(_storage.autoCopyMilestonesFile) ?? const {};

  void _write(Map<String, dynamic> map) =>
      _storage.writeJson(_storage.autoCopyMilestonesFile, map);

  /// How many $5 milestones have already triggered a copy for [ticket] -
  /// 0 if none yet.
  int get(int ticket) => (_readRaw()['$ticket'] as num?)?.toInt() ?? 0;

  void set(int ticket, int milestoneCount) {
    final map = Map<String, dynamic>.from(_readRaw());
    map['$ticket'] = milestoneCount;
    _write(map);
  }

  /// Drops state for any ticket not in [stillOpenTickets] - same
  /// never-grow-forever reasoning as [SlRatchetStore.pruneClosed].
  void pruneClosed(Set<int> stillOpenTickets) {
    final raw = _readRaw();
    final map = Map<String, dynamic>.from(raw);
    final before = map.length;
    map.removeWhere((k, _) => !stillOpenTickets.contains(int.tryParse(k)));
    if (map.length != before) _write(map);
  }
}
