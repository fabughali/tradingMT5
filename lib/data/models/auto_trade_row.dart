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
    required this.isPaused,
    required this.isLastTagged,
    this.direction,
    this.price,
    this.currentPrice,
    this.stopLoss,
    this.takeProfit,
    this.profit,
    this.pnlPercent,
    this.slRatchetThreshold,
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
    this.investmentValue,
    this.extraMargin,
    this.liquidationPrice,
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

  /// The LIVE market price (MT5's own `price_last`), separate from
  /// [price] above which is fixed at entry and never moves (2026-10-15,
  /// per the user: coloring Price/Liquidation yellow once the live price
  /// is within 20% of the estimated liquidation price needs an actual
  /// moving number to compare against - [price] alone can't do that,
  /// it's a snapshot of where the trade opened, not where it is now).
  /// Only set for [AutoTradeStatus.running].
  final double? currentPrice;
  final double? stopLoss;
  final double? takeProfit;

  /// Live floating P&L - only set for [AutoTradeStatus.running].
  final double? profit;

  /// [profit] expressed as a percentage of the position's own notional
  /// value (`currentVolume * contractSize * price`), NOT of account margin
  /// (2026-10-13, per the user wanting a percentage alongside the dollar
  /// figure). This app deliberately carries no investment/margin-sizing
  /// concept at all (see `engine_service.dart`'s own "no investment/margin
  /// sizing" doc comment) and MT5's own position/account data here has no
  /// leverage or per-position margin field to divide into either (confirmed
  /// live) - so this is "return on the full trade size," not "return on
  /// capital committed," which would read much larger under leverage. Null
  /// whenever [profit] is null, or the notional value can't be computed
  /// (price/volume/contract size missing or zero).
  final double? pnlPercent;

  /// The SL ratchet rung currently locked for this position (5/10/15/...),
  /// or null if it's never crossed the first rung (2026-10-13, per the
  /// user: "can i have a column in auto table to show current sll set...
  /// so user know what is current sll setup without any guessing"). Read
  /// straight from `SlRatchetStore`'s own file, keyed by this row's own
  /// [ticket] - see `EngineService._applySlRatchet`/§10.1 for how this gets
  /// set in the first place. Only ever set for [AutoTradeStatus.running].
  final int? slRatchetThreshold;

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

  /// Whether this base is in `auto-managed-bases.json` (2026-09-29 spec).
  /// Always true for a row that actually makes it into the table - the
  /// provider only includes auto-managed, non-retired bases (2026-09-30:
  /// "table only show auto managed pairs") - kept as its own field since
  /// removing a base from auto-management entirely still exists as a
  /// concept (it just has no Dashboard control of its own any more; see
  /// [isPaused] for what the former Auto toggle now does instead).
  final bool isAutoManaged;

  /// Play/Pause state (2026-10-09, per the user: "it is better to make it
  /// a play/pause button rather than a toggle" — replaces the old Auto
  /// toggle, which used to remove the base from auto-management entirely
  /// and unlist the row). True = the engine takes NO action on this pair
  /// at all right now, but it stays fully visible, in whatever state it
  /// was already in (running stays running, waiting stays waiting) - "the
  /// engine will not take any action to this pair unless it is unpaused."
  final bool isPaused;

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

  /// Notional value of this position in dollars (2026-10-15, per the user)
  /// - `volume * contractSize * openPrice`, the SAME figure [pnlPercent]'s
  /// own denominator already is, just surfaced directly rather than only
  /// used internally. Only set for [AutoTradeStatus.running].
  final double? investmentValue;

  /// The account's overall free margin (`AccountSnapshot.marginFree`), per
  /// the user's "extra margin in dollars" column - MT5 only tracks margin
  /// at the ACCOUNT level, not per position (confirmed live, same
  /// constraint [pnlPercent]'s own doc comment already documents), so this
  /// is deliberately the SAME single number on every running row, not a
  /// per-position breakdown MT5 has no way to give.
  final double? extraMargin;

  /// Estimated price at which THIS position alone, if it kept moving
  /// against its own direction while every other position's P&L and the
  /// account balance stayed exactly as they are right now, would drag the
  /// account's margin level down to Equiti Seychelles' own published
  /// Stop-Out Level (30% of used margin - confirmed directly from Equiti's
  /// own Support Center FAQ, 2026-10-15: "If your Equity falls to less
  /// than 30% of the required margin, your trade(s) will be closed out by
  /// our Automated Risk Management System"). This is a real, grounded
  /// estimate, not a guess - but it is still an ESTIMATE, not a fixed
  /// per-symbol number the way a crypto-exchange liquidation price is:
  /// MT5's stop-out is a single ACCOUNT-WIDE margin-level trigger, not
  /// resolvable into a true independent-per-position price the way this
  /// column necessarily implies. Only set for [AutoTradeStatus.running].
  final double? liquidationPrice;
}
