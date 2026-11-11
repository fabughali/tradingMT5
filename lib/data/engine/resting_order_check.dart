import '../models/trade_direction.dart';

/// Whether a resting (placed, not yet triggered) order should be cancelled
/// and re-placed for a fresh signal read (2026-10-25, per the user). Before,
/// ANY difference in SL/TP did it - but the 60/40 SL is solved from the live
/// entry price, so every small price tick moved it a hair and ADA's order
/// was cancelled and re-placed again and again while waiting. Now only a
/// changed direction, or SL/TP moving by more than [tolerance] (a fraction of
/// the resting level, default 1%), counts.
///
/// [referencePrice] (2026-11-11, per the user "fix it"): when given (the
/// trade's entry price), a move is measured against it instead of against
/// the level itself. ALGO's widened SL sits far below price (0.0153 at
/// price 0.092), so a 0.0002 wiggle was 1.3% of the SL - over the limit -
/// and its order was cancelled and re-placed every check (11:58, 12:09,
/// 12:21Z). Against the price it is 0.2%, so it now stays put.
bool restingOrderNeedsReplace({
  required TradeDirection restingDirection,
  required TradeDirection newDirection,
  required double? restingSl,
  required double targetSl,
  required double? restingTp,
  required double targetTp,
  double tolerance = 0.01,
  double? referencePrice,
}) {
  if (restingDirection != newDirection) return true;
  bool moved(double? resting, double target) {
    if (resting == null || resting == 0) return target != 0;
    final base = referencePrice != null && referencePrice > 0 ? referencePrice : resting;
    return ((target - resting) / base).abs() > tolerance;
  }

  return moved(restingSl, targetSl) || moved(restingTp, targetTp);
}
