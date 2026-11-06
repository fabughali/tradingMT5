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

/// What the engine does with one side (TP or SL) of a trade's own broker
/// level while a user trigger exists (2026-11-06, per the user: "once user
/// set tp/sl, then this should override tp/sl when it is set at the
/// beginning of the trade" / "once user deactive tp/sl, then the default
/// tp/sl will take place").
enum BrokerSideAction {
  /// Nothing to change.
  none,

  /// Save the current broker level as the default and remove it (send 0).
  remove,

  /// The user trigger is gone - put the saved default back on MT5.
  restore,

  /// The user trigger is gone and price is already past the saved default,
  /// which MT5 would have hit - close the trade now, as the default would.
  closeDefault,

  /// Nothing left to restore (the default was empty or is back already).
  dropSaved,
}

/// [userActive]: a user trigger is set on this side. [saved]: the default
/// level saved when it was removed (null = nothing saved, 0 = the trade had
/// none). [current]: the level MT5 has now (0 = none).
BrokerSideAction brokerSideAction({
  required bool userActive,
  required double? saved,
  required double current,
  required bool isTp,
  required bool isLong,
  double? price,
}) {
  if (userActive) {
    if (saved == null) return BrokerSideAction.remove;
    return current != 0 ? BrokerSideAction.remove : BrokerSideAction.none;
  }
  if (saved == null) return BrokerSideAction.none;
  if (saved == 0 || current == saved) return BrokerSideAction.dropSaved;
  if (price == null) return BrokerSideAction.none;
  final hit = userTriggerHit(trigger: UserTrigger(TriggerKind.price, saved), isTp: isTp, isLong: isLong, price: price);
  return hit ? BrokerSideAction.closeDefault : BrokerSideAction.restore;
}
