/// One row of the Dashboard's "Auto-Managed Trades" table (2026-09-29, per
/// the user: "a table .. a list of currenly running trades, filled trades,
/// waiting trades"). Every symbol in [config.symbols] gets exactly one row,
/// in one of three states — including a symbol the user has toggled Auto
/// off for (2026-09-29 spec extension: "toggle off = manual managed" still
/// needs to be visible in the table, not hidden).
enum AutoTradeStatus {
  /// A real open position exists (filled, actively running).
  running,

  /// No position yet, but a pending order the app placed is resting,
  /// waiting to trigger.
  waitingPending,

  /// No position, no order - waiting for a confirmed signal.
  waitingNoSignal,
}

class AutoTradeRow {
  const AutoTradeRow({
    required this.tvSymbol,
    required this.mt5Symbol,
    required this.status,
    required this.isAutoManaged,
    required this.isLastTagged,
    this.direction,
    this.price,
    this.stopLoss,
    this.takeProfit,
    this.profit,
    this.ticket,
    this.openedAt,
    this.startTag,
    this.startAt,
    this.updateTag,
    this.updateAt,
    this.waitingReason,
    this.lastCheckedAt,
    this.closeATag,
    this.closeAAt,
    this.closeBEta,
    this.desiredVolume,
    this.currentVolume,
    required this.volumeMin,
    required this.volumeStep,
    required this.volumeMax,
    this.startCandidateTag,
    this.startCandidateAt,
    this.startCandidateEta,
  });

  final String tvSymbol;
  final String mt5Symbol;
  final AutoTradeStatus status;

  /// 'buy' or 'sell' - the running position's or pending order's side. Null
  /// for [AutoTradeStatus.waitingNoSignal].
  final String? direction;

  /// Entry price if running, trigger price if a pending order. Null for
  /// [AutoTradeStatus.waitingNoSignal].
  final double? price;
  final double? stopLoss;
  final double? takeProfit;

  /// Live floating P&L - only set for [AutoTradeStatus.running].
  final double? profit;

  /// The position or order ticket, whichever applies.
  final int? ticket;

  /// The real MT5 position's `create_time` - only set for
  /// [AutoTradeStatus.running]. Source for the table's Duration column
  /// (elapsed time since this trade actually opened, not since the
  /// triggering signal fired).
  final DateTime? openedAt;

  /// The worm_9_26 tag ('hh'/'ll'/'buy'/'sell') that opened the CURRENT
  /// running trade, and its TradingView bar timestamp (epoch seconds) - from
  /// `entry-signal.json`. Null unless [status] is running.
  final String? startTag;
  final int? startAt;

  /// The latest SAME-direction confirming tag seen while this trade stayed
  /// open (e.g. a BUY confirming an LL-started long), and its TV timestamp -
  /// per the user: "also update if there is Buy signal with LL or sell
  /// signal with HH". Both null until the first such confirmation arrives.
  final String? updateTag;
  final int? updateAt;

  /// Auto toggle state (2026-09-29 spec): on = this base is in
  /// `auto-managed-bases.json` and gets checked/opened/closed automatically;
  /// off = manual, the engine skips it entirely but the row still shows.
  final bool isAutoManaged;

  /// Last toggle state (2026-09-29 spec): on = once the current trade
  /// closes (any path), the base retires from auto-management instead of
  /// being picked back up.
  final bool isLastTagged;

  /// The broker/MT5's own exact rejection text for the last failed open
  /// attempt (2026-09-29, per the user: "waiting pairs should reflect
  /// exact reason ... not guess ... for example (not enough margin)") -
  /// e.g. "deleted [no money]". Only meaningful for
  /// [AutoTradeStatus.waitingNoSignal]; null once a later attempt succeeds.
  final String? waitingReason;

  /// When this base was last genuinely re-evaluated (past the retry
  /// cooldown) — feeds the table's "Check" column, which only shows a mark
  /// when this falls within the current UTC hour AND [status] is running.
  final DateTime? lastCheckedAt;

  /// "Close A"/"Close B" (2026-09-30, per the user) - the live view of the
  /// "survive one extra candle" confirmation rule (`pending-signals.json`),
  /// scoped to THIS row only when it currently has a running position AND
  /// the pending candidate's own direction disagrees with it (i.e. it's a
  /// candidate that would actually close this trade if confirmed - an
  /// agreeing pending candidate isn't a "close" candidate at all). Close A
  /// is the disagreeing tag + its own bar time; Close B has no tag of its
  /// own to show while still mid-wait (the engine deliberately doesn't
  /// look at it until the wait ends) - [closeBEta] is simply WHEN that
  /// resolution happens, so the table can show "watching until ETA".
  final String? closeATag;
  final int? closeAAt;
  final DateTime? closeBEta;

  /// Trade-size override (2026-10-03, per the user: "add one more column
  /// about current trade volume ... with plus minus icons"). [desiredVolume]
  /// is the user's target for the NEXT open (null = no override, defaults
  /// to the broker minimum) — a currently-RUNNING trade's own size never
  /// changes, only a fresh/recycled open picks this up. [currentVolume] is
  /// the actual size in play: the live position's real MT5-reported volume
  /// while [status] is running, or the last successfully-applied volume
  /// while idle, or null if this pair has never opened a trade yet. The
  /// Dashboard shows [currentVolume] struck through next to [desiredVolume]
  /// in yellow only when the two differ — a pending change not yet in
  /// effect.
  final double? desiredVolume;
  final double? currentVolume;

  /// Broker-reported bounds/increment for this symbol (2026-09-17 data,
  /// same source [WatchedSymbol] already uses) — drives the +/- step size
  /// and clamps on the Dashboard's volume stepper.
  final double volumeMin;
  final double volumeStep;
  final double volumeMax;

  /// The live view of a not-yet-confirmed candidate signal for a row with
  /// NO running position or resting order yet (2026-10-03, per the user:
  /// waiting rows looked indistinguishable from genuinely idle ones even
  /// when a real signal had already triple-confirmed and was mid-"survive
  /// one extra candle" wait — "app will always push waiting trades to be
  /// filled", this just makes that progress visible). Mirrors [closeATag]/
  /// [closeBEta]'s own shape but for an OPEN candidate rather than a close
  /// one: [startCandidateTag]/[startCandidateAt] is the pending tag + its
  /// own bar time from `pending-signals.json`, [startCandidateEta] is when
  /// that wait resolves. Only meaningful for [AutoTradeStatus.waitingNoSignal].
  final String? startCandidateTag;
  final int? startCandidateAt;
  final DateTime? startCandidateEta;
}
