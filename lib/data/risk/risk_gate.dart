import '../../core/core_storage.dart';
import '../models/app_config.dart';
import '../models/auto_category.dart';
import '../models/risk_state.dart';

class GateResult {
  const GateResult.allowed() : allowed = true, reason = null;
  const GateResult.blocked(this.reason) : allowed = false;

  final bool allowed;
  final String? reason;
}

/// Position caps, daily loss limit, the STOP kill switch, and a live
/// margin-level gate — ported from tradingPionex/app/lib/data/risk/
/// risk_gate.dart, extended 2026-10-13 with the margin gate (broker-
/// specific, MT5-only, not carried over from tradingPionex). `close` is
/// always allowed; `open` is the only gated action.
class RiskGate {
  RiskGate(this._storage, this._config) {
    _state = _loadOrReset();
  }

  final CoreStorage _storage;
  final RiskConfig _config;
  late RiskState _state;

  /// Live account margin level (`equity / margin * 100`, the same figure
  /// the Dashboard's own "Margin Level" stat shows — see
  /// `AccountSnapshot.marginLevel`'s own doc comment for the formula),
  /// refreshed periodically by the engine (2026-10-13, per the user: "if
  /// margin reached <= 150%... waiting non-filled trades will stay
  /// non-filled... filled trades and non-triggered trades will become non
  /// filled"). Null means either no margin currently in use (nothing to
  /// protect against — never blocks) or not yet refreshed since startup
  /// (also never blocks, so a cold start doesn't spuriously trip this
  /// before the first real reading comes in).
  double? _marginLevel;

  /// Confirmed with the user directly: "that number margin level in
  /// [the] status section."
  static const double marginGateThresholdPct = 150;

  /// True once live margin level has genuinely dropped to/below
  /// [marginGateThresholdPct] — the single source of truth both [gate]
  /// (blocks future opens) and the engine's own pending-order-cancellation
  /// sweep key off, so the two can never disagree about current state.
  bool get marginGateTripped =>
      _marginLevel != null && _marginLevel! <= marginGateThresholdPct;

  double? get marginLevel => _marginLevel;

  /// Margin-level-tiered concurrent-position cap (2026-10-15, per the
  /// user, after a real margin stop-out: "what if there is good margin
  /// level... why you need to setup a fixed max positions?" - correctly
  /// pointing out a FLAT cap is a blunt proxy for risk, when the real
  /// thing that matters (margin level) is already tracked live. Null
  /// means "no cap at all" - the user's own "if margin is more than
  /// 300%... max position is open" (i.e. unrestricted). Below
  /// [marginGateThresholdPct] this is moot anyway - [gate] already blocks
  /// every open outright at that point, position count or not.
  static int? positionCapFor(double? marginLevel) {
    if (marginLevel == null || marginLevel > 300) return null;
    if (marginLevel > 200) return 6;
    if (marginLevel > marginGateThresholdPct) return 3;
    return 0;
  }

  /// Same margin tiers as [positionCapFor], but scaling the SIZE of the
  /// next trade instead of how many can run at once (2026-10-15, per the
  /// user - the companion half of the same idea: shrink new exposure as
  /// real risk rises, not just count it). 1.0 = full size (margin > 300%,
  /// or no live reading yet - never shrinks a trade before the first real
  /// margin snapshot arrives). Below [marginGateThresholdPct] is moot for
  /// the same reason as [positionCapFor] - nothing opens there regardless.
  static double marginSizeScaleFor(double? marginLevel) {
    if (marginLevel == null || marginLevel > 300) return 1.0;
    if (marginLevel > 200) return 0.6;
    if (marginLevel > marginGateThresholdPct) return 0.3;
    return 0.0;
  }

  void updateMarginLevel(double? marginLevel) {
    _marginLevel = marginLevel;
  }

  RiskState _loadOrReset() {
    final json = _storage.readJsonObject(_storage.stateFile);
    var state = json != null
        ? RiskState.fromJson(json)
        : RiskState.freshForToday();
    final todayStart = RiskState.utcMidnightMs(DateTime.now());
    if (state.dayStartUtcMs != todayStart) {
      state = RiskState.freshForToday();
      _persist(state);
    }
    return state;
  }

  void _persist(RiskState state) =>
      _storage.writeJson(_storage.stateFile, state.toJson());

  bool get killSwitchTripped => _storage.fileExists(_storage.stopFile);

  /// Composite key so the same symbol can hold one open position PER
  /// CATEGORY simultaneously (1m/5m/15m/1H/1D each independent), while
  /// still capping at one per symbol+category. Ported from tradingPionex's
  /// 2026-09-19 fix: before this, keying by bare symbol meant a position
  /// opened under any one category blocked every other category from ever
  /// opening on that symbol at all — contradicted the "1 per symbol per
  /// category" design and went unnoticed for a while since it fails
  /// silently (just refuses to open, no error). Never regress back to
  /// bare-symbol keying.
  String _key(String symbol, AutoCategory category) =>
      '$symbol|${category.wireValue}';

