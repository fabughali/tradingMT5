import '../models/liquidation_levels.dart';
import '../models/trade_direction.dart';

const stableLiquidationFraction = 0.60;

/// The 60/40 range-based TP/SL model — ported from tradingPionex's ORIGINAL
/// `computeLiquidationLevels` (ARCHITECTURE.md explains why the later
/// liquidation-price-shift model was deliberately not ported: it depends on
/// Pionex's real liquidation price from a margin/leverage-dependent probe,
/// an input that doesn't exist in this app's simplified flow — no
/// investment or margin calculation here, per the user).
///
/// Whichever edge (TP or SL) entry hasn't moved too close to (or past) stays
/// fixed at the natural chart-derived bound; the OTHER edge may widen so
/// entry lands at exactly 60% of the span away from it:
///
/// LONG:  entry > top (past the TP side entirely): TP (top) moves further
///        up so entry sits at exactly 60% up from the fixed SL (bottom).
///        Otherwise, TP = top (fixed); if entry is <60% of the span above
///        bottom, SL (bottom) moves further down so entry sits at exactly
///        60% up from it, TP still fixed.
/// SHORT: entry < bottom (past the TP side entirely): TP (bottom) moves
///        further down so entry sits at exactly 60% down from the fixed
///        SL (top). Otherwise, TP = bottom (fixed); if entry is <60% of the
///        span below top, SL (top) moves further up so entry sits at
///        exactly 60% down from it, TP still fixed.
///
/// If the solved edge would land on the wrong side of entry/the fixed edge,
/// or at/below zero (a degenerate input), the range is left unmodified
/// (`stable: false, widenApplied: false`) rather than producing a
/// nonsensical price.
LiquidationLevels computeLiquidationLevels({
  required double top,
  required double bottom,
  required double entry,
  required TradeDirection direction,
}) {
  final span = top - bottom;
  if (!span.isFinite || span <= 0) {
    throw ArgumentError('degenerate range: top ($top) <= bottom ($bottom)');
  }

  if (direction == TradeDirection.long) {
    if (entry > top) {
      final adjustedTop =
          bottom + (entry - bottom) / stableLiquidationFraction;
      return LiquidationLevels(
        direction: direction,
        takeProfitPrice: adjustedTop,
        stopLossPrice: bottom,
        stopLossFraction: (entry - bottom) / (adjustedTop - bottom),
        stable: false,
        widenApplied: true,
        gridTop: adjustedTop,
        gridBottom: bottom,
      );
    }
    final fraction = (entry - bottom) / span;
    final stable = fraction >= stableLiquidationFraction;
    if (stable) {
      return LiquidationLevels(
        direction: direction,
        takeProfitPrice: top,
        stopLossPrice: bottom,
        stopLossFraction: fraction,
        stable: true,
        widenApplied: false,
        gridTop: top,
        gridBottom: bottom,
      );
    }
    // Solve for a new bottom (B') — TP edge (top) fixed — such that
    // (entry - B') / (top - B') == 0.6, i.e. entry sits at 60% up from
    // the new, lower B'. B' < bottom always, when unstable.
    final adjustedBottom =
        (entry - stableLiquidationFraction * top) /
        (1 - stableLiquidationFraction);
    final possible =
        adjustedBottom < entry && adjustedBottom < top && adjustedBottom > 0;
    if (possible) {
      return LiquidationLevels(
        direction: direction,
        takeProfitPrice: top,
        stopLossPrice: adjustedBottom,
        stopLossFraction: (entry - adjustedBottom) / (top - adjustedBottom),
        stable: false,
        widenApplied: true,
        gridTop: top,
        gridBottom: adjustedBottom,
      );
    }
    return LiquidationLevels(
      direction: direction,
      takeProfitPrice: top,
      stopLossPrice: bottom,
      stopLossFraction: fraction,
      stable: false,
      widenApplied: false,
      gridTop: top,
      gridBottom: bottom,
    );
  }

  // SHORT — mirror image: TP = bottom, SL = top, unless entry is already
  // past the TP side (below bottom) entirely.
  if (entry < bottom) {
    final adjustedBottom = top - (top - entry) / stableLiquidationFraction;
    final possible = adjustedBottom < entry && adjustedBottom > 0;
    if (possible) {
      return LiquidationLevels(
        direction: direction,
        takeProfitPrice: adjustedBottom,
        stopLossPrice: top,
        stopLossFraction: (top - entry) / (top - adjustedBottom),
        stable: false,
        widenApplied: true,
        gridTop: top,
        gridBottom: adjustedBottom,
      );
    }
    return LiquidationLevels(
      direction: direction,
      takeProfitPrice: bottom,
      stopLossPrice: top,
      stopLossFraction: (top - entry) / span,
      stable: false,
      widenApplied: false,
      gridTop: top,
      gridBottom: bottom,
    );
  }
  final fraction = (top - entry) / span;
  final stable = fraction >= stableLiquidationFraction;
  if (stable) {
    return LiquidationLevels(
      direction: direction,
      takeProfitPrice: bottom,
      stopLossPrice: top,
      stopLossFraction: fraction,
      stable: true,
      widenApplied: false,
      gridTop: top,
      gridBottom: bottom,
    );
  }
  // Solve for a new top (T') — TP edge (bottom) fixed — such that
  // (T' - entry) / (T' - bottom) == 0.6, i.e. entry sits at 60% down from
  // the new, higher T'. T' > top always, when unstable.
  final adjustedTop =
      (entry - stableLiquidationFraction * bottom) /
      (1 - stableLiquidationFraction);
  final possible = adjustedTop > entry && adjustedTop > bottom;
  if (possible) {
    return LiquidationLevels(
      direction: direction,
      takeProfitPrice: bottom,
      stopLossPrice: adjustedTop,
      stopLossFraction: (adjustedTop - entry) / (adjustedTop - bottom),
      stable: false,
      widenApplied: true,
      gridTop: adjustedTop,
      gridBottom: bottom,
    );
  }
  return LiquidationLevels(
    direction: direction,
    takeProfitPrice: bottom,
    stopLossPrice: top,
    stopLossFraction: fraction,
    stable: false,
    widenApplied: false,
    gridTop: top,
    gridBottom: bottom,
  );
}
