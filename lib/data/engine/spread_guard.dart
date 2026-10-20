/// Spread guard (2026-10-20, per the user, v1.6.32): never open a trade
/// whose bid/ask spread ALONE already costs more than [maxSpreadCostUsd]
/// at the volume being sent. Found live: XRP opened SELL 100 at 00:19 right
/// after the daily rollover with a 0.06 spread - an instant -$6.00, closed
/// by the -$5 SLL baseline a second later. The app had no spread check at
/// all. An open blocked by this is simply retried next cycle.
library;

const double maxSpreadCostUsd = 1.0;

/// What the spread alone costs the moment a position of [volume] opens:
/// `(ask - bid) * volume * contractSize`, in the symbol's quote currency
/// (USD for every crypto .lv pair and USD-quoted forex - the only kind this
/// app trades; a non-USD-quoted pair is a close approximation).
double spreadCost({
  required double bid,
  required double ask,
  required double volume,
  required double contractSize,
}) =>
    (ask - bid).abs() * volume * contractSize;

bool spreadTooWide({
  required double bid,
  required double ask,
  required double volume,
  required double contractSize,
  double limit = maxSpreadCostUsd,
}) =>
    // Tiny tolerance so float noise ((1.01 - 1.00) * 100 = 1.0000000000000009)
    // can't turn a spread exactly AT the limit into a block.
    spreadCost(bid: bid, ask: ask, volume: volume, contractSize: contractSize) > limit + 1e-9;

/// Whether a copy trade's fixed -$[dollarCap] stop-loss can survive at all
/// (2026-10-20, per the user, v1.6.32). A copy is 1 lot by spec with a -$1
/// SL, i.e. an SL only `dollarCap / (volume * contractSize)` in PRICE away
/// from entry. For ETH (1 lot = $1 per $1 move) that was $1 - inside ETH's
/// normal spread - so the broker SL fired 11s after the fill and slipped
/// to -$2.70 (live, 2026-10-20 23:57). The SL distance must exceed the
/// spread plus the broker's minimum stop distance (trade_stops_level *
/// point), otherwise the copy is refused instead of opened into a
/// guaranteed loss.
bool copyStopLossSurvives({
  required double bid,
  required double ask,
  required double volume,
  required double contractSize,
  required double point,
  required int stopsLevelPoints,
  double dollarCap = 1.0,
}) {
  final perUnit = volume * contractSize;
  if (perUnit <= 0) return false;
  final slDistance = dollarCap / perUnit;
  final minDistance = (ask - bid).abs() + stopsLevelPoints * point;
  return slDistance > minDistance;
}
