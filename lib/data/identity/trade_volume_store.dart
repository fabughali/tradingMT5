import '../../core/core_storage.dart';

/// Per (category, tvSymbol) manual trade-size override + step-down retry
/// state — see [CoreStorage.tradeVolumeFile]. Keyed by
/// `${category.wireValue}|$tvSymbol`, same convention as
/// [PendingSignalStore]. Three fields per key:
///
/// - `desired`: the volume the user wants for the NEXT open of this pair
///   (set via the Dashboard's +/- buttons). A currently-running trade's own
///   size is untouched — this only takes effect once the pair closes and
///   reopens, fresh or recycled.
/// - `attempt`: the volume actually being tried right now, when the broker
///   rejected [desired] for a volume/margin reason and the engine had to
///   step down. Null means "no step-down in progress, try desired as-is."
///   Cleared on a successful open or whenever [setDesired] picks a new
///   target.
/// - `last_applied`: the volume actually used by the most recent
///   successfully-opened trade for this pair/category — the step-down
///   floor (per the user: "app will keep trying up to 20 [the old volume].
///   if 20 can't go, app will keep trying on 20 not applying any more
///   decrease") and the Dashboard's strikethrough baseline.
class TradeVolumeStore {
  TradeVolumeStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() =>
      _storage.readJsonObject(_storage.tradeVolumeFile) ?? const {};

  void _write(Map<String, dynamic> map) => _storage.writeJson(_storage.tradeVolumeFile, map);

  Map<String, dynamic> _entry(String key) =>
      (_readRaw()[key] as Map<String, dynamic>?) ?? const {};

  double? desired(String key) => (_entry(key)['desired'] as num?)?.toDouble();
  double? attempt(String key) => (_entry(key)['attempt'] as num?)?.toDouble();
  double? lastApplied(String key) => (_entry(key)['last_applied'] as num?)?.toDouble();

  void setDesired(String key, double volume) {
    final map = Map<String, dynamic>.from(_readRaw());
    final e = Map<String, dynamic>.from(map[key] as Map<String, dynamic>? ?? const {});
    e['desired'] = volume;
    e.remove('attempt');
    map[key] = e;
    _write(map);
  }

  void setAttempt(String key, double volume) {
    final map = Map<String, dynamic>.from(_readRaw());
    final e = Map<String, dynamic>.from(map[key] as Map<String, dynamic>? ?? const {});
    e['attempt'] = volume;
    map[key] = e;
    _write(map);
  }

  void recordApplied(String key, double volume) {
    final map = Map<String, dynamic>.from(_readRaw());
    final e = Map<String, dynamic>.from(map[key] as Map<String, dynamic>? ?? const {});
    e['last_applied'] = volume;
    e.remove('attempt');
    map[key] = e;
    _write(map);
  }

  /// Wipes [desired]/[attempt]/[lastApplied] entirely (2026-10-06, per the
  /// user: a pair that was retired and later re-added fresh via "Start
  /// Auto Trade" should start at the broker minimum again, not silently
  /// resume whatever custom volume it had before - "volume is reset for
  /// new auto pairs"). With no entry left, [_openPosition]'s own
  /// `?? volumeMin` fallbacks take over exactly as they would for a pair
  /// that had never been traded at all.
  void clear(String key) {
    final map = Map<String, dynamic>.from(_readRaw());
    if (map.remove(key) != null) _write(map);
  }
}
