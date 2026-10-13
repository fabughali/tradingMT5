import '../../core/core_storage.dart';

/// Tracks consecutive baseline-stop-loss terminations per base, so a pair
/// stops auto-reopening after repeatedly failing at the same -10%/-$10
/// baseline on the same signal (2026-10-13, per the user: "if pair beent
/// terminated two times in same signal, then this pair will not start
/// over again until signal is flipped"). Keyed by base (tvSymbol), not by
/// ticket — unlike [SlRatchetStore], this deliberately tracks a streak
/// ACROSS multiple trades on the same pair, not state for one.
///
/// A "baseline stop" only ever means a close via the flat -10%/-$10 SL
/// [EngineService._baselineStopLoss] sets at ignition, with the ratchet
/// never having tightened it first (see the call site's own doc comment
/// for how that's told apart from a ratchet-protected profit-lock close).
/// Any OTHER close (take-profit, a ratchet-protected SL, a genuine
/// opposite-signal close, a manual close) clears the streak outright —
/// only a run of CONSECUTIVE baseline-SL failures on the exact same
/// direction counts toward the block.
class BaselineStopStrikeStore {
  BaselineStopStrikeStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() =>
      _storage.readJsonObject(_storage.baselineStopStrikesFile) ?? const {};

  void _write(Map<String, dynamic> map) =>
      _storage.writeJson(_storage.baselineStopStrikesFile, map);

  int strikes(String base) {
    final entry = _readRaw()[base.toUpperCase()] as Map<String, dynamic>?;
    return (entry?['strikes'] as num?)?.toInt() ?? 0;
  }

  String? lastDirection(String base) {
    final entry = _readRaw()[base.toUpperCase()] as Map<String, dynamic>?;
    return entry?['direction'] as String?;
  }

  /// True once [direction] ('long'/'short') has hit the baseline SL twice
  /// in a row on this base with nothing breaking the streak in between -
  /// the single check [EngineService._openPosition] gates every open on.
  bool isBlocked(String base, String direction) =>
      lastDirection(base) == direction && strikes(base) >= 2;

  /// Called when a position closes via a genuine baseline SL hit (see this
  /// class's own doc comment for what qualifies). Increments if [direction]
  /// matches the last recorded one (same signal, still failing); starts a
  /// fresh count at 1 if it's the opposite direction (the signal already
  /// flipped since the last failure, so this is a new streak, not a
  /// continuation).
  void recordBaselineStop(String base, String direction) {
    final map = Map<String, dynamic>.from(_readRaw());
    final key = base.toUpperCase();
    final existing = map[key] as Map<String, dynamic>?;
    final sameDirection = existing != null && existing['direction'] == direction;
    final newStrikes = sameDirection ? ((existing['strikes'] as num?)?.toInt() ?? 0) + 1 : 1;
    map[key] = {'direction': direction, 'strikes': newStrikes};
    _write(map);
  }

  /// Called on any close that ISN'T a qualifying baseline-SL hit (a win,
  /// a ratchet-protected close, a manual/opposite-signal close) - breaks
  /// whatever streak was building, if any.
  void clear(String base) {
    final map = Map<String, dynamic>.from(_readRaw());
    if (map.remove(base.toUpperCase()) != null) _write(map);
  }
}
