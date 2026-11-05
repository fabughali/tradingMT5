import 'dart:math';

import 'volume_step.dart';

/// Auto volume (2026-11-05, v1.6.65, per the user: "if volume set to (auto)
/// then app decide what volume is good for achieving max gain and not
/// reaching margin less than 150" / "max number of trades ... max gain ...
/// watch history and understand what pairs has best gain and then apply max
/// volume" / "dollars are more important to me than percentage").
///
/// Pure helpers only - the engine supplies the live account and history.

/// One pair's 30-day closed result, in dollars (profit + swaps + commission).
class PairHistory {
  const PairHistory({required this.pnl, required this.trades});
  final double pnl;
  final int trades;
}

/// Fewer closed trades than this in 30 days = not enough history: weight 1.
const autoMinHistoryTrades = 5;

/// Weight per pair from its 30-day DOLLAR result (the user's choice, not
/// per-unit-of-size). Pairs with [autoMinHistoryTrades]+ trades are ranked by
/// dollars: top third x2, middle third x1, bottom third x0.5 - and any pair
/// that lost (or made nothing) is x0.5 whatever its rank. Pairs with too few
/// trades, or no history at all, are x1. Keys are returned upper-cased.
Map<String, double> autoPairWeights(Map<String, PairHistory> history) {
  final ranked = history.entries.where((e) => e.value.trades >= autoMinHistoryTrades).toList()
    ..sort((a, b) => b.value.pnl.compareTo(a.value.pnl));
  final weights = <String, double>{};
  for (final e in history.entries) {
    weights[e.key.toUpperCase()] = 1.0;
  }
  final n = ranked.length;
  for (var i = 0; i < n; i++) {
    final e = ranked[i];
    double w;
    if (e.value.pnl <= 0) {
      w = 0.5;
    } else if (i < (n / 3).ceil()) {
      w = 2.0;
    } else if (i < (2 * n / 3).ceil()) {
      w = 1.0;
    } else {
      w = 0.5;
    }
    weights[e.key.toUpperCase()] = w;
  }
  return weights;
}

/// Same margin rate [RiskGate.projectedMarginLevel] assumes for a new trade.
double autoMarginRate({required double margin, required double exposureNotional, double minRate = 0.07}) =>
    exposureNotional > 0 && margin > 0 ? max(margin / exposureNotional, minRate) : minRate;

/// A fixed-volume pair that is waiting to open: its card volume's notional.
class FixedNeed {
  const FixedNeed(this.key, this.notional);
  final String key;
  final double notional;
}

/// Margin dollars set aside for waiting FIXED pairs (per the user: "there
/// could be cases ... auto volume trades and fixed volume trades"). Only a
/// fixed pair that could really open is reserved - smallest first, while it
/// still fits in [room] - so one that can never fit (ETH at 0.6 on this
/// account) does not starve every auto pair.
double reserveForFixed({required double room, required double rate, required List<FixedNeed> needs}) {
  final sorted = [...needs]..sort((a, b) => a.notional.compareTo(b.notional));
  var reserved = 0.0;
  for (final n in sorted) {
    final m = n.notional * rate;
    if (reserved + m > room) break;
    reserved += m;
  }
  return reserved;
}

/// Result of [autoVolumeFor]: the size to send, and a short why for logs/GUI.
class AutoVolume {
  const AutoVolume(this.volume, this.why, {required this.fits});
  final double volume;
  final String why;

  /// False when even [volumeMin] does not fit the share - the margin floor
  /// will then make the pair wait.
  final bool fits;
}

/// Biggest volume for one auto pair that keeps the margin level at or above
/// [floorPct] once every waiting auto pair gets its share:
///
/// room   = equity / (floorPct/100) - margin - resting orders' margin
///          - margin set aside for waiting fixed pairs
/// share  = room * weight / (sum of the waiting auto pairs' weights)
/// volume = share / (rate * contractSize * price), floored to the broker's
///          grid, kept within [volumeMin, volumeMax].
///
/// [safety] trims the room a hair so a size computed to land exactly on the
/// floor still passes the floor check (which needs strictly above).
AutoVolume autoVolumeFor({
  required double equity,
  required double margin,
  required double exposureNotional,
  required double restingNotional,
  required double reservedMargin,
  required double weight,
  required double totalWeight,
  required double price,
  required double contractSize,
  required double volumeMin,
  required double volumeMax,
  required double volumeStep,
  double floorPct = 150,
  double safety = 0.99,
}) {
  final rate = autoMarginRate(margin: margin, exposureNotional: exposureNotional);
  final room = (equity / (floorPct / 100) - margin - restingNotional * rate - reservedMargin) * safety;
  final perLot = rate * contractSize * price;
  String f(double v) => v.toStringAsFixed(2);
  if (room <= 0 || perLot <= 0 || totalWeight <= 0) {
    return AutoVolume(volumeMin, 'no margin room above ${floorPct.toStringAsFixed(0)}% (room \$${f(room)})',
        fits: false);
  }
  final share = room * weight / totalWeight;
  final raw = share / perLot;
  if (raw < volumeMin) {
    return AutoVolume(
      volumeMin,
      'share \$${f(share)} of room \$${f(room)} is below the minimum (needs \$${f(volumeMin * perLot)})',
      fits: false,
    );
  }
  var volume = snapVolumeToStep(raw, volumeMin: volumeMin, volumeStep: volumeStep);
  if (volumeMax > 0 && volume > volumeMax) {
    volume = snapVolumeToStep(volumeMax, volumeMin: volumeMin, volumeStep: volumeStep);
  }
  return AutoVolume(
    volume,
    'x${weight.toStringAsFixed(1)} share \$${f(share)} of room \$${f(room)}',
    fits: true,
  );
}
