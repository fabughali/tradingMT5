import 'trade_direction.dart';

/// Result of the 60/40 range-based TP/SL model (lib/technique/liquidation.dart),
/// ported from tradingPionex's ORIGINAL model (pre-2026-09-14) — the version
/// that needs only entry price + range top/bottom, no Pionex-specific
/// margin/liquidation-price data (see ARCHITECTURE.md for why the later
/// liquidation-price-shift model was deliberately NOT ported here).
///
/// Whichever edge (TP or SL) entry hasn't moved too close to (or past) stays
/// fixed at the natural chart-derived bound; the OTHER edge may have been
/// widened (`widenApplied`) so entry lands at exactly 60% of the span away
/// from it.
class LiquidationLevels {
  const LiquidationLevels({
    required this.direction,
    required this.takeProfitPrice,
    required this.stopLossPrice,
    required this.stopLossFraction,
    required this.stable,
    required this.widenApplied,
    required this.gridTop,
    required this.gridBottom,
  });

  final TradeDirection direction;
  final double takeProfitPrice;
  final double stopLossPrice;
  final double stopLossFraction;

  /// True when entry was already >=60% of the span from the SL edge — no
  /// range change was needed.
  final bool stable;

  /// True when the SL-side edge was widened so entry lands at exactly 60%.
  /// False means either it was already stable, or the degenerate case (keep
  /// the original range, just record the SL price).
  final bool widenApplied;

  /// The final range edges used to derive takeProfitPrice/stopLossPrice
  /// (may differ from the input top/bottom when widenApplied is true).
  final double gridTop;
  final double gridBottom;
}
