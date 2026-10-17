/// One simulated trade from the technique backtester (2026-10-17, per the
/// user: "a reverse calculation... a table of list of rows... each long
/// and short trades with its indications and time stamp open (HH/LL)
/// update if any... Close A... Close b (always confirmed since the tag
/// signals are applied on previous days)"). Mirrors the live Dashboard's
/// own Open/Update/Close A/Close B shape, but every field here is already
/// fully resolved - there's no "waiting" state in a backtest.
class BacktestRow {
  const BacktestRow({
    required this.direction,
    required this.openTag,
    required this.openAt,
    this.updateTag,
    this.updateAt,
    required this.closeTag,
    required this.closeAt,
    required this.entryPrice,
    required this.exitPrice,
    required this.exitReason,
    required this.profitUsd,
    required this.profitPercent,
    required this.stillRunning,
  });

  /// 'buy' or 'sell'.
  final String direction;

  /// The 4-way display label (HH/LL/Buy/Sell) - same mapping
  /// [worm10EventKindDisplayLabel] already uses live.
  final String openTag;
  final int openAt;

  /// The latest SAME-direction confirming tag while this trade was open,
  /// if any - same concept as the Dashboard's own Update column.
  final String? updateTag;
  final int? updateAt;

  /// Close A - the tag/time of whatever actually ended this trade: the
  /// opposite/flip signal that triggered the close, OR (if price hit it
  /// first) a synthetic 'TP'/'SL' label. Close B is deliberately NOT a
  /// separate field here - per the user, a historical read has nothing
  /// left to wait on, so it's always shown as "confirmed" directly against
  /// this same tag/time in the UI, not tracked as its own pending state.
  final String closeTag;
  final int closeAt;

  final double entryPrice;
  final double exitPrice;

  /// 'take_profit' | 'stop_loss' | 'signal_close' | 'still_running'.
  final String exitReason;

  /// Real $ P&L at the run's own simulated volume ([BacktestResult.volume])
  /// with the pair's own real contract size - (exitPrice - entryPrice) *
  /// contractSize * volume, sign-adjusted for direction.
  final double profitUsd;

  /// [profitUsd] as a percentage of the investment value the user entered.
  final double profitPercent;

  /// True for the one trade (at most) still open at "now" - [closeTag]/
  /// [closeAt]/[exitPrice]/[exitReason] describe its CURRENT unrealized
  /// state as of the last bar read, not a genuine close.
  final bool stillRunning;

  Map<String, dynamic> toJson() => {
    'direction': direction,
    'open_tag': openTag,
    'open_at': openAt,
    if (updateTag != null) 'update_tag': updateTag,
    if (updateAt != null) 'update_at': updateAt,
    'close_tag': closeTag,
    'close_at': closeAt,
    'entry_price': entryPrice,
    'exit_price': exitPrice,
    'exit_reason': exitReason,
    'profit_usd': profitUsd,
    'profit_percent': profitPercent,
    'still_running': stillRunning,
  };

  factory BacktestRow.fromJson(Map<String, dynamic> json) => BacktestRow(
    direction: json['direction'] as String,
    openTag: json['open_tag'] as String,
    openAt: (json['open_at'] as num).toInt(),
    updateTag: json['update_tag'] as String?,
    updateAt: (json['update_at'] as num?)?.toInt(),
    closeTag: json['close_tag'] as String,
    closeAt: (json['close_at'] as num).toInt(),
    entryPrice: (json['entry_price'] as num).toDouble(),
    exitPrice: (json['exit_price'] as num).toDouble(),
    exitReason: json['exit_reason'] as String,
    profitUsd: (json['profit_usd'] as num).toDouble(),
    profitPercent: (json['profit_percent'] as num).toDouble(),
    stillRunning: json['still_running'] as bool? ?? false,
  );
}

/// The full backtest run's result - one per request, replacing whatever
/// the previous run produced (2026-10-17, per the user's 3-input spec:
/// investment/pair/days).
class BacktestResult {
  const BacktestResult({
    required this.tvSymbol,
    required this.investment,
    required this.days,
    required this.volume,
    required this.rows,
    required this.totalProfitUsd,
    required this.totalProfitPercent,
    required this.winCount,
    required this.lossCount,
    this.error,
  });

  final String tvSymbol;
  final double investment;
  final int days;

  /// The fixed lot size this run simulated every trade at (2026-10-17, per
  /// the user's follow-up: "in back tester, make sure can adjust volum, not
  /// fixed 1" - supersedes the original spec's flat v=1). Feeds the real
  /// baseline-SL/P&L math exactly like a live trade's own volume would -
  /// see [EngineService._runBacktest]'s own doc comment.
  final double volume;
  final List<BacktestRow> rows;
  final double totalProfitUsd;
  final double totalProfitPercent;
  final int winCount;
  final int lossCount;

  /// Set only when the run failed outright (no chart data, symbol not
  /// found, etc.) - [rows] is empty in that case.
  final String? error;

  Map<String, dynamic> toJson() => {
    'tv_symbol': tvSymbol,
    'investment': investment,
    'days': days,
    'volume': volume,
    'rows': rows.map((r) => r.toJson()).toList(),
    'total_profit_usd': totalProfitUsd,
    'total_profit_percent': totalProfitPercent,
    'win_count': winCount,
    'loss_count': lossCount,
    if (error != null) 'error': error,
  };

  factory BacktestResult.fromJson(Map<String, dynamic> json) => BacktestResult(
    tvSymbol: json['tv_symbol'] as String,
    investment: (json['investment'] as num).toDouble(),
    days: (json['days'] as num).toInt(),
    volume: (json['volume'] as num?)?.toDouble() ?? 1.0,
    rows: ((json['rows'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map(BacktestRow.fromJson)
        .toList(),
    totalProfitUsd: (json['total_profit_usd'] as num?)?.toDouble() ?? 0,
    totalProfitPercent: (json['total_profit_percent'] as num?)?.toDouble() ?? 0,
    winCount: (json['win_count'] as num?)?.toInt() ?? 0,
    lossCount: (json['loss_count'] as num?)?.toInt() ?? 0,
    error: json['error'] as String?,
  );
}
