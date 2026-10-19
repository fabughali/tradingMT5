import 'dart:async';
import 'dart:io';

import '../../core/core_storage.dart';
import '../../utilities/auto_cycle.dart';
import '../identity/auto_managed_store.dart';
import '../identity/baseline_stop_strike_store.dart';
import '../identity/bot_category_store.dart';
import '../identity/entry_signal_store.dart';
import '../identity/first_open_store.dart';
import '../identity/last_checked_store.dart';
import '../identity/last_tag_store.dart';
import '../identity/new_pair_wait_store.dart';
import '../identity/open_position_store.dart';
import '../identity/paused_pair_store.dart';
import '../identity/pending_signal_store.dart';
import '../identity/retired_store.dart';
import '../identity/auto_copy_milestone_store.dart';
import '../identity/sl_ratchet_store.dart';
import '../identity/supertrend_pending_store.dart';
import '../identity/symbol_resolve_store.dart';
import '../identity/add_copy_request_store.dart';
import '../identity/backtest_request_store.dart';
import '../identity/backtest_result_store.dart';
import '../models/backtest_row.dart';
import '../identity/add_copy_result_store.dart';
import '../identity/manual_copy_pending_order_store.dart';
import '../identity/copy_position_store.dart';
import '../identity/favorite_pair_store.dart';
import '../platform/windows_memory.dart';
import '../identity/ignited_pair_store.dart';
import '../identity/terminate_request_store.dart';
import '../identity/trade_volume_store.dart';
import '../identity/unpause_check_request_store.dart';
import '../identity/waiting_reason_store.dart';
import '../identity/widen_applied_store.dart';
import '../identity/worm10_entry_signal_store.dart';
import '../identity/worm10_pending_signal_store.dart';
import '../logging/app_logger.dart';
import '../models/account_snapshot.dart';
import '../models/app_config.dart';
import '../models/auto_category.dart';
import '../models/bot_history_entry.dart';
import '../models/decision_technique.dart';
import '../models/engine_status.dart';
import '../models/power_health.dart';
import '../models/range_result.dart';
import '../models/signal.dart';
import '../models/trade_direction.dart';
import '../mt5/mt5_client.dart';
import '../mt5/mt5_launcher.dart';
import '../net/connectivity.dart';
import '../risk/risk_gate.dart';
import '../technique/liquidation.dart';
import '../technique/zigzag_range.dart';
import '../tradingview/cdp_client.dart';
import '../tradingview/chart_state.dart';
import '../tradingview/enforce.dart';
import '../tradingview/launch.dart';
import '../tradingview/signals_reader.dart';
import 'sl_ratchet_ladder.dart';
import 'worm10_decision.dart';

/// Thrown by [EngineService._ensureCdpUpImpl] when TradingView genuinely
/// isn't installed at the configured path (2026-10-07, per the user: "app
/// need to be smart... need to show a dialog") - distinct from every other
/// exception that path can throw so the health-check's catch block (see
/// [EngineService._runHealthCheck]) can tell "not installed" apart from a
/// genuine connection/launch problem and surface the right
/// [PowerHealthState] for each.
class TradingViewNotInstalledException implements Exception {
  const TradingViewNotInstalledException(this.binaryPath);
  final String binaryPath;

  @override
  String toString() => 'TradingView is not installed at $binaryPath';
}

/// Plain result record for [EngineService._computeTargetLevels] — see its
/// own doc comment for why this is shared between placing a fresh order
/// and checking whether an already-resting one has gone stale.
class _TargetLevels {
  const _TargetLevels({
    required this.info,
    required this.entry,
    required this.bid,
    required this.ask,
    required this.digits,
    required this.sl,
    required this.tp,
    required this.widenApplied,
  });

  final Map<String, dynamic> info;
  final double entry;
  final double bid;
  final double ask;
  final int digits;
  final double sl;
  final double tp;
  final bool widenApplied;
}

/// The app brain — reads TradingView's signal for each configured symbol,
/// computes a range-based TP/SL, and opens/closes MT5 positions via the
/// native MCP server. This is a real, wired-up v1, not a stub — but see
/// GAPS.md for what's deliberately simplified relative to tradingPionex's
/// battle-hardened engine_service.dart (retry ladders, watchdog timers,
/// sleep/awake health recovery are NOT ported yet).
///
/// Per the user's explicit spec (2026-09-17): no investment/margin sizing —
/// every open uses the symbol's own MT5-reported minimum volume. TP/SL use
/// the 60/40 range model (data/technique/liquidation.dart), identical to
/// tradingPionex's ORIGINAL model, not the later Pionex-liquidation-price
/// variant (see ARCHITECTURE.md for why). Once a position is open with
/// SL/TP set on the MT5 order itself, the engine additionally closes it
/// early on a signal-flip (mirroring tradingPionex's opposite-signal exit).
class EngineService {
  EngineService({
    required this.config,
    required this.storage,
    required this.logger,
  }) {
    risk = RiskGate(storage, config.risk);
    mt5 = _buildMt5Client();
    openPositions = OpenPositionStore(storage);
    botCategories = BotCategoryStore(storage);
    entrySignals = EntrySignalStore(storage);
    retired = RetiredStore(storage);
    lastTag = LastTagStore(storage);
    terminateRequests = TerminateRequestStore(storage);
    addCopyRequests = AddCopyRequestStore(storage);
    addCopyResults = AddCopyResultStore(storage);
    manualCopyPendingOrders = ManualCopyPendingOrderStore(storage);
    copyPositions = CopyPositionStore(storage);
    backtestRequests = BacktestRequestStore(storage);
    backtestResults = BacktestResultStore(storage);
    ignitedPairs = IgnitedPairStore(storage);
    favoritePairs = FavoritePairStore(storage);
    waitingReasons = WaitingReasonStore(storage);
    lastCheckedStore = LastCheckedStore(storage);
    pendingSignals = PendingSignalStore(storage);
    tradeVolumes = TradeVolumeStore(storage);
    widenApplied = WidenAppliedStore(storage);
    firstOpen = FirstOpenStore(storage);
    newPairWait = NewPairWaitStore(storage);
    supertrendPending = SupertrendPendingStore(storage);
    paused = PausedPairStore(storage);
    unpauseRequests = UnpauseCheckRequestStore(storage);
    symbolResolve = SymbolResolveStore(storage);
    slRatchet = SlRatchetStore(storage);
    autoCopyMilestones = AutoCopyMilestoneStore(storage);
    baselineStopStrikes = BaselineStopStrikeStore(storage);
    worm10Pending = Worm10PendingSignalStore(storage);
    worm10EntrySignals = Worm10EntrySignalStore(storage);
    // Backfill [firstOpen] from every past trade this app has ever closed,
    // so the new "wait for a confirmed opposite signal before a pair's
    // first-ever entry" gate (2026-10-06, per the user) only applies to
    // pairs added AFTER this feature shipped - every symbol/category with
    // real prior history is immediately treated as already-seasoned, never
    // retroactively held up. Currently-OPEN positions that haven't closed
    // yet (so have no bot-history entry) are covered separately, the
    // moment [_findAppPosition] sees them each cycle - see its own call to
    // [firstOpen.markOpened].
    for (final entry in storage.readJsonl(storage.botHistoryFile)) {
      final tvSymbol = entry['tradingview_symbol'] as String?;
      final categoryWire = entry['category'] as String?;
      if (tvSymbol == null || categoryWire == null) continue;
      firstOpen.markOpened('$categoryWire|$tvSymbol');
    }
    autoManagedByCategory = {
      for (final c in allAutoCategories)
        c: AutoManagedStore(storage, filePath: storage.autoManagedBasesFileFor(c)),
    };
    // Bootstrap: every configured symbol is auto-managed under every
    // category by default, but ONLY on that category's true first-ever run
    // (its auto-managed-bases file not existing yet) — no GUI opt-in/opt-out
    // flow exists yet (see GAPS.md). Fixed 2026-09-28, per the user: this
    // used to run unconditionally on EVERY engine start, so removing a
    // symbol from auto-managed (e.g. "remove closed bots from auto") kept
    // silently reverting on the next routine restart as long as its mapping
    // was still sitting in config.json — confirmed live when SOL/TRX both
    // came back after a restart done minutes after removing them. A symbol
    // still needs a config.json mapping to ever be addable, but whether it's
    // CURRENTLY auto-managed is now solely up to auto-managed-bases.json,
    // undisturbed by restarts once that file exists at all.
    for (final entry in autoManagedByCategory.entries) {
      final file = File(storage.autoManagedBasesFileFor(entry.key));
      if (file.existsSync()) continue;
      for (final mapping in config.symbols) {
        entry.value.addBase(mapping.tradingViewSymbol);
      }
    }
  }

  final AppConfig config;
  final CoreStorage storage;
  final AppLogger logger;
  late final RiskGate risk;

  /// Mutable (not `late final`) — see [_runHealthCheck]: rebuilt on a
  /// failed `connect()` so a stale, pooled `http.Client` connection left
  /// over from before MT5 restarted never keeps retrying against a dead
  /// socket forever. Confirmed live 2026-09-20: after MT5's process was
  /// replaced (window stayed up, but the underlying terminal64.exe pid
  /// changed), the OLD client kept getting HTTP 404 on every single
  /// `initialize` call indefinitely, while a fresh `Mt5Client`/`http.Client`
  /// connected on the very first try — only restarting the whole engine
  /// process "fixed" it before this fix, which defeats the point of an
  /// automatic health check.
  late Mt5Client mt5;

  Mt5Client _buildMt5Client() {
    final env = storage.readEnvFile();
    return Mt5Client(
      apiKey: env['MT5_MCP_API_KEY'] ?? '',
      host: config.mt5.mcpHost,
      port: config.mt5.mcpPort,
      onLog: logger.log,
    );
  }
  late final OpenPositionStore openPositions;
  late final BotCategoryStore botCategories;
  late final EntrySignalStore entrySignals;
  late final RetiredStore retired;
  late final LastTagStore lastTag;
  late final TerminateRequestStore terminateRequests;
  late final AddCopyRequestStore addCopyRequests;
  late final AddCopyResultStore addCopyResults;
  late final ManualCopyPendingOrderStore manualCopyPendingOrders;
  late final CopyPositionStore copyPositions;
  late final IgnitedPairStore ignitedPairs;
  late final FavoritePairStore favoritePairs;
  late final BacktestRequestStore backtestRequests;
  late final BacktestResultStore backtestResults;
  late final WaitingReasonStore waitingReasons;
  late final LastCheckedStore lastCheckedStore;
  late final PendingSignalStore pendingSignals;
  late final TradeVolumeStore tradeVolumes;
  late final FirstOpenStore firstOpen;
  late final NewPairWaitStore newPairWait;
  late final SupertrendPendingStore supertrendPending;
  late final PausedPairStore paused;
  late final UnpauseCheckRequestStore unpauseRequests;
  late final SymbolResolveStore symbolResolve;
  late final SlRatchetStore slRatchet;
  late final AutoCopyMilestoneStore autoCopyMilestones;
  late final BaselineStopStrikeStore baselineStopStrikes;
  late final Worm10PendingSignalStore worm10Pending;
  late final Worm10EntrySignalStore worm10EntrySignals;

  /// Tickets the retroactive direction audit has already checked since the
  /// last time it was forced to re-run - in-memory only, see the audit's
  /// own doc comment in [_checkOneSymbol] for why persistence isn't needed.
  /// Originally cleared only on a fresh process start (2026-09-30); now ALSO
  /// cleared on every GUI stale→fresh transition (see [_guiWasOpen]), per
  /// the user (2026-10-05): "in each gui close & then reopen, app need to
  /// check current running trades by doing the reverse practice we already
  /// discussed it ... decision will be according to start, update, close a,
  /// close b signals" - re-running the full audit against every currently
  /// running ticket is exactly that reverse-reading practice.
  final Set<int> _auditedTickets = {};

  /// When [_auditedTickets] was last actually cleared, by ANY of its three
  /// independent triggers (GUI reopen, hourly pre-candle, internet
  /// recovery) - 2026-10-19, per the user: "if more than one case occures
  /// at same time, still one time reverse check will apply ... so app
  /// will not do duble reverse check". Each trigger has its own genuine,
  /// independent reason to want a fresh audit, but they're not mutually
  /// exclusive in time - e.g. the GUI reopening right as the hourly
  /// window opens, or internet recovering right as the GUI reopens after
  /// both being down together. Without this, two triggers landing close
  /// together but on separate cycles could each clear the cache and each
  /// cause their own full audit for the same ticket - see
  /// [_clearAuditCache]'s own doc comment for how this coalesces that
  /// into one.
  DateTime? _lastAuditCacheClearAt;

  /// How close together two of [_auditedTickets]'s clear triggers have to
  /// land to count as "the same occurrence" rather than two genuinely
  /// separate ones - generous enough to cover any realistic overlap
  /// between the GUI/hourly/internet triggers (none of which fire more
  /// than once within many seconds of each other under normal operation),
  /// short enough to never meaningfully delay a trigger that's actually
  /// unrelated to a recent one.
  static const _auditCacheClearDebounce = Duration(minutes: 2);

  /// Shared by all three blanket clear triggers (GUI reopen, hourly pre-
  /// candle, internet recovery) - the per-ticket unpause force
  /// ([_processAllPendingUnpauseChecks]'s own `.remove()`) is a
  /// deliberate single-pair user action, not a passive environmental
  /// re-arm, and stays independent of this debounce on purpose. See
  /// [_lastAuditCacheClearAt]'s own doc comment for why this exists.
  void _clearAuditCache(String reason) {
    final now = DateTime.now();
    if (_lastAuditCacheClearAt != null && now.difference(_lastAuditCacheClearAt!) < _auditCacheClearDebounce) {
      logger.log(
        '$reason - retroactive audit cache was already cleared '
        '${now.difference(_lastAuditCacheClearAt!).inSeconds}s ago by '
        'another trigger; not clearing again for the same occurrence.',
      );
      return;
    }
    logger.log('$reason - clearing the retroactive audit cache to re-check every running ticket against the full signal history.');
    _auditedTickets.clear();
    _lastAuditCacheClearAt = now;
  }

  /// The UTC epoch-hour [_auditedTickets] was last cleared for the hourly
  /// pre-candle re-arm below (2026-10-06, per the user: agreed to re-run
  /// the retroactive audit every 1H cycle, not just on a GUI reopen) - null
  /// until the first hour this process has been alive for crosses the
  /// trigger window. Guards against clearing on every tick while inside
  /// that window; only once per hour.
  int? _lastHourlyAuditEpochHour;

  /// How far before the next hourly candle the re-arm above fires
  /// (2026-10-06, per the user: "45 min after current cycle start" of a 1H
  /// candle, i.e. 15 min before the next one) - early enough that the
  /// audit (and whatever recycle/close-reopen it decides) has time to
  /// finish well before the new candle, so "once 1H new cycle occurs,
  /// everything is assured healthy" actually holds.
  static const _hourlyAuditLeadTime = Duration(minutes: 15);
  late final WidenAppliedStore widenApplied;
  late final Map<AutoCategory, AutoManagedStore> autoManagedByCategory;

  CdpClient? _cdp;
  bool _mt5Connected = false;

  /// In-memory only (see GAPS.md): when this engine last actually READ a
  /// "category|tvSymbol" key's chart, gating the whole expensive
  /// TradingView read (up to ~40s across two triple-read confirmations) -
  /// checked BEFORE any chart work happens, not after. Added 2026-09-28
  /// ("link only need to be checked every 3 min") to skip the read
  /// entirely while nothing is filled yet (a still-resting pending order
  /// and a fully failed attempt are treated the same - keep trying every
  /// [_retryCooldown]). Originally also applied a 1-hour cooldown to
  /// already-filled positions ("others every 1h becuse others are already
  /// filled and running") - REMOVED 2026-09-29, per the user ("once you
  /// see the signal ... do action" / "for fucking what????" - confirmed
  /// live: SHIBUSD showed a real HH against a running LL/buy position and
  /// the app couldn't even look again for up to an hour). Every symbol,
  /// filled or not, now uses the same [_retryCooldown]. Losing this on
  /// restart just means one immediate re-check right after restart for
  /// every symbol — not a safety issue, since OpenPositionStore +
  /// RiskGate.maxPerSymbol are what actually prevent a duplicate
  /// open/close, not this gate.
  final Map<String, DateTime> _lastCheckedAt = {};

  static const _retryCooldown = Duration(minutes: 3);

  /// Hard ceiling on the whole TradingView-readiness step in
  /// [_runHealthCheck] (2026-10-05) — see the call site for why.
  static const _tradingViewCheckDeadline = Duration(seconds: 30);


  bool _stopRequested = false;

  /// Whether the GUI was open as of the LAST tick — compared against
  /// [_isGuiOpen] each iteration purely to detect the stale→fresh edge (GUI
  /// just reopened) so [_auditedTickets] gets cleared exactly once per
  /// reopen, not on every tick while it stays open. Starts false: on a
  /// fresh process start, this process should only ever be running because
  /// the GUI already started it (see [run]'s own doc comment) — if the
  /// GUI's heartbeat ISN'T fresh on that very first tick, something started
  /// this process without the GUI's involvement, and [run] stops it
  /// immediately rather than ever reaching real TradingView/MT5 work.
  bool _guiWasOpen = false;

  /// How old [CoreStorage.guiHeartbeatFile] can be before the GUI is
  /// considered closed (2026-10-05, per the user: "make engine stop if gui
  /// is stopped ... trading view/mt5 should not launch unless user open
  /// gui"). The GUI touches this file every 5s (see lib/main.dart); this
  /// threshold gives a few missed ticks of slack (a GC pause, a slow
  /// cycle on the GUI's isolate) before concluding it's actually gone,
  /// while still catching a real close within one short multiple of the
  /// engine's own [AppConfig.pollIntervalSec] poll.
  static const _guiStaleThreshold = Duration(seconds: 20);

  /// See [_guiStaleThreshold]. A missing file (GUI never opened since this
  /// engine process started, e.g. right after a fresh boot) counts as
  /// closed, not open — there is nothing to be stale relative to yet.
  bool _isGuiOpen() {
    final file = File(storage.guiHeartbeatFile);
    if (!file.existsSync()) return false;
    final age = DateTime.now().difference(file.statSync().modified);
    return age < _guiStaleThreshold;
  }

  /// The last health result this "Power on" session produced — reset to
  /// [PowerHealthState.off] whenever Power goes off, so the very next
  /// switch-on writes exactly one [PowerHealthState.checking] tick before
  /// the real check result lands (see `run()`). Never re-shown on later
  /// cycles while Power stays on, so continuous re-checking doesn't blink
  /// the toggle on every poll.
  PowerHealthState _lastHealth = PowerHealthState.off;

  /// When [run] started - gates [_reconcileClosedPositions] for
  /// [_reconcileGracePeriod] after startup. Added 2026-09-29 after a real
  /// live incident: on two consecutive restarts, MT5's own
  /// `get_trading_open_positions` response was unreliable for LONGER than
  /// the 3-second confirmation re-read reconciliation had just been given -
  /// it returned every single tracked position as "vanished" on both the
  /// first AND the retry read, both times, right at startup only (never
  /// during steady-state operation, where reconciliation has worked
  /// correctly all session). Rather than guess a longer read-retry gap
  /// that might still not be enough, reconciliation simply doesn't run at
  /// all until MT5's connection has had real time to settle after a fresh
  /// restart - a position that's genuinely closed while the engine is
  /// mid-restart just gets reconciled a little later, once the grace
  /// period ends, instead of risking every open position being wrongly
  /// forgotten (and the normal per-symbol loop opening a duplicate/
  /// conflicting position on top of each one, as actually happened to
  /// AAVE).
  late final DateTime _startedAt = DateTime.now();
  static const _reconcileGracePeriod = Duration(seconds: 90);

  /// Power-toggle mandatory health check cadence (2026-09-30, per the
  /// user: "power toggle button once it is clicked on, it should
  /// (mandatory) check connection with mt5 and connection with trading
  /// view and if both are open and if two indicators are viewed. this
  /// cycle should run every 5 seconds") - the OUTER loop in [run] already
  /// re-checks health once per iteration, but each iteration also runs a
  /// full [_runCycle] sweep through every auto-managed symbol, which can
  /// take minutes - meaning health was really only re-verified once per
  /// multi-minute sweep, not every 5s. [_maybeRunHealthCheck] re-checks
  /// opportunistically at the same natural per-symbol boundary already
  /// used for instant terminate-request handling, closing that gap. This
  /// stays fully SEQUENTIAL (just awaited more frequently at a clean
  /// boundary, never concurrently with any other MT5/CDP call in flight) -
  /// a genuinely concurrent second connection was deliberately avoided
  /// elsewhere this session for the same reason.
  DateTime _lastHealthCheckAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _healthCheckInterval = Duration(seconds: 5);

  /// Returns false (meaning: abort the rest of this cycle sweep) when a
  /// check actually ran and came back unhealthy - the outer loop in [run]
  /// will naturally retry via its own next health check before starting a
  /// new sweep. Returns true otherwise (either genuinely healthy, or not
  /// yet due for a recheck) so the caller keeps going.
  Future<bool> _maybeRunHealthCheck() async {
    if (DateTime.now().difference(_lastHealthCheckAt) < _healthCheckInterval) {
      return true;
    }
    _lastHealthCheckAt = DateTime.now();
    final health = await _runHealthCheck();
    if (health != PowerHealthState.ready) {
      logger.log(
        'Mandatory 5s health recheck failed mid-cycle ($health) - aborting '
        'the rest of this sweep.',
        level: 'ERROR',
      );
      return false;
    }
    return true;
  }

  /// SL ratchet sweep cadence (2026-10-13, per the user). No need for
  /// anything close to [_healthCheckInterval]'s 5s - this is a protective
  /// safety net against a trade giving back profit, not a time-critical
  /// signal read, and it's genuinely pure MT5 (see [_applySlRatchet]'s own
  /// doc comment for why this never touches TradingView/CDP at all) so
  /// there's no chart-contention reason to run it any faster either. 30s
  /// still reacts well within the kind of multi-minute reversal swings the
  /// real trade-history study behind this feature found.
  DateTime _lastSlRatchetAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _slRatchetInterval = Duration(seconds: 30);

  Future<void> _maybeApplySlRatchet() async {
    if (DateTime.now().difference(_lastSlRatchetAt) < _slRatchetInterval) {
      return;
    }
    _lastSlRatchetAt = DateTime.now();
    try {
      await _applySlRatchet();
    } catch (e, st) {
      logger.log('SL ratchet sweep failed: $e\n$st', level: 'ERROR');
    }
  }

