import '../models/trade_direction.dart';

/// Whether a resting (placed, not yet triggered) order should be cancelled
/// and re-placed for a fresh signal read (2026-10-25, per the user). Before,
/// ANY difference in SL/TP did it - but the 60/40 SL is solved from the live
/// entry price, so every small price tick moved it a hair and ADA's order
/// was cancelled and re-placed again and again while waiting. Now only a
/// changed direction, or SL/TP moving by more than [tolerance] (a fraction of
/// the resting level, default 1%), counts.
bool restingOrderNeedsReplace({
  required TradeDirection restingDirection,
  required TradeDirection newDirection,
  required double? restingSl,
  required double targetSl,
  required double? restingTp,
  required double targetTp,
  double tolerance = 0.01,
}) {
  if (restingDirection != newDirection) return true;
  bool moved(double? resting, double target) {
    if (resting == null || resting == 0) return target != 0;
    return ((target - resting) / resting).abs() > tolerance;
  }

  return moved(restingSl, targetSl) || moved(restingTp, targetTp);
}
