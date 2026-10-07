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
  });

  final bool running;
  final bool connected;
  final DateTime? lastCycleAt;
  final String? message;

  /// The Power toggle's live health state (2026-09-20) — internet/MT5/
  /// TradingView, checked in that order, re-checked every cycle while
  /// Power is on. See [PowerHealthState].
  final PowerHealthState health;

  factory EngineStatus.fromJson(Map<String, dynamic> json) => EngineStatus(
    running: json['running'] as bool? ?? false,
    connected: json['connected'] as bool? ?? false,
    lastCycleAt: json['last_cycle_at'] != null
        ? DateTime.tryParse(json['last_cycle_at'] as String)
        : null,
    message: json['message'] as String?,
    health: PowerHealthState.fromWire(json['health'] as String?),
  );

  Map<String, dynamic> toJson() => {
    'running': running,
    'connected': connected,
    if (lastCycleAt != null) 'last_cycle_at': lastCycleAt!.toIso8601String(),
    if (message != null) 'message': message,
    'health': health.wireValue,
  };

  static const disconnected = EngineStatus(
    running: false,
    connected: false,
    health: PowerHealthState.off,
  );
}