  /// [bypassMarginGate] (2026-10-17, per the user: "margin level has
  /// nothing to do with manual ignited pair. so if margin level is less
  /// than rule, still this ignited pair will run once it is triggered") -
  /// skips BOTH margin-level rules (the hard [marginGateTripped] block and
  /// the margin-tiered position cap, [positionCapFor]) for a pair the user
  /// explicitly ignited via the Dashboard's thunder icon. Every other gate
  /// (kill switch, cooldown, daily loss limit, per-symbol max-positions)
  /// still applies unchanged - the user only ever singled out margin level.
  GateResult gate(
    String action,
    String symbol,
    AutoCategory category, {
    bool bypassMarginGate = false,
  }) {
    if (action == 'close') return const GateResult.allowed();

    _rolloverIfNewDay();
    final now = DateTime.now().millisecondsSinceEpoch;
    final key = _key(symbol, category);

    if (killSwitchTripped) {
      return const GateResult.blocked('KILL SWITCH: STOP file present');
    }
    if (!bypassMarginGate && marginGateTripped) {
      return GateResult.blocked(
        'MARGIN GATE: margin level ${_marginLevel!.toStringAsFixed(1)}% <= '
        '$marginGateThresholdPct% - new opens blocked until it recovers',
      );
    }
    if (now < _state.cooldownUntilMs) {
      final until = DateTime.fromMillisecondsSinceEpoch(
        _state.cooldownUntilMs,
      ).toUtc().toIso8601String();
      return GateResult.blocked('Cooldown active until $until');
    }
    if (_state.dayPnlPct <= -_config.dailyLossLimitPct) {
      return GateResult.blocked(
        'Daily loss limit hit: ${_state.dayPnlPct}% <= -${_config.dailyLossLimitPct}%',
      );
    }
    // Margin-level-tiered concurrent-position cap (2026-10-15, per the
    // user, after a real margin stop-out) - see [positionCapFor]'s own
    // doc comment for the full reasoning and exact tiers. A flat count
    // cap would have been a blunt proxy for risk; this ties the limit to
    // the actual thing that matters (live margin level), tightening as
    // real risk rises and getting out of the way entirely above 300%.
    // Checked BEFORE the per-symbol cap so the more general limit is what
    // the user sees in the block reason when both would apply.
    final cap = bypassMarginGate ? null : positionCapFor(_marginLevel);
    if (cap != null) {
      final totalOpen = _state.openPositions.values.fold(0, (a, b) => a + b);
      if (totalOpen >= cap) {
        return GateResult.blocked(
          'Margin-tiered position cap: $totalOpen/$cap open '
          '(margin level ${_marginLevel!.toStringAsFixed(1)}%)',
        );
      }
    }
    final perSymbol = _state.openPositions[key] ?? 0;
    if (perSymbol >= _config.maxPerSymbol) {
      return GateResult.blocked(
        'Max positions for $key: $perSymbol/${_config.maxPerSymbol}',
      );
    }
    return const GateResult.allowed();
  }

  void openPosition(String symbol, AutoCategory category) {
    _rolloverIfNewDay();
    final key = _key(symbol, category);
    _state.openPositions[key] = (_state.openPositions[key] ?? 0) + 1;
    _persist(_state);
  }

  /// Must be called on every close, mirroring openPosition — skipping this
  /// leaves position counters only ever growing until max_positions/
  /// max_per_symbol permanently blocks all further opens (the exact bug
  /// tradingPionex's original Node engine had for weeks). Never regress.
  void closePosition(String symbol, AutoCategory category) {
    final key = _key(symbol, category);
    final current = _state.openPositions[key];
    if (current != null) {
      final next = current - 1;
      if (next <= 0) {
        _state.openPositions.remove(key);
      } else {
        _state.openPositions[key] = next;
      }
    }
    _persist(_state);
  }

  /// One-time rebuild of the whole open-positions map from a fresh live
  /// broker snapshot — ported from tradingPionex's 2026-09-19 fix, added
  /// there because a pure key-format migration (bare symbol ->
  /// symbol|category) would have silently lost track of already-open
  /// positions rather than just re-deriving the correct counts. Call this
  /// at startup with the real open positions read from MT5 (matched back
  /// to their category via BotCategoryStore) rather than trusting
  /// whatever state.json happened to have on disk from before a format
  /// change.
  void resetTo(Map<String, int> liveOpenPositions) {
    _state.openPositions
      ..clear()
      ..addAll(liveOpenPositions);
    _persist(_state);
  }

  void recordPnl(double pnlPct) {
    _rolloverIfNewDay();
    _state.dayPnlPct += pnlPct;
    _persist(_state);
    if (_state.dayPnlPct <= -_config.dailyLossLimitPct) {
      _state.cooldownUntilMs =
          DateTime.now().millisecondsSinceEpoch + _config.cooldownSec * 1000;
      _persist(_state);
    }
  }

  RiskState get status => _state;

  void _rolloverIfNewDay() {
    final todayStart = RiskState.utcMidnightMs(DateTime.now());
    if (_state.dayStartUtcMs != todayStart) {
      _state = RiskState.freshForToday();
      _persist(_state);
    }
  }
}
