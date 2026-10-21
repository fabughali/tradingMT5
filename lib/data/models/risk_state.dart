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

  /// The new UTC day's state, carrying over everything that is NOT a
  /// per-day counter (2026-10-21, v1.6.33, found live): the old rollover
  /// used [freshForToday], which also wiped [openPositions] - for up to a
  /// full cycle (~20 min) after UTC midnight the margin-tiered position cap
  /// saw "0 open" with ~13 really open, and SHIB + TRX opened past a cap
  /// of 6. Only the daily P&L restarts; open positions and any active
  /// cooldown are facts about NOW, not about the day.
  RiskState rolledOverToToday() => RiskState(
    dayStartUtcMs: utcMidnightMs(DateTime.now()),
    openPositions: Map<String, int>.from(openPositions),
    cooldownUntilMs: cooldownUntilMs,
  );

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
