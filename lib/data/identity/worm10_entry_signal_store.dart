import '../../core/core_storage.dart';
import '../engine/worm10_decision.dart';

/// The open-side event snapshot for each currently-open position under the
/// third decision technique (worm_10_26 + spy_9_26) - same role as
/// [EntrySignalStore], just a [Worm10EventKind] wire string instead of a
/// 4-way HH/LL/BUY/SELL tag (2026-10-14, per the user's third decision
/// technique). [updateKind]/[updateTime] record the latest SAME-direction
/// re-confirming event (the Dashboard's Update column) while this position
/// stays open - overwritten, not accumulated, same as [EntrySignalSnapshot].
class Worm10EntrySignalSnapshot {
  const Worm10EntrySignalSnapshot({
    required this.kind,
    required this.barTime,
    this.updateKind,
    this.updateTime,
  });

  final Worm10EventKind kind;
  final int barTime;
  final Worm10EventKind? updateKind;
  final int? updateTime;

  Worm10EntrySignalSnapshot withUpdate(Worm10EventKind kind, int time) => Worm10EntrySignalSnapshot(
    kind: this.kind,
    barTime: barTime,
    updateKind: kind,
    updateTime: time,
  );

  Map<String, dynamic> toJson() => {
    'kind': worm10EventKindToWire(kind),
    'bar_time': barTime,
    if (updateKind != null) 'update_kind': worm10EventKindToWire(updateKind!),
    if (updateTime != null) 'update_time': updateTime,
  };

  factory Worm10EntrySignalSnapshot.fromJson(Map<String, dynamic> json) => Worm10EntrySignalSnapshot(
    kind: worm10EventKindFromWire(json['kind'] as String),
    barTime: (json['bar_time'] as num).toInt(),
    updateKind: json['update_kind'] != null ? worm10EventKindFromWire(json['update_kind'] as String) : null,
    updateTime: (json['update_time'] as num?)?.toInt(),
  );
}

class Worm10EntrySignalStore {
  Worm10EntrySignalStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Map<int, Worm10EntrySignalSnapshot> _byTicket = {};

  void load() {
    final raw = _storage.readJsonObject(_storage.worm10EntrySignalFile) ?? const {};
    _byTicket.clear();
    raw.forEach((id, value) {
      final ticket = int.tryParse(id);
      if (ticket != null && value is Map<String, dynamic>) {
        try {
          _byTicket[ticket] = Worm10EntrySignalSnapshot.fromJson(value);
        } catch (_) {
          // Skip a corrupt entry rather than failing the whole load.
        }
      }
    });
  }

  void _persist() => _storage.writeJson(
    _storage.worm10EntrySignalFile,
    _byTicket.map((k, v) => MapEntry(k.toString(), v.toJson())),
  );

  void record(int ticket, Worm10EntrySignalSnapshot snapshot) {
    _byTicket[ticket] = snapshot;
    _persist();
  }

  void recordUpdate(int ticket, Worm10EventKind kind, int time) {
    final existing = _byTicket[ticket];
    if (existing == null) return;
    _byTicket[ticket] = existing.withUpdate(kind, time);
    _persist();
  }

  Worm10EntrySignalSnapshot? peek(int ticket) => _byTicket[ticket];

  Worm10EntrySignalSnapshot? takeFor(int ticket) {
    final snapshot = _byTicket.remove(ticket);
    if (snapshot != null) _persist();
    return snapshot;
  }

  void forget(int ticket) {
    if (_byTicket.remove(ticket) != null) _persist();
  }
}
