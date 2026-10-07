import '../../core/core_storage.dart';

/// The open-side signal snapshot (which worm_9_26 tag + bar time confirmed
/// the entry) for each currently-open app position, keyed by ticket —
/// recorded the moment a position opens, read back once (and forgotten)
/// when it eventually closes, to fill [BotHistoryEntry]'s open_signal_*
/// fields. Mirrors tradingPionex's own `EntrySignalStore` pattern
/// (2026-09-27, per the user's history-record request; dropped `zone`/
/// `rsiValue` 2026-09-29 along with the RSI-zone decision model itself).
///
/// [updateTag]/[updateTime] (added 2026-09-29, per the user's Dashboard-
/// table spec: "update if there is Buy signal with LL or sell signal with
/// HH") record the LATEST same-direction confirming tag seen while this
/// position stays open - i.e. exactly the "ignore, already correct
/// direction" case in `EngineService._checkOneSymbol`. Both null until the
/// first such confirmation arrives; overwritten (not accumulated) on every
/// later one, so they always reflect the MOST RECENT confirmation, not a
/// history of all of them.
class EntrySignalSnapshot {
  const EntrySignalSnapshot({
    required this.tag,
    required this.barTime,
    this.updateTag,
    this.updateTime,
  });

  final String tag;
  final int barTime;
  final String? updateTag;
  final int? updateTime;

  EntrySignalSnapshot withUpdate(String tag, int time) => EntrySignalSnapshot(
    tag: this.tag,
    barTime: barTime,
    updateTag: tag,
    updateTime: time,
  );

  Map<String, dynamic> toJson() => {
    'tag': tag,
    'bar_time': barTime,
    if (updateTag != null) 'update_tag': updateTag,
    if (updateTime != null) 'update_time': updateTime,
  };

  factory EntrySignalSnapshot.fromJson(Map<String, dynamic> json) => EntrySignalSnapshot(
    tag: json['tag'] as String,
    barTime: (json['bar_time'] as num).toInt(),
    updateTag: json['update_tag'] as String?,
    updateTime: (json['update_time'] as num?)?.toInt(),
  );
}

class EntrySignalStore {
  EntrySignalStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Map<int, EntrySignalSnapshot> _byTicket = {};

  void load() {
    final raw = _storage.readJsonObject(_storage.entrySignalFile) ?? const {};
    _byTicket.clear();
    raw.forEach((id, value) {
      final ticket = int.tryParse(id);
      if (ticket != null && value is Map<String, dynamic>) {
        try {
          _byTicket[ticket] = EntrySignalSnapshot.fromJson(value);
        } catch (_) {
          // Skip a corrupt entry rather than failing the whole load.
        }
      }
    });
  }

  void _persist() => _storage.writeJson(
    _storage.entrySignalFile,
    _byTicket.map((k, v) => MapEntry(k.toString(), v.toJson())),
  );

  void record(int ticket, EntrySignalSnapshot snapshot) {
    _byTicket[ticket] = snapshot;
    _persist();
  }

  /// Overwrites the update-signal fields on an existing snapshot - a no-op
  /// if [ticket] has no snapshot at all (shouldn't happen: a position with
  /// no entry snapshot has no ticket to update against in the first
  /// place).
  void recordUpdate(int ticket, String tag, int time) {
    final existing = _byTicket[ticket];
    if (existing == null) return;
    _byTicket[ticket] = existing.withUpdate(tag, time);
    _persist();
  }

  /// Read-only lookup - unlike [takeFor], does NOT remove the snapshot.
  /// Used mid-trade (e.g. to check the original start tag before deciding
  /// whether a new confirming tag counts as the Dashboard table's Update
  /// Signal) where the position is still open and the snapshot is still
  /// needed later at close time.
  EntrySignalSnapshot? peek(int ticket) => _byTicket[ticket];

  /// Reads and removes the snapshot in one step — a history entry only
  /// ever needs it once, at close time.
  EntrySignalSnapshot? takeFor(int ticket) {
    final snapshot = _byTicket.remove(ticket);
    if (snapshot != null) _persist();
    return snapshot;
  }

  void forget(int ticket) {
    if (_byTicket.remove(ticket) != null) _persist();
  }
}
