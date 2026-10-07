/// Persisted risk-manager state (logs/state.json). Day boundaries are UTC
/// midnight, deterministic regardless of machine timezone — tradingPionex's
/// original engine reset counters at local midnight despite its own docs
/// claiming UTC; don't regress that here.
class RiskState {
  RiskState({
    required this.dayStartUtcMs,
    this.dayPnlPct = 0,
    Map<String, int>? openPositions,
    this.cooldownUntilMs = 0,
  }) : openPositions = openPositions ?? {};

  int dayStartUtcMs;
  double dayPnlPct;
  final Map<String, int> openPositions;
  int cooldownUntilMs;

  int get totalOpenPositions => openPositions.values.fold(0, (a, b) => a + b);

  static int utcMidnightMs(DateTime now) => DateTime.utc(
    now.toUtc().year,
    now.toUtc().month,
    now.toUtc().day,
  ).millisecondsSinceEpoch;

  factory RiskState.freshForToday() =>
      RiskState(dayStartUtcMs: utcMidnightMs(DateTime.now()));

  factory RiskState.fromJson(Map<String, dynamic> json) => RiskState(
    dayStartUtcMs:
        (json['day_start'] as num?)?.toInt() ?? utcMidnightMs(DateTime.now()),
    dayPnlPct: (json['day_pnl'] as num?)?.toDouble() ?? 0,
    openPositions: ((json['open_positions'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(k as String, (v as num).toInt()),
    ),
    cooldownUntilMs: (json['cooldown_until'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'day_start': dayStartUtcMs,
    'day_pnl': dayPnlPct,
    'open_positions': openPositions,
    'cooldown_until': cooldownUntilMs,
  };
}
