import '../identity/user_trigger_store.dart';

/// Pure checks for user TP/SL triggers (v1.6.67) - shared by the engine's
/// 5-second sweep and the Dashboard dialog, so both apply the same rule.

/// The live value the trigger is compared against, in its own unit.
double? liveValueFor(TriggerKind kind, {double? pct, double? usd, double? price}) => switch (kind) {
      TriggerKind.pct => pct,
      TriggerKind.usd => usd,
      TriggerKind.price => price,
    };

/// True when [trigger] is reached. TP: P&L %/$ at or above the value; price
/// at or above it on a buy, at or below it on a sell. SL: the mirror image.
bool userTriggerHit({
  required UserTrigger trigger,
  required bool isTp,
  required bool isLong,
  double? pct,
  double? usd,
  double? price,
}) {
  final live = liveValueFor(trigger.kind, pct: pct, usd: usd, price: price);
  if (live == null) return false;
  final up = trigger.kind == TriggerKind.price ? isLong == isTp : isTp;
  return up ? live >= trigger.value : live <= trigger.value;
}

/// Why [trigger] can't be set right now, or null if it can (per the user:
/// "tp p&l % should be more than current p&l once it is set ... tp price
/// should be more (in long trades) or less (in short trades)" - SL the
/// other way). A waiting pair has P&L 0 and no live price/direction check
/// unless [isLong] and [price] are known.
String? userTriggerInvalidReason({
  required UserTrigger trigger,
  required bool isTp,
  required bool? isLong,
  double? pct,
  double? usd,
  double? price,
  bool filled = true,
}) {
  final name = isTp ? 'Take profit' : 'Stop loss';
  if (trigger.kind == TriggerKind.price) {
    if (trigger.value <= 0) return 'Price must be above 0';
    if (isLong == null || price == null) {
      return 'Price trigger needs the trade direction - wait until a signal or order shows BUY/SELL';
    }
  }
  final live = filled
      ? liveValueFor(trigger.kind, pct: pct, usd: usd, price: price)
      : (trigger.kind == TriggerKind.price ? price : 0.0);
  if (live == null) return 'Current value not known yet - try again in a few seconds';
  final up = trigger.kind == TriggerKind.price ? isLong == isTp : isTp;
  final ok = up ? trigger.value > live : trigger.value < live;
  if (ok) return null;
  final unit = switch (trigger.kind) {
    TriggerKind.pct => 'P&L % (now ${live.toStringAsFixed(2)}%)',
    TriggerKind.usd => 'P&L \$ (now ${live.toStringAsFixed(2)})',
    TriggerKind.price => 'the price (now $live)',
  };
  return '$name must be ${up ? 'above' : 'below'} $unit';
}
