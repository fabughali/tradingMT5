import '../models/signal.dart';
import '../models/trade_direction.dart';

/// The third decision technique (worm_10_26 + spy_9_26, Heikin Ashi) - pure
/// decision logic, deliberately isolated from [EngineService] so it can be
/// dry-run verified against real historical signal data before ever being
/// wired into a live open/close call. 2026-10-14, per the user, after
/// extensive back-and-forth to pin down the exact spec against real
/// worm_10_26 plot data (see PRD §9.x for the full worked-example trail -
/// multiple earlier guesses were wrong and explicitly corrected).
///
/// The six distinct event kinds checked each cycle. Each implies both a
/// direction and an action class:
///
/// - [buyOpen1]/[sellOpen1] ("case 1", full confluence including the
///   Supertrend leg): opens from flat; RECYCLES (close+reopen) the SAME
///   direction if it's already running ("if current trade is buy and new
///   buy open case 1 appears ... app close this trade and start buy
///   again" - confirmed directly with the user); FLIPS (closes the
///   opposite + opens this one) if the opposite direction is running -
///   [buyOpen1]'s own LL+RSI-blue/purple leg, minus the Supertrend check,
///   is exactly [sellClose1]'s full condition, so whenever [buyOpen1]
///   holds, [sellClose1] necessarily also holds for the same bar.
/// - [buyClose1]/[sellClose1] ("case 1", weak - HH/LL + RSI, NO Supertrend
///   check): FLIPS the opposite direction if it's running. No-op from flat
///   and no-op if the SAME direction is running (that's the recycle case
///   above, not this one).
/// - [zigzagBuy]/[zigzagSell] ("case 3", the bare all-caps BUY/SELL plot -
///   same heritage as worm_9_26, confirmed NOT the mixed-case discrete
///   Supertrend plot): FLIPS the opposite direction if it's running; is
///   just an Update (log only, no state change) if the SAME direction is
///   already running; no-op from flat (a bare signal alone never opens a
///   fresh trade - only case 1 can).
///
/// "Case 2" (both open and close) is never checked as an independent
/// condition - it's the automatic CONSEQUENCE of a flip above ("a SELL
/// trade closing" IS what opens the BUY, not a separate thing to verify).
enum Worm10EventKind { buyOpen1, sellOpen1, buyClose1, sellClose1, zigzagBuy, zigzagSell }

Worm10EventKind worm10EventKindFromWire(String s) => switch (s) {
  'BUY_OPEN1' => Worm10EventKind.buyOpen1,
  'SELL_OPEN1' => Worm10EventKind.sellOpen1,
  'BUY_CLOSE1' => Worm10EventKind.buyClose1,
  'SELL_CLOSE1' => Worm10EventKind.sellClose1,
  'ZIGZAG_BUY' => Worm10EventKind.zigzagBuy,
  'ZIGZAG_SELL' => Worm10EventKind.zigzagSell,
  _ => throw ArgumentError('unknown worm10 event kind: $s'),
};

String worm10EventKindToWire(Worm10EventKind k) => switch (k) {
  Worm10EventKind.buyOpen1 => 'BUY_OPEN1',
  Worm10EventKind.sellOpen1 => 'SELL_OPEN1',
  Worm10EventKind.buyClose1 => 'BUY_CLOSE1',
  Worm10EventKind.sellClose1 => 'SELL_CLOSE1',
  Worm10EventKind.zigzagBuy => 'ZIGZAG_BUY',
  Worm10EventKind.zigzagSell => 'ZIGZAG_SELL',
};

/// One worm_10_26/spy_9_26 derived event on one bar - same per-bar shape as
/// [Signal], six kinds instead of four.
class Worm10Event {
  const Worm10Event({required this.kind, required this.time});
  final Worm10EventKind kind;
  final int time;
}