  /// Tightening-only stop-loss ladder (2026-10-13, per the user - see
  /// [highestSlRatchetThresholdCrossed]'s own doc comment for the real
  /// trade-history study behind the specific thresholds). Deliberately pure
  /// MT5 - unlike every other per-cycle check in this file, this never
  /// touches TradingView/CDP at all (just live P&L% + a stop-loss
  /// modification, both plain MT5 MCP calls), so unlike
  /// [_processAllPendingSymbolResolveRequests] there's no single-shared-
  /// chart reason this couldn't safely run concurrently with anything else
  /// - it's still just awaited sequentially here for the same
  /// keep-it-simple reasoning as everything else in this engine, not
  /// because it has to be.
  ///
  /// Scope: every OPEN position whose MT5 symbol maps to a currently
  /// auto-managed, non-retired, non-paused base - mirrors exactly what
  /// [_runCycle]'s own main loop already skips, so a paused pair's running
  /// trade is left completely untouched by this too, consistent with
  /// "paused means no action at all." A manually-opened MT5 position on a
  /// symbol this app doesn't manage is never touched.
  Future<void> _applySlRatchet() async {
    final symbols = _loadSymbolsFresh();
    final tvByMt5Symbol = {
      for (final m in symbols) m.mt5Symbol.toUpperCase(): m.tradingViewSymbol,
    };
    final autoManaged = autoManagedByCategory[AutoCategory.oneHour]!;

    final positionsResult = await mt5.getOpenPositions();
    final positions = ((positionsResult['positions'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();

    final stillOpenTickets = <int>{};
    for (final position in positions) {
      final ticket = int.tryParse('${position['position_id']}');
      if (ticket != null) stillOpenTickets.add(ticket);
    }
    // Always prune, even with zero open positions right now - a position
    // that closed since the last sweep should have its old rung state
    // dropped immediately, not linger until the next time something else
    // happens to be open.
    slRatchet.pruneClosed(stillOpenTickets);
    if (positions.isEmpty) return;

    // Bulk-fetched once per sweep (not per position) for contract size and
    // quote-precision digits - the same live catalog data
    // [AutoTradeRow.pnlPercent] already reads on the GUI side.
    final watchedBySymbol = {
      for (final w in await mt5.getWatchedSymbols())
        (w['symbol'] as String).toUpperCase(): w,
    };

    for (final position in positions) {
      final ticket = int.tryParse('${position['position_id']}');
      final mt5Symbol = position['symbol'] as String?;
      if (ticket == null || mt5Symbol == null) continue;

      final tvSymbol = tvByMt5Symbol[mt5Symbol.toUpperCase()];
      if (tvSymbol == null) continue;
      if (!autoManaged.isAutoManaged(tvSymbol)) continue;
      if (retired.isRetiredBase(tvSymbol)) continue;
      if (paused.isPaused(tvSymbol)) continue;
      // 2026-10-16, per the user: "engine does not require to check any
      // copy trade" - this ratchet progression (+5%/+10%/...) is about
      // the PARENT's own profit-lock journey; applying it to a copy as
      // well would tighten/override a copy's own deliberately fixed -$1
      // SL for no reason, since a copy is never meant to ratchet at all.
      if (copyPositions.isCopy(ticket)) continue;

      final profit = (position['profit'] as num?)?.toDouble();
      final priceOpen = (position['price_open'] as num?)?.toDouble();
      final volume = (position['volume'] as num?)?.toDouble();
      final direction = position['action'] as String?;
      if (profit == null || priceOpen == null || volume == null || direction == null) {
        continue;
      }

      final watched = watchedBySymbol[mt5Symbol.toUpperCase()];
      final contractSize = (watched?['contract_size'] as num?)?.toDouble() ?? 1.0;
      final notional = volume * contractSize * priceOpen;
      if (notional == 0) continue;
      final pnlPercent = profit / notional * 100;

      // 2026-10-17 REDESIGN, per the user: "tp/sl should be fixed
      // according to 40/60 rules... app should take an action according
      // to P&L.. but not modifying tp/sl" / "sll rules applied and
      // checked every 30 sec not by modifying tp/sl" - replaces BOTH the
      // former baseline-SL-modification block and the ratchet's own SL
      // modification below. The real MT5 SL/TP are now the 60/40 model's
      // levels, set once at open and never touched again by this sweep -
      // instead, this directly CLOSES the position once live P&L crosses
      // whatever the SLL ladder currently says: flat -$5 before any rung
      // has locked, or the locked rung's own percent afterward. Accepted
      // trade-off, confirmed with the user: this protection now only
      // applies while the engine is actively running - the original wide
      // 60/40 SL/TP still sit on MT5 as the one remaining broker-side
      // backstop if the engine itself is down.
      final existingThreshold = slRatchet.highestThreshold(ticket);
      if (existingThreshold == null) {
        if (profit <= -5) {
          try {
            await _closePosition(
              AutoCategory.oneHour,
              tvSymbol,
              mt5Symbol,
              position,
              stopReason: 'sll_baseline',
              detail: 'SLL: flat -\$5 baseline reached (live P&L \$${profit.toStringAsFixed(2)}).',
            );
            logger.log(
              'SLL: $tvSymbol ($mt5Symbol) closed at the -\$5 baseline '
              '(P&L \$${profit.toStringAsFixed(2)}).',
            );
          } catch (e) {
            logger.log(
              'SLL: failed to close $tvSymbol ($mt5Symbol) at the -\$5 baseline: $e',
              level: 'ERROR',
            );
          }
          continue;
        }
      } else {
        final lockPercent = slRatioForThreshold(existingThreshold);
        if (pnlPercent <= lockPercent) {
          try {
            await _closePosition(
              AutoCategory.oneHour,
              tvSymbol,
              mt5Symbol,
              position,
              stopReason: 'sll_ratchet',
              detail: 'SLL: locked +$existingThreshold% rung reached '
                  '(live P&L ${pnlPercent.toStringAsFixed(2)}%).',
            );
            logger.log(
              'SLL: $tvSymbol ($mt5Symbol) closed at its locked +$existingThreshold% '
              'rung (P&L ${pnlPercent.toStringAsFixed(2)}%).',
            );
          } catch (e) {
            logger.log(
              'SLL: failed to close $tvSymbol ($mt5Symbol) at its locked rung: $e',
              level: 'ERROR',
            );
          }
          continue;
        }
      }

      final newThreshold = highestSlRatchetThresholdCrossed(pnlPercent);
      if (newThreshold == null) continue;
      if (existingThreshold != null && newThreshold <= existingThreshold) continue;

      slRatchet.recordLock(ticket, newThreshold);
      logger.log(
        'SLL: $tvSymbol ($mt5Symbol) crossed +$newThreshold% P&L - locking in '
        '+${slRatioForThreshold(newThreshold).toStringAsFixed(0)}% (real TP/SL left untouched).',
      );
    }
  }

  /// One-time retroactive SL correction for positions already open when
  /// the 2026-10-17 SLL redesign shipped (2026-10-17, per the user:
  /// "modify all running trades and waiting trades accordingly"). Every
  /// position opened under the OLD architecture has its real SL sitting at
  /// whatever the old baseline/ratchet logic last set it to, not the 60/40
  /// model's own level - this restores it, ONCE, then never runs again
  /// (gated by [CoreStorage.sllMigrationDoneFile]).
  ///
  /// The true original range was never persisted (only the final SL PRICE
  /// was, and that's exactly what's wrong) - confirmed with the user this
  /// can't be exactly reconstructed, so this re-derives an honest SL fresh
  /// from [computeLiquidationLevels] using the position's own REAL entry
  /// price against the CURRENT live zigzag range, rather than guessing at
  /// history. Pending/waiting orders need no equivalent fix -
  /// [_reconcileStaleRestingOrderIfAny] already recomputes and replaces a
  /// stale resting order's SL/TP against the 60/40 model fresh on every
  /// single cycle, so they self-correct with no migration needed. Copies
  /// are skipped - their own -$1 baseline-at-open is a separate, unchanged
  /// mechanism, never the 60/40 model.
  Future<void> retroactiveFix6040SlOnce() async {
    if (storage.fileExists(storage.sllMigrationDoneFile)) return;
    try {
      await _ensureCdpUp();
      final cdp = _cdp!;
      final symbols = _loadSymbolsFresh();
      final tvByMt5Symbol = {
        for (final m in symbols) m.mt5Symbol.toUpperCase(): m.tradingViewSymbol,
      };
      final positionsResult = await mt5.getOpenPositions();
      final positions = ((positionsResult['positions'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      // Only mark this migration done once EVERY eligible position was
      // actually resolved (corrected, or already correct) - never on a
      // partial pass. Found live: right after a fresh engine/TradingView
      // restart, the chart can still be mid-warm-up for several minutes,
      // so an early position in the loop can get skipped for "no live
      // range" purely from bad timing - that must retry next cycle, not
      // get silently treated as permanently done just because later
      // positions in the same pass happened to succeed.
      var anySkipped = false;
      for (final position in positions) {
        final ticket = _parseTicket(position['position_id']);
        final mt5Symbol = position['symbol'] as String?;
        if (ticket == null || mt5Symbol == null) continue;
        final tvSymbol = tvByMt5Symbol[mt5Symbol.toUpperCase()];
        if (tvSymbol == null) continue;
        if (copyPositions.isCopy(ticket)) continue;
        final direction = (position['action'] as String?) == 'sell' ? TradeDirection.short : TradeDirection.long;
        final priceOpen = (position['price_open'] as num?)?.toDouble();
        final currentSl = (position['stop_loss'] as num?)?.toDouble();
        if (priceOpen == null) continue;

        // 2026-10-17 bugfix: was missing the worm10Script scriptIdPart
        // override (see [_readConfirmedRange]'s own doc comment) - without
        // it, this defaulted to customScripts[0] (worm_9_26/MSB), which
        // isn't even attached to the chart under the worm10 technique
        // (only worm_10_26 + spy_9_26 are, per the free-account 2-
        // indicator limit) - this read was searching for a script that
        // was never on the chart, guaranteed to fail every single time
        // regardless of history or TradingView readiness.
        final range = await _readConfirmedRange(
          cdp,
          AutoCategory.oneHour,
          tvSymbol,
          immediate: true,
          scriptIdPart: worm10Script.scriptIdPart,
        );
        if (range == null) {
          logger.log(
            'SLL MIGRATION: no live range for $tvSymbol ($mt5Symbol) yet - '
            'will retry this pair next cycle.',
            level: 'WARNING',
          );
          anySkipped = true;
          continue;
        }
        try {
          final levels = computeLiquidationLevels(
            top: range.top,
            bottom: range.bottom,
            entry: priceOpen,
            direction: direction,
          );
          final symbolInfoResult = await mt5.getMarketWatchSymbol(mt5Symbol);
          final infoList = (symbolInfoResult['symbols'] as List?) ?? const [];
          final digits = infoList.isNotEmpty
              ? ((infoList.first as Map<String, dynamic>)['digits'] as num?)?.toInt() ?? 5
              : 5;
          final newSl = _roundToDigits(levels.stopLossPrice, digits);
          if (currentSl == newSl) continue;
          await mt5.modifyStopLossTakeProfit(symbol: mt5Symbol, positionTicket: ticket, sl: newSl);
          logger.log(
            'SLL MIGRATION: $tvSymbol ($mt5Symbol) ticket=$ticket SL restored to '
            'the 60/40 model: $newSl (was $currentSl).',
          );
        } catch (e) {
          logger.log('SLL MIGRATION: failed for $tvSymbol ($mt5Symbol) ticket=$ticket: $e', level: 'ERROR');
          anySkipped = true;
        }
      }
      if (anySkipped) {
        logger.log('SLL MIGRATION: not all positions resolved this pass - will retry next cycle.', level: 'WARNING');
        return;
      }
    } catch (e, st) {
      logger.log('SLL MIGRATION: sweep failed, will retry next restart: $e\n$st', level: 'ERROR');
      return;
    }
    storage.writeString(storage.sllMigrationDoneFile, DateTime.now().toUtc().toIso8601String());
    logger.log('SLL MIGRATION: complete.');
  }

  /// Margin gate refresh cadence (2026-10-13, per the user). Same reasoning
  /// as [_slRatchetInterval] - a live safety check, not a time-critical
  /// signal read, and pure MT5 (account info + resting-order cancellation,
  /// no TradingView/CDP involved) so there's no chart-contention reason to
  /// run it any faster.
  DateTime _lastMarginCheckAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _marginCheckInterval = Duration(seconds: 30);
  bool _marginGateWasTripped = false;

  Future<void> _maybeRefreshMarginGate() async {
    if (DateTime.now().difference(_lastMarginCheckAt) < _marginCheckInterval) {
      return;
    }
    _lastMarginCheckAt = DateTime.now();
    try {
      final info = await mt5.getAccountInfo();
      final account = info['account'] as Map<String, dynamic>?;
      final equity = (account?['equity'] as num?)?.toDouble();
      final margin = (account?['margin'] as num?)?.toDouble();
      // Same null-when-no-exposure rule as the Dashboard's own
      // AccountSnapshot.marginLevel - margin == 0 means nothing is
      // currently at risk, so there's nothing for this gate to protect
      // against yet.
      final marginLevel = (equity != null && margin != null && margin > 0)
          ? equity / margin * 100
          : null;
      risk.updateMarginLevel(marginLevel);

      final isTripped = risk.marginGateTripped;
      if (isTripped && !_marginGateWasTripped) {
        logger.log(
          'MARGIN GATE: margin level ${marginLevel!.toStringAsFixed(1)}% <= '
          '${RiskGate.marginGateThresholdPct}% - blocking new opens and '
          'cancelling every resting (not-yet-triggered) pending order this '
          'app placed.',
          level: 'WARNING',
        );
      } else if (!isTripped && _marginGateWasTripped) {
        logger.log(
          'MARGIN GATE: margin level recovered to '
          '${marginLevel?.toStringAsFixed(1)}% - normal opens resume.',
        );
      }
      _marginGateWasTripped = isTripped;

      if (isTripped) {
        await _cancelAllRestingPendingOrders();
      }
    } catch (e, st) {
      logger.log('Margin gate refresh failed: $e\n$st', level: 'ERROR');
    }
  }

  /// Cancels every resting (placed but not yet triggered) pending order
  /// this app itself opened, across every auto category - called only
  /// while [RiskGate.marginGateTripped] is true (2026-10-13, per the user:
  /// "if there is a current trade filled and not yet triggered, app will
  /// delete the fill and keep it on waiting not filled... because if any
  /// waiting filled (non-triggered) pair is triggered, then margin will
  /// become more lower than 150%"). Deliberately only cancels ORDERS, never
  /// touches an already-triggered, genuinely open POSITION - this gate
  /// stops NEW exposure from being added, it never closes anything live.
  Future<void> _cancelAllRestingPendingOrders() async {
    // Keep this store from growing unbounded (2026-10-15) - see
    // [ManualCopyPendingOrderStore.pruneOlderThan]'s own doc comment.
    manualCopyPendingOrders.pruneOlderThan(const Duration(minutes: 10));
    final result = await mt5.getOpenPositions();
    final orders = ((result['orders'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    for (final category in allAutoCategories) {
      final tag = 'trading_mt5 ${category.wireValue}';
      for (final order in orders) {
        if (order['comment'] != tag || order['state'] != 'placed') continue;
        final symbol = order['symbol'] as String?;
        final orderTicket = _parseTicket(order['order_id']);
        if (symbol == null || orderTicket == null) continue;
        // 2026-10-15, per the user: "manual copies done by user: has
        // nothing to do with margin level" - a manual copy's own pending
        // fallback order is exempt from this sweep for as long as it's
        // genuinely still pending (confirmed live: ticket 1660701907 on
        // LTCUSD.lv was cancelled this exact way at 92.9% margin before
        // this exemption existed).
        if (manualCopyPendingOrders.isPending(orderTicket)) {
          logger.log(
            'MARGIN GATE: leaving resting pending order $orderTicket ($symbol) alone - '
            'it\'s a manual copy, exempt from margin-level cancellation.',
          );
          continue;
        }
        try {
          final deleteResult = await mt5.deleteOrder(symbol: symbol, orderTicket: orderTicket);
          final retcode = (deleteResult['retcode'] as num?)?.toInt();
          if (retcode != null && retcode != 10009) {
            logger.log(
              'MARGIN GATE: failed to cancel resting order $orderTicket '
              '($symbol, retcode=$retcode) - will retry next sweep.',
              level: 'ERROR',
            );
            continue;
          }
          logger.log(
            'MARGIN GATE: cancelled resting pending order $orderTicket '
            '($symbol) - margin level too low to let it trigger.',
          );
        } catch (e) {
          logger.log(
            'MARGIN GATE: failed to cancel resting order $orderTicket '
            '($symbol): $e',
            level: 'ERROR',
          );
        }
      }
    }
  }

  Future<void> run() async {
    _startedAt; // force initialization now, not lazily on first read
    logger.log('Engine starting.');
    // Replaced 2026-10-05, per the user's new spec ("make app closing
    // engine instantly once power toggle off and once gui closed... once
    // user toggle power on, app will launch the engine"): Power is no
    // longer a PAUSE file this already-running process polls - it's now
    // whether this OS process exists at all. The GUI starts this process
    // (`systemctl --user start`) when the user flips Power on, and stops
    // it (`systemctl --user stop`, sending SIGTERM - see bin/engine.dart's
    // signal handlers) when they flip it off OR the GUI itself closes for
    // any reason. So by the time this loop is running at all, Power is
    // implicitly on - every iteration goes straight to a real health check
    // and cycle, with no internal on/off gate to check any more. (Supersedes
    // the old PAUSE-file branch and the 2026-09-27 "Power persists across
    // restarts" revert note that used to live here - both described a model
    // that no longer exists.)

    while (!_stopRequested) {
      if (storage.fileExists(storage.stopFile)) {
        logger.log('STOP file present — shutting down.');
        break;
      }
      storage.touchFile(storage.heartbeatFile);

      // Outermost gate - 2026-10-05, per the user: "trading view/mt5
      // should not launch unless user open gui" AND "make app closing
      // engine instantly once ... gui closed (under any scenario: user
      // closed gui, machine restarted, etc.)". The GUI's own graceful
      // close handler already asks systemd to stop this process the
      // instant the window closes (fast path); this check is the
      // safety-net fallback for every UNGRACEFUL loss - a GUI crash, a
      // force-kill, or the machine restarting without a clean shutdown -
      // where nothing could signal this process directly. Once the GUI's
      // heartbeat goes stale, this process stops itself outright rather
      // than idling in place, since under the new model there is no
      // "Power on, GUI closed" state to idle through any more - see the
      // comment above [run].
      final guiOpen = _isGuiOpen();
      if (guiOpen != _guiWasOpen) {
        if (guiOpen) {
          _clearAuditCache('GUI: reopened — resuming');
        }
        _guiWasOpen = guiOpen;
      }
      if (!guiOpen) {
        logger.log(
          'GUI: closed (or never opened) — stopping the engine. Power '
          'stays off until the user reopens the GUI and turns it back on.',
        );
        break;
      }

      // Hourly pre-candle re-arm (2026-10-06, per the user, agreed) - the
      // retroactive audit above is otherwise only re-triggered by a GUI
      // reopen, so a position that's been running across several hourly
      // candles without the GUI ever closing would never get re-audited.
      // Firing once near the END of the current candle (not its start)
      // leaves the audit - and any close/reopen it decides on - time to
      // finish before the next candle begins. Guarded by epoch-hour so
      // this clears [_auditedTickets] exactly once per hour, not on every
      // tick inside the window.
      final epochHour = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 3600000;
      if (timeUntilNextHourlyCandle() <= _hourlyAuditLeadTime &&
          _lastHourlyAuditEpochHour != epochHour) {
        _clearAuditCache('Hourly pre-candle audit');
        _lastHourlyAuditEpochHour = epochHour;
      }

      // Just started (or just resumed from the GUI having been gone) —
      // surface "checking" right away rather than leaving the toggle on
      // its stale last state for however long the check run below takes.
      if (_lastHealth == PowerHealthState.off) {
        _writeStatus(
          health: PowerHealthState.checking,
          message: 'Checking connection…',
          connected: _mt5Connected,
        );
      }
      final health = await _runHealthCheck();
      _lastHealthCheckAt = DateTime.now();
      if (health == PowerHealthState.ready) {
        await _runCycle();
      }

      storage.deleteFileIfExists(storage.checknowFile);
      await Future<void>.delayed(Duration(seconds: config.pollIntervalSec));
    }
    _cdp?.close();
  }

  /// Layered Power health check (2026-09-20, per the user) — internet,
  /// then MT5, then TradingView/its two required indicators, in that
  /// dependency order (nothing past a failed step can meaningfully work).
  /// Runs every cycle for as long as Power stays on, not just once at
  /// switch-on, so a connection dropping later is reflected within one
  /// poll. Writes a status update BEFORE each step starts too (not just on
  /// failure/completion) — per the user: the status text must always name
  /// whichever specific step is running right now ("Checking internet",
  /// "Checking MT5 connection", "Launching MT5", "Checking TradingView
  /// connection", "Loading indicators"...), staying green/blinking
  /// ([PowerHealthState.checking]) through every one of those — color only
  /// changes to yellow/blue/orange on an actual failure of that step.
  /// Logs a line ONLY when the health state actually CHANGES since the last
  /// check (2026-10-03, per the user: "include in log trading view/mt5/
  /// internet connection/power down/everything") - logging every single
  /// check (every 5s while Power is on) would flood engine.log uselessly;
  /// a TRANSITION (internet lost/restored, MT5 down/up, TradingView down/
  /// up, or reaching/leaving fully ready) is the meaningful event worth a
  /// permanent record of. [_lastHealth] is the single source of truth for
  /// this comparison regardless of which call site ([run]'s own loop or
  /// [_maybeRunHealthCheck]'s mid-cycle recheck) triggered this run.
  PowerHealthState _finishHealthCheck(PowerHealthState state) {
    if (state != _lastHealth) {
      logger.log(
        'Health: ${_lastHealth.name} -> ${state.name}.',
        level: state == PowerHealthState.ready ? 'INFO' : 'ERROR',
      );
      // 2026-10-19, per the user, closing the one gap in the
      // retroactive-audit coverage table ("apply 5/5" - Power off/on,
      // app off/on, an engine restart under any cause, and pause/unpause
      // already guaranteed a full audit; recovering from a genuine
      // internet outage did not, since the engine process itself never
      // restarts and `_runCycle` simply resumes with whatever the audit
      // cache already held from before the outage). Internet coming back
      // now re-arms the cache too, same as every other "something was
      // down, now it's back" transition already does (GUI reopen, hourly
      // re-arm).
      if (_lastHealth == PowerHealthState.internetProblem && state == PowerHealthState.ready) {
        _clearAuditCache('Internet recovered');
      }
    }
    _lastHealth = state;
    return state;
  }

  Future<PowerHealthState> _runHealthCheck() async {
    _writeStatus(
      health: PowerHealthState.checking,
      message: 'Checking internet',
      connected: _mt5Connected,
    );
    if (!await hasInternetConnection()) {
      logger.log('No internet connection detected.', level: 'ERROR');
      _writeStatus(
        health: PowerHealthState.internetProblem,
        message: 'No internet connection.',
        connected: false,
      );
      return _finishHealthCheck(PowerHealthState.internetProblem);
    }

    _writeStatus(
      health: PowerHealthState.checking,
      message: 'Checking MT5 connection',
      connected: false,
    );
    if (!await isMt5Up(config.mt5.mcpHost, config.mt5.mcpPort)) {
      final mt5LaunchConfig = _mt5LaunchConfig();
      if (!await isMt5Installed(mt5LaunchConfig)) {
        logger.log(
          'Power check: MetaTrader 5 is not installed at '
          '${mt5LaunchConfig.terminalPath}${Platform.isWindows ? '' : ' (or Wine itself is missing)'}.',
          level: 'ERROR',
        );
        _writeStatus(
          health: PowerHealthState.mt5NotInstalled,
          message: 'MetaTrader 5 is not installed. Install it, then turn Power on again.',
          connected: false,
        );
        return _finishHealthCheck(PowerHealthState.mt5NotInstalled);
      }
      // 2026-10-18, per the user, after a real incident: closed the GUI
      // (and TradingView and MT5 themselves), reopened it with Power
      // still showing off, and found MT5 open anyway. Root cause: MT5 is
      // deliberately launched DETACHED (see [ensureMt5Running]'s own doc
      // comment - the engine never auto-kills a live broker session), so
      // an in-flight launch that started moments before a stop signal
      // arrives keeps running to completion with zero lifecycle tie back
      // to this process, outliving it even after a forced exit. This
      // can't be fully eliminated (once [ensureMt5Running] below is
      // actually called there's no way to un-launch it), but checking
      // [_stopRequested] right before STARTING a fresh launch closes the
      // much more common window - earlier steps this same cycle
      // iteration (internet check, status writes) give a real chance for
      // a stop signal to land before this point is even reached.
      if (_stopRequested) return _finishHealthCheck(_lastHealth);
      logger.log('Power check: MT5 not running — launching it.');
      _writeStatus(
        health: PowerHealthState.checking,
        message: 'Launching MT5',
        connected: false,
      );
      final launched = await ensureMt5Running(config.mt5.mcpHost, config.mt5.mcpPort, mt5LaunchConfig);
      if (!launched) {
        logger.log('MT5 did not come up after launch attempt.', level: 'ERROR');
        _writeStatus(
          health: PowerHealthState.mt5Problem,
          message: 'MT5 did not come up.',
          connected: false,
        );
        return _finishHealthCheck(PowerHealthState.mt5Problem);
      }
    }

    try {
      await mt5.connect();
      _mt5Connected = true;
    } catch (e) {
      logger.log('MT5 connection failed: $e', level: 'ERROR');
      // Rebuild with a fresh http.Client for the NEXT attempt — see the
      // doc comment on [mt5]. A failed connect is exactly the signal that
      // this client's pooled connection might be stale (e.g. MT5's process
      // was replaced underneath it), so never keep retrying the same one
      // forever.
      mt5.close();
      mt5 = _buildMt5Client();
      _writeStatus(
        health: PowerHealthState.mt5Problem,
        message: 'MT5 connect failed: $e',
        connected: false,
      );
      return _finishHealthCheck(PowerHealthState.mt5Problem);
    }

    _writeStatus(
      health: PowerHealthState.checking,
      message: 'Checking TradingView connection',
      connected: true,
    );
    try {
      // Hard outer deadline added 2026-10-05, per the user ("fix the bug so
      // the engine will never stuck for 5 min") - confirmed live that the
      // OLD 60s-per-request CDP timeout x connectToChart's 5 retries could
      // stack up to a genuine 5-minute stall here. The per-call timeouts
      // above were already shrunk (see CoreConstants.cdpRequestTimeout,
      // connectToChart's maxRetries, waitForChartApiReady's default) so
      // this should never actually fire in practice - it exists as a
      // guaranteed ceiling regardless of how those internals misbehave, so
      // a single bad TradingView attempt can never again block the whole
      // engine (and by extension the Power-off/GUI-closed reaction time)
      // for more than this long.
      await _ensureCdpUp().timeout(_tradingViewCheckDeadline);
    } catch (e) {
      if (e is TradingViewNotInstalledException) {
        logger.log('Power check: $e', level: 'ERROR');
        _writeStatus(
          health: PowerHealthState.tradingViewNotInstalled,
          message: 'TradingView is not installed. Install it, then turn Power on again.',
          connected: true,
        );
        return _finishHealthCheck(PowerHealthState.tradingViewNotInstalled);
      }
      logger.log('Power check: TradingView not ready: $e', level: 'ERROR');
      _writeStatus(
        health: PowerHealthState.tradingViewProblem,
        message: 'TradingView not ready: $e',
        connected: true,
      );
      return _finishHealthCheck(PowerHealthState.tradingViewProblem);
    }

    _writeStatus(health: PowerHealthState.ready, message: 'Ready', connected: true);
    return _finishHealthCheck(PowerHealthState.ready);
  }

  /// Catches a position closing WITHOUT the engine's own [_closePosition]
  /// ever running it — MT5 itself closes a position outright when its own
  /// SL/TP price is hit, and a human can close one directly in the
  /// terminal; neither goes through our code at all, so without this check
  /// those closes would just silently vanish from tracking with no history
  /// record (2026-09-27, per the user's history-record request: "closed by
  /// app/user/sl/tp/opposite signal" needs to cover ALL of these, not just
  /// the app's own opposite-signal path). Runs once per cycle, across every
  /// tracked ticket regardless of category, before the normal per-category
  /// loop below.
  Future<void> _reconcileClosedPositions() async {
    if (DateTime.now().difference(_startedAt) < _reconcileGracePeriod) return;

    final openResult = await mt5.getOpenPositions();
    final livePositions = (openResult['positions'] as List?) ?? const [];
    final stillOpen = livePositions
        .map((p) => _parseTicket((p as Map<String, dynamic>)['position_id']))
        .whereType<int>()
        .toSet();

    // Self-register any LIVE position carrying our own comment tag that
    // isn't tracked AT ALL yet (2026-10-16 - found live: NEARUSD.lv's
    // genuine app-opened copy, ticket 1660893666, was never registered in
    // [openPositions] - the normal self-heal for this lives in
    // [_findAppPosition], but that only runs per-symbol as part of the
    // regular check loop, so a straggler could sit unregistered for a
    // while depending on that symbol's own timing. Doing it here too,
    // unconditionally every cycle across every symbol, closes that gap
    // immediately rather than waiting on it.
    for (final p in livePositions.cast<Map<String, dynamic>>()) {
      final ticket = _parseTicket(p['position_id']);
      final mt5Symbol = p['symbol'] as String?;
      final comment = p['comment'] as String?;
      if (ticket == null || mt5Symbol == null || comment == null) continue;
      if (openPositions.isAppOpened(ticket)) continue;
      AutoCategory? category;
      for (final c in allAutoCategories) {
        if (comment == 'trading_mt5 ${c.wireValue}') {
          category = c;
          break;
        }
      }
      if (category == null) continue;
      openPositions.rememberPosition(ticket);
      botCategories.setCategory(ticket, category);
      risk.openPosition(mt5Symbol, category);
      logger.log(
        '$mt5Symbol ($category): found untracked position ticket=$ticket with our '
        'own comment tag during reconciliation - registering it now.',
      );
    }

    final tracked = openPositions.listAppPositions();
    if (tracked.isEmpty) return;

    // Rebuild RiskGate's open-position counts from live reality every
    // cycle, using [RiskGate.resetTo] - a self-heal method that already
    // existed in the code but nothing ever called. Added 2026-09-29 after
    // a real live incident: RiskGate's counters only ever move via
    // [risk.openPosition]/[risk.closePosition] calls in [_openPosition]/
    // [_closePosition], so ANY close that happens outside those exact
    // call sites (a manual cancel/close done directly in MT5 or via a
    // one-off script, this reconciliation function's own "no matching
    // history record" branch below, or any future code path this doesn't
    // anticipate) leaves the counter permanently too high with no way to
    // ever self-correct - confirmed live: AAVEUSD.lv showed 1 with zero
    // real positions, several other symbols showed 2 with only 1 real
    // position each, silently blocking every one of them from ever
    // opening again ("Max positions for X: 1/1") until manually fixed.
    // Rebuilding from the ground truth every cycle means drift from ANY
    // cause self-corrects within one cycle instead of accumulating
    // forever.
    final symbolByTicket = <int, String>{
      for (final p in livePositions.cast<Map<String, dynamic>>())
        if (_parseTicket(p['position_id']) != null)
          _parseTicket(p['position_id'])!: p['symbol'] as String? ?? '',
    };
    final liveRiskCounts = <String, int>{};
    for (final ticket in tracked) {
      if (!stillOpen.contains(ticket)) continue;
      final mt5Symbol = symbolByTicket[ticket];
      final category = botCategories.categoryOf(ticket);
      if (mt5Symbol == null || mt5Symbol.isEmpty || category == null) continue;
      final key = '$mt5Symbol|${category.wireValue}';
      liveRiskCounts[key] = (liveRiskCounts[key] ?? 0) + 1;
    }
    risk.resetTo(liveRiskCounts);

    // Backfill copy-tracking for a position that was already open BEFORE
    // [CopyPositionStore] existed (2026-10-16, per the user: "still sll
    // for copied trades -5$???" - a pre-existing copy never went through
    // [_openCopyPosition]'s own markCopy call, so it had no entry at all,
    // and the SLL/color fixes had nothing to go on for it). Same "lowest
    // ticket per symbol+category group = original" heuristic already
    // used for the Dashboard's own grouping/coloring - safe here
    // specifically because this only ever marks a ticket copy that isn't
    // ALREADY tracked, never un-marks anything, so it can't undo
    // [_openCopyPosition]'s own authoritative marking of a genuine
    // original that happens to share a group with an older copy.
    final symbolCategoryGroups = <String, List<int>>{};
    for (final ticket in tracked) {
      if (!stillOpen.contains(ticket)) continue;
      final mt5Symbol = symbolByTicket[ticket];
      final category = botCategories.categoryOf(ticket);
      if (mt5Symbol == null || mt5Symbol.isEmpty || category == null) continue;
      (symbolCategoryGroups['$mt5Symbol|${category.wireValue}'] ??= []).add(ticket);
    }
    for (final groupTickets in symbolCategoryGroups.values) {
      if (groupTickets.length < 2) continue;
      groupTickets.sort();
      for (final ticket in groupTickets.skip(1)) {
        if (!copyPositions.isCopy(ticket)) copyPositions.markCopy(ticket);
      }
    }

    var vanished = tracked.where((t) => !stillOpen.contains(t)).toList();
    if (vanished.isEmpty) return;

    // Confirmation re-read (2026-09-29, per a real live incident: AAVE's
    // still-genuinely-open position was declared "vanished" off a single
    // read right after an engine restart - MT5's own API response was
    // apparently incomplete/stale that one time - which forgot its
    // tracking and let the normal per-symbol loop open a second, opposite
    // position on top of it since it looked like nothing was running.
    // Every other live-data read in this app already requires agreement
    // across multiple reads before being trusted (TradingView's triple-read
    // rule); this was the one place that didn't. A single re-read 3s later
    // is enough here - unlike a genuinely flickering chart read, this is
    // just confirming a real API response, not converging on a moving
    // target.
    await Future<void>.delayed(const Duration(seconds: 3));
    final recheckResult = await mt5.getOpenPositions();
    final stillOpenRecheck = ((recheckResult['positions'] as List?) ?? const [])
        .map((p) => _parseTicket((p as Map<String, dynamic>)['position_id']))
        .whereType<int>()
        .toSet();
    vanished = vanished.where((t) => !stillOpenRecheck.contains(t)).toList();
    if (vanished.isEmpty) return;

    final historyResult = await mt5.getHistoryPositions();
    final history = (historyResult['positions'] as List?) ?? const [];
    // 2026-10-14, per the user's history-card request - same contract-size
    // lookup [_closePosition] added for an ACTIVE close, bulk-fetched once
    // here since this loop can close several vanished tickets in one pass.
    final contractSizeBySymbol = {
      for (final w in await mt5.getWatchedSymbols())
        (w['symbol'] as String).toUpperCase(): (w['contract_size'] as num?)?.toDouble() ?? 1.0,
    };
    for (final ticket in vanished) {
      final record = history.cast<Map<String, dynamic>?>().firstWhere(
        (h) => _parseTicket(h?['position_id']) == ticket,
        orElse: () => null,
      );
      final category = botCategories.categoryOf(ticket) ?? AutoCategory.oneHour;
      if (record == null) {
        // Genuinely can't explain this one — still forget it rather than
        // checking it forever, but say so loudly since this shouldn't
        // normally happen.
        logger.log(
          'Ticket=$ticket vanished from open positions but has no matching '
          'history record — forgetting tracking without a history entry.',
          level: 'ERROR',
        );
        openPositions.forgetPosition(ticket);
        botCategories.forget(ticket);
        widenApplied.forget(ticket);
        entrySignals.forget(ticket);
        worm10EntrySignals.forget(ticket);
        copyPositions.forget(ticket);
        continue;
      }

      final mt5Symbol = record['symbol'] as String? ?? '';
      final tvSymbol = config.symbols
          .firstWhere(
            (m) => m.mt5Symbol.toUpperCase() == mt5Symbol.toUpperCase(),
            orElse: () => SymbolMapping(tradingViewSymbol: mt5Symbol, mt5Symbol: mt5Symbol),
          )
          .tradingViewSymbol;
      final closePrice = (record['close_price'] as num?)?.toDouble();
      final stopLoss = (record['stop_loss'] as num?)?.toDouble();
      final takeProfit = (record['take_profit'] as num?)?.toDouble();
      // MT5's own `close_reason` field on the history record is the real,
      // authoritative answer - prefer it directly over guessing from price
      // proximity. Confirmed live, 2026-10-15, per the user ("i did not
      // close any... it was all closed by mt5 itself reaching liquidation
      // price"): the OLD price-proximity-only guess mislabeled two real
      // cases as "closed_by_user" - a genuine SL hit whose fill slipped
      // past the 0.1% tolerance (close_reason: "Stop loss", but close
      // price ~0.33% from the recorded SL), and a genuine broker-forced
      // margin stop-out (close_reason: "Stop out", closed nowhere near
      // either SL or TP - the account's overall margin level dropped
      // below the broker's stop-out threshold, not this position's own
      // exit level). "Stop out" gets its own distinct label - a forced
      // liquidation is a materially different, more serious event than a
      // normal SL hit or an intentional manual close, and conflating it
      // with either would hide real account-risk signal. The old
      // price-proximity check survives only as a fallback for the rare
      // case `close_reason` itself is missing/unrecognized.
      final mt5CloseReason = (record['close_reason'] as String?)?.trim().toLowerCase();
      final String stopReason;
      final String detail;
      bool near(double? a, double? b) =>
          a != null && b != null && b != 0 && (a - b).abs() / b.abs() < 0.001;
      if (mt5CloseReason == 'stop loss') {
        stopReason = 'stop_loss';
        detail = 'Closed by MT5 hitting its own stop-loss price.';
      } else if (mt5CloseReason == 'take profit') {
        stopReason = 'take_profit';
        detail = 'Closed by MT5 hitting its own take-profit price.';
      } else if (mt5CloseReason == 'stop out') {
        stopReason = 'margin_stop_out';
        detail = 'Force-closed by the broker\'s own margin stop-out - account margin level dropped too low, not a normal SL/TP or a manual close.';
      } else if (mt5CloseReason != null) {
        stopReason = 'closed_by_user';
        detail = 'Closed directly in MT5 (reason: "${record['close_reason']}"), not by this app.';
      } else if (near(closePrice, stopLoss)) {
        stopReason = 'stop_loss';
        detail = 'Closed by MT5 hitting its own stop-loss price.';
      } else if (near(closePrice, takeProfit)) {
        stopReason = 'take_profit';
        detail = 'Closed by MT5 hitting its own take-profit price.';
      } else {
        stopReason = 'closed_by_user';
        detail = 'Closed directly in MT5, not by this app and not at SL/TP.';
      }

      // worm_10_26 technique keeps its own open/update snapshot - same
      // fallback order as [_recordHistory]'s own.
      final worm10Snapshot = worm10EntrySignals.takeFor(ticket);
      final openSnapshot = worm10Snapshot == null ? entrySignals.takeFor(ticket) : null;
      final direction =
          (record['type'] as String?) == 'sell' ? TradeDirection.short : TradeDirection.long;

      // 2026-10-13, per the user: "if pair beent terminated two times in
      // same signal, then this pair will not start over again until
      // signal is flipped." A qualifying "baseline stop" is a stop_loss
      // close where the ratchet never tightened this ticket's SL first
      // (`slRatchet.highestThreshold == null`) - otherwise this was a
      // RATCHET-protected profit-lock hit, not a repeated-failure-at-open
      // one, and shouldn't count toward the block. Any other close
      // (take-profit, a ratchet-protected SL, closed outside the app)
      // breaks whatever streak was building.
      //
      // Skipped entirely for a Multiplier copy's own ticket (2026-10-16,
      // per the user: "once copied trade is terminated... it is not
      // repeated == no auto listed anymore... that's applied for copied
      // only not for parent/original") - a copy's own tight -$1 SL is a
      // deliberate, routine profit-lock exit on an already-winning leg,
      // not a "this pair keeps failing at the baseline" signal, and this
      // whole mechanism is about the PARENT's own lifecycle only. See
      // [CopyPositionStore]'s own doc comment.
      if (!copyPositions.isCopy(ticket)) {
        if (stopReason == 'stop_loss' && slRatchet.highestThreshold(ticket) == null) {
          final directionStr = direction == TradeDirection.long ? 'long' : 'short';
          baselineStopStrikes.recordBaselineStop(tvSymbol, directionStr);
          logger.log(
            'BASELINE STOP: $mt5Symbol ($category) hit the baseline SL as '
            '$directionStr (strike ${baselineStopStrikes.strikes(tvSymbol)}/2 '
            'before this pair is blocked until the signal flips).',
          );
        } else {
          baselineStopStrikes.clear(tvSymbol);
        }
      }

      final entryPriceForPct = (record['open_price'] as num?)?.toDouble() ?? 0.0;
      final volumeForPct = (record['volume'] as num?)?.toDouble();
      final profitForPct = (record['profit'] as num?)?.toDouble();
      final contractSizeForPct = contractSizeBySymbol[mt5Symbol.toUpperCase()] ?? 1.0;
      final notionalForPct = (volumeForPct ?? 0) * contractSizeForPct * entryPriceForPct;
      final realizedProfitPercent =
          (profitForPct != null && notionalForPct != 0) ? profitForPct / notionalForPct * 100 : null;
      final ratchetThreshold = slRatchet.highestThreshold(ticket);
      // A copy's own baseline SL is -$1, not the normal -$5 (2026-10-16,
      // per the user) - see the Dashboard SLL column's own matching fix
      // for the full reasoning.
      final sllAtTermination = ratchetThreshold != null
          ? '+$ratchetThreshold%'
          : copyPositions.isCopy(ticket)
          ? '-\$1'
          : '-\$5';
      storage.appendJsonl(
        storage.botHistoryFile,
        BotHistoryEntry(
          id: '$ticket-${DateTime.now().microsecondsSinceEpoch}',
          ts: DateTime.now(),
          mt5Symbol: mt5Symbol,
          tradingViewSymbol: tvSymbol,
          category: category,
          ticket: ticket,
          direction: direction,
          entryPrice: entryPriceForPct,
          exitPrice: closePrice,
          volume: volumeForPct,
          stopLoss: stopLoss,
          takeProfit: takeProfit,
          realizedProfit: profitForPct,
          startTime: DateTime.tryParse(record['open_time'] as String? ?? '') ?? DateTime.now(),
          endTime: DateTime.tryParse(record['close_time'] as String? ?? ''),
          openSignalType: worm10Snapshot != null
              ? worm10EventKindToWire(worm10Snapshot.kind)
              : openSnapshot?.tag,
          openSignalAt: worm10Snapshot?.barTime ?? openSnapshot?.barTime,
          updateSignalType: worm10Snapshot?.updateKind != null
              ? worm10EventKindToWire(worm10Snapshot!.updateKind!)
              : openSnapshot?.updateTag,
          updateSignalAt: worm10Snapshot?.updateTime ?? openSnapshot?.updateTime,
          stopReason: stopReason,
          detail: detail,
          realizedProfitPercent: realizedProfitPercent,
          sllAtTermination: sllAtTermination,
          investmentValue: notionalForPct,
        ).toJson(),
      );
      logger.log('$mt5Symbol ($category): reconciled ticket=$ticket as $stopReason.');
      final wasCopy = copyPositions.isCopy(ticket);
      openPositions.forgetPosition(ticket);
      botCategories.forget(ticket);
      widenApplied.forget(ticket);
      risk.closePosition(mt5Symbol, category);
      copyPositions.forget(ticket);
      // Skipped for a copy's own close, same reasoning as the
      // baseline-stop-strike block above - "Last" retirement is a
      // decision about the PARENT's own lifecycle, never a copy's.
      if (!wasCopy) _finalizeLastTagOnClose(category, tvSymbol);
    }
  }

  /// Re-parses just the `symbols` array out of config.json on disk, instead
  /// of trusting the copy captured in `config` once at engine startup. Falls
  /// back to that startup copy if the file is missing/unreadable right now.
  List<SymbolMapping> _loadSymbolsFresh() {
    final json = storage.readJsonObject(storage.configFile);
    if (json == null) return config.symbols;
    return ((json['symbols'] as List?) ?? const [])
        .map((e) => SymbolMapping.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> _runCycle() async {
    if (storage.fileExists(storage.autoPausedFile)) {
      _writeStatus(
        connected: true,
        message: 'Auto paused',
        health: PowerHealthState.ready,
      );
      return;
    }

    // Extends the same startup-timing fix from [_reconcileClosedPositions]
    // to the WHOLE cycle (2026-09-29, per the user: "fix the bug" - found
    // live that [_findAppPosition]'s self-heal, called from every
    // per-symbol check's own early gate, hit the identical "MT5 not ready
    // yet right after restart" flakiness reconciliation did - AAVE and
    // SHIB both needed several check-cycles across multiple minutes before
    // self-healing back into tracking, and in AAVE's case one of those
    // early attempts is exactly what read MT5 as empty and let a
    // conflicting position get opened in the first place). Skipping the
    // entire cycle, not just reconciliation, means no per-symbol check
    // ever acts on a live-position read from this same fragile window
    // either - nothing opens, closes, or self-heals until MT5's connection
    // has had real time to settle.
    if (DateTime.now().difference(_startedAt) < _reconcileGracePeriod) {
      _writeStatus(
        connected: true,
        message: 'Settling after restart',
        health: PowerHealthState.ready,
      );
      return;
    }

    // 2026-10-13, moved ahead of everything else in this cycle (was after
    // [_reverseCheckOnTechniqueSwitchIfNeeded]) - found live that the
    // startup/technique-switch reverse-check sweep below is a single long
    // `await` that walks every auto-managed base through TradingView
    // sequentially (confirmed ~45-60s per base from real log timestamps),
    // so with ~20+ auto-managed bases it can take 15-20+ minutes to return.
    // Since both this sweep and the margin gate are pure MT5 (no CDP/
    // TradingView involved at all - see [_applySlRatchet]'s own doc
    // comment), there's no reason they need to wait behind it; sequencing
    // them after meant that on every restart during this session's rapid
    // redeploy cycle, that first slow sweep got interrupted by the NEXT
    // restart before it ever returned - so this safety-critical sweep had
    // never once actually executed in production despite being fully
    // wired and throttled correctly. Self-throttled internally, so calling
    // this first changes nothing about its own cadence - just removes the
    // slow sweep as a gate in front of it.
    await _maybeApplySlRatchet();
    // Same reasoning - margin level is account-wide, not per-symbol.
    await _maybeRefreshMarginGate();

    await _reconcileClosedPositions();

    // 2026-10-04, per the user: "dont let app to add, remove pairs from
    // redlist ... in simple words, dont let app to do cosmetic work" -
    // TradingView's Red list has zero bearing on signal reading or any
    // trading decision (confirmed earlier the same day by tracing the full
    // code path: setChartView/readSwingOscillatorSignals read the chart's
    // own dataSources directly, never the watchlist) - the automation that
    // used to add/re-check pairs there has been removed entirely, not just
    // disabled, so it can never run again even by accident.
    await _processAllPendingTerminateRequests();
    await _processAllPendingAddCopyRequests();
    // Only drained here, at the top of the cycle - NOT inside the long
    // per-symbol sweeps the other requests are also drained from
    // (2026-10-17) - a backtest can genuinely take a while (pulling
    // multiple days/weeks of history), so it's deliberately NOT given the
    // same "don't starve behind a sweep" responsiveness; it waits for a
    // natural cycle boundary instead; the next full cycle after this one
    // just picks up a bit later than normal, never any WORSE than that.
    await _processPendingBacktestRequest();
    await retroactiveFix6040SlOnce();
    // Periodic scan, not a one-shot queued request like the two calls
    // above - re-evaluates every running original's own P&L against its
    // $5 ladder once per full cycle pass (2026-10-15, per the user's
    // auto-copy spec). Doesn't need the sweep-interior responsiveness
    // those two have, since profit moves gradually, not in one click.
    try {
      await _processAutoCopyMilestones(AutoCategory.oneHour);
    } catch (e, st) {
      logger.log('Auto-copy milestone scan error: $e\n$st', level: 'ERROR');
    }

    // 2026-10-06, per the user's second decision technique - read once per
    // sweep (all pairs use whichever technique is active right now; it
    // can't change mid-sweep since only the GUI writes this file).
    final technique = _activeTechnique();

    await _reverseCheckOnTechniqueSwitchIfNeeded(technique);

    // 2026-10-09, per the user - processed BEFORE the main per-symbol loop
    // below so a just-unpaused pair's own later pass through that loop
    // (same cycle) finds it already checked moments ago and skips via the
    // normal retry-cooldown gate, instead of being checked twice in one
    // cycle.
    await _processAllPendingUnpauseChecks(technique);

    // 2026-10-10, per the user's Add Pair flow ("confirmed from three apps
    // ... trading view: if this pair matching the name or need mapping") -
    // the GUI can't check TradingView itself (CDP is this engine's own
    // exclusive single connection - see _ensureCdpUpInFlight's own doc
    // comment), so it asks here instead. Processed early, same reasoning
    // as the unpause-check drain above.
    await _processAllPendingSymbolResolveRequests();

    for (final category in allAutoCategories) {
      if (storage.fileExists(storage.autoCategoryPausedFileFor(category))) {
        continue;
      }
      final store = autoManagedByCategory[category]!;
      // 2026-10-18, per the user: "add a star icon for those
      // waiting/unfilled cards where once this icon is clicked, app will
      // give those pairs priority in filling once margin is okay. now:
      // app choosing to fill pairs randomly" - [loadAutoManagedBases] is
      // actually a fixed alphabetical order every cycle, which looks
      // arbitrary to a human with no say in it. Starred pairs are now
      // checked first (alphabetically among themselves), everyone else
      // after (also alphabetical) - this ONLY changes which waiting pair
      // the loop reaches first once margin genuinely allows an open; the
      // margin gate itself (RiskGate.gate) is completely untouched, see
      // [FavoritePairStore]'s own doc comment.
      final bases = store.loadAutoManagedBases();
      final favorites = favoritePairs.loadFavorites();
      final orderedBases = [
        ...bases.where(favorites.contains),
        ...bases.where((b) => !favorites.contains(b)),
      ];
      for (final tvSymbol in orderedBases) {
        if (retired.isRetiredBase(tvSymbol)) continue;
        // 2026-10-09, per the user: "paused pair is still an auto pair but
        // the current status is paused so engine will not take any action
        // to this pair unless it is unpaused" - skipped exactly like a
        // retired base, but WITHOUT leaving auto-managed-bases.json (see
        // [PausedPairStore]'s own doc comment) - the row stays fully
        // listed, whatever it was doing (running/waiting) untouched.
        if (paused.isPaused(tvSymbol)) continue;
        // 2026-09-30, per the user: "once user press on power = terminate
        // ... it should be instant" - re-checked before EVERY symbol, not
        // just once at the top of the cycle, so a request doesn't have to
        // wait out the ENTIRE rest of the sweep (which can take minutes)
        // to be noticed - only however long whichever symbol happens to be
        // mid-check right now takes (usually ~1-2s; up to ~40s only if
        // that symbol is mid-triple-read). A true guaranteed-instant fix
        // would need a second, fully concurrent MT5 connection - held off
        // on that given the risk of running two overlapping sessions
        // against a live account without more testing.
        await _processAllPendingTerminateRequests();
        // Same "don't wait out the whole sweep" reasoning as the terminate
        // drain immediately above, for the Multiplier column's "add a copy
        // trade" click (2026-10-15, per the user: found live a click sat
        // unprocessed for minutes because the only earlier drain call was
        // at the very top of [_runCycle], never reached again until this
        // sweep finished - the exact same starvation shape terminate
        // requests were already fixed for).
        await _processAllPendingAddCopyRequests();
        // Same "don't wait out the whole sweep" reasoning as the terminate
        // drain immediately above, for an unpause-triggered instant check
        // (2026-10-09).
        await _processAllPendingUnpauseChecks(technique);
        // Same reasoning again, for an Add Pair TradingView check
        // (2026-10-10, per the user: "why app need to have cycle to check
        // pair... the cycle for what?" - found live the symbol-resolve
        // drain only ran once at the very top of the sweep, so a request
        // made partway through a long sweep had to wait out the ENTIRE
        // rest of it (confirmed live: 55s for KASUSDT) before being
        // noticed, the exact same problem terminate/unpause already solved
        // by re-checking before every symbol instead of once per lap.
        await _processAllPendingSymbolResolveRequests();
        // Same "don't wait out the whole sweep" reasoning as the terminate
        // drain above - REVERSED 2026-10-17 from this feature's original
        // "only at the top of the cycle" design (see that comment's own
        // history): confirmed live a full audit sweep (every symbol
        // force-re-checked, e.g. right after a restart) can run 20-30+
        // minutes, not the "few seconds" the original reasoning assumed -
        // a backtest request sitting behind that is indistinguishable from
        // "broken" to the user. Drained at every per-symbol boundary now,
        // same as everything else in this block.
        await _processPendingBacktestRequest();
        // Self-throttled to [_slRatchetInterval] internally - safe to call
        // this liberally at every per-symbol boundary in the loop, same
        // pattern as the mandatory health recheck right below (2026-10-13).
        await _maybeApplySlRatchet();
        // Same reasoning again, for the margin-level safety gate
        // (2026-10-13, per the user) - crucially, this is what actually
        // makes "stay non-filled until margin recovers" responsive: this
        // IS the gate [risk.gate('open', ...)] below checks, so refreshing
        // it right before that call (not just once per lap) is what keeps
        // a just-tripped gate from still letting one more open through on
        // a symbol later in the same long sweep.
        await _maybeRefreshMarginGate();
        if (!(await _maybeRunHealthCheck())) return;
        try {
          // Re-read symbols from config.json fresh every cycle (rather than
          // the copy cached in `config` at engine startup) so a symbol added
          // to config.json while the engine is already running - e.g. DOGE,
          // added live on 2026-09-27 - is picked up on the very next cycle
          // instead of needing a restart, matching how auto-managed-bases.json
          // already hot-reloads. Wrapped in the same try/catch as the check
          // itself so one unmapped symbol logs an error and is skipped rather
          // than crashing the rest of this cycle's symbols (the previous
          // uncaught StateError here did exactly that to DOGE/SOL/TRX).
          final currentSymbols = _loadSymbolsFresh();
          final mapping = currentSymbols.firstWhere(
            (m) => m.tradingViewSymbol.toUpperCase() == tvSymbol.toUpperCase(),
            orElse: () => throw StateError(
              'auto-managed symbol "$tvSymbol" has no SymbolMapping in config.json — '
              'add one (tradingview_symbol + mt5_symbol) or remove it from auto-managed.',
            ),
          );
          if (technique.id == DecisionTechnique.supertrendPlus.id) {
            await _checkOneSymbolSupertrend(category, mapping);
          } else if (technique.id == DecisionTechnique.worm10.id) {
            await _checkOneSymbolWorm10(category, mapping);
          } else {
            await _checkOneSymbol(category, mapping);
          }
        } catch (e, st) {
          logger.log(
            'Cycle error for $tvSymbol ($category): $e\n$st',
            level: 'ERROR',
          );
        }
      }
    }

    _writeStatus(connected: true, message: 'Ready', health: PowerHealthState.ready);
  }

  /// Consecutive times [_ensureCdpUp] failed AFTER confirming TradingView's
  /// CDP port itself was genuinely reachable — covers both a chart that
  /// never becomes ready ([waitForChartApiReady] failing) and one that's
  /// ready but stuck behind something blocking indicator automation (e.g. a
  /// leftover dialog left open by an interrupted previous attempt -
  /// confirmed live 2026-09-29: "Indicators, metrics, and strategies" stuck
  /// open after a restart mid-[enforceCustomScripts], which then failed the
  /// exact same way — msb=false — on every subsequent attempt with nothing
  /// ever trying to clear it). Either case is the signature of TradingView
  /// being alive-but-stuck, as opposed to genuinely not running (which the
  /// "launch it" branch above already handles). Reset to 0 on full success.
  int _consecutiveStuckAttempts = 0;

  /// Self-healing escalation ported from tradingPionex 2026-09-29, per the
  /// user ("learn from tradingpionex... make a self healing for this
  /// problem" / "if you can do it better here do it"): a stuck-but-
  /// connectable TradingView would otherwise fail [_ensureCdpUp] the exact
  /// same way forever, since every fresh attempt just reconnects to the
  /// same frozen process — nothing ever tried the one thing that actually
  /// fixes a stuck desktop app: killing and relaunching it. Once
  /// [_consecutiveStuckAttempts] reaches this many, force-kills TradingView
  /// (`pkill -9`, the same mechanism [launchTradingView] itself already
  /// uses to clear a stale instance) so the next call's "not running"
  /// branch launches it fresh — a clean relaunch clears ANY stuck UI state
  /// (dialogs included), not just the one failure mode that happened to be
  /// anticipated.
  static const int _forceRelaunchTradingViewThreshold = 3;

  Future<void> _forceRelaunchTradingViewIfStuck(String home) async {
    _consecutiveStuckAttempts++;
    if (_consecutiveStuckAttempts < _forceRelaunchTradingViewThreshold) {
      return;
    }
    _consecutiveStuckAttempts = 0;
    logger.log(
      'TRADINGVIEW WATCHDOG: CDP port reachable but TradingView never '
      'cooperated $_forceRelaunchTradingViewThreshold times in a row - '
      'looks alive but stuck, not genuinely down. Force-killing it now so '
      'the next connect attempt starts it fresh.',
      level: 'CRITICAL',
    );
    try {
      final binaryPath = (await _tradingViewLaunchConfig(home)).binaryPath;
      if (Platform.isWindows) {
        // Verified + retried, not a single unchecked Process.run (2026-10-16,
        // per the user, after a real ~10-hour Windows stall: confirmed live
        // this exact watchdog kill's result was never checked at all - if
        // `taskkill` silently failed (e.g. "Access is denied" against a
        // Store/MSIX-packaged TradingView), the counter above still reset to
        // 0 and this whole mechanism would just quietly repeat the identical
        // failed kill every 3 attempts forever, with nothing ever surfacing
        // that the "fix" was never actually taking effect. See
        // [taskkillByBinaryPath]'s own doc comment.
        final killed = await taskkillByBinaryPath(binaryPath, onLog: logger.log);
        if (!killed) {
          logger.log(
            'TRADINGVIEW WATCHDOG: could not actually kill TradingView - it '
            'will keep failing the same way until it\'s closed manually.',
            level: 'CRITICAL',
          );
        }
      } else {
        await Process.run('pkill', ['-9', '-f', binaryPath]);
      }
    } catch (e) {
      logger.log('TRADINGVIEW WATCHDOG: force-kill failed: $e');
    }
  }

  /// Platform-appropriate MT5 launch config - Windows (UNTESTED against a
  /// real Windows machine) needs no home/display/Wine plumbing at all; see
  /// [Mt5LaunchConfig.defaultForWindows]'s own doc comment.
  Mt5LaunchConfig _mt5LaunchConfig() {
    if (Platform.isWindows) return Mt5LaunchConfig.defaultForWindows();
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    return Mt5LaunchConfig.defaultForHome(home);
  }

  /// Platform-appropriate TradingView launch config - see
  /// [LaunchConfig.defaultForWindows]'s own doc comment (confirmed live
  /// 2026-10-11 - async now, since resolving a Microsoft Store install
  /// means shelling out to `Get-AppxPackage`).
  Future<LaunchConfig> _tradingViewLaunchConfig(String home) async {
    if (Platform.isWindows) return LaunchConfig.defaultForWindows();
    return LaunchConfig.defaultForHome(home);
  }

  /// Ensures TradingView is up, the chart API is ready, and both required
  /// indicators are attached — called every cycle now (from
  /// [_runHealthCheck], continuous per the user's 2026-09-20 spec), not
  /// just on the first connect. A live, already-open connection is now
  /// re-verified with the CHEAP read-only [areIndicatorsPresent] check on
  /// every call instead of being trusted forever once open — only the full
  /// close-and-re-add [enforceCustomScripts] cycle runs when something is
  /// actually missing.
  /// The currently-selected [DecisionTechnique], read fresh from
  /// [CoreStorage.decisionTechniqueFile] every call (2026-10-06) - same
  /// "re-read fresh, don't trust a cached copy" pattern as
  /// [_loadSymbolsFresh], so a switch made from the GUI takes effect on the
  /// very next cycle rather than needing an engine restart. Defaults to
  /// [DecisionTechnique.signalFlip] if the file is missing/unreadable -
  /// that's also the only technique that ever existed before this file did,
  /// so an absent file correctly means "nothing has ever been switched."
  DecisionTechnique _activeTechnique() {
    final json = storage.readJsonObject(storage.decisionTechniqueFile);
    final id = json?['id'] as String?;
    return DecisionTechnique.all.firstWhere(
      (t) => t.id == id,
      orElse: () => DecisionTechnique.signalFlip,
    );
  }

  /// Checks the indicator(s) + candle style the ACTIVE technique needs are
  /// in place. 2026-10-18, per the user: "worm 10 is include supertrend
  /// plus signal... now it will need to check worm 10 indicator. so there
  /// is no need for supertrend plus indicator anymore" and "signal
  /// flipping technique can use worm 10 too... so there is no need for
  /// worm 9 anymore" - the user updated their TradingView Pine Scripts so
  /// worm_10_26 now internally contains both the old Supertrend-Plus-only
  /// signal AND the old worm_9_26-only zigzag signal (plus its own
  /// range data), alongside spy_9_26's RSI zones - exactly what all
  /// three techniques need, already proven by Worm10's own technique
  /// reading all three pieces out of this exact pair of scripts (see
  /// [readWorm10Signals]). All three techniques now require the
  /// IDENTICAL pair of scripts and the identical Heikin Ashi candle
  /// style Worm10 itself has always required for this same script -
  /// one chart, one script, one candle type behind every signal it
  /// computes, so Signal Flip reading worm_10_26 needs heikinAshi too,
  /// same as Supertrend Plus does already (this supersedes a 2026-10-06
  /// note that used to live here about Signal Flip needing regular
  /// candles - that was true back when it read a genuinely different
  /// script).
  Future<bool> _indicatorsReadyFor(DecisionTechnique technique, CdpClient client) async {
    final styleOk = await ensureChartStyle(client, ChartStyle.heikinAshi);
    return styleOk && await isWorm10Present(client);
  }

  /// Guards [_ensureCdpUp] against overlapping calls (2026-10-06 - found
  /// live: the outer 30s deadline wrapping this call in [_runHealthCheck]
  /// was tuned for Signal Flip's own enforcement, which the ORIGINAL doc
  /// comment on that deadline says should "never actually fire in
  /// practice" - true for a single script, but Supertrend Plus's own
  /// enforcement needs to search/add TWO scripts from a cold chart, which
  /// can legitimately take longer than that. When the deadline fires, the
  /// caller stops AWAITING this function, but the function itself keeps
  /// running underneath - Dart's `.timeout()` abandons the wait, it does
  /// not cancel the future. The very next health-check tick then started a
  /// SECOND, fully independent `_ensureCdpUp` while the first was still
  /// mid-[enforceSupertrendPlus]/[enforceCustomScripts], and both calls
  /// `removeAllSources` + re-add scripts on the SAME chart - confirmed live
  /// as the exact flicker the user saw ("it loads supertrend first,
  /// closing it then load worm/spy"): two overlapping enforce passes
  /// fighting over the same "Indicators" search dialog, each one's
  /// `removeAllSources` wiping out whatever the other had just added.
  /// Every caller now awaits the SAME in-flight call instead of starting a
  /// new overlapping one.
  Future<void>? _ensureCdpUpInFlight;

  Future<void> _ensureCdpUp() {
    final inFlight = _ensureCdpUpInFlight;
    if (inFlight != null) return inFlight;
    final future = _ensureCdpUpImpl();
    _ensureCdpUpInFlight = future;
    return future.whenComplete(() => _ensureCdpUpInFlight = null);
  }

  Future<void> _ensureCdpUpImpl() async {
    final technique = _activeTechnique();
    if (_cdp != null && !_cdp!.dead) {
      if (await _indicatorsReadyFor(technique, _cdp!)) return;
      logger.log('Indicators missing on an already-open chart — re-enforcing.');
    } else if (_cdp != null) {
      logger.log('CDP client was dead — reconnecting fresh.');
      _cdp = null;
    }

    final host = config.cdp.host;
    final port = config.cdp.port;
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '.';
    if (!await isCdpUp(host, port)) {
      final tvLaunchConfig = await _tradingViewLaunchConfig(home);
      if (!isTradingViewInstalled(tvLaunchConfig)) {
        throw TradingViewNotInstalledException(tvLaunchConfig.binaryPath);
      }
      _writeStatus(
        health: PowerHealthState.checking,
        message: 'Launching TradingView',
        connected: true,
      );
      final launched = await launchTradingView(
        host,
        port,
        tvLaunchConfig,
        remoteSession: config.remoteSession,
        onLog: logger.log,
      );
      if (!launched) {
        throw StateError('TradingView Desktop did not come up on $host:$port');
      }
    }

    final CdpClient client;
    try {
      client = _cdp ?? await connectToChart(host, port);
    } catch (e) {
      // Found live 2026-10-07 ("trading view is loading forever"): a
      // TradingView process that still accepts a bare TCP connect to the
      // CDP port but never completes a single real protocol round-trip
      // (e.g. "CDP request timed out ... for Runtime.enable") throws
      // straight out of [connectToChart], which used to skip the watchdog
      // below entirely - [_consecutiveStuckAttempts] never incremented for
      // THIS failure mode, so a hung-but-port-open TradingView retried
      // forever against the exact same frozen process instead of ever
      // getting force-killed and relaunched fresh. Same "alive but stuck"
      // signature [_forceRelaunchTradingViewIfStuck] already exists to
      // catch for the `!ready` case below - just needed to also catch it
      // here, one step earlier.
      _cdp = null;
      await _forceRelaunchTradingViewIfStuck(home);
      rethrow;
    }
    final ready = await waitForChartApiReady(client);
    if (!ready) {
      client.close();
      _cdp = null;
      await _forceRelaunchTradingViewIfStuck(home);
      throw StateError('Chart API did not become ready in time');
    }

    if (!await _indicatorsReadyFor(technique, client)) {
      _writeStatus(
        health: PowerHealthState.checking,
        message: 'Loading indicators',
        connected: true,
      );
      // 2026-10-18, per the user: all three techniques now read the same
      // worm_10_26 + spy_9_26 pair (see [_indicatorsReadyFor]'s own doc
      // comment) - one shared enforcement function for all of them.
      final enforceResult = await enforceWorm10(host, port);
      final ok = enforceResult.finalMsb && enforceResult.finalRsi;
      if (!ok) {
        client.close();
        _cdp = null;
        await _forceRelaunchTradingViewIfStuck(home);
        throw StateError(
          'indicator enforcement failed for ${technique.name} '
          '(msb=${enforceResult.finalMsb}, rsi=${enforceResult.finalRsi}): '
          '${enforceResult.error}',
        );
      }
      await ensureChartStyle(client, ChartStyle.heikinAshi);
    }
    _consecutiveStuckAttempts = 0;
    _cdp = client;
  }

  /// Set once the FIRST [_runCycle] of this engine PROCESS has run its
  /// technique check - every fresh Power-on starts a brand new process (see
  /// [EngineControlRepository]'s own doc comment: Power on means
  /// `systemctl --user start`), so this is naturally "has Power-on already
  /// been verified this run."
  bool _startupTechniqueCheckDone = false;

  /// Immediate reverse-check sweep across every auto-managed pair (running,
  /// waiting, not-filled alike), for whichever technique is active right
  /// now - fires on TWO occasions: (1) unconditionally, the very first cycle
  /// after every Power-on, regardless of whether the technique "changed" -
  /// 2026-10-06, per the user: "i want a smart app.. so if i power on ....
  /// app need to check techniqu[e] not to keep choosing drop down" - don't
  /// make the user re-toggle the picker just to force a re-verify; Power-on
  /// itself is already the moment to trust the active technique fully,
  /// matching the exact same philosophy as the Signal Flip audit's own
  /// "GUI reopened - clearing the cache to re-check everything" rule. (2)
  /// afterward, only when [technique] genuinely differs from what the
  /// engine last acted on (2026-10-06, per the user's original spec: "once
  /// technique is choosed.. app need to do a reverse check... this applies
  /// to all auto trades" - confirmed: "action will be immediately if there
  /// is a reverse signal", triple-read still required, just without the
  /// normal "survive one extra candle" wait). [CoreStorage.lastSeenTechniqueFile]
  /// still exists purely to log the right before/after names on a genuine
  /// switch - it's no longer what GATES whether the sweep runs on startup.
  Future<void> _reverseCheckOnTechniqueSwitchIfNeeded(DecisionTechnique technique) async {
    final isStartupCheck = !_startupTechniqueCheckDone;
    _startupTechniqueCheckDone = true;

    final lastSeenId = storage.readJsonObject(storage.lastSeenTechniqueFile)?['id'] as String?;
    if (!isStartupCheck && lastSeenId == technique.id) return;

    logger.log(
      isStartupCheck
          ? 'Power on - verifying every auto-managed pair against the active '
              'technique (${technique.name}) with an immediate reverse-check sweep.'
          : 'Decision technique switched (${lastSeenId ?? "none"} -> ${technique.id}) - '
              'running an immediate reverse-check sweep over every auto-managed pair.',
    );
    storage.writeJson(storage.lastSeenTechniqueFile, {'id': technique.id});

    for (final category in allAutoCategories) {
      final store = autoManagedByCategory[category]!;
      for (final tvSymbol in store.loadAutoManagedBases()) {
        if (retired.isRetiredBase(tvSymbol)) continue;
        // 2026-10-09, per the user - a paused pair gets NO automatic
        // action of any kind, including this sweep; it'll get its own
        // immediate check the moment it's un-paused (see
        // [_processAllPendingUnpauseChecks]), not before.
        if (paused.isPaused(tvSymbol)) continue;
        await _processAllPendingTerminateRequests();
        // Same "don't wait out the whole sweep" reasoning as the terminate
        // drain immediately above - this is the exact sweep ("Power on...
        // immediate reverse-check sweep") a real Multiplier click got
        // stuck behind for minutes before this was added (2026-10-15).
        await _processAllPendingAddCopyRequests();
        // 2026-10-17 - this IS the exact sweep a real backtest request got
        // stuck behind for 10+ minutes (confirmed live, right after a
        // restart forces this "Power on" full sweep) - same fix as above.
        await _processPendingBacktestRequest();
        await retroactiveFix6040SlOnce();
        try {
          final currentSymbols = _loadSymbolsFresh();
          final mapping = currentSymbols.firstWhere(
            (m) => m.tradingViewSymbol.toUpperCase() == tvSymbol.toUpperCase(),
            orElse: () => throw StateError(
              'auto-managed symbol "$tvSymbol" has no SymbolMapping in config.json.',
            ),
          );
          if (technique.id == DecisionTechnique.supertrendPlus.id) {
            await _checkOneSymbolSupertrend(category, mapping, immediate: true);
          } else if (technique.id == DecisionTechnique.worm10.id) {
            await _checkOneSymbolWorm10(category, mapping, immediate: true);
          } else {
            await _checkOneSymbol(category, mapping, immediate: true);
          }
        } catch (e, st) {
          logger.log(
            'Technique-switch reverse check failed for $tvSymbol ($category): $e\n$st',
            level: 'ERROR',
          );
        }
      }
    }
  }

  /// [immediate] (2026-10-06, per the user's original decision-technique
  /// spec: "once technique is choosed.. app need to do a reverse check
  /// according to current running trade compared with start signal" -
  /// confirmed later: "action will be immediately if there is a reverse
  /// signal") - set ONLY by the one-time sweep [_reverseCheckOnTechniqueSwitch]
  /// runs right when the active technique changes. Skips the cooldown gate
  /// and the "survive one extra candle" wait entirely (every OTHER safety
  /// check - the triple-read confirmation most of all - still applies in
  /// full); normal per-cycle calls never pass this, so the existing,
  /// already-proven timing behavior is completely unchanged for them.
  Future<void> _checkOneSymbol(AutoCategory category, SymbolMapping mapping, {bool immediate = false}) async {
    final tvSymbol = mapping.tradingViewSymbol;
    final mt5Symbol = mapping.mt5Symbol;
    final barKey = '${category.wireValue}|$tvSymbol';

    // Drop any leftover Supertrend Plus pending entry for this pair - same
    // reasoning as [_checkOneSymbolSupertrend]'s own matching clear of
    // [pendingSignals], mirrored here so switching technique in either
    // direction never leaves the OTHER technique's own stale pending
    // candidate sitting around. Cheap no-op once already clear.
    supertrendPending.clear(barKey);

    // Cheap early gate (2026-09-28, per the user: "link only need to be
    // checked every 3 min") - decide whether this symbol is even due for a
    // check BEFORE paying for the expensive TradingView chart read (up to
    // ~40s across the two triple-read confirmations below), not after.
    // Cuts total chart-switching a lot with several symbols in rotation,
    // which should also reduce the cross-symbol FLICKER noise that comes
    // from switching charts back-to-back. Every symbol uses the same
    // [_retryCooldown] regardless of fill status (2026-09-29 - see the
    // doc comment on [_lastCheckedAt] for why the earlier 1-hour-once-
    // filled version was removed). [existing] is reused below instead of
    // re-querying MT5 again.
    final existing = await _findAppPosition(mt5Symbol, category, tvSymbol);

    // "Survive one full extra candle" wait gate (2026-09-30, per the user:
    // "app need to wait for end of next candle once signal appears ... if
    // this next candle still empty ... then step 3 will applied. other
    // wise ... make steps 1,2,3 on this new candle") - while a
    // triple-confirmed candidate signal is mid-wait, this symbol is
    // skipped ENTIRELY (no chart access at all) until wall-clock reaches
    // the end of the candle immediately after the candidate's own bar -
    // checked once at that point, not every cycle. See the actual
    // resolution logic further down, right after the signal triple-read.
    // Bypassed entirely when [immediate].
    final pending = pendingSignals.get(barKey);
    if (!immediate && pending != null) {
      final checkAt = pending.barTime + category.candlePeriod.inSeconds * 2;
      final nowEpoch = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      if (nowEpoch < checkAt) return;
    }

    final lastChecked = _lastCheckedAt[barKey];
    if (!immediate && lastChecked != null && DateTime.now().difference(lastChecked) < _retryCooldown) {
      return;
    }
    _lastCheckedAt[barKey] = DateTime.now();

    // Dashboard "Check" column (2026-09-29, per the user: "only running
    // pairs checked") - stamp the moment a real (past-cooldown) evaluation
    // starts for this symbol, but only while a real position is running.
    // The GUI derives "checked THIS candle cycle" purely from comparing
    // this timestamp's UTC hour against wall-clock now - see
    // [LastCheckedStore]'s doc comment.
    if (existing != null) lastCheckedStore.record(tvSymbol);

    await _ensureCdpUp();
    final cdp = _cdp!;

    // 2026-10-18, per the user: "signal flipping technique can use worm
    // 10 too... so there is no need for worm 9 anymore" - worm_10_26
    // carries this same zigzag range data built in (the same reason
    // [_checkOneSymbolWorm10] already reads its range this exact way).
    final range = await _readConfirmedRange(
      cdp,
      category,
      tvSymbol,
      immediate: immediate,
      scriptIdPart: worm10Script.scriptIdPart,
    );
    if (range == null) return;

    // 2026-10-17 - found live, root-caused from a real financial loss: this
    // call's own return value was never checked. When the switch silently
    // times out (confirmed happening repeatedly under the TradingView/CDP
    // instability already well-documented throughout this codebase's own
    // doc comments), the code used to barrel ahead and read signals from
    // WHATEVER symbol the chart was still actually showing - in one
    // confirmed live incident, an entire 26-symbol "verify every
    // auto-managed pair" sweep misattributed ONE stuck symbol's own
    // 10-day-old signal to every other symbol in the sweep, each exactly
    // ~43s apart, because every single switch attempt in that sweep
    // silently failed and nothing ever noticed. Refusing to read signals
    // at all unless the chart is CONFIRMED showing the right symbol is the
    // only safe response - a skipped cycle is far better than a decision
    // made on the wrong pair's data.
    final chartView = await setChartView(cdp, tvSymbol, category.signalResolution);
    if (!chartView.ok) {
      logger.log(
        '$tvSymbol ($category): chart view switch failed (${chartView.error}) - '
        'refusing to read signals from a chart that might still be showing a '
        'different symbol. Skipping this cycle.',
        level: 'ERROR',
      );
      return;
    }
    // 2026-10-18, per the user: worm_10_26 already exposes this exact
    // HH/LL/BUY/SELL signal as its own `zigzag` field (same BuySellCheck
    // shape [readSwingOscillatorSignals] used to produce - see
    // [readWorm10Signals]'s own doc comment) - this technique's own
    // decision logic below (retroactive audit, triple-read, etc.) is
    // otherwise completely unchanged, only the data source moved.
    var check = (await readWorm10Signals(
      cdp,
      tvSymbol,
      worm10Script.scriptIdPart,
      customScripts[1].scriptIdPart,
      onDebugError: (msg) => logger.log('$tvSymbol ($category) signal: $msg'),
    )).zigzag;
    // Same extra-retry treatment as the range read above, same reasoning.
    for (var i = 0; i < 2 && (check.latest == null || check.latestBarTime == null) && immediate; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      check = (await readWorm10Signals(
        cdp,
        tvSymbol,
        worm10Script.scriptIdPart,
        customScripts[1].scriptIdPart,
        onDebugError: (msg) => logger.log('$tvSymbol ($category) signal retry: $msg'),
      )).zigzag;
    }
    final latest = check.latest;
    if (latest == null || check.latestBarTime == null) {
      logger.log('$tvSymbol ($category): no signal yet, skipping cycle.');
      return;
    }

    // RETROACTIVE AUDIT - full forward replay from Start (rewritten
    // 2026-10-06, per the user: "it should check from start signal and
    // forward... check all signals after start signal (check all LL/HH/
    // Buy Sell signals after start signal) and on this check app had to
    // decide according to decision rules" - replaces the earlier version,
    // which only looked at the single most recent HH/LL plus, at most, one
    // BUY/SELL after it. That older approach could reach the WRONG verdict
    // whenever more than one flip had happened since Start (e.g. Start ->
    // disagreeing tag -> a LATER tag that flips back toward Start's own
    // direction again - the old version's "last HH/LL, then one check"
    // shape couldn't see the second flip at all), and it never considered
    // an HH/LL appearing after the anchor as something that could ALSO
    // flip the trade, only BUY/SELL. This version walks every tag
    // (HH/LL/BUY/SELL alike) strictly after Start in chronological order,
    // applying the exact same agree-or-flip rule the normal real-time flow
    // uses at each one, so it always lands on the same answer a human
    // replaying the whole chain by hand would reach. Runs once per ticket
    // per [_auditedTickets] gate (see its own doc comment) - re-armed on a
    // GUI reopen and once an hour before each new 1H candle, not on every
    // single cycle. Deliberately bypasses the generic pending-candidate
    // queue (per the user: "it is simple ... check from start signal up to
    // now ... if there is any flipping signal, close and recycle") - that
    // queue is built around "trust the single freshest tag," which can't
    // carry an old historical tag without being immediately overwritten by
    // the normal flow's own fresh `latest` read.
    if (existing != null) {
      final auditTicket = _parseTicket(existing['position_id']);
      if (auditTicket != null && !_auditedTickets.contains(auditTicket)) {
        final openSnapshot = entrySignals.peek(auditTicket);
        final runningDirection =
            (existing['action'] as String?) == 'sell' ? TradeDirection.short : TradeDirection.long;

        // The replay's starting point: the position's own recorded Start
        // signal if one exists, otherwise (the very first time this
        // ticket is ever audited, nothing recorded yet) the most recent
        // HH/LL at or before now - same bootstrap fallback the prior
        // version used, just to have SOMETHING to anchor the first-ever
        // audit to.
        Signal? startSignal;
        if (openSnapshot != null) {
          startSignal = Signal(
            tag: signalTagFromWire(openSnapshot.tag),
            time: openSnapshot.barTime,
          );
        } else {
          final hhLlCandidates = check.signals.where((s) => s.tag == SignalTag.hh || s.tag == SignalTag.ll).toList()
            ..sort((a, b) => b.time.compareTo(a.time));
          startSignal = hhLlCandidates.isEmpty ? null : hhLlCandidates.first;
        }

        if (startSignal == null) {
          // 2026-09-30, per the user: "mandatory any auto pair should have
          // a record for start signal" - deliberately do NOT mark this
          // ticket as audited when there's nothing at all to start from,
          // so it keeps retrying on later cycles (e.g. once the chart's
          // loaded history window has grown enough) instead of permanently
          // giving up after one unlucky read.
          logger.log(
            '$mt5Symbol ($category): ticket=$auditTicket has no HH/LL signal '
            'loaded far enough back to investigate yet - will retry on a later cycle.',
            level: 'WARNING',
          );
        } else {
          _auditedTickets.add(auditTicket);
          final startSignalChecked = startSignal; // promote to non-null for the closure below
          final startDirection =
              startSignalChecked.side == SignalSide.buy ? TradeDirection.long : TradeDirection.short;

          // Every tag STRICTLY after Start (2026-09-30, fixed after a
          // confirmed live false-positive on BNBUSD.lv: worm_9_26 can paint
          // MULTIPLE independent tags on the SAME bar - e.g. HH and BUY
          // both true on the bar that opened a trade. Including
          // `s.time == startSignalChecked.time` here would re-surface that
          // same already-resolved co-occurring tag as a fake flip), in
          // chronological order - the FULL history since Start, every tag
          // type, not just the single most recent HH/LL.
          final afterStart = check.signals.where((s) => s.time > startSignalChecked.time).toList()
            ..sort((a, b) => a.time.compareTo(b.time));

          // Walk forward applying the SAME rule the normal real-time flow
          // uses at every single tag: one that agrees with the current
          // direction is just a confirmation (Update); one that disagrees
          // flips the direction AND becomes the new effective Start from
          // that point on - so a position that flipped twice since opening
          // correctly lands on the SECOND flip's direction, not the first.
          var trueDirection = startDirection;
          var trueStart = startSignalChecked;
          Signal? updateSignal;
          for (final s in afterStart) {
            final sDirection = s.side == SignalSide.buy ? TradeDirection.long : TradeDirection.short;
            if (sDirection == trueDirection) {
              updateSignal = s;
            } else {
              trueDirection = sDirection;
              trueStart = s;
              updateSignal = null;
            }
          }

          // Close A/Close B gate (2026-10-06, per the user: "if there is a
          // signal on close a (current candle) then app need to apply same
          // rules for close a close b") - the replay's own final verdict
          // (`trueStart`) must survive one full extra candle the exact same
          // way a fresh real-time signal has to, before this audit trusts
          // it enough to write or act on it. Without this, a tag that just
          // landed on the still-forming current candle (Close A, not yet
          // confirmed) could get treated as final a candle early. No
          // special re-arm needed to retry this later - it simply stays in
          // [_auditedTickets] and gets picked up again by the NEXT GUI
          // reopen or hourly re-arm, which (at an hourly cadence, same as
          // this category's own candle period) naturally IS "one more
          // candle" later.
          final surviveUntil = trueStart.time + category.candlePeriod.inSeconds * 2;
          final nowEpoch = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
          if (nowEpoch < surviveUntil) {
            logger.log(
              '$mt5Symbol ($category): audit replay for ticket=$auditTicket '
              'landed on ${signalTagToWire(trueStart.tag)}@${trueStart.time}, '
              'but that bar hasn\'t survived one full extra candle yet - '
              'deferring, will re-check next time this audit re-arms.',
            );
          } else if (trueDirection == runningDirection) {
            final trueStartWire = signalTagToWire(trueStart.tag);
            // 2026-10-17 REDESIGN, per the user: "tv readings should be
            // before mt5 .. if in any scenario tv readings are after mt5
            // readings = readings are fake" - found live: this "correct an
            // already-backfilled Start" path could overwrite Open with a
            // LATER same-direction reconfirmation than the position's own
            // real MT5 open time, which can never be a legitimate "what
            // opened this trade" signal (a cause can't postdate its
            // effect). Open is now written ONCE, on the ticket's genuine
            // first backfill only - a later same-direction reconfirmation
            // belongs in the Update field below instead, which already
            // exists for exactly this. Pure persistence change - the
            // audit's own forward-replay decision logic below always
            // recomputes [trueStart] fresh from live data regardless of
            // what's stored here, so this has zero effect on trading
            // correctness, only on what gets displayed as "Open."
            if (openSnapshot == null) {
              entrySignals.record(
                auditTicket,
                EntrySignalSnapshot(tag: trueStartWire, barTime: trueStart.time),
              );
              logger.log(
                '$mt5Symbol ($category): backfilled Start signal for '
                'ticket=$auditTicket - $trueStartWire@${trueStart.time}.',
              );
            }
            if (updateSignal != null) {
              final updateWire = signalTagToWire(updateSignal.tag);
              final current = entrySignals.peek(auditTicket);
              if (current?.updateTag != updateWire || current?.updateTime != updateSignal.time) {
                entrySignals.recordUpdate(auditTicket, updateWire, updateSignal.time);
                logger.log(
                  '$mt5Symbol ($category): backfilled Update signal for '
                  'ticket=$auditTicket - $updateWire@${updateSignal.time}.',
                );
              }
            }
          } else {
            // Genuine mismatch - the true (possibly flipped) signal chain
            // disagrees with what the bot is actually running. Per the
            // user: "there is no point to continue this trade" - re-confirm
            // the signal is still really there before acting (chart data
            // can shift), then close and recycle into the correct
            // direction.
            logger.log(
              '$mt5Symbol ($category): RETROACTIVE AUDIT - ticket=$auditTicket is running '
              '${runningDirection == TradeDirection.short ? "SELL" : "BUY"} but the true signal '
              'chain says ${trueDirection == TradeDirection.short ? "SELL" : "BUY"} '
              '(${signalTagToWire(trueStart.tag)}@${trueStart.time}) - closing and recycling.',
              level: 'WARNING',
            );
            final recheck = (await readWorm10Signals(
              cdp,
              tvSymbol,
              worm10Script.scriptIdPart,
              customScripts[1].scriptIdPart,
              onDebugError: (msg) => logger.log('$tvSymbol ($category) audit recheck: $msg'),
            )).zigzag;
            final stillThere = recheck.signals.any((s) => s.tag == trueStart.tag && s.time == trueStart.time);
            if (!stillThere) {
              logger.log(
                '$tvSymbol ($category): audit signal no longer present on '
                're-read - skipping correction.',
                level: 'WARNING',
              );
            } else {
              await _closePosition(
                category,
                tvSymbol,
                mt5Symbol,
                existing,
                closeSignal: trueStart,
                stopReason: 'opposite_signal',
                detail: 'Retroactive audit: the true signal chain disagreed with the running direction.',
              );
              if (!(await _hasPendingAppOrder(mt5Symbol, category))) {
                final ignitedAudit = ignitedPairs.isIgnited(tvSymbol);
                final flipGate = risk.gate('open', mt5Symbol, category, bypassMarginGate: ignitedAudit);
                if (flipGate.allowed) {
                  if (await _openPosition(category, mapping, trueDirection, range.top, range.bottom, trueStart)) {
                    if (ignitedAudit) ignitedPairs.consume(tvSymbol);
                  }
                } else {
                  logger.log(
                    '$tvSymbol ($category): audit-driven risk gate blocked reopen: ${flipGate.reason}',
                  );
                }
              }
              return;
            }
          }
        }
      }
    }

    // TRIPLE-read confirmation (strengthened 2026-09-27, per the user:
    // "dont open/close trade unless you are 1 million sure" - a single
    // double-read (6s apart) still let real flickers through, including
    // one this exact session where the app read BUY then SELL, 6s apart,
    // for the same symbol. Mirrors tradingPionex's flicker fix, but
    // requires the signal to agree across THREE independent reads spaced
    // 10s apart (20s total) - a single coincidental repeat is far less
    // likely across three tries than two. Compares the raw TAG, not just
    // its side (2026-09-29) - e.g. HH and SELL both mean "sell" but are
    // genuinely different tags, and a flip between them mid-confirmation
    // is exactly the kind of instability this check exists to catch. Never
    // mark the bar as seen on disagreement, so a genuinely fresh signal
    // gets a clean re-check next cycle instead of acting on a flicker.
    for (var i = 0; i < 2; i++) {
      await Future<void>.delayed(const Duration(seconds: 10));
      final recheck = (await readWorm10Signals(
        cdp,
        tvSymbol,
        worm10Script.scriptIdPart,
        customScripts[1].scriptIdPart,
        onDebugError: (msg) => logger.log('$tvSymbol ($category) signal recheck: $msg'),
      )).zigzag;
      final recheckLatest = recheck.latest;
      if (recheckLatest == null ||
          recheckLatest.tag != latest.tag ||
          recheckLatest.time != latest.time) {
        logger.log(
          '$tvSymbol ($category): SIGNAL FLICKER (read ${i + 2}/3) - first '
          'read ${signalTagToWire(latest.tag)}@${latest.time}, this read '
          '${recheckLatest != null ? signalTagToWire(recheckLatest.tag) : null}'
          '@${recheckLatest?.time} disagree — skipping this cycle.',
          level: 'WARNING',
        );
        return;
      }
    }

    // "Survive one full extra candle" wait gate, part 2 (2026-09-30 - see
    // the doc comment on the early skip-gate above and on
    // [PendingSignalStore]). `latest` here is always the freshest tag
    // across the WHOLE chart, so if nothing newer has appeared since
    // [pending] was registered, `latest` still points at the exact same
    // tag+bar - that alone proves the candle after it came up empty, no
    // separate "inspect candle B directly" check needed.
    final latestWire = signalTagToWire(latest.tag);
    if (!immediate && (pending == null || pending.tag != latestWire || pending.barTime != latest.time)) {
      // Either the very first time this signal is being seen, or a newer
      // one has replaced whatever was pending - either way, this becomes
      // the new candidate and must itself survive one full extra candle
      // before anything acts on it.
      pendingSignals.set(barKey, latestWire, latest.time);
      logger.log(
        '$tvSymbol ($category): $latestWire@${latest.time} triple-confirmed - '
        'deferring action until the following candle confirms it (no waiting '
        'was needed before this rule; still 1-million-sure once it resolves).',
      );
      return;
    }
    if (immediate) {
      logger.log(
        '$tvSymbol ($category): technique switch reverse check - '
        '$latestWire@${latest.time} triple-confirmed, acting immediately.',
      );
    }
    // Confirmed unchanged through a full extra candle - act on it now via
    // the decision engine below, using THIS cycle's fresh range/signal
    // reads (per the user: "just act as if signal occures now. instant
    // action"). Deliberately NOT cleared yet (2026-09-30, per the user:
    // "once app terminate the trade = sure close signal == sure recycle
    // signal ... app currently waiting for next signal after closing. and
    // this is not okay") - clearing unconditionally here lost the
    // "already confirmed" status the instant a close+flip's immediate
    // reopen hit a retriable snag (duplicate order resting, risk gate, a
    // failed order) and had NOTHING left to retry with except waiting out
    // an entire fresh candle for the same signal all over again. Now only
    // cleared by each branch below once its action genuinely succeeds (or
    // is a legitimate no-op, i.e. "ignore") - every other path leaves this
    // exact confirmed signal in place, and since `checkAt` only ever
    // moves further into the past from here, every future cycle retries
    // it immediately (past the skip-gate, past the wait) with no extra
    // flag needed.

    // Decision engine (simplified 2026-09-29, per the user: "no delete
    // this .... i want to do action immediatly according to signal ...
    // signal appears > 1 million reading > action" / "no waitng for new
    // signal" / "delete it from code and prd" - removes the earlier HH/LL
    // "close only, wait for a genuinely new tag" exception entirely. Every
    // tag type is now treated identically once triple-read confirmed: a
    // disagreeing signal ALWAYS closes and immediately reopens opposite,
    // never just closes-and-waits. The "1 million reading" is the
    // triple-read confirmation above, not a cooldown after that - once
    // confirmed, the action is immediate.
    final newDirection = latest.side == SignalSide.buy ? TradeDirection.long : TradeDirection.short;

    if (existing != null) {
      final existingDirection =
          (existing['action'] as String?) == 'sell' ? TradeDirection.short : TradeDirection.long;
      if (existingDirection == newDirection) {
        // Same direction - the confirming tag agrees with the running
        // position. Ignore (no close/reopen). Also record it as the
        // Dashboard table's Update Signal, but ONLY for the exact
        // cross-tag confirmation the user described (2026-09-29: "also
        // update if there is Buy signal with LL or sell signal with HH") -
        // i.e. the entry snapshot's OWN start tag was HH/LL and this new
        // tag is the opposite-kind SELL/BUY confirming it. A same-tag
        // repeat (e.g. a second HH while already running the HH-started
        // short) is still correctly ignored for trading purposes, but does
        // NOT count as an "update" in the table - the user's wording never
        // described that case as one.
        final existingTicket = _parseTicket(existing['position_id']);
        if (existingTicket != null) {
          final startTag = entrySignals.peek(existingTicket)?.tag;
          final wireTag = signalTagToWire(latest.tag);
          final isCrossConfirm = (startTag == 'HH' && wireTag == 'SELL') ||
              (startTag == 'LL' && wireTag == 'BUY');
          if (isCrossConfirm) {
            entrySignals.recordUpdate(existingTicket, wireTag, latest.time);
          }
        }
        pendingSignals.clear(barKey);
        return;
      }
      // Disagrees - wrong direction. Close AND immediately reopen
      // opposite, same signal instance, regardless of tag type. Per the
      // user: "sure close signal == sure recycle signal" - a retriable
      // snag below (duplicate order already resting, risk gate, or the
      // open itself failing) must NOT clear [pendingSignals]; only a
      // genuine success does, so a failed recycle attempt retries this
      // exact confirmed signal again next cycle instead of waiting out a
      // fresh candle.
      await _closePosition(category, tvSymbol, mt5Symbol, existing, closeSignal: latest);
      if (await _hasPendingAppOrder(mt5Symbol, category)) {
        logger.log(
          '$tvSymbol ($category): a pending order for this symbol/category '
          'is already resting in MT5 - not placing a duplicate.',
        );
        return;
      }
      final ignitedFlip = ignitedPairs.isIgnited(tvSymbol);
      final flipGate = risk.gate('open', mt5Symbol, category, bypassMarginGate: ignitedFlip);
      if (!flipGate.allowed) {
        logger.log('$tvSymbol ($category): risk gate blocked open: ${flipGate.reason}');
        return;
      }
      if (await _openPosition(category, mapping, newDirection, range.top, range.bottom, latest)) {
        pendingSignals.clear(barKey);
        if (ignitedFlip) ignitedPairs.consume(tvSymbol);
      }
      return;
    }

    // No position running - open in the latest tag's own direction. Same
    // "only clear on genuine success" rule as the close+flip branch above.
    if (await _reconcileStaleRestingOrderIfAny(category, tvSymbol, mt5Symbol, newDirection, range.top, range.bottom)) {
      return;
    }

    // "Wait for a confirmed opposite signal" gate, first-ever entry only
    // (2026-10-06, per the user: "create waiting trades OPPOSITE to
    // current signal... wait the opposite signal to occur... once
    // assured, fill it" / "this only for new added auto trades not for
    // recycled ones"). A pair that's never achieved a real open yet
    // doesn't trust whatever direction happens to be showing the first
    // time it's checked - that signal could already be stale, close to
    // its own reversal. It waits for a GENUINELY opposite direction to
    // show up instead, through the exact same triple-read +
    // survive-one-candle confirmation every signal already had to pass to
    // reach this point - that machinery already IS the "another checkup"
    // being asked for, no separate extra check needed. Anything that's
    // EVER had a real open before skips this entirely and behaves exactly
    // as before - [firstOpen] is permanent once set, see its own doc
    // comment.
    final seasonKey = '${category.wireValue}|$tvSymbol';
    if (!firstOpen.hasOpened(seasonKey)) {
      final excluded = newPairWait.get(seasonKey);
      if (excluded == null) {
        newPairWait.set(seasonKey, newDirection);
        logger.log(
          '$tvSymbol ($category): new pair, never opened before - not '
          'entering on the first signal seen '
          '(${newDirection == TradeDirection.long ? "BUY" : "SELL"}) - '
          'waiting for a confirmed OPPOSITE signal before its first-ever entry.',
        );
        return;
      }
      if (newDirection == excluded) {
        // Still the same direction being waited out - nothing has
        // reversed yet, keep waiting.
        return;
      }
      newPairWait.clear(seasonKey);
      logger.log(
        '$tvSymbol ($category): confirmed opposite signal arrived - '
        'clearing this new pair for its first-ever entry.',
      );
    }

    // Ignite bypass (2026-10-17, per the user: "margin level has nothing
    // to do with manual ignited pair") - a pair the user explicitly
    // ignited via the Dashboard's thunder icon still waits for this same
    // genuine signal, it just doesn't get blocked by margin level once
    // the signal is real. One-shot: consumed the moment this fresh open
    // actually succeeds.
    final ignited = ignitedPairs.isIgnited(tvSymbol);
    final gate = risk.gate('open', mt5Symbol, category, bypassMarginGate: ignited);
    if (!gate.allowed) {
      logger.log('$tvSymbol ($category): risk gate blocked open: ${gate.reason}');
      return;
    }
    if (ignited) {
      logger.log('$tvSymbol ($category): opening on an ignited pair - margin-level gate bypassed.');
    }

    if (await _openPosition(category, mapping, newDirection, range.top, range.bottom, latest)) {
      pendingSignals.clear(barKey);
      firstOpen.markOpened(seasonKey);
      if (ignited) ignitedPairs.consume(tvSymbol);
    }
  }

  /// Supertrend Plus's own decision flow (2026-10-06, second decision
  /// technique) - deliberately a SEPARATE method from [_checkOneSymbol]
  /// rather than more branches threaded through that already-large
  /// function, same reasoning as [enforceSupertrendPlus]'s own doc comment.
  /// Much simpler by design, straight from the user's own spec: "the chart
  /// only show entry signals (buy/sell) so once signal is buy == open buy
  /// trade. the close of this buy trade will be the beginning of sell
  /// signal" - confirmed live that these two plots fire as sparse, strictly
  /// alternating events, so there's no HH/LL trend-anchor concept, no
  /// cross-tag "Update" confirmation, and (deliberately, per the user's
  /// point 5: "if the app has waiting trade... if it is currently buy, then
  /// app need to start buy") no [firstOpen]/[newPairWait] "wait for the
  /// opposite signal" gate for a brand-new pair either - a new pair here
  /// takes whatever's currently confirmed immediately, simply by never
  /// calling into those stores at all.
  ///
  /// No separate retroactive-audit replay like [_checkOneSymbol]'s own
  /// block: that machinery exists because Signal Flip's running direction
  /// can drift from the truth across an HH/LL + BUY/SELL chain the Dashboard
  /// never re-walks on its own. Here, every single cycle already re-reads
  /// the latest triple-confirmed Buy/Sell tag and compares it straight
  /// against the running direction (the exact same "reverse check... if
  /// everything agrees with signal, keep trade as is... if something is
  /// against it, then close" the user originally asked for) - so the
  /// ongoing per-cycle comparison below already IS the reverse check, with
  /// nothing historical left to replay. The hourly re-arm in [run] still
  /// fires, but has no audit block to trigger for tickets opened under this
  /// technique.
  /// See [_checkOneSymbol]'s own doc comment on [immediate] - identical
  /// meaning and only source (the technique-switch sweep), just against
  /// [supertrendPending] instead of [pendingSignals].
  Future<void> _checkOneSymbolSupertrend(
    AutoCategory category,
    SymbolMapping mapping, {
    bool immediate = false,
  }) async {
    final tvSymbol = mapping.tradingViewSymbol;
    final mt5Symbol = mapping.mt5Symbol;
    final barKey = '${category.wireValue}|$tvSymbol';

    // Drop any leftover Signal Flip pending entry for this pair (2026-10-07,
    // per the user: "why there is LL/HH in auto table while the technique
    // selected is supertrend????" - found live: a pair that had a candidate
    // HH/LL/BUY/SELL sitting in [pendingSignals] from BEFORE switching to
    // Supertrend Plus kept showing it in the Dashboard's Close A column
    // forever after, since this method only ever reads/writes/clears
    // [supertrendPending] - [pendingSignals] is never Supertrend Plus's to
    // leave alone, it belongs entirely to Signal Flip, so nothing here was
    // ever going to clear a stale entry on its own). Cheap no-op once
    // already clear.
    pendingSignals.clear(barKey);

    final existing = await _findAppPosition(mt5Symbol, category, tvSymbol);

    // Survive-one-candle gate REMOVED for a currently-running trade
    // (2026-10-08, per the user: "for currently running trades, i dont want
    // app to wait for close a and close b to confirm signal flipping. i
    // want app once opposite signal appears, then app need to take the
    // action. this only applies on supertrend technique") - a running
    // position now flips the instant its opposite signal is TRIPLE-READ
    // confirmed (still "1 million sure" - the triple-read a few lines below
    // is never skipped), with no extra-candle wait on top of that any more.
    // Still applies in full to a pair with NO running position (a fresh
    // first-ever open, or a not-yet-filled resting order) - the user's own
    // wording ("currently running trades ... signal flipping") only
    // describes an already-open position reversing, not a brand-new entry,
    // so that case is deliberately left exactly as it was before this
    // change. [supertrendPending] stays the mechanism for that remaining
    // case; it's simply never consulted at all once [existing] is non-null.
    final skipExtraCandleWait = existing != null;

    // Own survive-one-candle gate, using the SEPARATE [supertrendPending]
    // store (2026-10-06, per the user: "you have to make same signal check
    // as close a close b .. so you are sure about signal flipping") - never
    // [pendingSignals], so the Dashboard's "Close A"/"Update" columns stay
    // blank for Supertrend-driven pairs with zero changes to that GUI code
    // (see [CoreStorage.supertrendPendingFile]'s own doc comment). Bypassed
    // entirely when [immediate] or [skipExtraCandleWait].
    final pending = supertrendPending.get(barKey);
    if (!immediate && !skipExtraCandleWait && pending != null) {
      final checkAt = pending.barTime + category.candlePeriod.inSeconds * 2;
      final nowEpoch = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      if (nowEpoch < checkAt) return;
    }

    final lastChecked = _lastCheckedAt[barKey];
    if (!immediate && lastChecked != null && DateTime.now().difference(lastChecked) < _retryCooldown) {
      return;
    }
    _lastCheckedAt[barKey] = DateTime.now();

    if (existing != null) lastCheckedStore.record(tvSymbol);

    await _ensureCdpUp();
    final cdp = _cdp!;

    // TP/SL range - 2026-10-18, per the user: worm_10_26 now carries its
    // own range/zigzag data built in (the same reason [_checkOneSymbolWorm10]
    // already reads its range this exact way) - no more separate worm_9_26
    // script needed just for this. Identical triple-read confirmation to
    // [_checkOneSymbol]'s own range read - literally the same shared
    // [_readConfirmedRange] helper, just pointed at a different script now.
    final range = await _readConfirmedRange(
      cdp,
      category,
      tvSymbol,
      immediate: immediate,
      scriptIdPart: worm10Script.scriptIdPart,
    );
    if (range == null) return;

    // Supertrend Plus's own Buy/Sell entry signal - 2026-10-18, per the
    // user: "worm 10 is include supertrend plus signal... so there is no
    // need for supertrend plus indicator anymore". worm_10_26 already
    // exposes this exact signal as its own `supertrend` field (same
    // BuySellCheck shape [readSupertrendSignals] used to produce - see
    // [readWorm10Signals]'s own doc comment) - this technique's own
    // decision logic below is otherwise completely unchanged, only the
    // data source moved.
    // 2026-10-17 - same unchecked-result bug fixed everywhere else this
    // exact call appears - see [_checkOneSymbol]'s own matching fix for
    // the full root-cause reasoning (confirmed live: a whole sweep
    // misattributing one stuck symbol's stale signal to every other
    // symbol in it).
    final chartView = await setChartView(cdp, tvSymbol, category.signalResolution);
    if (!chartView.ok) {
      logger.log(
        '$tvSymbol ($category): chart view switch failed (${chartView.error}) - '
        'refusing to read signals from a chart that might still be showing a '
        'different symbol. Skipping this cycle.',
        level: 'ERROR',
      );
      return;
    }
    final check = await readWorm10Signals(
      cdp,
      tvSymbol,
      worm10Script.scriptIdPart,
      customScripts[1].scriptIdPart,
      onDebugError: (msg) => logger.log('$tvSymbol ($category) supertrend signal: $msg'),
    );
    var latest = check.supertrend.latest;
    // Same extra-retry treatment as the range read above, same reasoning.
    for (var i = 0; i < 2 && latest == null && immediate; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      final retryCheck = await readWorm10Signals(
        cdp,
        tvSymbol,
        worm10Script.scriptIdPart,
        customScripts[1].scriptIdPart,
        onDebugError: (msg) => logger.log('$tvSymbol ($category) supertrend signal retry: $msg'),
      );
      latest = retryCheck.supertrend.latest;
    }
    if (latest == null) {
      logger.log('$tvSymbol ($category): no supertrend signal yet, skipping cycle.');
      return;
    }

    // TRIPLE-read confirmation, same "1 million sure" rule as
    // [_checkOneSymbol]'s own signal read.
    for (var i = 0; i < 2; i++) {
      await Future<void>.delayed(const Duration(seconds: 10));
      final recheck = await readWorm10Signals(
        cdp,
        tvSymbol,
        worm10Script.scriptIdPart,
        customScripts[1].scriptIdPart,
        onDebugError: (msg) => logger.log('$tvSymbol ($category) supertrend recheck: $msg'),
      );
      final recheckLatest = recheck.supertrend.latest;
      if (recheckLatest == null || recheckLatest.tag != latest.tag || recheckLatest.time != latest.time) {
        logger.log(
          '$tvSymbol ($category): SUPERTREND SIGNAL FLICKER (read ${i + 2}/3) - first '
          'read ${signalTagToWire(latest.tag)}@${latest.time}, this read '
          '${recheckLatest != null ? signalTagToWire(recheckLatest.tag) : null}'
          '@${recheckLatest?.time} disagree — skipping this cycle.',
          level: 'WARNING',
        );
        return;
      }
    }

    // "Survive one full extra candle" wait gate, part 2 - same shape as
    // [_checkOneSymbol]'s, just against [supertrendPending] instead.
    // Bypassed entirely when [immediate] or [skipExtraCandleWait] (a
    // currently-running trade - see this method's own doc comment above on
    // [skipExtraCandleWait] for why).
    final latestWire = signalTagToWire(latest.tag);
    if (!immediate && !skipExtraCandleWait &&
        (pending == null || pending.tag != latestWire || pending.barTime != latest.time)) {
      supertrendPending.set(barKey, latestWire, latest.time);
      logger.log(
        '$tvSymbol ($category): supertrend $latestWire@${latest.time} triple-confirmed - '
        'deferring action until the following candle confirms it.',
      );
      return;
    }
    if (immediate) {
      logger.log(
        '$tvSymbol ($category): technique switch reverse check - '
        'supertrend $latestWire@${latest.time} triple-confirmed, acting immediately.',
      );
    } else if (skipExtraCandleWait) {
      logger.log(
        '$tvSymbol ($category): supertrend $latestWire@${latest.time} triple-confirmed - '
        'running trade, acting immediately (no extra-candle wait for a signal flip).',
      );
    }
    // Confirmed unchanged through a full extra candle - act on it now.
    // Deliberately NOT cleared here, same reasoning as [_checkOneSymbol]'s
    // own comment - only cleared by each branch below once its action
    // genuinely succeeds.

    final newDirection = latest.side == SignalSide.buy ? TradeDirection.long : TradeDirection.short;

    if (existing != null) {
      final existingDirection =
          (existing['action'] as String?) == 'sell' ? TradeDirection.short : TradeDirection.long;
      if (existingDirection == newDirection) {
        // Same direction - the confirming tag agrees with the running
        // position (in practice rare, since Buy/Sell strictly alternate,
        // but handled defensively). Ignore - no close/reopen. Deliberately
        // NEVER call `entrySignals.recordUpdate(...)` here or anywhere else
        // in this method - per the user: "close A, Update will nevr be
        // filled in auto table. they are always blank" - the Update column
        // stays blank with no suppression code needed, since it's simply
        // never written for this technique.
        //
        // Backfill the Open Signal snapshot to THIS confirmed Supertrend
        // tag (2026-10-06, per the user: "why auto table is not updated
        // according to opensignal... i can still seel HHLL??" - found live:
        // a pair left running because it already agreed (no close+reopen)
        // kept showing whatever tag ACTUALLY opened it, which for a pair
        // opened back under Signal Flip is a stale HH/LL - correct as a
        // literal history of that open, but confusing once the table is
        // meant to reflect Supertrend Plus going forward). Same backfill
        // concept Signal Flip's own retroactive audit already uses for its
        // own "agrees" case - only writes when it's actually different, so
        // a pair the sweep re-confirms every Power-on doesn't rewrite the
        // same value over and over.
        final ticket = _parseTicket(existing['position_id']);
        if (ticket != null) {
          final currentSnapshot = entrySignals.peek(ticket);
          if (currentSnapshot?.tag != latestWire || currentSnapshot?.barTime != latest.time) {
            entrySignals.record(ticket, EntrySignalSnapshot(tag: latestWire, barTime: latest.time));
          }
        }
        supertrendPending.clear(barKey);
        return;
      }
      // Disagrees - the opposite signal has arrived, which per the user's
      // own spec IS the close for the running trade ("the close of this buy
      // trade will be the beginning of sell signal"). Close AND immediately
      // reopen opposite, same signal instance. Open/close signals ARE
      // recorded to bot-history here (via [_closePosition]'s own
      // [_recordHistory] call and [_openPosition]'s own
      // [_recordOpenSignal] call) - the "always blank" instruction is
      // specifically about the Dashboard's live columns, not the
      // permanent History record.
      await _closePosition(category, tvSymbol, mt5Symbol, existing, closeSignal: latest);
      if (await _hasPendingAppOrder(mt5Symbol, category)) {
        logger.log(
          '$tvSymbol ($category): a pending order for this symbol/category '
          'is already resting in MT5 - not placing a duplicate.',
        );
        return;
      }
      final ignitedFlip = ignitedPairs.isIgnited(tvSymbol);
      final flipGate = risk.gate('open', mt5Symbol, category, bypassMarginGate: ignitedFlip);
      if (!flipGate.allowed) {
        logger.log('$tvSymbol ($category): risk gate blocked open: ${flipGate.reason}');
        return;
      }
      if (await _openPosition(category, mapping, newDirection, range.top, range.bottom, latest)) {
        supertrendPending.clear(barKey);
        if (ignitedFlip) ignitedPairs.consume(tvSymbol);
      }
      return;
    }

    // No position running - open (or, for a waiting/not-yet-filled pair,
    // make sure the resting order still matches) in the latest signal's own
    // direction. Per the user's point 5: "if the app has waiting trade,
    // then app need to look at the beginning of current buy/sell signals.
    // if it is currently buy, then app need to start buy" - no
    // [firstOpen]/[newPairWait] gate for this technique, see this method's
    // own doc comment.
    if (await _reconcileStaleRestingOrderIfAny(category, tvSymbol, mt5Symbol, newDirection, range.top, range.bottom)) {
      return;
    }

    final ignited = ignitedPairs.isIgnited(tvSymbol);
    final gate = risk.gate('open', mt5Symbol, category, bypassMarginGate: ignited);
    if (!gate.allowed) {
      logger.log('$tvSymbol ($category): risk gate blocked open: ${gate.reason}');
      return;
    }
    if (ignited) {
      logger.log('$tvSymbol ($category): opening on an ignited pair - margin-level gate bypassed.');
    }

    if (await _openPosition(category, mapping, newDirection, range.top, range.bottom, latest)) {
      supertrendPending.clear(barKey);
      if (ignited) ignitedPairs.consume(tvSymbol);
    }
  }

  /// The third decision technique (worm_10_26 + spy_9_26, Heikin Ashi,
  /// 2026-10-14) - deliberately a separate method, same reasoning as
  /// [_checkOneSymbolSupertrend]'s own doc comment. Full spec and the pure
  /// decision logic this method is just a thin MT5/TradingView wrapper
  /// around live in `lib/data/engine/worm10_decision.dart` - see that
  /// file's own doc comment for the complete case-by-case reasoning,
  /// confirmed directly with the user across multiple corrected rounds
  /// (several earlier guesses were wrong and explicitly corrected - do not
  /// re-derive the spec from first principles, trust that file).
  ///
  /// Same triple-confirm + survive-one-candle shape as [_checkOneSymbol]
  /// (NOT [_checkOneSymbolSupertrend]'s "skip the extra candle for a
  /// running trade" shortcut - that was explicitly scoped to "the
  /// supertrend technique" only, never generalized to this one). Does keep
  /// an Update concept, like [_checkOneSymbol] and unlike
  /// [_checkOneSymbolSupertrend] - a same-direction zigzag signal while
  /// already running is a real Update per the spec, not a non-event.
  Future<void> _checkOneSymbolWorm10(
    AutoCategory category,
    SymbolMapping mapping, {
    bool immediate = false,
  }) async {
    final tvSymbol = mapping.tradingViewSymbol;
    final mt5Symbol = mapping.mt5Symbol;
    final barKey = '${category.wireValue}|$tvSymbol';

    // Drop any leftover pending entry from the OTHER two techniques for
    // this pair - same reasoning as both of their own equivalent clears.
    pendingSignals.clear(barKey);
    supertrendPending.clear(barKey);

    final existing = await _findAppPosition(mt5Symbol, category, tvSymbol);

    final pending = worm10Pending.get(barKey);
    if (!immediate && pending != null) {
      final checkAt = pending.barTime + category.candlePeriod.inSeconds * 2;
      final nowEpoch = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      if (nowEpoch < checkAt) return;
    }

    final lastChecked = _lastCheckedAt[barKey];
    if (!immediate && lastChecked != null && DateTime.now().difference(lastChecked) < _retryCooldown) {
      return;
    }
    _lastCheckedAt[barKey] = DateTime.now();

    if (existing != null) lastCheckedStore.record(tvSymbol);

    await _ensureCdpUp();
    final cdp = _cdp!;

    // worm_10_26 carries its own MSB/ZigZag++ range data (same plot
    // structure as worm_9_26, different scriptIdPart) - see
    // [_readConfirmedRange]'s own doc comment on its [scriptIdPart]
    // parameter.
    final range = await _readConfirmedRange(
      cdp,
      category,
      tvSymbol,
      immediate: immediate,
      scriptIdPart: worm10Script.scriptIdPart,
    );
    if (range == null) return;

    // 2026-10-17 - THIS is the exact call that caused a confirmed real
    // financial loss: its return value was never checked, so when the
    // chart-view switch silently timed out during a "verify every
    // auto-managed pair" sweep, the code kept reading whatever symbol the
    // chart was ACTUALLY still showing and misattributing it to every
    // other symbol in the sweep - confirmed live via engine.log: 26
    // different symbols all returned the IDENTICAL 10-day-old
    // SELL_OPEN1@Oct6 event, each read roughly 43s apart, one per symbol in
    // the sweep's own alphabetical order, meaning only the very first
    // symbol's chart was ever genuinely showing - every subsequent "switch"
    // never actually happened. See [_checkOneSymbol]'s own matching fix for
    // the general pattern.
    final chartView = await setChartView(cdp, tvSymbol, category.signalResolution);
    if (!chartView.ok) {
      logger.log(
        '$tvSymbol ($category): chart view switch failed (${chartView.error}) - '
        'refusing to read signals from a chart that might still be showing a '
        'different symbol. Skipping this cycle.',
        level: 'ERROR',
      );
      return;
    }
    var check = await readWorm10Signals(
      cdp,
      tvSymbol,
      worm10Script.scriptIdPart,
      customScripts[1].scriptIdPart,
      onDebugError: (msg) => logger.log('$tvSymbol ($category) worm10 signal: $msg'),
    );
    // 2026-10-18, per a real confirmed bug - [chartView.ok] only means the
    // chart's symbol LABEL switched; the worm_10_26/spy_9_26 scripts' own
    // computed plot data can still lag behind that for a few seconds
    // (confirmed live in the backtester, same mechanism: a stale read
    // right after a symbol switch produced an impossible Update timestamp
    // over a month before its own position's Open, on 3 separate live
    // tickets). Only worth the settle delay when a switch actually
    // happened this cycle ([chartView.switched]) - most cycles re-check a
    // chart already showing the right symbol.
    if (chartView.switched) {
      var stable = false;
      for (var attempt = 0; attempt < 6; attempt++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        final recheck = await readWorm10Signals(
          cdp,
          tvSymbol,
          worm10Script.scriptIdPart,
          customScripts[1].scriptIdPart,
          onDebugError: (msg) => logger.log('$tvSymbol ($category) worm10 settle recheck: $msg'),
        );
        final prevLast = check.zigzag.signals.isEmpty ? null : check.zigzag.signals.last;
        final nextLast = recheck.zigzag.signals.isEmpty ? null : recheck.zigzag.signals.last;
        final agree = prevLast?.time == nextLast?.time && prevLast?.tag == nextLast?.tag;
        check = recheck;
        if (agree) {
          stable = true;
          break;
        }
        logger.log(
          '$tvSymbol ($category): worm10 signal data still settling after '
          'the symbol switch (attempt ${attempt + 1}/6) - retrying.',
        );
      }
      if (!stable) {
        logger.log(
          '$tvSymbol ($category): worm10 signal data never stabilized after '
          'switching charts - skipping this cycle rather than risk acting on '
          'possibly-stale data from another symbol.',
          level: 'ERROR',
        );
        return;
      }
    }
    var events = deriveWorm10Events(check);
    // Same extra-retry treatment as every other technique's own signal read.
    for (var i = 0; i < 2 && events.isEmpty && immediate; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      check = await readWorm10Signals(
        cdp,
        tvSymbol,
        worm10Script.scriptIdPart,
        customScripts[1].scriptIdPart,
        onDebugError: (msg) => logger.log('$tvSymbol ($category) worm10 signal retry: $msg'),
      );
      events = deriveWorm10Events(check);
    }
    if (events.isEmpty) {
      logger.log('$tvSymbol ($category): no worm10 event yet, skipping cycle.');
      return;
    }
    final latest = events.last;

    // RETROACTIVE AUDIT - full forward replay from Start, same shape and
    // reasoning as [_checkOneSymbol]'s own block (2026-10-14, added after
    // the user asked directly "please confirm that app open trades are
    // updated according to buy/sell HH/LL reverse reading" - found live
    // this technique had ONLY the real-time single-latest-event check,
    // never this replay, unlike Signal Flip. Without it, more than one
    // flip happening between checks (e.g. a long outage) could land on
    // the wrong direction, since the real-time path only ever compares
    // the single newest event against whatever's currently running, not
    // the full chain since Start). Reuses [worm10DecisionFor] directly at
    // every step - the exact same pure function the real-time path uses,
    // so the two can never disagree about what a given event does.
    if (existing != null) {
      final auditTicket = _parseTicket(existing['position_id']);
      if (auditTicket != null && !_auditedTickets.contains(auditTicket)) {
        final openSnapshot = worm10EntrySignals.peek(auditTicket);
        final runningDirection =
            (existing['action'] as String?) == 'sell' ? TradeDirection.short : TradeDirection.long;

        // Start is ALWAYS the latest genuine case-1 confluence event
        // (buyOpen1/sellOpen1) - NEVER whatever this specific ticket
        // happens to have recorded as its own open snapshot (corrected
        // 2026-10-14, per the user, after an initial wrong attempt: "go
        // backwards to the latest LL/HH case 1 open buy/sell... not go
        // backwards to the signal where trade actually open" - a running
        // position can genuinely have been OPENED by a flip that itself
        // fired on a bare zigzag tag, not a case-1 confluence; the audit
        // must still anchor to the latest real case-1 event regardless of
        // what literally opened this ticket, per the user's own spec:
        // "look backwards at latest open signal case 1."
        var auditEvents = events;
        var case1Events = auditEvents
            .where((e) => e.kind == Worm10EventKind.buyOpen1 || e.kind == Worm10EventKind.sellOpen1)
            .toList()
          ..sort((a, b) => b.time.compareTo(a.time));
        var startEvent = case1Events.isEmpty ? null : case1Events.first;

        // No case-1 confluence anywhere in the currently-loaded window - per
        // the user ("app pulls the data from there", 2026-10-14), the app
        // itself must ask TradingView for more backward history and look
        // again before giving up, not just defer forever on whatever happens
        // to already be loaded.
        if (startEvent == null) {
          final eventsBefore = auditEvents.length;
          final extended = await requestMoreChartHistory(cdp);
          logger.log(
            '$mt5Symbol ($category): worm10 history-extend for ticket=$auditTicket '
            'returned extended=$extended (had $eventsBefore events loaded before).',
          );
          if (extended) {
            final reread = await readWorm10Signals(
              cdp,
              tvSymbol,
              worm10Script.scriptIdPart,
              customScripts[1].scriptIdPart,
              onDebugError: (msg) => logger.log('$tvSymbol ($category) worm10 extended-history read: $msg'),
            );
            auditEvents = deriveWorm10Events(reread);
            case1Events = auditEvents
                .where((e) => e.kind == Worm10EventKind.buyOpen1 || e.kind == Worm10EventKind.sellOpen1)
                .toList()
              ..sort((a, b) => b.time.compareTo(a.time));
            startEvent = case1Events.isEmpty ? null : case1Events.first;
            logger.log(
              '$mt5Symbol ($category): worm10 history-extend for ticket=$auditTicket '
              're-read ${auditEvents.length} events after extension (was $eventsBefore), '
              'found ${case1Events.length} case-1 events in the extended window.',
            );
            if (startEvent != null) {
              logger.log(
                '$mt5Symbol ($category): pulled more chart history for ticket=$auditTicket '
                'and found a case-1 event further back - continuing audit.',
              );
            }
          }
        }

        if (startEvent == null) {
          logger.log(
            '$mt5Symbol ($category): ticket=$auditTicket has no worm10 event '
            'loaded far enough back to investigate yet, even after requesting '
            'more chart history - will retry on a later cycle.',
            level: 'WARNING',
          );
        } else {
          _auditedTickets.add(auditTicket);
          final startEventChecked = startEvent;
          var trueDirection = worm10DecisionFor(null, startEventChecked.kind).resultDirection!;
          var trueStart = startEventChecked;
          Worm10Event? updateEvent;

          // Every event STRICTLY after Start, in chronological order - the
          // full history since Start, not just the single most recent one.
          final afterStart = auditEvents.where((e) => e.time > startEventChecked.time).toList()
            ..sort((a, b) => a.time.compareTo(b.time));
          for (final e in afterStart) {
            final decision = worm10DecisionFor(trueDirection, e.kind);
            switch (decision.action) {
              case Worm10Action.none:
                break;
              case Worm10Action.update:
                updateEvent = e;
              case Worm10Action.recycle:
                trueStart = e;
                updateEvent = null;
              case Worm10Action.flip:
              case Worm10Action.openFresh:
                // openFresh can't actually happen here - [trueDirection]
                // is never null mid-walk - but the switch must be
                // exhaustive; treated identically to a flip if it somehow
                // did.
                trueDirection = decision.resultDirection!;
                trueStart = e;
                updateEvent = null;
            }
          }

          // Same "survive one full extra candle" gate as [_checkOneSymbol]'s
          // own audit - the replay's own final verdict must be at least
          // one candle old before this audit trusts it enough to ACT (i.e.
          // close and recycle/flip a real position). But a brand new
          // ticket that has NEVER had any Open recorded at all
          // (openSnapshot == null) isn't an action this gate needs to
          // protect - the position is already open and running regardless
          // of whether this bar has "survived" yet; withholding the
          // Open-column backfill in that case was pure display lag with no
          // safety benefit (confirmed live, 2026-10-14, per the user: a
          // freshly-opened ticket's own triggering bar is always recent,
          // so this gate was leaving Open blank for up to 2 full candles
          // on every single new position - "since trade is running it
          // means OPEN signal is detected... record that signal"). Only
          // the real mismatch/close-and-recycle action below, and
          // CORRECTING an already-recorded Start, still wait for the gate.
          final surviveUntil = trueStart.time + category.candlePeriod.inSeconds * 2;
          final nowEpoch = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
          final trueStartWire = worm10EventKindToWire(trueStart.kind);
          final barHasSurvived = nowEpoch >= surviveUntil;
          // Only a brand-new ticket (nothing recorded yet) whose computed
          // direction already MATCHES what's running is pure bookkeeping -
          // every other case (a mismatch needing a real close+recycle, or
          // correcting an existing record) still waits for the gate below.
          final isBrandNewBookkeepingOnly = openSnapshot == null && trueDirection == runningDirection;
          if (!barHasSurvived && !isBrandNewBookkeepingOnly) {
            logger.log(
              '$mt5Symbol ($category): worm10 audit replay for ticket=$auditTicket '
              'landed on $trueStartWire@${trueStart.time}, but that bar hasn\'t '
              'survived one full extra candle yet - deferring, will re-check '
              'next time this audit re-arms.',
            );
          } else if (trueDirection == runningDirection) {
            // 2026-10-17 REDESIGN, per the user: "tv readings should be
            // before mt5 .. if in any scenario tv readings are after mt5
            // readings = readings are fake" - found live (ticket
            // 1660890548): this "correct an already-backfilled Start" path
            // could overwrite Open with a LATER same-direction
            // reconfirmation than the position's own real MT5 open time,
            // which can never be a legitimate "what opened this trade"
            // signal. Open is now written ONCE, on the ticket's genuine
            // first backfill only - a later same-direction reconfirmation
            // belongs in the Update field below instead. Pure persistence
            // change - the forward-replay decision logic above always
            // recomputes [trueStart] fresh from live data regardless of
            // what's stored here, so this has zero effect on trading
            // correctness, only on what gets displayed as "Open."
            if (openSnapshot == null) {
              // Re-confirm this Start event is still really there before
              // WRITING it (2026-10-17, found live: right as the MT5
              // bridge reconnected after a brief connection-refused
              // outage, a single stale read briefly reported the wrong
              // "latest case-1 event" - e.g. one 21 days old - and this
              // audit only ever runs ONCE per ticket, so that bad read
              // would have been permanently baked in with no chance to
              // self-correct).
              final recheck = await readWorm10Signals(
                cdp,
                tvSymbol,
                worm10Script.scriptIdPart,
                customScripts[1].scriptIdPart,
                onDebugError: (msg) => logger.log('$tvSymbol ($category) worm10 audit Start recheck: $msg'),
              );
              final recheckEvents = deriveWorm10Events(recheck);
              final stillThere = recheckEvents.any((e) => e.kind == trueStart.kind && e.time == trueStart.time);
              if (!stillThere) {
                logger.log(
                  '$tvSymbol ($category): worm10 audit Start event ($trueStartWire@${trueStart.time}) '
                  'no longer present on re-read - skipping write to avoid baking in a stale read.',
                  level: 'WARNING',
                );
              } else {
                worm10EntrySignals.record(
                  auditTicket,
                  Worm10EntrySignalSnapshot(kind: trueStart.kind, barTime: trueStart.time),
                );
                logger.log(
                  '$mt5Symbol ($category): backfilled worm10 Start for '
                  'ticket=$auditTicket - $trueStartWire@${trueStart.time}.',
                );
              }
            }
            if (updateEvent != null) {
              final updateWire = worm10EventKindToWire(updateEvent.kind);
              final current = worm10EntrySignals.peek(auditTicket);
              if (current?.updateKind != updateEvent.kind || current?.updateTime != updateEvent.time) {
                worm10EntrySignals.recordUpdate(auditTicket, updateEvent.kind, updateEvent.time);
                logger.log(
                  '$mt5Symbol ($category): backfilled worm10 Update for '
                  'ticket=$auditTicket - $updateWire@${updateEvent.time}.',
                );
              }
            }
          } else {
            // Genuine mismatch - re-confirm the signal is still really
            // there before acting (chart data can shift), then close and
            // recycle into the correct direction. Same discipline as
            // [_checkOneSymbol]'s own audit.
            logger.log(
              '$mt5Symbol ($category): WORM10 RETROACTIVE AUDIT - ticket=$auditTicket is '
              'running ${runningDirection == TradeDirection.short ? "SELL" : "BUY"} but the '
              'true event chain says ${trueDirection == TradeDirection.short ? "SELL" : "BUY"} '
              '($trueStartWire@${trueStart.time}) - closing and recycling.',
              level: 'WARNING',
            );
            final recheck = await readWorm10Signals(
              cdp,
              tvSymbol,
              worm10Script.scriptIdPart,
              customScripts[1].scriptIdPart,
              onDebugError: (msg) => logger.log('$tvSymbol ($category) worm10 audit recheck: $msg'),
            );
            final recheckEvents = deriveWorm10Events(recheck);
            final stillThere = recheckEvents.any((e) => e.kind == trueStart.kind && e.time == trueStart.time);
            if (!stillThere) {
              logger.log(
                '$tvSymbol ($category): worm10 audit event no longer present '
                'on re-read - skipping correction.',
                level: 'WARNING',
              );
            } else {
              await _closePosition(
                category,
                tvSymbol,
                mt5Symbol,
                existing,
                stopReason: 'opposite_signal',
                detail: 'Retroactive audit: the true worm10 event chain disagreed with the running direction.',
                worm10CloseKindWire: trueStartWire,
                worm10CloseAt: trueStart.time,
              );
              if (!(await _hasPendingAppOrder(mt5Symbol, category))) {
                final ignitedAudit = ignitedPairs.isIgnited(tvSymbol);
                final flipGate = risk.gate('open', mt5Symbol, category, bypassMarginGate: ignitedAudit);
                if (flipGate.allowed) {
                  if (await _openPosition(
                    category,
                    mapping,
                    trueDirection,
                    range.top,
                    range.bottom,
                    trueDirection == TradeDirection.long
                        ? const Signal(tag: SignalTag.buy, time: 0)
                        : const Signal(tag: SignalTag.sell, time: 0),
                    worm10OpenKindWire: trueStartWire,
                    worm10OpenAt: trueStart.time,
                  )) {
                    if (ignitedAudit) ignitedPairs.consume(tvSymbol);
                  }
                } else {
                  logger.log(
                    '$tvSymbol ($category): worm10 audit-driven risk gate blocked reopen: ${flipGate.reason}',
                  );
                }
              }
              return;
            }
          }
        }
      }
    }

    // TRIPLE-read confirmation, same "1 million sure" rule as every other
    // technique's own signal read.
    for (var i = 0; i < 2; i++) {
      await Future<void>.delayed(const Duration(seconds: 10));
      final recheck = await readWorm10Signals(
        cdp,
        tvSymbol,
        worm10Script.scriptIdPart,
        customScripts[1].scriptIdPart,
        onDebugError: (msg) => logger.log('$tvSymbol ($category) worm10 recheck: $msg'),
      );
      final recheckEvents = deriveWorm10Events(recheck);
      final recheckLatest = recheckEvents.isEmpty ? null : recheckEvents.last;
      if (recheckLatest == null || recheckLatest.kind != latest.kind || recheckLatest.time != latest.time) {
        logger.log(
          '$tvSymbol ($category): WORM10 SIGNAL FLICKER (read ${i + 2}/3) - first '
          'read ${worm10EventKindToWire(latest.kind)}@${latest.time}, this read '
          '${recheckLatest != null ? worm10EventKindToWire(recheckLatest.kind) : null}'
          '@${recheckLatest?.time} disagree — skipping this cycle.',
          level: 'WARNING',
        );
        return;
      }
    }

    // "Survive one full extra candle" wait gate - same shape as every
    // other technique's own, against [worm10Pending].
    final latestWire = worm10EventKindToWire(latest.kind);
    if (!immediate && (pending == null || pending.kind != latest.kind || pending.barTime != latest.time)) {
      worm10Pending.set(barKey, latest.kind, latest.time);
      logger.log(
        '$tvSymbol ($category): worm10 $latestWire@${latest.time} triple-confirmed - '
        'deferring action until the following candle confirms it.',
      );
      return;
    }
    if (immediate) {
      logger.log(
        '$tvSymbol ($category): technique switch reverse check - '
        'worm10 $latestWire@${latest.time} triple-confirmed, acting immediately.',
      );
    }

    final currentDirection = existing == null
        ? null
        : ((existing['action'] as String?) == 'sell' ? TradeDirection.short : TradeDirection.long);
    final decision = worm10DecisionFor(currentDirection, latest.kind);

    // A synthetic [Signal] matching [decision.resultDirection]/[latest.time]
    // - [_openPosition] requires one positionally, but never actually reads
    // it when [worm10OpenKindWire]/[worm10OpenAt] are both supplied (see
    // that method's own doc comment) - this is purely to satisfy the type,
    // not read for anything.
    Signal syntheticSignal(TradeDirection dir) => Signal(
      tag: dir == TradeDirection.long ? SignalTag.buy : SignalTag.sell,
      time: latest.time,
    );

    switch (decision.action) {
      case Worm10Action.none:
        worm10Pending.clear(barKey);
        return;

      case Worm10Action.update:
        // Same-direction re-confirmation while already running - log only,
        // same concept as [_checkOneSymbol]'s own Update tracking. [latest]
        // is always the single most-recent event in the FULL signal
        // history, not something newly observed this cycle - re-reading
        // the exact same bar that originally opened the position (nothing
        // newer has happened yet) must NOT count as a fresh Update, or
        // every single cycle would overwrite Update with an identical
        // copy of Open (confirmed live, ticket 1660457325: update_kind ==
        // kind, update_time == bar_time). Only a genuinely newer bar than
        // BOTH the original open AND whatever Update is already recorded
        // counts.
        if (existing != null) {
          final ticket = _parseTicket(existing['position_id']);
          if (ticket != null) {
            final current = worm10EntrySignals.peek(ticket);
            final isGenuinelyNewer = current != null &&
                latest.time != current.barTime &&
                latest.time != current.updateTime;
            if (isGenuinelyNewer) {
              worm10EntrySignals.recordUpdate(ticket, latest.kind, latest.time);
              logger.log('$tvSymbol ($category): worm10 Update - $latestWire@${latest.time}.');
            }
          }
        }
        worm10Pending.clear(barKey);
        return;

      case Worm10Action.openFresh:
        if (await _reconcileStaleRestingOrderIfAny(category, tvSymbol, mt5Symbol, decision.resultDirection!, range.top, range.bottom)) {
          return;
        }
        final ignitedFresh = ignitedPairs.isIgnited(tvSymbol);
        final gate = risk.gate('open', mt5Symbol, category, bypassMarginGate: ignitedFresh);
        if (!gate.allowed) {
          logger.log('$tvSymbol ($category): risk gate blocked open: ${gate.reason}');
          return;
        }
        if (ignitedFresh) {
          logger.log('$tvSymbol ($category): opening on an ignited pair - margin-level gate bypassed.');
        }
        if (await _openPosition(
          category,
          mapping,
          decision.resultDirection!,
          range.top,
          range.bottom,
          syntheticSignal(decision.resultDirection!),
          worm10OpenKindWire: latestWire,
          worm10OpenAt: latest.time,
        )) {
          worm10Pending.clear(barKey);
          if (ignitedFresh) ignitedPairs.consume(tvSymbol);
        }
        return;

      case Worm10Action.recycle:
      case Worm10Action.flip:
        // A recycle must be a GENUINELY NEW case-1 occurrence of the same
        // direction ("if current trade is buy and a NEW buy open case1
        // appears" - the user's own wording) - [worm10DecisionFor] is a
        // pure function of (currentDirection, kind) and can't tell a fresh
        // occurrence from a stale re-read of the exact event that already
        // opened this very ticket, same reasoning as the Update branch's
        // own "genuinely newer" guard above. Without this, a slow-filling
        // pending order that only registers minutes after [latest] became
        // the pending signal would see that SAME already-acted-upon bar
        // as "the latest event" on its own very first audit pass, and
        // recycle again immediately - confirmed live, 2026-10-14: ATOM/BNB
        // both closed-and-reopened repeatedly onto the identical
        // BUY_OPEN1 bar, each cycle a real, unnecessary loss. A flip is
        // NEVER skipped by this guard - a direction change is always
        // meaningful, never a stale repeat of what's already running.
        if (decision.action == Worm10Action.recycle && existing != null) {
          final ticket = _parseTicket(existing['position_id']);
          final snapshot = ticket == null ? null : worm10EntrySignals.peek(ticket);
          if (snapshot != null && snapshot.kind == latest.kind && snapshot.barTime == latest.time) {
            logger.log(
              '$tvSymbol ($category): worm10 recycle signal $latestWire@${latest.time} is '
              'the same event that already opened this ticket - not a fresh occurrence, skipping.',
            );
            worm10Pending.clear(barKey);
            return;
          }
        }
        if (existing == null) {
          // Nothing actually running (e.g. a resting-but-unfilled order) -
          // recycle/flip only make sense against a real running position;
          // fall through to the same stale-order reconcile + open path
          // [Worm10Action.openFresh] uses.
          if (await _reconcileStaleRestingOrderIfAny(category, tvSymbol, mt5Symbol, decision.resultDirection!, range.top, range.bottom)) {
            return;
          }
          final ignitedRecycle = ignitedPairs.isIgnited(tvSymbol);
          final gate = risk.gate('open', mt5Symbol, category, bypassMarginGate: ignitedRecycle);
          if (!gate.allowed) {
            logger.log('$tvSymbol ($category): risk gate blocked open: ${gate.reason}');
            return;
          }
          if (ignitedRecycle) {
            logger.log('$tvSymbol ($category): opening on an ignited pair - margin-level gate bypassed.');
          }
          if (await _openPosition(
            category,
            mapping,
            decision.resultDirection!,
            range.top,
            range.bottom,
            syntheticSignal(decision.resultDirection!),
            worm10OpenKindWire: latestWire,
            worm10OpenAt: latest.time,
          )) {
            worm10Pending.clear(barKey);
            if (ignitedRecycle) ignitedPairs.consume(tvSymbol);
          }
          return;
        }
        await _closePosition(
          category,
          tvSymbol,
          mt5Symbol,
          existing,
          stopReason: decision.action == Worm10Action.recycle ? 'worm10_recycle' : 'opposite_signal',
          detail: decision.action == Worm10Action.recycle
              ? 'Closed and recycling fresh - the same entry confluence ($latestWire) fired again while running.'
              : 'Closed automatically on an opposite worm10 event ($latestWire).',
          worm10CloseKindWire: latestWire,
          worm10CloseAt: latest.time,
        );
        if (await _hasPendingAppOrder(mt5Symbol, category)) {
          logger.log(
            '$tvSymbol ($category): a pending order for this symbol/category '
            'is already resting in MT5 - not placing a duplicate.',
          );
          return;
        }
        final ignitedFlip = ignitedPairs.isIgnited(tvSymbol);
        final flipGate = risk.gate('open', mt5Symbol, category, bypassMarginGate: ignitedFlip);
        if (!flipGate.allowed) {
          logger.log('$tvSymbol ($category): risk gate blocked open: ${flipGate.reason}');
          return;
        }
        if (await _openPosition(
          category,
          mapping,
          decision.resultDirection!,
          range.top,
          range.bottom,
          syntheticSignal(decision.resultDirection!),
          worm10OpenKindWire: latestWire,
          worm10OpenAt: latest.time,
        )) {
          worm10Pending.clear(barKey);
          if (ignitedFlip) ignitedPairs.consume(tvSymbol);
        }
        return;
    }
  }

  /// Snapshots the confirmed signal that triggered an open, keyed by the
  /// real position ticket, for [BotHistoryEntry]'s open_signal_* fields
  /// once this position eventually closes. [worm10OpenKindWire]/
  /// [worm10OpenAt] (2026-10-14) route to [worm10EntrySignals] instead -
  /// see [_openPosition]'s own doc comment.
  void _recordOpenSignal(
    int ticket,
    Signal signal, {
    String? worm10OpenKindWire,
    int? worm10OpenAt,
  }) {
    if (worm10OpenKindWire != null && worm10OpenAt != null) {
      worm10EntrySignals.record(
        ticket,
        Worm10EntrySignalSnapshot(
          kind: worm10EventKindFromWire(worm10OpenKindWire),
          barTime: worm10OpenAt,
        ),
      );
      return;
    }
    entrySignals.record(
      ticket,
      EntrySignalSnapshot(tag: signalTagToWire(signal.tag), barTime: signal.time),
    );
  }

  /// True if MT5 already has a resting pending order (the
  /// fill-mode-workaround path in [_openPosition] places these, tagged
  /// with this exact category's comment) for this symbol. Confirmed live
  /// 2026-09-27, per the user ("why again trx is placed while there is
  /// currently running trx"): a resting pending order that hasn't
  /// triggered yet within [_openPosition]'s 20s registration window is
  /// invisible to [_findAppPosition] (which only sees real POSITIONS) - so
  /// a later cycle, engine restart, or new bar happily placed a SECOND
  /// duplicate order for the same symbol+category while the first was
  /// still resting, confirmed live twice, once even after a real position
  /// had already opened from an earlier attempt. This check is a
  /// necessary companion to [_findAppPosition]'s own self-healing fix
  /// below, not a replacement for it.
  Future<bool> _hasPendingAppOrder(String mt5Symbol, AutoCategory category) async =>
      (await _findPendingAppOrder(mt5Symbol, category)) != null;

  /// Same lookup as [_hasPendingAppOrder], but returns the order's own raw
  /// fields instead of just whether one exists - added 2026-10-06, per the
  /// user, so the "no position running" branch in [_checkOneSymbol] can
  /// compare what's actually resting (its `type`/`stop_loss`/`take_profit`)
  /// against a fresh signal, not just know something is there. Field names
  /// confirmed live against this account's own real resting orders:
  /// `order_id` (string, needs parsing), `type` ("buy stop"/"sell stop" -
  /// space-separated, not the colon-free style [Mt5Client.sendPendingOrder]
  /// sends), `stop_loss`, `take_profit`.
  Future<Map<String, dynamic>?> _findPendingAppOrder(String mt5Symbol, AutoCategory category) async {
    final result = await mt5.getOpenPositions(symbol: mt5Symbol);
    final orders = (result['orders'] as List?) ?? const [];
    final tag = 'trading_mt5 ${category.wireValue}';
    for (final o in orders) {
      final map = o as Map<String, dynamic>;
      if (map['comment'] == tag && map['state'] == 'placed') return map;
    }
    return null;
  }

  /// Shared by [_checkOneSymbol] and [_checkOneSymbolSupertrend]'s own
  /// "no position running" branches (2026-10-07, extracted - both had
  /// carried byte-identical copies of this exact block since 2026-10-06,
  /// per the user: "for waiting pairs. if anything updated. then app need
  /// to update this pair rather it is filled or not filled ... if it is
  /// required to close current filled pair and refill again, app need to
  /// do it" - "waiting" explicitly includes a not-yet-filled resting
  /// order, not just a running position. Compares what a FRESH open would
  /// use RIGHT NOW against what's actually resting; only cancels+replaces
  /// if either the direction or the SL/TP has genuinely changed. Pure
  /// extraction, not a behavior change - every log message, branch, and
  /// return condition is unchanged from what both call sites already did
  /// inline.
  ///
  /// Returns true if the caller should STOP here (either because the
  /// resting order already matches and nothing more is needed, or because
  /// cancelling a stale one failed and the retry will happen next cycle).
  /// Returns false if there was no resting order, or a stale one was
  /// successfully cancelled - either way, the caller should proceed to
  /// place a fresh one.
  Future<bool> _reconcileStaleRestingOrderIfAny(
    AutoCategory category,
    String tvSymbol,
    String mt5Symbol,
    TradeDirection newDirection,
    double rangeTop,
    double rangeBottom,
  ) async {
    final pendingOrder = await _findPendingAppOrder(mt5Symbol, category);
    if (pendingOrder == null) return false;
    final restingDirection = (pendingOrder['type'] as String? ?? '').contains('buy')
        ? TradeDirection.long
        : TradeDirection.short;
    final restingSl = (pendingOrder['stop_loss'] as num?)?.toDouble();
    final restingTp = (pendingOrder['take_profit'] as num?)?.toDouble();
    final target = await _computeTargetLevels(mt5Symbol, newDirection, rangeTop, rangeBottom);
    // 2026-10-17 REDESIGN, per the user - compared against the 60/40
    // model's own `target.sl` directly now, since [_openPosition] no
    // longer overwrites it with the baseline (see that method's own doc
    // comment on this same date) - a resting order is stale only if the
    // direction or the real 60/40 levels themselves have moved.
    final changed = target != null &&
        (restingDirection != newDirection || restingSl != target.sl || restingTp != target.tp);
    if (!changed) {
      logger.log(
        '$tvSymbol ($category): a pending order for this symbol/category '
        'is already resting in MT5 and still matches the current signal - '
        'not placing a duplicate.',
      );
      return true;
    }
    final orderTicket = _parseTicket(pendingOrder['order_id']);
    if (orderTicket == null) {
      logger.log(
        '$tvSymbol ($category): resting order has gone stale (signal/range '
        'moved on) but its own ticket could not be parsed from '
        '$pendingOrder - leaving it alone rather than risk touching the '
        'wrong order.',
        level: 'ERROR',
      );
      return true;
    }
    logger.log(
      '$tvSymbol ($category): resting pending order (order_id=$orderTicket) '
      'has gone stale - direction/SL/TP no longer match the current '
      'signal - cancelling it and re-placing with the current one.',
    );
    final deleteResult = await mt5.deleteOrder(symbol: mt5Symbol, orderTicket: orderTicket);
    final deleteRetcode = (deleteResult['retcode'] as num?)?.toInt();
    if (deleteRetcode != null && deleteRetcode != 10009) {
      logger.log(
        '$tvSymbol ($category): failed to cancel stale resting order '
        '(retcode=$deleteRetcode) - leaving it in place, will retry next cycle.',
        level: 'ERROR',
      );
      return true;
    }
    return false;
  }

  /// Shared by both check methods' own range reads (2026-10-07, extracted -
  /// both carried byte-identical copies of this exact triple-read-with-
  /// immediate-retry sequence). Pure extraction - every delay, log message,
  /// and comparison is unchanged from what each call site already did
  /// inline. Returns null (after logging why) on "no range yet" or a
  /// flicker between reads; the caller's own job is just `if (range ==
  /// null) return;`.
  Future<RangeResult?> _readConfirmedRange(
    CdpClient cdp,
    AutoCategory category,
    String tvSymbol, {
    required bool immediate,
    // 2026-10-14, per the third decision technique (worm_10_26 + spy_9_26) -
    // that technique has worm_9_26's own ZigZag++ range data built into
    // worm_10_26 itself (same plot structure, different scriptIdPart - see
    // worm10Script's own doc comment), and only ever has worm_10_26
    // attached, never worm_9_26 (the free-account 2-indicator limit only
    // leaves room for worm_10_26 + spy_9_26). Defaults to Signal
    // Flip/Supertrend Plus's own worm_9_26 hash so every existing call site
    // is unaffected.
    String? scriptIdPart,
  }) async {
    final rangeScriptIdPart = scriptIdPart ?? customScripts[0].scriptIdPart;
    // 2026-10-17 - same unchecked-result bug fixed everywhere else this
    // call appears - see [_checkOneSymbol]'s own matching fix for the full
    // root-cause reasoning. This one feeds the TP/SL range every
    // technique shares, so a misattributed symbol here would compute the
    // WRONG stop-loss/take-profit levels for whatever's actually open.
    final chartView = await setChartView(cdp, tvSymbol, category.rangeResolution);
    if (!chartView.ok) {
      logger.log(
        '$tvSymbol ($category): chart view switch failed (${chartView.error}) - '
        'refusing to read the TP/SL range from a chart that might still be '
        'showing a different symbol.',
        level: 'ERROR',
      );
      return null;
    }
    final lines = await readLines(cdp, rangeScriptIdPart);
    var range = detectZigzagRange(lines, swingCount: config.technique.rangeSwingCount);
    // Extra retries when [immediate] - see the Power-on sweep's own doc
    // comment on [_reverseCheckOnTechniqueSwitchIfNeeded] for why: a
    // one-shot-per-pair skip here would otherwise silently fall this pair
    // back to the slow, normal cadence instead of getting the immediate
    // treatment every other pair in the sweep got.
    for (var i = 0; i < 2 && range == null && immediate; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      final retryLines = await readLines(cdp, rangeScriptIdPart);
      range = detectZigzagRange(retryLines, swingCount: config.technique.rangeSwingCount);
    }
    // 2026-10-17 - found live: a chart that just freshly loaded (e.g. right
    // after TradingView restarts) can start with too SHORT a default
    // history window to contain [config.technique.rangeSwingCount]
    // confirmed swings at all - no amount of re-reading the SAME short
    // window ever produces a range in that case, only asking for more
    // history does. Same [requestMoreChartHistory] call the worm10
    // retroactive audit's own case-1 search already uses for the identical
    // "not enough loaded yet" problem - only engaged here as a last resort,
    // so the normal already-working case pays nothing extra.
    if (range == null) {
      final extended = await requestMoreChartHistory(cdp);
      if (extended) {
        final extendedLines = await readLines(cdp, rangeScriptIdPart);
        range = detectZigzagRange(extendedLines, swingCount: config.technique.rangeSwingCount);
      }
    }
    if (range == null) {
      logger.log('$tvSymbol ($category): no range yet, skipping cycle.');
      return null;
    }
    // TRIPLE-read confirmation (strengthened 2026-09-27, per the user:
    // "dont open/close trade unless you are 1 million sure" - two reads 6s
    // apart was not strong enough; a single read had returned a range of
    // 0.99-1.70 for BTC (~$84,500 at the time), which would have produced a
    // stop-loss with essentially no real protection. Now requires the
    // range to agree across THREE independent reads spaced 10s apart (20s
    // total) before ever being trusted — same TradingView chart-settling
    // race as the signal read, just hitting the zigzag/range script.
    for (var i = 0; i < 2; i++) {
      await Future<void>.delayed(const Duration(seconds: 10));
      final linesRecheck = await readLines(cdp, rangeScriptIdPart);
      final rangeRecheck = detectZigzagRange(linesRecheck, swingCount: config.technique.rangeSwingCount);
      if (rangeRecheck == null || rangeRecheck.top != range.top || rangeRecheck.bottom != range.bottom) {
        logger.log(
          '$tvSymbol ($category): RANGE FLICKER (read ${i + 2}/3) - first '
          'read ${range.bottom}-${range.top}, this read '
          '${rangeRecheck?.bottom}-${rangeRecheck?.top} disagree — '
          'skipping this cycle.',
          level: 'WARNING',
        );
        return null;
      }
    }
    return range;
  }

  /// Finds an OPEN MT5 position on [mt5Symbol] that this app itself opened.
  /// Self-heals 2026-09-27, per the user (found live: a pending order that
  /// finally triggered AFTER [_openPosition]'s 20s registration poll gave
  /// up sat as a real position forever invisible to [OpenPositionStore] -
  /// neither tracked as ours nor still a "pending order" [_hasPendingAppOrder]
  /// could catch, so the NEXT cycle opened a third position on top of it).
  /// Any position carrying this exact category's own comment tag is
  /// registered into tracking right here if it wasn't already, rather than
  /// depending solely on that one-shot post-placement poll ever having
  /// succeeded. A manually-opened position (no matching comment, or a
  /// different category's tag) is still deliberately left untouched
  /// (OpenPositionStore's rule 3: a manual position never blocks a new app
  /// position, rule 2: the app never touches a position it didn't open).
  Future<Map<String, dynamic>?> _findAppPosition(
    String mt5Symbol,
    AutoCategory category,
    String tvSymbol,
  ) async {
    final tag = 'trading_mt5 ${category.wireValue}';
    final result = await mt5.getOpenPositions(symbol: mt5Symbol);
    final positions = (result['positions'] as List?) ?? const [];
    // Prefer the ORIGINAL over a copy when both exist (2026-10-16, per the
    // user: a copy's own termination must never drive the pair-level
    // logic meant for the parent trade's own lifecycle - see
    // [CopyPositionStore]'s own doc comment). Every app-owned match gets
    // registered the same as before; a copy is only ever RETURNED here
    // if no original match exists for this symbol (shouldn't normally
    // happen, since a copy can only open alongside an already-running
    // original - defensive, not expected in practice).
    Map<String, dynamic>? originalMatch;
    Map<String, dynamic>? copyMatch;
    for (final p in positions) {
      final map = p as Map<String, dynamic>;
      final ticket = _parseTicket(map['position_id']);
      if (ticket == null) continue;
      if (!openPositions.isAppOpened(ticket) && map['comment'] == tag) {
        openPositions.rememberPosition(ticket);
        botCategories.setCategory(ticket, category);
        risk.openPosition(mt5Symbol, category);
        logger.log(
          '$mt5Symbol ($category): found untracked position ticket=$ticket '
          'with our own comment tag - registering it now (a pending order '
          'must have triggered after the post-placement registration '
          'window gave up).',
        );
      }
      if (openPositions.isAppOpened(ticket)) {
        if (copyPositions.isCopy(ticket)) {
          copyMatch ??= map;
        } else {
          originalMatch ??= map;
        }
      }
    }
    final chosen = originalMatch ?? copyMatch;
    if (chosen != null) {
      // A real, app-owned position exists for this symbol/category no
      // matter how we got here - always seasoned from this point on, see
      // [FirstOpenStore]'s own doc comment for why this matters.
      firstOpen.markOpened('${category.wireValue}|$tvSymbol');
    }
    return chosen;
  }

  double _roundToDigits(double v, int digits) {
    var mult = 1.0;
    for (var i = 0; i < digits; i++) {
      mult *= 10;
    }
    return (v * mult).round() / mult;
  }

  /// What a BRAND NEW open for [direction] would use right now, computed
  /// from the market's CURRENT bid/ask and [rangeTop]/[rangeBottom] -
  /// factored out of [_openPosition] (2026-10-06, per the user: "for
  /// waiting pairs. if anything updated... app need to update this pair
  /// rather it is filled or not filled") so the SAME formula can also
  /// decide whether an already-resting pending order's own SL/TP has gone
  /// stale relative to the live chart, not just drive a fresh open. Null
  /// means "can't tell right now" (symbol unreadable from Market Watch, or
  /// the final sanity guard tripped) - every caller must treat that as
  /// leave-things-alone, never as license to act.
  Future<_TargetLevels?> _computeTargetLevels(
    String mt5Symbol,
    TradeDirection direction,
    double rangeTop,
    double rangeBottom,
  ) async {
    final symbolInfoResult = await mt5.getMarketWatchSymbol(mt5Symbol);
    final symbols = (symbolInfoResult['symbols'] as List?) ?? const [];
    if (symbols.isEmpty) {
      logger.log('$mt5Symbol: not found in Market Watch, cannot open.', level: 'ERROR');
      return null;
    }
    final info = symbols.first as Map<String, dynamic>;
    final digits = (info['digits'] as num?)?.toInt() ?? 5;
    final bid = (info['bid'] as num).toDouble();
    final ask = (info['ask'] as num).toDouble();
    final entry = direction == TradeDirection.long ? ask : bid;

    // Final sanity guard (2026-09-27, per the user - found live: a
    // corrupted range read of 0.99-1.70 on BTC at ~$84,500 nearly produced
    // a stop-loss with essentially no real protection). NOT a containment
    // check - entry legitimately lands outside [bottom, top] whenever the
    // widen logic below is meant to fire (see computeLiquidationLevels's
    // own doc comment: "entry > top... TP moves further up" is the
    // documented, normal widen trigger, not an error). This instead
    // catches the actual failure mode - the range being a wildly different
    // ORDER OF MAGNITUDE than the real price (here, ~50,000x off) - which
    // a legitimate widen (price moving somewhat past a support/resistance
    // level) never produces.
    if (rangeTop < entry * 0.01 || rangeBottom > entry * 100) {
      logger.log(
        '$mt5Symbol: refusing to compute levels — range $rangeBottom-'
        '$rangeTop is a wildly different scale than entry=$entry (a '
        'corrupted/stale range read would produce a bogus SL/TP).',
        level: 'ERROR',
      );
      return null;
    }

    final levels = computeLiquidationLevels(
      top: rangeTop,
      bottom: rangeBottom,
      entry: entry,
      direction: direction,
    );

    return _TargetLevels(
      info: info,
      entry: entry,
      bid: bid,
      ask: ask,
      digits: digits,
      sl: _roundToDigits(levels.stopLossPrice, digits),
      tp: _roundToDigits(levels.takeProfitPrice, digits),
      widenApplied: levels.widenApplied,
    );
  }

  /// A flat -$5 stop-loss (2026-10-13, per the user, originally "whichever
  /// occurs first" between -10%/-$10, later tightened to -5%/-$5 the same
  /// way - simplified 2026-10-14, per the user, to a pure dollar cap: "if
  /// pair is =0% or less... make it -5$ only sl" / "so the app only
  /// triggers stop loss if P&L reaches -$5" - dropped the percent
  /// comparison entirely, since for a large position 5% of notional could
  /// be far more than $5, which the user confirmed should NOT be allowed
  /// to run that far ("still stop at -$5 for large positions too"). Fills
  /// in the SL ratchet ladder's own "0% or below" row (§10.1) - replaces
  /// the 60/40 liquidation-avoidance model's own [_computeTargetLevels]
  /// `sl` (confirmed live this is typically MUCH wider, e.g. entry
  /// 1.7784/SL 2.6313 on a real SELL, a ~48% distance) - the ratchet
  /// tightens FROM here the moment P&L turns positive, this is the worst
  /// case below that. Needs [volume] (bigger volume reaches a flat $5 loss
  /// on a smaller price move) - called separately from
  /// [_computeTargetLevels] because the real volume for a fresh open isn't
  /// known until after the step-down retry ladder picks it.
  double _baselineStopLoss({
    required double entry,
    required TradeDirection direction,
    required double volume,
    required double contractSize,
    required int digits,
    // 2026-10-15, per the user's Multiplier-column spec: a copy trade
    // (only ever opened while the original is already profitable) gets a
    // tighter -$1 cap instead of the normal -$5 - every existing call
    // site keeps the original -$5 behavior unchanged by not passing this.
    double dollarCap = 5,
  }) {
    final notionalPerUnit = volume * contractSize;
    final dollarDistance = notionalPerUnit > 0 ? dollarCap / notionalPerUnit : 0.0;
    final dollarSl = direction == TradeDirection.long
        ? entry - dollarDistance
        : entry + dollarDistance;
    return _roundToDigits(dollarSl, digits);
  }

  /// Returns true only on a genuine success (position opened directly, or
  /// a pending-fallback order triggered within the poll window) - every
  /// other path (not found, corrupted range, order rejected, no ticket
  /// recognized, or a pending order still resting unresolved) returns
  /// false so the caller knows NOT to clear its confirmed pending signal
  /// (2026-09-30, per the user - see the call sites' own comments).
  Future<bool> _openPosition(
    AutoCategory category,
    SymbolMapping mapping,
    TradeDirection direction,
    double rangeTop,
    double rangeBottom,
    Signal openSignal, {
    // See [_closePosition]'s own doc comment - same reasoning, for the open
    // side. When both are provided, the open snapshot is recorded to
    // [worm10EntrySignals] instead of [entrySignals]; [openSignal] is still
    // required syntactically but goes unused in that case.
    String? worm10OpenKindWire,
    int? worm10OpenAt,
  }) async {
    final mt5Symbol = mapping.mt5Symbol;

    // 2026-10-13, per the user: "if pair beent terminated two times in
    // same signal, then this pair will not start over again until signal
    // is flipped" - the single gate every open path funnels through
    // (5 call sites, all into this one function), so there's only one
    // place this check needs to live. [direction] differing from whatever
    // direction was blocked IS the flip - this naturally never blocks the
    // opposite direction, no separate "clear on flip" logic needed here.
    final directionStr = direction == TradeDirection.long ? 'long' : 'short';
    if (baselineStopStrikes.isBlocked(mapping.tradingViewSymbol, directionStr)) {
      logger.log(
        '$mt5Symbol ($category): refusing to open '
        '${direction == TradeDirection.long ? 'BUY' : 'SELL'} - hit the '
        'baseline stop-loss twice in a row on this exact signal with '
        'nothing breaking the streak in between. Waiting for the opposite '
        'signal before trying this pair again.',
      );
      return false;
    }

    final target = await _computeTargetLevels(mt5Symbol, direction, rangeTop, rangeBottom);
    if (target == null) return false;
    final info = target.info;
    final entry = target.entry;
    final bid = target.bid;
    final ask = target.ask;
    final digits = target.digits;
    var sl = target.sl;
    final tp = target.tp;
    // Reverted 2026-09-27, per a live test the user asked for: flooring
    // this at 0.01 (per the user seeing 0.01 in MT5's own New Order
    // dialog) was actively causing every BTCUSD.lv open to be rejected
    // with "no money" - 0.01 lots needs more margin than this account's
    // balance covers. A REAL, confirmed-open, running position at 0.001
    // (position_id 1656620205) proves the API's own volume_min is both
    // valid AND affordable for this account, where 0.01 is valid but not
    // affordable. Trusting the live trade result over the UI's suggested
    // default.
    final volumeMin = (info['volume_min'] as num).toDouble();
    // Manual trade-size override + step-down retry (2026-10-03, per the
    // user: "add one more column about current trade volume ... with plus
    // minus icons ... if the recycled trade cant place because of volum,
    // then app should decrease the volum step by step and keep trying").
    // `desiredVolume` is the user's target (Dashboard +/-, defaults to the
    // broker minimum if never touched); `floorVolume` is the last volume
    // that actually worked for this pair/category (never step below it -
    // "if old volum was 20 ... app will keep trying on 20 not applying any
    // more decrease"); `tryVolume` is what THIS attempt actually sends,
    // persisted across cycles so a step-down survives until it either
    // succeeds or bottoms out at the floor.
    final volumeStep = (info['volume_step'] as num?)?.toDouble() ?? volumeMin;
    final volKey = '${category.wireValue}|${mapping.tradingViewSymbol}';
    // Margin-level-tiered size scaling (2026-10-15, per the user - the
    // companion half of [RiskGate.positionCapFor]'s own cap: shrink new
    // exposure as real risk rises, not just count it). Applied to the
    // DESIRED volume, not the final try - [tryVolume] below is already
    // clamped to never exceed [desiredVolume] AND never drop below
    // [floorVolume] (the last size that actually worked for this pair),
    // so scaling down here naturally respects both existing rules rather
    // than introducing a new, separate clamp.
    final marginScale = RiskGate.marginSizeScaleFor(risk.marginLevel);
    final desiredVolumeRaw = tradeVolumes.desired(volKey) ?? volumeMin;
    final desiredVolume = marginScale >= 1.0 ? desiredVolumeRaw : desiredVolumeRaw * marginScale;
    final floorVolume = tradeVolumes.lastApplied(volKey) ?? volumeMin;
    var tryVolume = tradeVolumes.attempt(volKey) ?? desiredVolume;
    if (tryVolume > desiredVolume) tryVolume = desiredVolume;
    if (tryVolume < floorVolume) tryVolume = floorVolume;
    final point = (info['point'] as num?)?.toDouble() ?? 0.0;
    final stopsLevelPoints = (info['trade_stops_level'] as num?)?.toInt() ?? 0;

    // 2026-10-17 REDESIGN, per the user: "tp/sl should be fixed according
    // to 40/60 rules... app should take an action according to P&L.. but
    // not modifying tp/sl" - the real broker-side SL/TP is now the 60/40
    // model's own [target.sl]/[tp], set ONCE here and never touched again
    // by anything (previously this line overwrote [target.sl] with the
    // tight -$5 baseline from the very first moment a trade opened - the
    // baseline/ratchet protection has moved entirely to [_applySlRatchet]'s
    // own live 30s P&L sweep, which now closes the position directly
    // instead of ever modifying its SL/TP).
    logger.log(
      '$mt5Symbol ($category): opening ${direction == TradeDirection.long ? 'BUY' : 'SELL'} '
      'vol=$tryVolume entry=$entry sl=$sl tp=$tp '
      '(range ${rangeBottom.toStringAsFixed(digits)}-${rangeTop.toStringAsFixed(digits)}'
      '${target.widenApplied ? ", widened" : ""})'
      '${marginScale < 1.0 ? " [size scaled to ${(marginScale * 100).toStringAsFixed(0)}% - margin level ${risk.marginLevel?.toStringAsFixed(1)}%]" : ""}',
    );

    var result = await mt5.sendMarketOrder(
      symbol: mt5Symbol,
      side: direction == TradeDirection.long ? 'buy' : 'sell',
      volume: tryVolume,
      sl: sl,
      tp: tp,
      comment: 'trading_mt5 ${category.wireValue}',
    );

    var retcode = (result['retcode'] as num?)?.toInt();
    var viaPendingFallback = false;
    if (retcode != null && retcode != 10009) {
      if (retcode == 10030) {
        // Invalid fill - confirmed live 2026-09-27 for BTCUSD.lv:
        // trade_send_market_order has NO filling-mode parameter at all, and
        // the MCP server's hidden default doesn't match this symbol's own
        // spec (which only allows IOC). trade_send_pending_order DOES
        // expose filling_type, so a stop order placed just past current
        // price - which triggers essentially immediately - opens a real
        // position where the market-order tool categorically cannot for
        // this class of symbol.
        logger.log(
          '$mt5Symbol ($category): market order rejected (Invalid fill) — '
          'retrying as an immediate-trigger pending order.',
        );
        // Buffer fixed 2026-09-27, per the user ("place it running... why
        // you dont listen"): the previous 0.2% buffer (~$169 on BTC) made
        // this wait for a real price swing instead of triggering right
        // away. Using the symbol's OWN minimum stop distance instead
        // (trade_stops_level, in points) - the smallest legal distance
        // from current price - so the stop order sits just past current
        // price and triggers on essentially the very next tick, matching
        // a real market order in practice.
        //
        // Tightened further 2026-10-16, per the user ("any filled trade
        // should have a trigger price +/-1 value. same as setting in (+)
        // button so the trigger occures asap") - dropped the extra "+2
        // points" safety padding this used to add on top of the broker's
        // own minimum, matching the exact same tightening already applied
        // to copy trades' own pending-order fallback in
        // [_openCopyPosition] (which itself had to add BACK the broker's
        // real minimum after a first attempt using a flat one price unit
        // broke placement outright with retcode=10015 "Invalid price" -
        // the floor below is a hard broker rule, not a buffer this app
        // can shrink past).
        final minDistance = point <= 0
            ? entry * 0.0005
            : stopsLevelPoints > 0
            ? stopsLevelPoints * point
            : point;
        final buffer = minDistance;
        final triggerPrice = _roundToDigits(
          direction == TradeDirection.long ? ask + buffer : bid - buffer,
          digits,
        );
        result = await mt5.sendPendingOrder(
          symbol: mt5Symbol,
          type: direction == TradeDirection.long ? 'buy_stop' : 'sell_stop',
          volume: tryVolume,
          price: triggerPrice,
          sl: sl,
          tp: tp,
          fillingType: 'ioc',
          comment: 'trading_mt5 ${category.wireValue}',
        );
        retcode = (result['retcode'] as num?)?.toInt();
        viaPendingFallback = true;
      }
      if (retcode != null && retcode != 10009) {
        final reason = 'order rejected: retcode=$retcode ${result['retcode_details'] ?? ''}'.trim();
        logger.log('$mt5Symbol ($category): $reason', level: 'ERROR');
        waitingReasons.record(mapping.tradingViewSymbol, reason);
        // 10019 = TRADE_RETCODE_NO_MONEY, 10014 = TRADE_RETCODE_INVALID_VOLUME
        // - the two MT5 rejection codes that actually mean "this volume is
        // the problem," as opposed to e.g. market closed or trading
        // disabled. Per the user: step down by one broker volume_step and
        // let the next cycle's retry pick up the lower value - never below
        // [floorVolume] (the last volume that actually worked).
        const volumeRelatedRetcodes = {10019, 10014};
        if (volumeRelatedRetcodes.contains(retcode) && tryVolume > floorVolume) {
          final stepped = (tryVolume - volumeStep).clamp(floorVolume, desiredVolume).toDouble();
          tradeVolumes.setAttempt(volKey, stepped);
          logger.log(
            '$mt5Symbol ($category): volume-related rejection — stepping '
            'down from $tryVolume to $stepped and will retry (floor=$floorVolume).',
          );
        }
        return false;
      }
    }

    // Confirmed live 2026-09-27 (pending-order path): the new ticket comes
    // back as `order`. Kept as a defensive multi-name lookup since a
    // genuine market-order success (a different symbol, no fallback
    // needed) has never been observed live to confirm its own field name.
    final ticket = _firstIntField(result, const [
      'ticket',
      'position_ticket',
      'position',
      'order',
      'deal',
    ]);
    if (ticket == null) {
      logger.log(
        'Order for $mt5Symbol appears to have been SENT but no ticket field '
        'was recognized in the response: $result — NOT tracked as an '
        'app-opened position. Check MT5 manually and update '
        '_firstIntField\'s field-name list in engine_service.dart once the '
        'real field name is confirmed.',
        level: 'CRITICAL',
      );
      return false;
    }

    if (!viaPendingFallback) {
      openPositions.rememberPosition(ticket);
      botCategories.setCategory(ticket, category);
      if (target.widenApplied) widenApplied.markWidened(ticket);
      risk.openPosition(mt5Symbol, category);
      _recordOpenSignal(ticket, openSignal, worm10OpenKindWire: worm10OpenKindWire, worm10OpenAt: worm10OpenAt);
      waitingReasons.clear(mapping.tradingViewSymbol);
      tradeVolumes.recordApplied(volKey, tryVolume);
      logger.log('$mt5Symbol ($category): opened, ticket=$ticket.');
      return true;
    }

    // The pending-order path's ticket is an ORDER id, not the POSITION id
    // it becomes once triggered - MT5 assigns those independently, so
    // remembering the order ticket here would never match the real
    // position later (`_findAppPosition` matches on `position_id`).
    // Poll briefly for the triggered position instead, since the stop
    // price is set to trigger essentially immediately.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final positionsResult = await mt5.getOpenPositions(symbol: mt5Symbol);
      final positions = (positionsResult['positions'] as List?) ?? const [];
      for (final p in positions) {
        final map = p as Map<String, dynamic>;
        final positionTicket = _parseTicket(map['position_id']);
        if (positionTicket == null || openPositions.isAppOpened(positionTicket)) {
          continue;
        }
        openPositions.rememberPosition(positionTicket);
        botCategories.setCategory(positionTicket, category);
        if (target.widenApplied) widenApplied.markWidened(positionTicket);
        risk.openPosition(mt5Symbol, category);
        _recordOpenSignal(positionTicket, openSignal, worm10OpenKindWire: worm10OpenKindWire, worm10OpenAt: worm10OpenAt);
        waitingReasons.clear(mapping.tradingViewSymbol);
        tradeVolumes.recordApplied(volKey, tryVolume);
        logger.log(
          '$mt5Symbol ($category): pending order $ticket triggered, '
          'opened ticket=$positionTicket.',
        );
        return true;
      }
    }
    logger.log(
      '$mt5Symbol ($category): pending order $ticket placed but did not '
      'trigger within 20s — still resting in MT5, not yet tracked as an '
      'app-opened position. Will be picked up once it triggers and the '
      'next cycle sees it, or check MT5 manually.',
      level: 'ERROR',
    );
    // 2026-09-29, per the user: "waiting pairs should reflect exact reason
    // ... not guess ... for example (not enough margin)" - confirmed live
    // that XRPUSD.lv's repeated "did not trigger" orders were all silently
    // deleted by the broker for insufficient margin, invisible from
    // [getOpenPositions] alone once the order is gone. Look the order up
    // in history to find out whether it's still genuinely resting (no
    // reason to record - that's a legitimate wait) or was actually
    // rejected/deleted, and if so, surface the broker's own exact wording.
    try {
      final history = await mt5.getHistoryOrders(symbol: mt5Symbol);
      final orders = (history['orders'] as List?) ?? const [];
      for (final o in orders) {
        final map = o as Map<String, dynamic>;
        if (_parseTicket(map['order_id']) == ticket && map['state'] != 'placed') {
          final comment = map['comment'] as String? ?? map['state'] as String? ?? 'rejected';
          waitingReasons.record(mapping.tradingViewSymbol, comment);
          break;
        }
      }
    } catch (e) {
      logger.log('$mt5Symbol ($category): could not check order $ticket\'s history: $e', level: 'ERROR');
    }
    return false;
  }

  /// [closeSignal] null + [stopReason]/[detail] overridden (2026-09-29, per
  /// the user's power-icon spec: "once it is pressed, trade will be
  /// terminated") covers a manual terminate-request close, which has no
  /// signal behind it at all - the default single call site (an opposite-
  /// signal close) keeps passing a real [closeSignal] and the original
  /// wording unchanged.
  Future<void> _closePosition(
    AutoCategory category,
    String tvSymbol,
    String mt5Symbol,
    Map<String, dynamic> position, {
    Signal? closeSignal,
    String stopReason = 'opposite_signal',
    String? detail,
    // 2026-10-14, per the third decision technique (worm_10_26 + spy_9_26) -
    // that technique has its own six-way [Worm10EventKind], not the 4-way
    // [SignalTag] every other technique uses, and its own
    // [Worm10EntrySignalStore], not [entrySignals] - these let its own
    // caller pass its own wire strings straight through to history instead
    // of forcing a [Signal] object that doesn't fit. Every existing call
    // site is unaffected - leaving these null keeps the original
    // [closeSignal]/[entrySignals] behavior exactly as it was.
    String? worm10CloseKindWire,
    int? worm10CloseAt,
  }) async {
    final ticket = _parseTicket(position['position_id'])!;
    logger.log('$mt5Symbol ($category): closing ticket=$ticket ($stopReason).');
    // Account snapshot taken BEFORE the close, while this position was
    // still genuinely running (2026-10-15, per the user: "all details
    // required in history") - same semantics as the Dashboard's own live
    // Extra Margin/Liquidation columns, which are always computed against
    // a currently-running trade's own numbers, not after it's already
    // gone.
    AccountSnapshot? accountSnapshotBeforeClose;
    try {
      accountSnapshotBeforeClose = AccountSnapshot.fromJson(await mt5.getAccountInfo());
    } catch (_) {
      // History just gets "—" for these two columns this time.
    }
    await mt5.closePosition(symbol: mt5Symbol, positionTicket: ticket);
    // 2026-10-14, per the user: "include the P&L value in history card ...
    // +11.02 (+33.45%)" / "include the sll setup at the trade terminal" -
    // both need live-looked-up data ([getMarketWatchSymbol]'s contract
    // size for the percent; [slRatchet]'s own threshold for the SLL text)
    // that [_recordHistory] itself can't fetch (it's synchronous, called
    // from several places). Fetched here, once, right before the one call
    // site that matters for a real close.
    double contractSize = 1.0;
    try {
      final info = await mt5.getMarketWatchSymbol(mt5Symbol);
      final symbols = (info['symbols'] as List?) ?? const [];
      if (symbols.isNotEmpty) {
        contractSize = ((symbols.first as Map<String, dynamic>)['contract_size'] as num?)?.toDouble() ?? 1.0;
      }
    } catch (e) {
      logger.log('$mt5Symbol ($category): could not fetch contract size for history percent: $e', level: 'WARNING');
    }
    final ratchetThreshold = slRatchet.highestThreshold(ticket);
    // Same copy-aware baseline fix as the reconciliation loop's own
    // matching line (2026-10-16, per the user) - defensive here, since
    // [_findAppPosition] now always prefers the original over a copy, so
    // this path shouldn't normally ever see a copy's own ticket.
    final sllAtTermination = ratchetThreshold != null
        ? '+$ratchetThreshold%'
        : copyPositions.isCopy(ticket)
        ? '-\$1'
        : '-\$5';
    // Same Equiti-30%-Stop-Out-Level estimate as the Dashboard's own live
    // Liquidation column (see [AutoTradeRow.liquidationPrice]'s doc
    // comment for the exact formula) - computed here from
    // [accountSnapshotBeforeClose] + this position's own last-known
    // numbers, since both are only meaningful relative to a genuinely
    // running trade's state right before it closed.
    double? liquidationPriceForHistory;
    const stopOutLevel = 0.30;
    final positionProfitBeforeClose = (position['profit'] as num?)?.toDouble();
    final positionVolumeBeforeClose = (position['volume'] as num?)?.toDouble();
    final positionPriceOpenBeforeClose = (position['price_open'] as num?)?.toDouble();
    if (accountSnapshotBeforeClose != null &&
        accountSnapshotBeforeClose.margin > 0 &&
        positionProfitBeforeClose != null &&
        positionVolumeBeforeClose != null &&
        positionVolumeBeforeClose != 0 &&
        positionPriceOpenBeforeClose != null &&
        contractSize != 0) {
      final otherEquity = accountSnapshotBeforeClose.equity - positionProfitBeforeClose;
      final targetProfit = stopOutLevel * accountSnapshotBeforeClose.margin - otherEquity;
      final priceDelta = targetProfit / (positionVolumeBeforeClose * contractSize);
      liquidationPriceForHistory = (position['action'] as String?) == 'sell'
          ? positionPriceOpenBeforeClose - priceDelta
          : positionPriceOpenBeforeClose + priceDelta;
    }
    _recordHistory(
      category: category,
      tvSymbol: tvSymbol,
      mt5Symbol: mt5Symbol,
      ticket: ticket,
      position: position,
      closeSignal: closeSignal,
      stopReason: stopReason,
      detail: detail ??
          (closeSignal != null
              ? 'Closed automatically on an opposite ${closeSignal.side.name} signal.'
              : 'Closed.'),
      worm10CloseKindWire: worm10CloseKindWire,
      worm10CloseAt: worm10CloseAt,
      contractSize: contractSize,
      sllAtTermination: sllAtTermination,
      extraMargin: accountSnapshotBeforeClose?.marginFree,
      liquidationPrice: liquidationPriceForHistory,
    );
    openPositions.forgetPosition(ticket);
    botCategories.forget(ticket);
    widenApplied.forget(ticket);
    risk.closePosition(mt5Symbol, category);
    // 2026-10-13, per the user - this is always an ACTIVE close (opposite
    // signal confirmed, or a manual terminate), never a passive baseline-SL
    // hit (those are only ever detected after the fact, in
    // [_reconcileClosedPositions]) - always breaks whatever streak was
    // building for this base.
    baselineStopStrikes.clear(tvSymbol);
    _finalizeLastTagOnClose(category, tvSymbol);
    // 2026-10-16, per the user: "if parent is triggered close (signal
    // close case 1,2,3) not close by margin level... all copy trades
    // should be close" - every call into THIS function is already exactly
    // that "active, signal/user-driven close" case (opposite-signal
    // confirmed, or a manual terminate via the power icon) - margin level
    // never actively closes a running position anywhere in this app, it
    // only ever blocks NEW opens or cancels a resting pending order, so
    // there's no separate "was this a margin close" branch to check here.
    // A copy's own SL/TP hit, or the parent's own baseline-SL hit, are
    // the passive exception the user carved out - those are caught
    // independently by [_reconcileClosedPositions], never through here.
    await _closeCopiesOf(category, tvSymbol, mt5Symbol, excludeTicket: ticket);
  }

  /// Cascades a PARENT's own active close onto every one of its still-open
  /// copies - see [_closePosition]'s own call site for the full reasoning.
  /// A copy exists purely to ride the SAME trade idea as its parent; once
  /// the signal (or the user) says that idea is over, every copy riding
  /// it closes too, not just the parent.
  Future<void> _closeCopiesOf(
    AutoCategory category,
    String tvSymbol,
    String mt5Symbol, {
    required int excludeTicket,
  }) async {
    final result = await mt5.getOpenPositions(symbol: mt5Symbol);
    final positions = (result['positions'] as List?) ?? const [];
    final copyTickets = <int, Map<String, dynamic>>{
      for (final p in positions)
        if (_parseTicket((p as Map<String, dynamic>)['position_id']) != null)
          _parseTicket(p['position_id'])!: p,
    }..removeWhere((t, _) => t == excludeTicket || !openPositions.isAppOpened(t) || !copyPositions.isCopy(t));
    if (copyTickets.isEmpty) return;

    AccountSnapshot? accountSnapshotBeforeClose;
    try {
      accountSnapshotBeforeClose = AccountSnapshot.fromJson(await mt5.getAccountInfo());
    } catch (_) {}
    double contractSize = 1.0;
    try {
      final info = await mt5.getMarketWatchSymbol(mt5Symbol);
      final symbols = (info['symbols'] as List?) ?? const [];
      if (symbols.isNotEmpty) {
        contractSize = ((symbols.first as Map<String, dynamic>)['contract_size'] as num?)?.toDouble() ?? 1.0;
      }
    } catch (_) {}

    for (final entry in copyTickets.entries) {
      final copyTicket = entry.key;
      final copyPosition = entry.value;
      logger.log(
        '$mt5Symbol ($category): closing copy ticket=$copyTicket - its parent trade just closed.',
      );
      try {
        await mt5.closePosition(symbol: mt5Symbol, positionTicket: copyTicket);
      } catch (e) {
        logger.log('$mt5Symbol ($category): failed to close copy ticket=$copyTicket: $e', level: 'ERROR');
        continue;
      }
      double? liquidationPriceForHistory;
      const stopOutLevel = 0.30;
      final profit = (copyPosition['profit'] as num?)?.toDouble();
      final volume = (copyPosition['volume'] as num?)?.toDouble();
      final priceOpen = (copyPosition['price_open'] as num?)?.toDouble();
      if (accountSnapshotBeforeClose != null &&
          accountSnapshotBeforeClose.margin > 0 &&
          profit != null &&
          volume != null &&
          volume != 0 &&
          priceOpen != null &&
          contractSize != 0) {
        final otherEquity = accountSnapshotBeforeClose.equity - profit;
        final targetProfit = stopOutLevel * accountSnapshotBeforeClose.margin - otherEquity;
        final priceDelta = targetProfit / (volume * contractSize);
        liquidationPriceForHistory = (copyPosition['action'] as String?) == 'sell'
            ? priceOpen - priceDelta
            : priceOpen + priceDelta;
      }
      _recordHistory(
        category: category,
        tvSymbol: tvSymbol,
        mt5Symbol: mt5Symbol,
        ticket: copyTicket,
        position: copyPosition,
        stopReason: 'parent_closed',
        detail: 'Closed because its parent trade closed.',
        contractSize: contractSize,
        sllAtTermination: '-\$1',
        extraMargin: accountSnapshotBeforeClose?.marginFree,
        liquidationPrice: liquidationPriceForHistory,
      );
      openPositions.forgetPosition(copyTicket);
      botCategories.forget(copyTicket);
      widenApplied.forget(copyTicket);
      risk.closePosition(mt5Symbol, category);
      copyPositions.forget(copyTicket);
    }
  }

  /// Per the user's Dashboard-table "Last" toggle spec: "once this trade is
  /// closed/terminated. pair will not managed auto." Called from every
  /// close path (opposite-signal, reconciliation's SL/TP/manual detection,
  /// and the terminate-request handler) once the position is actually
  /// gone. Reuses [RetiredStore] - already the exact mechanism that keeps
  /// a base out of the per-category auto-check loop (`if
  /// (retired.isRetiredBase(tvSymbol)) continue;`) - rather than building a
  /// second, parallel "stop auto-managing" pathway. Clears the pending Last
  /// flag itself, since it's now been acted on.
  ///
  /// ALSO removes the base from [autoManagedByCategory] (2026-10-06, fixed
  /// after a confirmed live bug: a Last-tagged WAITING pair (XRPUSDT),
  /// terminated via the Dashboard power icon, ended up retired but still
  /// listed as auto-managed - the Dashboard's checkbox-disable logic reads
  /// auto-managed membership, not [RetiredStore], so the pair stayed
  /// permanently un-selectable in the pair picker even though the engine
  /// itself correctly skips it for trading. This function's own doc
  /// comment already promised "pair will not managed auto" - retiring
  /// alone didn't deliver that for the UI, only for the trading loop).
  void _finalizeLastTagOnClose(AutoCategory category, String tvSymbol) {
    if (!lastTag.isLastTagged(tvSymbol)) return;
    retired.addRetiredBases([tvSymbol]);
    autoManagedByCategory[category]?.removeBase(tvSymbol);
    lastTag.setLastTagged(tvSymbol, false);
    logger.log(
      '$tvSymbol: Last-tagged trade closed - retiring this base from auto-management.',
    );
  }

  /// Drains every currently-pending terminate request (2026-09-30) -
  /// called at the top of every [_runCycle] AND again before every single
  /// symbol check within it (see that call site's own comment on why: so
  /// a request doesn't have to wait out an entire multi-minute sweep to be
  /// noticed). TerminateRequestStore is deliberately category-agnostic
  /// (just a base name), matching this app's single-category (1H)
  /// reality, so [AutoCategory.oneHour] is hardcoded here.
  Future<void> _processAllPendingTerminateRequests() async {
    for (final base in terminateRequests.loadPending()) {
      final matches = _loadSymbolsFresh().where((m) => m.tradingViewSymbol.toUpperCase() == base);
      final mapping = matches.isEmpty ? null : matches.first;
      if (mapping == null) {
        logger.log(
          '$base: pending terminate request but no SymbolMapping in config.json - '
          'clearing the stale request.',
          level: 'WARNING',
        );
        terminateRequests.clear(base);
        continue;
      }
      try {
        await _processTerminateRequest(AutoCategory.oneHour, mapping);
      } catch (e, st) {
        logger.log('Terminate request error for $base: $e\n$st', level: 'ERROR');
      }
    }
  }

  /// Drains every currently-pending "add a copy trade" request from the
  /// Dashboard's Multiplier column (2026-10-15, per the user: "once user
  /// click on it ... a new trade opens with same tp/sl open signal"). Same
  /// one-shot per-cycle drain pattern as [_processAllPendingTerminateRequests].
  Future<void> _processAllPendingAddCopyRequests() async {
    for (final base in addCopyRequests.loadPending()) {
      final matches = _loadSymbolsFresh().where((m) => m.tradingViewSymbol.toUpperCase() == base);
      final mapping = matches.isEmpty ? null : matches.first;
      if (mapping == null) {
        logger.log(
          '$base: pending add-copy request but no SymbolMapping in config.json - '
          'clearing the stale request.',
          level: 'WARNING',
        );
        addCopyRequests.clear(base);
        continue;
      }
      try {
        await _processAddCopyRequest(AutoCategory.oneHour, mapping);
      } catch (e, st) {
        logger.log('Add-copy request error for $base: $e\n$st', level: 'ERROR');
      }
    }
  }

  /// One click of the Multiplier column's "+" control - opens ONE
  /// additional real position on the same pair/category, mirroring
  /// whatever's already running's own direction, TP, and volume exactly
  /// (2026-10-15, per the user: "same tp/sl open signal. no need for
  /// recalculations" - TP and volume are copied verbatim, SL is the one
  /// deliberate exception, tightened to -$1 instead of the normal -$5
  /// baseline, per the user: "sll -1 for copied trades" - since a copy is
  /// only ever opened while the original is already winning, it doesn't
  /// need the same room). Deliberately bypasses [RiskGate.gate]'s own
  /// per-symbol cap (currently 1) - that cap exists to stop the automated
  /// signal logic from piling up duplicate SAME-signal positions by
  /// accident, not to block this explicit, manual, profit-gated action -
  /// but still fully respects the kill switch and the margin-tiered
  /// position cap (§ margin protection), since a copy is still a real
  /// position consuming a real slot.
  Future<void> _processAddCopyRequest(AutoCategory category, SymbolMapping mapping) async {
    final tvSymbol = mapping.tradingViewSymbol;
    final mt5Symbol = mapping.mt5Symbol;
    // Cleared up FRONT, not at the end (2026-10-15) - confirmed live that
    // clearing only after the whole attempt finishes (which can take up
    // to ~30s between the 20s trigger-poll and the history-lookup retries)
    // silently swallowed every extra "+" click that landed WHILE a
    // previous attempt for the same symbol was still in flight: a repeat
    // click just re-adds the same already-present Set entry (a no-op),
    // then gets wiped out by the FIRST attempt's own clear() the moment it
    // finishes, with that click never getting its own processing or
    // result at all. Clearing immediately means a click during an
    // in-flight attempt re-queues a genuinely fresh request, picked up on
    // the next drain pass once the current one is done, instead of
    // vanishing with zero feedback.
    addCopyRequests.clear(tvSymbol);
    final existing = await _findAppPosition(mt5Symbol, category, tvSymbol);
    if (existing == null) {
      logger.log(
        '$mt5Symbol ($category): add-copy requested but no running position found - ignoring.',
        level: 'WARNING',
      );
      return;
    }
    final profit = (existing['profit'] as num?)?.toDouble() ?? 0;
    if (profit <= 0) {
      logger.log(
        '$mt5Symbol ($category): add-copy requested but P&L is not positive '
        '(${profit.toStringAsFixed(2)}) - refusing.',
        level: 'WARNING',
      );
      return;
    }
    if (risk.killSwitchTripped) {
      logger.log('$mt5Symbol ($category): add-copy blocked - KILL SWITCH: STOP file present.', level: 'WARNING');
      return;
    }
    // Deliberately NOT margin-cap gated (2026-10-15, per the user: "manual
    // copies done by user: has nothing to do with margin level") - unlike
    // the automated milestone path below, a manual click is a one-shot,
    // explicit, already-profit-gated human decision.
    final result = await _openCopyPosition(category, mapping, existing, reasonLabel: 'manual');
    // Surface the outcome back to the Dashboard as a SnackBar (2026-10-15,
    // per the user, after a real copy's pending fallback order was REJECTED
    // by MT5 itself for insufficient margin ("no money") while this app's
    // own margin-tiered gate sat at a perfectly healthy level for the
    // manual path - the click succeeded at bypassing OUR gate, but MT5's
    // own broker-side margin check can't be bypassed by anything this app
    // does, and silently logging that to engine.log alone left the user
    // with "nothing happend" and no idea why). Only a genuinely KNOWN
    // failure reason gets recorded - the ambiguous "still resting, might
    // still trigger" case deliberately records nothing, see
    // [_openCopyPosition]'s own doc comment.
    if (result.success) {
      addCopyResults.recordSuccess(tvSymbol);
    } else if (result.failureReason != null) {
      addCopyResults.recordFailure(tvSymbol, result.failureReason!);
    }
  }

  /// The real order-placement core shared by [_processAddCopyRequest]
  /// (manual "+" click) and [_processAutoCopyMilestones] (automated +\$5
  /// milestone copies) - mirrors [existing]'s own direction/TP exactly
  /// ("same tp/sl open signal. no need for recalculations"), fixed at 1
  /// lot regardless of the original's own size ("it has to be v=1 fixed
  /// and if user want to add more volum then he has to increase number of
  /// copies"), with a tightened -\$1 SL instead of the normal -\$5
  /// baseline (only ever opened while already winning, doesn't need the
  /// same room). Returns a record rather than a plain bool (2026-10-15) -
  /// `success` is true only on genuine success (filled, or a pending
  /// fallback that triggered within the poll window); `failureReason` is
  /// set ONLY for a genuinely known failure worth telling the user about
  /// (MT5 itself rejecting the order, e.g. "no money") - it's deliberately
  /// left null for the ambiguous "pending order still resting, might yet
  /// trigger on its own" case, since that one isn't a failure the user
  /// needs to react to.
  Future<({bool success, String? failureReason})> _openCopyPosition(
    AutoCategory category,
    SymbolMapping mapping,
    Map<String, dynamic> existing, {
    required String reasonLabel,
  }) async {
    final mt5Symbol = mapping.mt5Symbol;
    final direction = (existing['action'] as String?) == 'sell' ? TradeDirection.short : TradeDirection.long;
    final existingTp = (existing['take_profit'] as num?)?.toDouble();
    if (existingTp == null) {
      logger.log(
        '$mt5Symbol ($category): $reasonLabel copy blocked - running position is missing its TP, '
        'nothing to copy.',
        level: 'ERROR',
      );
      return (success: false, failureReason: 'Running position has no TP to copy.');
    }
    const copyVolume = 1.0;

    final symbolInfoResult = await mt5.getMarketWatchSymbol(mt5Symbol);
    final symbols = (symbolInfoResult['symbols'] as List?) ?? const [];
    if (symbols.isEmpty) {
      logger.log('$mt5Symbol ($category): $reasonLabel copy blocked - not found in Market Watch.', level: 'ERROR');
      return (success: false, failureReason: '$mt5Symbol not found in MT5 Market Watch.');
    }
    final info = symbols.first as Map<String, dynamic>;
    final digits = (info['digits'] as num?)?.toInt() ?? 5;
    final contractSize = (info['contract_size'] as num?)?.toDouble() ?? 1.0;
    final bid = (info['bid'] as num).toDouble();
    final ask = (info['ask'] as num).toDouble();
    final entry = direction == TradeDirection.long ? ask : bid;

    final copySl = _baselineStopLoss(
      entry: entry,
      direction: direction,
      volume: copyVolume,
      contractSize: contractSize,
      digits: digits,
      dollarCap: 1,
    );
    final copyTp = _roundToDigits(existingTp, digits);
    final profit = (existing['profit'] as num?)?.toDouble() ?? 0;

    logger.log(
      '$mt5Symbol ($category): opening $reasonLabel COPY ${direction == TradeDirection.long ? 'BUY' : 'SELL'} '
      'vol=$copyVolume entry=$entry sl=$copySl (-\$1) tp=$copyTp (copied from running '
      'ticket=${existing['position_id']}, profit was +${profit.toStringAsFixed(2)}).',
    );
    var result = await mt5.sendMarketOrder(
      symbol: mt5Symbol,
      side: direction == TradeDirection.long ? 'buy' : 'sell',
      volume: copyVolume,
      sl: copySl,
      tp: copyTp,
      comment: 'trading_mt5 ${category.wireValue}',
    );

    var retcode = (result['retcode'] as num?)?.toInt();
    var viaPendingFallback = false;
    if (retcode != null && retcode != 10009) {
      if (retcode == 10030) {
        // Same "Invalid fill" fallback as a normal open, but with the
        // TIGHTEST distance MT5 will actually accept rather than
        // [_openPosition]'s own `(stopsLevelPoints + 2) * point` safety
        // buffer (2026-10-15, per the user: "i asked you to make the copy
        // run instantly but according to app setting the instant run
        // cant be placed... make the trigger price +1 value" - fire on
        // the very next tick rather than waiting for price to clear a
        // multi-point margin). First attempt was a flat one price unit
        // (e.g. 3.01 -> 3.02) with no floor at all - confirmed live this
        // broke placement outright (retcode=10015 "Invalid price") for
        // LTCUSD.lv/ATOMUSD.lv, whose real `trade_stops_level` is 5
        // points (0.005), not 1. MT5's minimum distance is a hard broker
        // rule, not a buffer this app can shrink past - so this still
        // respects it, just drops the "+2" extra padding on top of it
        // that a normal open uses, giving the tightest distance that
        // will genuinely be accepted (falling back to one unit only for
        // a symbol with no stated minimum at all).
        final stopsLevelPoints = (info['trade_stops_level'] as num?)?.toInt() ?? 0;
        final point = (info['point'] as num?)?.toDouble() ?? 0.0;
        var unitMult = 1.0;
        for (var i = 0; i < digits; i++) {
          unitMult *= 10;
        }
        final oneUnit = 1 / unitMult;
        final minDistance = point > 0 && stopsLevelPoints > 0
            ? stopsLevelPoints * point
            : oneUnit;
        final triggerPrice = _roundToDigits(
          direction == TradeDirection.long ? ask + minDistance : bid - minDistance,
          digits,
        );
        logger.log(
          '$mt5Symbol ($category): $reasonLabel copy market order rejected (Invalid fill) — '
          'retrying as an immediate-trigger pending order.',
        );
        result = await mt5.sendPendingOrder(
          symbol: mt5Symbol,
          type: direction == TradeDirection.long ? 'buy_stop' : 'sell_stop',
          volume: copyVolume,
          price: triggerPrice,
          sl: copySl,
          tp: copyTp,
          fillingType: 'ioc',
          comment: 'trading_mt5 ${category.wireValue}',
        );
        retcode = (result['retcode'] as num?)?.toInt();
        viaPendingFallback = true;
      }
      if (retcode != null && retcode != 10009) {
        logger.log(
          '$mt5Symbol ($category): $reasonLabel copy order rejected: retcode=$retcode '
          '${result['retcode_details'] ?? ''}'.trim(),
          level: 'ERROR',
        );
        return (
          success: false,
          failureReason: 'MT5 rejected the order (retcode=$retcode).',
        );
      }
    }

    final ticket = _firstIntField(result, const ['ticket', 'position_ticket', 'position', 'order', 'deal']);
    if (ticket == null) {
      logger.log(
        '$reasonLabel copy order for $mt5Symbol appears to have been SENT but no ticket field '
        'was recognized in the response: $result — NOT tracked.',
        level: 'CRITICAL',
      );
      return (
        success: false,
        failureReason: 'Order was sent but MT5\'s response had no ticket - check MT5 manually.',
      );
    }

    // Same open signal as the original (2026-10-15, per the user: "same
    // tp/sl open signal") - copied verbatim, not a fresh lookup, so the
    // Dashboard's Open column reads identically for every row in this
    // pair's group.
    void copyOpenSignalOnto(int newTicket) {
      final existingTicket = _parseTicket(existing['position_id']);
      final worm10Snapshot = existingTicket == null ? null : worm10EntrySignals.peek(existingTicket);
      if (worm10Snapshot != null) {
        worm10EntrySignals.record(newTicket, worm10Snapshot);
        return;
      }
      final regularSnapshot = existingTicket == null ? null : entrySignals.peek(existingTicket);
      if (regularSnapshot != null) entrySignals.record(newTicket, regularSnapshot);
    }

    if (!viaPendingFallback) {
      openPositions.rememberPosition(ticket);
      botCategories.setCategory(ticket, category);
      risk.openPosition(mt5Symbol, category);
      copyOpenSignalOnto(ticket);
      copyPositions.markCopy(ticket);
      logger.log('$mt5Symbol ($category): $reasonLabel copy opened, ticket=$ticket.');
      return (success: true, failureReason: null);
    }

    // Exempt a MANUAL copy's own resting pending order from the margin
    // gate's cancellation sweep for as long as it's genuinely still
    // pending (2026-10-15, per the user: "manual copies done by user: has
    // nothing to do with margin level" - confirmed live that
    // [_cancelAllRestingPendingOrders] otherwise cancels this within
    // seconds, since it shares the same comment tag as any other pending
    // order). Deliberately NOT done for the auto +$5 milestone path - that
    // one is supposed to respect the margin gate throughout.
    if (reasonLabel == 'manual') manualCopyPendingOrders.markPending(ticket);

    // Same ticket-vs-order-id distinction as a normal open's own pending
    // fallback - poll briefly for the triggered position.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final positionsResult = await mt5.getOpenPositions(symbol: mt5Symbol);
      final positions = (positionsResult['positions'] as List?) ?? const [];
      for (final p in positions) {
        final map = p as Map<String, dynamic>;
        final positionTicket = _parseTicket(map['position_id']);
        if (positionTicket == null || openPositions.isAppOpened(positionTicket)) continue;
        openPositions.rememberPosition(positionTicket);
        botCategories.setCategory(positionTicket, category);
        risk.openPosition(mt5Symbol, category);
        copyOpenSignalOnto(positionTicket);
        copyPositions.markCopy(positionTicket);
        manualCopyPendingOrders.clear(ticket);
        logger.log(
          '$mt5Symbol ($category): $reasonLabel copy pending order $ticket triggered, opened ticket=$positionTicket.',
        );
        return (success: true, failureReason: null);
      }
    }
    logger.log(
      '$mt5Symbol ($category): $reasonLabel copy pending order $ticket placed but did not trigger within '
      '20s — still resting in MT5, not yet tracked. Will be picked up once it triggers and '
      'the next cycle sees it, or check MT5 manually.',
      level: 'ERROR',
    );
    // Same "check history orders for the real reason" pattern as
    // [_openPosition]'s own doc comment (2026-09-29) - a "did not trigger"
    // timeout is NOT necessarily still-resting-and-fine; MT5 itself can
    // silently reject/delete the order (e.g. `comment: "deleted [no
    // money]"` - insufficient free margin), invisible from
    // [getOpenPositions] alone once the order is gone. Confirmed live
    // 2026-10-15: a manual copy's fallback order (ticket 1660700117,
    // LTCUSD.lv) vanished this exact way while account margin sat at
    // ~95-97% - the app's OWN margin gate was correctly bypassed for the
    // manual click, but MT5's broker-side margin check can't be bypassed
    // by anything this app does, and that distinction was invisible to the
    // user until this lookup was added.
    // Retried, not a single shot (2026-10-15) - confirmed live that MT5
    // doesn't always reflect a rejection in its own history INSTANTLY at
    // the 20s mark: ticket 1660704726 showed up rejected within ~10ms of
    // the timeout, but a later attempt (1660706623) found nothing on the
    // first check and would have silently given up with no reason at all,
    // reproducing the exact "nothing happend" report this whole lookup was
    // built to fix. A few seconds' slack covers that lag.
    for (var attempt = 0; attempt < 4; attempt++) {
      if (attempt > 0) await Future<void>.delayed(const Duration(seconds: 3));
      try {
        final history = await mt5.getHistoryOrders(symbol: mt5Symbol);
        final orders = (history['orders'] as List?) ?? const [];
        for (final o in orders) {
          final map = o as Map<String, dynamic>;
          if (_parseTicket(map['order_id']) == ticket && map['state'] != 'placed') {
            final comment = map['comment'] as String? ?? map['state'] as String? ?? 'rejected';
            logger.log(
              '$mt5Symbol ($category): $reasonLabel copy pending order $ticket was REJECTED by '
              'MT5: "$comment".',
              level: 'ERROR',
            );
            manualCopyPendingOrders.clear(ticket);
            return (
              success: false,
              failureReason: 'MT5 rejected the order: $comment',
            );
          }
        }
      } catch (e) {
        logger.log('$mt5Symbol ($category): could not check $reasonLabel copy order $ticket\'s history: $e', level: 'ERROR');
      }
    }
    // Still genuinely ambiguous after retrying (order not found as
    // rejected in history either) - leave failureReason null so no
    // SnackBar fires for what may yet resolve itself on a later cycle.
    logger.log(
      '$mt5Symbol ($category): $reasonLabel copy pending order $ticket still not resolved in '
      'MT5 history after retrying - leaving it be, not reporting a failure yet.',
      level: 'WARNING',
    );
    return (success: false, failureReason: null);
  }

  /// Automated +\$5 milestone copying (2026-10-15, per the user: "auto
  /// copy, this will be applied each time P&L has +5$ more... if btcusd
  /// is 5.5$, an auto copy will be created... applied again if it becomes
  /// +10$... i am speaking here about the parent not the copy"). Tracks
  /// each ORIGINAL (lowest-ticket) position's highest $5 milestone
  /// already consumed in [autoCopyMilestones], so a position sitting at
  /// +\$5 forever only ever triggers ONE copy, not one per cycle. Unlike
  /// the manual path, THIS one fully respects the margin-tiered position
  /// cap ("if margin level is more than +150% or whatever margin rules
  /// applies") - a milestone that's blocked by margin is simply left
  /// un-consumed and retried next cycle, never skipped.
  Future<void> _processAutoCopyMilestones(AutoCategory category) async {
    final cap = RiskGate.positionCapFor(risk.marginLevel);
    if (cap == 0) return;
    if (risk.killSwitchTripped) return;

    final openResult = await mt5.getOpenPositions();
    final positions = ((openResult['positions'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where((p) => p['comment'] == 'trading_mt5 ${category.wireValue}');
    // The ORIGINAL per symbol is whichever ticket is lowest - same
    // derivation as the Dashboard's own darker-shade-for-the-original
    // coloring, no separate original/copy tracking needed.
    final bySymbol = <String, List<Map<String, dynamic>>>{};
    for (final p in positions) {
      final symbol = (p['symbol'] as String).toUpperCase();
      (bySymbol[symbol] ??= []).add(p);
    }
    for (final entry in bySymbol.entries) {
      final group = entry.value;
      Map<String, dynamic>? original;
      int? lowestTicket;
      for (final p in group) {
        final t = _parseTicket(p['position_id']);
        if (t == null) continue;
        if (lowestTicket == null || t < lowestTicket) {
          lowestTicket = t;
          original = p;
        }
      }
      if (original == null || lowestTicket == null) continue;

      final profit = (original['profit'] as num?)?.toDouble() ?? 0;
      final targetMilestone = profit > 0 ? (profit / 5).floor() : 0;
      var consumed = autoCopyMilestones.get(lowestTicket);
      if (targetMilestone <= consumed) continue;

      final matches = _loadSymbolsFresh().where((m) => m.mt5Symbol.toUpperCase() == entry.key);
      if (matches.isEmpty) continue;
      final mapping = matches.first;

      // Catch up every crossed milestone in one pass (e.g. a sudden jump
      // from +\$3 to +\$12 crosses both the +\$5 and +\$10 rungs at once) -
      // stop and leave the rest for next cycle the moment one is blocked,
      // rather than skipping ahead and losing track of it.
      while (consumed < targetMilestone) {
        final freshCap = RiskGate.positionCapFor(risk.marginLevel);
        if (freshCap == 0) break;
        final result = await _openCopyPosition(category, mapping, original, reasonLabel: 'auto +\$5 milestone');
        if (!result.success) break;
        consumed++;
        autoCopyMilestones.set(lowestTicket, consumed);
        logger.log(
          '${mapping.mt5Symbol} ($category): auto-copy milestone ${consumed * 5} reached '
          '(ticket=$lowestTicket profit was +${profit.toStringAsFixed(2)}) - copy opened.',
        );
      }
    }
  }

  /// Drains every currently-pending unpause-checkup request (2026-10-09, per
  /// the user: "if running paused pair un-paused: then a reverse checkup
  /// will occur on this pair instantly and then action according to this
  /// checkup. if waiting paused pair un-paused: then an instant checkup
  /// will be applied to match current filled calculations"). Called at the
  /// top of every [_runCycle] AND again before every single symbol check
  /// within it, same responsiveness reasoning as
  /// [_processAllPendingTerminateRequests]. A single `immediate: true` call
  /// into the pair's own normal check method covers BOTH cases the user
  /// described - that method's existing running-vs-waiting branches already
  /// do the right thing either way (a running trade gets compared against
  /// the freshly re-read signal and flips if it disagrees - "a reverse
  /// checkup, act accordingly"; a waiting pair gets evaluated immediately
  /// against the current chart instead of waiting out the normal cooldown -
  /// "an instant checkup against current calculations") - no separate code
  /// path needed. [AutoCategory.oneHour] is hardcoded, same single-category
  /// reality as [_processAllPendingTerminateRequests].
  Future<void> _processAllPendingUnpauseChecks(DecisionTechnique technique) async {
    for (final base in unpauseRequests.loadPending()) {
      if (paused.isPaused(base)) {
        // Re-paused again before this request was ever processed - the
        // user's own later action wins; don't act on a stale request.
        unpauseRequests.clear(base);
        continue;
      }
      final matches = _loadSymbolsFresh().where((m) => m.tradingViewSymbol.toUpperCase() == base);
      final mapping = matches.isEmpty ? null : matches.first;
      if (mapping == null) {
        logger.log(
          '$base: pending unpause checkup but no SymbolMapping in config.json - '
          'clearing the stale request.',
          level: 'WARNING',
        );
        unpauseRequests.clear(base);
        continue;
      }
      // 2026-10-19, per the user: "then force to apply full reverse
      // check" - without this, a running position's retroactive audit
      // (the full forward-replay-from-Start block in [_checkOneSymbol]/
      // [_checkOneSymbolWorm10]) only fires once per ticket per GUI-
      // reopen/hour (see [_auditedTickets]'s own doc comment) -
      // unrelated to pause/unpause at all, so an unpause landing after
      // that gate had already fired this hour silently got the LIGHTER
      // check instead (compare latest signal to running direction, no
      // full history re-derivation). Clearing this ticket's own gate
      // right before the immediate check guarantees the full audit
      // actually runs every time a pair is unpaused, not just
      // sometimes. Harmless no-op for Supertrend Plus, which has no
      // separate audit gate to clear (every cycle already re-reads the
      // latest signal directly).
      final existingForAudit = await _findAppPosition(mapping.mt5Symbol, AutoCategory.oneHour, mapping.tradingViewSymbol);
      final auditTicketToForce = _parseTicket(existingForAudit?['position_id']);
      if (auditTicketToForce != null) _auditedTickets.remove(auditTicketToForce);

      try {
        if (technique.id == DecisionTechnique.supertrendPlus.id) {
          await _checkOneSymbolSupertrend(AutoCategory.oneHour, mapping, immediate: true);
        } else if (technique.id == DecisionTechnique.worm10.id) {
          await _checkOneSymbolWorm10(AutoCategory.oneHour, mapping, immediate: true);
        } else {
          await _checkOneSymbol(AutoCategory.oneHour, mapping, immediate: true);
        }
      } catch (e, st) {
        logger.log('Unpause checkup error for $base: $e\n$st', level: 'ERROR');
      }
      unpauseRequests.clear(base);
    }
  }

  /// Drains every pending "does this TradingView symbol exist" request
  /// (2026-10-10, Add Pair flow - see [SymbolResolveStore]'s own doc
  /// comment for why this has to go through the engine at all). For each
  /// candidate: switches the shared chart to it and checks whether
  /// TradingView actually resolved to something, exactly the same
  /// `setChartView` call/base-ticker comparison every normal signal read
  /// already uses - no new chart-reading logic, just a one-off use of the
  /// existing mechanism with no resolution requested (only the symbol
  /// itself is being verified, nothing about a specific timeframe). A
  /// failure anywhere in this (TradingView not installed, CDP down, the
  /// symbol genuinely not resolving) is recorded as "not found" rather
  /// than left pending forever - the GUI is polling for an answer, and an
  /// explicit "no" is always better than a request that silently never
  /// completes.
  Future<void> _processAllPendingSymbolResolveRequests() async {
    for (final candidate in symbolResolve.loadPending()) {
      try {
        await _ensureCdpUp();
        final result = await setChartView(_cdp!, candidate, null);
        symbolResolve.recordResult(
          candidate,
          found: result.ok,
          resolvedSymbol: result.state?.symbol,
        );
      } catch (e) {
        logger.log('Symbol resolve check failed for $candidate: $e', level: 'WARNING');
        symbolResolve.recordResult(candidate, found: false);
      }
    }
  }

  /// Dashboard power icon (2026-09-29 spec, revised 2026-09-30: "make it as
  /// red ... once it is clicked last, it removes the pair from auto list
  /// ... same red action" for the pending/waiting case too). Pulled out of
  /// [_checkOneSymbol] and called via [_processAllPendingTerminateRequests]
  /// for EVERY pending request (2026-09-30, confirmed live: [_checkOneSymbol]
  /// is only ever invoked for bases CURRENTLY in [AutoManagedStore] - once a
  /// base is removed from auto (by this very action, among others), it drops
  /// out of that loop entirely and a later terminate request for it would
  /// sit in [TerminateRequestStore] forever, unprocessed, since nothing
  /// would ever call [_checkOneSymbol] for it again). Running this
  /// independently of auto-managed membership means the power icon keeps
  /// working on a pair no matter its Auto state.
  Future<void> _processTerminateRequest(AutoCategory category, SymbolMapping mapping) async {
    final tvSymbol = mapping.tradingViewSymbol;
    final mt5Symbol = mapping.mt5Symbol;
    final existing = await _findAppPosition(mt5Symbol, category, tvSymbol);
    if (existing != null) {
      await _closePosition(
        category,
        tvSymbol,
        mt5Symbol,
        existing,
        stopReason: 'closed_by_user',
        detail: 'Closed by user via the Dashboard power icon.',
      );
    } else {
      final ordersResult = await mt5.getOpenPositions(symbol: mt5Symbol);
      final orders = (ordersResult['orders'] as List?) ?? const [];
      final tag = 'trading_mt5 ${category.wireValue}';
      for (final o in orders) {
        final map = o as Map<String, dynamic>;
        if (map['comment'] == tag && map['state'] == 'placed') {
          final orderTicket = _parseTicket(map['order_id']);
          if (orderTicket != null) {
            await mt5.deleteOrder(symbol: mt5Symbol, orderTicket: orderTicket);
            logger.log(
              '$mt5Symbol ($category): cancelled resting order=$orderTicket '
              'via Dashboard power icon.',
            );
          }
        }
      }
      _finalizeLastTagOnClose(category, tvSymbol);
    }
    terminateRequests.clear(tvSymbol);
  }

  /// Builds and appends one [BotHistoryEntry] for a position that just
  /// closed (or was found already gone — see the reconciliation loop in
  /// [_runCycle]) — the single write point for every close reason
  /// ('opposite_signal' here; 'take_profit'/'stop_loss'/'margin_stop_out'/
  /// 'closed_by_user' from reconciliation). Reads back [entrySignals]' snapshot taken at
  /// open time (forgetting it) to fill the open_signal_* fields; [position]
  /// (the last known live snapshot before closing) supplies entry/exit
  /// price and realized profit.
  void _recordHistory({
    required AutoCategory category,
    required String tvSymbol,
    required String mt5Symbol,
    required int ticket,
    required Map<String, dynamic> position,
    Signal? closeSignal,
    required String stopReason,
    required String detail,
    // See [_closePosition]'s own doc comment on these two.
    String? worm10CloseKindWire,
    int? worm10CloseAt,
    // 2026-10-14, per the user's history-card request - see
    // [_closePosition]'s own doc comment on where these come from.
    double contractSize = 1.0,
    String? sllAtTermination,
    // 2026-10-15, per the user ("all details required in history") - see
    // [BotHistoryEntry.extraMargin]/[liquidationPrice]'s own doc comments
    // for why these two (unlike [investmentValue] below) can only ever be
    // set going forward, never backfilled for a past close.
    double? extraMargin,
    double? liquidationPrice,
  }) {
    // The worm_10_26 technique keeps its own open/update snapshot in
    // [worm10EntrySignals] (a six-way [Worm10EventKind], not the 4-way
    // [SignalTag] [entrySignals] holds) - try that store FIRST and only
    // fall back to [entrySignals] if nothing's there, so a ticket opened
    // under this technique never accidentally reads a stale/absent Signal
    // Flip snapshot instead of its own.
    final worm10Snapshot = worm10EntrySignals.takeFor(ticket);
    final openSnapshot = worm10Snapshot == null ? entrySignals.takeFor(ticket) : null;
    final direction = (position['action'] as String?) == 'sell'
        ? TradeDirection.short
        : TradeDirection.long;
    final entryPrice = (position['price_open'] as num?)?.toDouble() ?? 0.0;
    final exitPrice = (position['price_last'] as num?)?.toDouble();
    final volume = (position['volume'] as num?)?.toDouble();
    // 2026-10-15, per the user's Multiplier-column work, found live: this
    // read the wrong field names ('sl'/'tp') this whole time - the real
    // open-position field names confirmed live are 'stop_loss'/
    // 'take_profit' (see RiskGate... no, see the Dashboard's own existing,
    // already-correct app_providers.dart read of the same shape). History
    // entries for an ACTIVE app-initiated close have always recorded a
    // null stopLoss/takeProfit because of this - fixed.
    final stopLoss = (position['stop_loss'] as num?)?.toDouble();
    final takeProfit = (position['take_profit'] as num?)?.toDouble();
    final profit = (position['profit'] as num?)?.toDouble();
    final startTime = DateTime.tryParse(
      (position['create_time'] as String?) ?? '',
    ) ?? DateTime.now();
    // Same formula as the Dashboard's own live P&L% column (2026-10-14).
    final notional = (volume ?? 0) * contractSize * entryPrice;
    final realizedProfitPercent = (profit != null && notional != 0) ? profit / notional * 100 : null;
    storage.appendJsonl(
      storage.botHistoryFile,
      BotHistoryEntry(
        id: '$ticket-${DateTime.now().microsecondsSinceEpoch}',
        ts: DateTime.now(),
        mt5Symbol: mt5Symbol,
        tradingViewSymbol: tvSymbol,
        category: category,
        ticket: ticket,
        direction: direction,
        entryPrice: entryPrice,
        exitPrice: exitPrice,
        volume: volume,
        stopLoss: stopLoss,
        takeProfit: takeProfit,
        realizedProfit: profit,
        startTime: startTime,
        endTime: DateTime.now(),
        openSignalType: worm10Snapshot != null
            ? worm10EventKindToWire(worm10Snapshot.kind)
            : openSnapshot?.tag,
        openSignalAt: worm10Snapshot?.barTime ?? openSnapshot?.barTime,
        updateSignalType: worm10Snapshot?.updateKind != null
            ? worm10EventKindToWire(worm10Snapshot!.updateKind!)
            : openSnapshot?.updateTag,
        updateSignalAt: worm10Snapshot?.updateTime ?? openSnapshot?.updateTime,
        closeSignalType: worm10CloseKindWire ??
            (closeSignal != null ? signalTagToWire(closeSignal.tag) : null),
        closeSignalAt: worm10CloseAt ?? closeSignal?.time,
        stopReason: stopReason,
        detail: detail,
        realizedProfitPercent: realizedProfitPercent,
        sllAtTermination: sllAtTermination,
        investmentValue: notional,
        extraMargin: extraMargin,
        liquidationPrice: liquidationPrice,
      ).toJson(),
    );
  }

  int? _firstIntField(Map<String, dynamic> map, List<String> keys) {
    for (final k in keys) {
      final v = map[k];
      if (v is num) return v.toInt();
    }
    return null;
  }

  /// `position_id` comes back as a quoted STRING from
  /// `get_trading_open_positions` (confirmed live 2026-09-27 — crashed
  /// every cycle with "type 'String' is not a subtype of type 'num?'"
  /// before this fix), unlike the numeric `order`/`ticket` fields
  /// [_firstIntField] handles elsewhere. Accepts either shape defensively.
  int? _parseTicket(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// System-wide available RAM, read fresh on every status write
  /// (2026-10-17, per the user, after a real incident: TradingView froze
  /// mid-sweep and crashed while the system was down to ~955MB free with
  /// heavy swap use - a Dashboard light for this is the whole point, so
  /// the NEXT time this happens the user sees it immediately instead of
  /// having to diagnose it after the fact). Reads `/proc/meminfo`'s
  /// `MemAvailable` - the kernel's own "truly usable, including
  /// reclaimable cache" figure, the same number `free -h`'s own
  /// "available" column reports. Linux-only; null (never treated as
  /// "low") anywhere else or if the read fails for any reason.
  ///
  /// 2026-10-18, per the user: "check why ram is not showing same thing
  /// in exe as linex in engine card" - this was never a different NUMBER
  /// on Windows, it was no number at all: `/proc/meminfo` doesn't exist
  /// there, so the read always threw and both values stayed silently
  /// null. [readWindowsMemoryMb] is the real Windows counterpart (a
  /// direct `GlobalMemoryStatusEx` syscall, not a `wmic`/PowerShell
  /// subprocess - see its own doc comment for why that matters at this
  /// call frequency); on any other platform both stay null, same as
  /// today.
  int? _readMeminfoValueMb(String key) {
    try {
      final content = File('/proc/meminfo').readAsStringSync();
      for (final line in content.split('\n')) {
        if (line.startsWith(key)) {
          final match = RegExp(r'(\d+)').firstMatch(line);
          if (match != null) return int.parse(match.group(1)!) ~/ 1024;
        }
      }
    } catch (_) {
      // Not on Linux, or /proc unavailable - stays null.
    }
    return null;
  }

  int? _readAvailableRamMb() => Platform.isWindows ? readWindowsMemoryMb()?.availMb : _readMeminfoValueMb('MemAvailable:');
  int? _readTotalRamMb() => Platform.isWindows ? readWindowsMemoryMb()?.totalMb : _readMeminfoValueMb('MemTotal:');

  void _writeStatus({
    bool connected = false,
    String? message,
    PowerHealthState health = PowerHealthState.off,
  }) {
    storage.writeJson(
      storage.statusFile,
      EngineStatus(
        running: true,
        connected: connected,
        lastCycleAt: DateTime.now(),
        message: message,
        health: health,
        ramAvailableMb: _readAvailableRamMb(),
        ramTotalMb: _readTotalRamMb(),
      ).toJson(),
    );
  }

  /// Technique Summary screen's "reverse calculation" backtester
  /// (2026-10-17, per the user: investment value + pair + number of days,
  /// re-running the SAME real worm_10_26 decision logic against historical
  /// TradingView data as if it had been trading live the whole time -
  /// "same as if it is currently running .. real calculations .. full
  /// mackup"). One request at a time - see [BacktestRequestStore]'s own
  /// doc comment for why. Deliberately NOT queued through the terminate/
  /// add-copy drain points inside the long per-symbol sweep - a multi-day
  /// history pull can genuinely take a while, and there's no reason to
  /// risk starving that sweep's own responsiveness for it.
  Future<void> _processPendingBacktestRequest() async {
    final req = backtestRequests.loadPending();
    if (req == null) return;
    final tvSymbol = (req['tv_symbol'] as String).toUpperCase();
    final investment = (req['investment'] as num).toDouble();
    final days = (req['days'] as num).toInt();
    final volume = (req['volume'] as num).toDouble();
    // 2026-10-17, per the user: the GUI resolves (or confirms a listed
    // pair's own) MT5 symbol itself before ever sending this request, so
    // this is trusted directly rather than re-derived from config.json -
    // see [BacktestRequestStore.request]'s own doc comment.
    final requestedMt5Symbol = req['mt5_symbol'] as String?;
    backtestRequests.clear();

    SymbolMapping? mapping;
    if (requestedMt5Symbol != null) {
      mapping = SymbolMapping(tradingViewSymbol: tvSymbol, mt5Symbol: requestedMt5Symbol);
    } else {
      final matches = _loadSymbolsFresh().where((m) => m.tradingViewSymbol.toUpperCase() == tvSymbol);
      if (matches.isNotEmpty) mapping = matches.first;
    }
    if (mapping == null) {
      backtestResults.recordDone(
        BacktestResult(
          tvSymbol: tvSymbol,
          investment: investment,
          days: days,
          rows: const [],
          totalProfitUsd: 0,
          totalProfitPercent: 0,
          winCount: 0,
          lossCount: 0,
          error: 'No symbol mapping found for $tvSymbol in config.json.',
        ),
      );
      return;
    }
    backtestResults.recordRunning(tvSymbol);
    logger.log(
      'BACKTEST: starting $tvSymbol over the last $days day(s), '
      'investment=\$${investment.toStringAsFixed(2)}.',
    );
    try {
      final result = await _runBacktest(mapping, investment: investment, days: days, volume: volume);
      backtestResults.recordDone(result);
      logger.log(
        'BACKTEST: $tvSymbol finished - ${result.rows.length} trade(s), '
        'total \$${result.totalProfitUsd.toStringAsFixed(2)} '
        '(${result.totalProfitPercent.toStringAsFixed(2)}%).',
      );
    } catch (e, st) {
      logger.log('BACKTEST: $tvSymbol failed: $e\n$st', level: 'ERROR');
      backtestResults.recordDone(
        BacktestResult(
          tvSymbol: tvSymbol,
          investment: investment,
          days: days,
          rows: const [],
          totalProfitUsd: 0,
          totalProfitPercent: 0,
          winCount: 0,
          lossCount: 0,
          error: '$e',
        ),
      );
    }
  }

  /// The actual simulation - see [_processPendingBacktestRequest]'s own
  /// doc comment for the full spec. 2026-10-17 REDESIGN, per the user:
  /// "i want open signals and close signals and update signals ... i
  /// dont want any sll" - a trade closes ONLY on the next opposing/
  /// closing worm10 signal, same as the chart's own signal-to-signal
  /// logic. An earlier version of this simulated a flat -$5 SL + 60/40-
  /// model TP as real-price-path exits (scanning bar High/Low) - that
  /// was never part of the original spec and was the actual source of
  /// "this doesn't match what I see on the chart" confusion, since a
  /// trade could close on SL long before the real next signal. Removed
  /// entirely, not just disclosed as a limitation.
  Future<BacktestResult> _runBacktest(
    SymbolMapping mapping, {
    required double investment,
    required int days,
    // 2026-10-18, per the user: "inputs are investment, pair, days,
    // volum" - real, independent input again. Real MT5 has no "dollar
    // investment" concept at all, only the lot size you actually choose
    // to trade - [investment] stays purely the %-return basis
    // ([BacktestRow.profitPercent]'s own denominator).
    required double volume,
  }) async {
    final tvSymbol = mapping.tradingViewSymbol;
    final mt5Symbol = mapping.mt5Symbol;
    const category = AutoCategory.oneHour;

    await _ensureCdpUp();
    final cdp = _cdp!;

    final chartView = await setChartView(cdp, tvSymbol, category.signalResolution);
    if (!chartView.ok) {
      throw StateError('could not switch the chart to $tvSymbol (${chartView.error})');
    }
    // 2026-10-17 bugfix: worm_10_26/spy_9_26 are documented as requiring
    // Heikin Ashi candles (see [_indicatorsReadyFor]'s own live-path
    // equivalent) - [setChartView] only switches the SYMBOL/resolution,
    // never the candle style, so without this the backtest was reading
    // signals off whatever style the chart happened to already be on.
    // Found live: a real run (SOLUSDT, 7 days) came back with SIX trades,
    // every single one LONG off an "LL" open that immediately stopped out
    // - exactly the kind of systematic skew reading regular candles
    // instead of Heikin Ashi would produce.
    final styleOk = await ensureChartStyle(cdp, ChartStyle.heikinAshi);
    if (!styleOk) {
      throw StateError('could not switch the chart to Heikin Ashi candles for $tvSymbol');
    }

    final cutoff = DateTime.now().toUtc().subtract(Duration(days: days)).millisecondsSinceEpoch ~/ 1000;
    await requestMoreChartHistory(cdp);

    Future<List<List<dynamic>>> readBarsOnce() async {
      final raw = await cdp.evaluate('''(function() {
        try {
          var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
          var series = chart.model().mainSeries();
          var bars = series.bars();
          var size = bars.size();
          if (size === 0) return { error: 'no bars loaded' };
          var first = bars.firstIndex();
          var last = bars.lastIndex();
          var out = [];
          for (var i = first; i <= last; i++) {
            var v = bars.valueAt(i);
            if (v) out.push(v);
          }
          return { bars: out };
        } catch (e) {
          return { error: String(e && e.message || e) };
        }
      })()''') as Map<String, dynamic>?;
      if (raw?['error'] != null) {
        throw StateError('could not read historical bars: ${raw!['error']}');
      }
      final list = ((raw?['bars'] as List?) ?? const []).cast<List<dynamic>>();
      if (list.isEmpty) throw StateError('no historical bars available for $tvSymbol');
      return list;
    }

    // 2026-10-18, per a real confirmed bug - the Heikin Ashi style switch
    // just above (`ensureChartStyle`) only confirms the chart's STYLE
    // FLAG changed, not that the HA-derived OHLC values across the whole
    // loaded history have finished recomputing from the underlying
    // regular candles - that recalculation isn't instant for a multi-week
    // history. Confirmed live: two back-to-back backtests for the exact
    // same symbol/period/historical bar returned two DIFFERENT close
    // prices for it (69.39 vs 71.56, ~3% apart) - impossible for fixed
    // historical data, same class of bug as the already-fixed signal
    // settle race, just hitting the price series instead of the
    // indicator's own plot data. Same fix: re-read until two consecutive
    // reads agree on the FULL bar list before trusting it.
    var barsList = await readBarsOnce();
    var barsStable = false;
    for (var attempt = 0; attempt < 6; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final recheck = await readBarsOnce();
      final agree = barsList.length == recheck.length &&
          barsList.last[0] == recheck.last[0] &&
          barsList.last[4] == recheck.last[4] &&
          barsList.first[0] == recheck.first[0] &&
          barsList.first[4] == recheck.first[4];
      barsList = recheck;
      if (agree) {
        barsStable = true;
        break;
      }
      logger.log(
        'BACKTEST $tvSymbol: bar data still settling after the Heikin Ashi '
        'switch (attempt ${attempt + 1}/6) - retrying.',
      );
    }
    if (!barsStable) {
      throw StateError(
        '$tvSymbol bar data never stabilized after the Heikin Ashi switch - '
        'refusing to run a backtest on possibly-stale price data',
      );
    }

    final barTimes = <int>[];
    final barClose = <double>[];
    for (final b in barsList) {
      barTimes.add((b[0] as num).toInt());
      barClose.add((b[4] as num).toDouble());
    }

    // 2026-10-17, per the user - self-healing against stale indicator
    // data: [setChartView] above already confirms the CHART reports the
    // new symbol, but the worm10/spy9 custom scripts' own computed plot
    // data can lag behind that for a few seconds while they recalculate
    // for the newly-switched symbol. Confirmed live: running a backtest
    // for XRPUSDT immediately after one for LTCUSDT produced IDENTICAL
    // event timestamps AND entry prices in LTC's ~$60-70 range (XRP
    // trades under $5) - the chart had switched, but [readWorm10Signals]
    // still read the previous symbol's stale computed signals. Re-read
    // with a short settle delay until two consecutive reads agree on the
    // latest signal before trusting the data; fail loudly instead of
    // silently handing back a wrong result if it never settles.
    Future<Worm10Check> readSignalsOnce() => readWorm10Signals(
      cdp,
      tvSymbol,
      worm10Script.scriptIdPart,
      customScripts[1].scriptIdPart,
      onDebugError: (msg) => logger.log('BACKTEST $tvSymbol signal: $msg'),
    );
    bool sameLatestSignal(Worm10Check a, Worm10Check b) {
      final aLast = a.zigzag.signals.isEmpty ? null : a.zigzag.signals.last;
      final bLast = b.zigzag.signals.isEmpty ? null : b.zigzag.signals.last;
      return aLast?.time == bLast?.time && aLast?.tag == bLast?.tag;
    }

    var check = await readSignalsOnce();
    const maxStabilizeAttempts = 6;
    var stable = false;
    for (var attempt = 0; attempt < maxStabilizeAttempts; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final recheck = await readSignalsOnce();
      final agree = sameLatestSignal(check, recheck);
      check = recheck;
      if (agree) {
        stable = true;
        break;
      }
      logger.log(
        'BACKTEST $tvSymbol: signal data still settling after the symbol '
        'switch (attempt ${attempt + 1}/$maxStabilizeAttempts) - retrying.',
      );
    }
    if (!stable) {
      throw StateError(
        '$tvSymbol signal data never stabilized after switching charts - '
        'refusing to run a backtest on possibly-stale data from another symbol',
      );
    }

    // 2026-10-17, per the user - a trade already running when the
    // requested window starts (opened by a qualifying signal BEFORE
    // `cutoff`) must still show its real, pre-window open time once it
    // closes inside the window (confirmed live: LTCUSDT trade 1's true
    // open was 10-06 03:00, two days before a 10-day window's cutoff,
    // closing 10-08 17:00 - filtering events by cutoff before simulating
    // discarded that open entirely). So simulate over the FULL available
    // history unfiltered, and only filter the resulting rows afterward by
    // whether they're relevant to the requested window.
    final events = deriveWorm10Events(check);

    final symInfo = await mt5.getMarketWatchSymbol(mt5Symbol);
    final symbols = (symInfo['symbols'] as List?) ?? const [];
    if (symbols.isEmpty) throw StateError('$mt5Symbol not found in MT5 Market Watch');
    final symbolInfo = symbols.first as Map<String, dynamic>;
    final contractSize = (symbolInfo['contract_size'] as num?)?.toDouble() ?? 1.0;
    // 2026-10-18, per the user: "calculation should be same as mt5
    // calculations 100000%" - the user's own typed volume is normalized
    // to what MT5 would ACTUALLY let them trade (the real volume_step
    // this symbol enforces, floored at its real volume_min), the exact
    // same clamp [_openPosition] applies for a live trade, rather than
    // simulating P&L at a lot size the broker would silently round or
    // reject.
    final volumeMin = (symbolInfo['volume_min'] as num?)?.toDouble() ?? 0.01;
    final volumeStep = (symbolInfo['volume_step'] as num?)?.toDouble() ?? volumeMin;
    var normalizedVolume = (volume / volumeStep).floorToDouble() * volumeStep;
    if (normalizedVolume < volumeMin) normalizedVolume = volumeMin;

    double priceAtOrAfter(int time) {
      for (var i = 0; i < barTimes.length; i++) {
        if (barTimes[i] >= time) return barClose[i];
      }
      return barClose.last;
    }

    // 2026-10-17 REDESIGN, per the user: "i want open signals and close
    // signals and update signals ... i dont want any sll" - the original
    // spec never asked for a simulated stop-loss/take-profit at all
    // ("Close A(HH/LL or Buy/Sell of zigzag)... Close b always confirmed")
    // - SL/TP price-level exit detection was an unrequested addition on
    // top of that, and became the source of the "this doesn't match what
    // I see on the chart" confusion all along. A trade now closes
    // EXCLUSIVELY on the next opposing/closing worm10 signal, matching
    // the chart's own signal-to-signal logic directly - nothing else.
    final rows = <BacktestRow>[];
    TradeDirection? current;
    int? openAt;
    String? openTag;
    double? entryPrice;
    String? updateTag;
    int? updateAt;

    void openTrade(Worm10Event event, TradeDirection direction) {
      current = direction;
      openAt = event.time;
      openTag = worm10EventKindDisplayLabel(event.kind);
      entryPrice = priceAtOrAfter(event.time);
      updateTag = null;
      updateAt = null;
    }

    // 2026-10-18, per the user - the backtest's simulated P&L must match
    // what MT5 actually nets, not just raw price movement: confirmed live
    // against this broker's (Equiti) own real trade history
    // (get_trading_history_positions) that its reported `profit` field is
    // GROSS price-movement only - the real commission charge comes back
    // as a SEPARATE `commission` field (consistently -$0.1 per round-trip
    // position across real app-placed trades sampled), never folded into
    // `profit` itself. Charged once per position opened, regardless of
    // how it closes (including still-running, since the broker charges it
    // at open).
    const commissionPerTrade = 0.1;

    void closeTrade({
      required int atTime,
      required double exitPrice,
      required String closeTagLabel,
      bool stillRunning = false,
    }) {
      final dir = current!;
      final pnl =
          (dir == TradeDirection.long ? (exitPrice - entryPrice!) : (entryPrice! - exitPrice)) *
              contractSize *
              normalizedVolume -
          commissionPerTrade;
      rows.add(
        BacktestRow(
          direction: dir == TradeDirection.long ? 'buy' : 'sell',
          openTag: openTag!,
          openAt: openAt!,
          updateTag: updateTag,
          updateAt: updateAt,
          closeTag: closeTagLabel,
          closeAt: atTime,
          entryPrice: entryPrice!,
          exitPrice: exitPrice,
          exitReason: stillRunning ? 'still_running' : 'signal_close',
          profitUsd: pnl,
          profitPercent: investment > 0 ? pnl / investment * 100 : 0,
          stillRunning: stillRunning,
          volume: normalizedVolume,
        ),
      );
      current = null;
      openAt = null;
      openTag = null;
      entryPrice = null;
      updateTag = null;
      updateAt = null;
    }

    for (final event in events) {
      final decision = worm10DecisionFor(current, event.kind);
      // 2026-10-17, per the user: "i want a table with full LL/HH buy
      // sell ... close" - full raw-event trace, one line per resolved
      // signal, so the exact chain feeding each trade can be checked
      // against the chart directly instead of only seeing the collapsed
      // open/update/close per trade.
      final resultDirLabel = decision.resultDirection == null
          ? ''
          : ' ${decision.resultDirection == TradeDirection.long ? "LONG" : "SHORT"}';
      logger.log(
        'BACKTEST $tvSymbol: event ${worm10EventKindToWire(event.kind)}'
        '(${worm10EventKindDisplayLabel(event.kind)})@${event.time} '
        '[running=${current == null ? "flat" : (current == TradeDirection.long ? "LONG" : "SHORT")}] '
        '-> ${decision.action.name}$resultDirLabel',
      );
      switch (decision.action) {
        case Worm10Action.none:
          break;
        case Worm10Action.update:
          updateTag = worm10EventKindDisplayLabel(event.kind);
          updateAt = event.time;
        case Worm10Action.openFresh:
          openTrade(event, decision.resultDirection!);
        case Worm10Action.recycle:
        case Worm10Action.flip:
          if (current != null) {
            closeTrade(
              atTime: event.time,
              exitPrice: priceAtOrAfter(event.time),
              closeTagLabel: worm10EventKindDisplayLabel(event.kind),
            );
          }
          openTrade(event, decision.resultDirection!);
      }
    }

    if (current != null) {
      closeTrade(
        atTime: barTimes.last,
        exitPrice: barClose.last,
        closeTagLabel: '—',
        stillRunning: true,
      );
    }

    // Report only rows relevant to the requested window - a trade that
    // closed before `cutoff` has nothing to do with this window at all,
    // even though simulating from full history was necessary to get its
    // own open/close times (and any later trade's open) right.
    final reportRows = rows.where((r) => r.closeAt >= cutoff).toList();

    final totalUsd = reportRows.fold(0.0, (sum, r) => sum + r.profitUsd);
    final wins = reportRows.where((r) => !r.stillRunning && r.profitUsd > 0).length;
    final losses = reportRows.where((r) => !r.stillRunning && r.profitUsd <= 0).length;

    // 2026-10-18, per the user: "entry price will be the price at first
    // trade. close price will be the price according to last trade (not
    // now trade)... so last trade is the trade where there is open and
    // close" - [reportRows] is already in chronological order (trades
    // are appended as they close, in event order), so the first row's
    // own entry is the window's overall entry; the last GENUINELY CLOSED
    // row's exit (explicitly skipping the one still-open "now" trade,
    // which has no real close yet) is the window's overall close.
    final firstEntryPrice = reportRows.isEmpty ? null : reportRows.first.entryPrice;
    double? lastClosePrice;
    for (var i = reportRows.length - 1; i >= 0; i--) {
      if (!reportRows[i].stillRunning) {
        lastClosePrice = reportRows[i].exitPrice;
        break;
      }
    }

    return BacktestResult(
      tvSymbol: tvSymbol,
      investment: investment,
      days: days,
      rows: reportRows,
      totalProfitUsd: totalUsd,
      totalProfitPercent: investment > 0 ? totalUsd / investment * 100 : 0,
      winCount: wins,
      lossCount: losses,
      firstEntryPrice: firstEntryPrice,
      lastClosePrice: lastClosePrice,
    );
  }

  void stop() => _stopRequested = true;
}
