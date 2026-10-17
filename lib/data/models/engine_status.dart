import 'power_health.dart';

/// The engine's on-disk status snapshot (`logs/status.json`), read by the
/// GUI — never written by it. Deliberately minimal for now: extend this as
/// real MT5 engine state (connection, positions, last cycle) gets built,
/// but remember tradingPionex's lesson — anything added here that's meant to
/// survive a restart needs its own load-on-startup path, not just a write.
class EngineStatus {
  const EngineStatus({
    required this.running,
    required this.connected,
    this.lastCycleAt,
    this.message,
    this.health = PowerHealthState.off,
    this.ramAvailableMb,
    this.ramTotalMb,
  });

  final bool running;
  final bool connected;
  final DateTime? lastCycleAt;
  final String? message;

  /// The Power toggle's live health state (2026-09-20) — internet/MT5/
  /// TradingView, checked in that order, re-checked every cycle while
  /// Power is on. See [PowerHealthState].
  final PowerHealthState health;

  /// System-wide available RAM in MB, refreshed every health check
  /// (2026-10-17, per the user, after a real incident: TradingView froze
  /// mid-sweep and crashed while the system was down to ~955MB free with
  /// heavy swap use - low RAM was the actual root cause of several
  /// "wrong reading" reports that day, not a logic bug). Null only if the
  /// read itself failed (e.g. /proc/meminfo unavailable) - never treated
  /// as "low" in that case, same as every other null-means-unknown field
  /// here.
  final int? ramAvailableMb;

  /// System-wide total RAM in MB, read alongside [ramAvailableMb] purely
  /// to compute [ramUsedPercent] for display (2026-10-17, per the user -
  /// the Dashboard should show usage %, not just a free-MB count).
  final int? ramTotalMb;

  /// Below this, [ramOk] is false and the Dashboard shows the RAM light
  /// red - chosen from the real incident: TradingView was already
  /// unstable well above 955MB free, so 1500MB gives a genuine margin
  /// before things start failing, not a last-second warning.
  static const int ramLowThresholdMb = 1500;

  bool get ramOk => ramAvailableMb == null || ramAvailableMb! >= ramLowThresholdMb;

  /// Percentage of total RAM currently in use (0-100), or null if either
  /// reading is unavailable or [ramTotalMb] is zero.
  int? get ramUsedPercent {
    if (ramAvailableMb == null || ramTotalMb == null || ramTotalMb == 0) return null;
    return (((ramTotalMb! - ramAvailableMb!) / ramTotalMb!) * 100).round();
  }

  factory EngineStatus.fromJson(Map<String, dynamic> json) => EngineStatus(
    running: json['running'] as bool? ?? false,
    connected: json['connected'] as bool? ?? false,
    lastCycleAt: json['last_cycle_at'] != null
        ? DateTime.tryParse(json['last_cycle_at'] as String)
        : null,
    message: json['message'] as String?,
    health: PowerHealthState.fromWire(json['health'] as String?),
    ramAvailableMb: (json['ram_available_mb'] as num?)?.toInt(),
    ramTotalMb: (json['ram_total_mb'] as num?)?.toInt(),
  );

  Map<String, dynamic> toJson() => {
    'running': running,
    'connected': connected,
    if (lastCycleAt != null) 'last_cycle_at': lastCycleAt!.toIso8601String(),
    if (message != null) 'message': message,
    'health': health.wireValue,
    if (ramAvailableMb != null) 'ram_available_mb': ramAvailableMb,
    if (ramTotalMb != null) 'ram_total_mb': ramTotalMb,
  };

  static const disconnected = EngineStatus(
    running: false,
    connected: false,
    health: PowerHealthState.off,
  );
}