/// Builds the full chronological event list from one combined
/// [Worm10Check] read - the SINGLE source both the real-time per-cycle
/// check and the retroactive audit derive from, so the two can never
/// disagree with each other.
///
/// At most ONE event per occurrence of a zigzag HH/LL/BUY/SELL tag - when
/// the STRONG, full-confluence condition ([buyOpen1]/[sellOpen1]) and the
/// WEAK condition it implies ([sellClose1]/[buyClose1]) would both fire on
/// the exact same bar (they share the LL-or-HH+RSI leg; the strong one just
/// adds the Supertrend requirement), only the strong one is emitted - it
/// already fully subsumes the weak one's consequence via
/// [worm10DecisionFor], so emitting both would double-act on one bar (e.g.
/// flip then immediately recycle on the very same signal).
List<Worm10Event> deriveWorm10Events(Worm10Check check) {
  final rsiByTime = {for (final z in check.rsiZones) z.time: z.zone};

  // Supertrend's own latest-known direction as of any bar time - sparse,
  // persists forward until the next discrete signal (2026-10-14, per the
  // user: "supertrend need to be sell" means the STATE the last discrete
  // Supertrend signal established, not a per-bar flag).
  final supertrendSorted = [...check.supertrend.signals]..sort((a, b) => a.time.compareTo(b.time));
  TradeDirection? supertrendDirectionAt(int t) {
    TradeDirection? dir;
    for (final s in supertrendSorted) {
      if (s.time > t) break;
      dir = s.tag == SignalTag.buy ? TradeDirection.long : TradeDirection.short;
    }
    return dir;
  }

  final events = <Worm10Event>[];
  for (final s in check.zigzag.signals) {
    final zone = rsiByTime[s.time];
    switch (s.tag) {
      case SignalTag.hh:
        final rsiOk = zone == RsiZone.yellow || zone == RsiZone.green;
        if (!rsiOk) break;
        if (supertrendDirectionAt(s.time) == TradeDirection.long) {
          events.add(Worm10Event(kind: Worm10EventKind.sellOpen1, time: s.time));
        } else {
          events.add(Worm10Event(kind: Worm10EventKind.buyClose1, time: s.time));
        }
      case SignalTag.ll:
        final rsiOk = zone == RsiZone.blue || zone == RsiZone.purple;
        if (!rsiOk) break;
        if (supertrendDirectionAt(s.time) == TradeDirection.short) {
          events.add(Worm10Event(kind: Worm10EventKind.buyOpen1, time: s.time));
        } else {
          events.add(Worm10Event(kind: Worm10EventKind.sellClose1, time: s.time));
        }
      case SignalTag.buy:
        events.add(Worm10Event(kind: Worm10EventKind.zigzagBuy, time: s.time));
      case SignalTag.sell:
        events.add(Worm10Event(kind: Worm10EventKind.zigzagSell, time: s.time));
    }
  }
  events.sort((a, b) => a.time.compareTo(b.time));
  return events;
}

enum Worm10Action { openFresh, recycle, flip, update, none }

class Worm10Decision {
  const Worm10Decision({required this.action, required this.resultDirection});

  final Worm10Action action;

  /// The direction the pair is in AFTER this event resolves - null only
  /// when [action] is [Worm10Action.none] and nothing was running before
  /// either.
  final TradeDirection? resultDirection;
}

/// The one pure state-transition rule, applied to a single event against
/// whatever is currently running ([current] - null means flat/waiting).
/// Used identically by the real-time per-cycle check (against the single
/// latest event) and the retroactive audit (walked forward across every
/// event since the running position's own recorded Start) - see this
/// file's own top-of-file doc comment for the full case-by-case reasoning,
/// confirmed directly with the user across multiple corrected rounds.
Worm10Decision worm10DecisionFor(TradeDirection? current, Worm10EventKind kind) {
  switch (kind) {
    case Worm10EventKind.buyOpen1:
      if (current == null) {
        return const Worm10Decision(action: Worm10Action.openFresh, resultDirection: TradeDirection.long);
      }
      if (current == TradeDirection.long) {
        return const Worm10Decision(action: Worm10Action.recycle, resultDirection: TradeDirection.long);
      }
      return const Worm10Decision(action: Worm10Action.flip, resultDirection: TradeDirection.long);
    case Worm10EventKind.sellOpen1:
      if (current == null) {
        return const Worm10Decision(action: Worm10Action.openFresh, resultDirection: TradeDirection.short);
      }
      if (current == TradeDirection.short) {
        return const Worm10Decision(action: Worm10Action.recycle, resultDirection: TradeDirection.short);
      }
      return const Worm10Decision(action: Worm10Action.flip, resultDirection: TradeDirection.short);
    case Worm10EventKind.buyClose1:
      if (current == TradeDirection.long) {
        return const Worm10Decision(action: Worm10Action.flip, resultDirection: TradeDirection.short);
      }
      return Worm10Decision(action: Worm10Action.none, resultDirection: current);
    case Worm10EventKind.sellClose1:
      if (current == TradeDirection.short) {
        return const Worm10Decision(action: Worm10Action.flip, resultDirection: TradeDirection.long);
      }
      return Worm10Decision(action: Worm10Action.none, resultDirection: current);
    case Worm10EventKind.zigzagBuy:
      if (current == TradeDirection.short) {
        return const Worm10Decision(action: Worm10Action.flip, resultDirection: TradeDirection.long);
      }
      if (current == TradeDirection.long) {
        return const Worm10Decision(action: Worm10Action.update, resultDirection: TradeDirection.long);
      }
      return const Worm10Decision(action: Worm10Action.none, resultDirection: null);
    case Worm10EventKind.zigzagSell:
      if (current == TradeDirection.long) {
        return const Worm10Decision(action: Worm10Action.flip, resultDirection: TradeDirection.short);
      }
      if (current == TradeDirection.short) {
        return const Worm10Decision(action: Worm10Action.update, resultDirection: TradeDirection.short);
      }
      return const Worm10Decision(action: Worm10Action.none, resultDirection: null);
  }
}
