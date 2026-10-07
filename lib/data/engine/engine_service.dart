import 'dart:async';
import 'dart:io';

import '../../core/core_storage.dart';
import '../../utilities/auto_cycle.dart';
import '../identity/auto_managed_store.dart';
import '../identity/bot_category_store.dart';
import '../identity/entry_signal_store.dart';
import '../identity/first_open_store.dart';
import '../identity/last_checked_store.dart';
import '../identity/last_tag_store.dart';
import '../identity/new_pair_wait_store.dart';
import '../identity/open_position_store.dart';
import '../identity/pending_signal_store.dart';
import '../identity/retired_store.dart';
import '../identity/supertrend_pending_store.dart';
import '../identity/terminate_request_store.dart';
import '../identity/trade_volume_store.dart';
import '../identity/waiting_reason_store.dart';
import '../identity/widen_applied_store.dart';
import '../logging/app_logger.dart';
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
    waitingReasons = WaitingReasonStore(storage);
    lastCheckedStore = LastCheckedStore(storage);
    pendingSignals = PendingSignalStore(storage);
    tradeVolumes = TradeVolumeStore(storage);
    widenApplied = WidenAppliedStore(storage);
    firstOpen = FirstOpenStore(storage);
    newPairWait = NewPairWaitStore(storage);
    supertrendPending = SupertrendPendingStore(storage);
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
  late final WaitingReasonStore waitingReasons;
  late final LastCheckedStore lastCheckedStore;
  late final PendingSignalStore pendingSignals;
  late final TradeVolumeStore tradeVolumes;
  late final FirstOpenStore firstOpen;
  late final NewPairWaitStore newPairWait;
  late final SupertrendPendingStore supertrendPending;

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
          logger.log(
            'GUI: reopened — resuming, and clearing the retroactive audit '
            'cache to re-check every running ticket against the full '
            'signal history.',
          );
          _auditedTickets.clear();
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
        logger.log(
          'Hourly pre-candle audit: clearing the retroactive audit cache '
          'to re-check every running ticket before the next 1H candle.',
        );
        _auditedTickets.clear();
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

    final tracked = openPositions.listAppPositions();
    if (tracked.isEmpty) return;

    final openResult = await mt5.getOpenPositions();
    final livePositions = (openResult['positions'] as List?) ?? const [];
    final stillOpen = livePositions
        .map((p) => _parseTicket((p as Map<String, dynamic>)['position_id']))
        .whereType<int>()
        .toSet();

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
      // Within 0.1% counts as "hit that level" — MT5 fills at/through the
      // exact SL/TP price, not necessarily to the last decimal.
      bool near(double? a, double? b) =>
          a != null && b != null && b != 0 && (a - b).abs() / b.abs() < 0.001;
      final String stopReason;
      final String detail;
      if (near(closePrice, stopLoss)) {
        stopReason = 'stop_loss';
        detail = 'Closed by MT5 hitting its own stop-loss price.';
      } else if (near(closePrice, takeProfit)) {
        stopReason = 'take_profit';
        detail = 'Closed by MT5 hitting its own take-profit price.';
      } else {
        stopReason = 'closed_by_user';
        detail = 'Closed directly in MT5, not by this app and not at SL/TP.';
      }

      final openSnapshot = entrySignals.takeFor(ticket);
      final direction =
          (record['type'] as String?) == 'sell' ? TradeDirection.short : TradeDirection.long;
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
          entryPrice: (record['open_price'] as num?)?.toDouble() ?? 0.0,
          exitPrice: closePrice,
          volume: (record['volume'] as num?)?.toDouble(),
          stopLoss: stopLoss,
          takeProfit: takeProfit,
          realizedProfit: (record['profit'] as num?)?.toDouble(),
          startTime: DateTime.tryParse(record['open_time'] as String? ?? '') ?? DateTime.now(),
          endTime: DateTime.tryParse(record['close_time'] as String? ?? ''),
          openSignalType: openSnapshot?.tag,
          openSignalAt: openSnapshot?.barTime,
          updateSignalType: openSnapshot?.updateTag,
          updateSignalAt: openSnapshot?.updateTime,
          stopReason: stopReason,
          detail: detail,
        ).toJson(),
      );
      logger.log('$mt5Symbol ($category): reconciled ticket=$ticket as $stopReason.');
      openPositions.forgetPosition(ticket);
      botCategories.forget(ticket);
      widenApplied.forget(ticket);
      risk.closePosition(mt5Symbol, category);
      _finalizeLastTagOnClose(category, tvSymbol);
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

    // 2026-10-06, per the user's second decision technique - read once per
    // sweep (all pairs use whichever technique is active right now; it
    // can't change mid-sweep since only the GUI writes this file).
    final technique = _activeTechnique();

    await _reverseCheckOnTechniqueSwitchIfNeeded(technique);

    for (final category in allAutoCategories) {
      if (storage.fileExists(storage.autoCategoryPausedFileFor(category))) {
        continue;
      }
      final store = autoManagedByCategory[category]!;
      for (final tvSymbol in store.loadAutoManagedBases()) {
        if (retired.isRetiredBase(tvSymbol)) continue;
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
      final binaryPath = _tradingViewLaunchConfig(home).binaryPath;
      if (Platform.isWindows) {
        final imageName = binaryPath.split(RegExp(r'[\\/]')).last;
        await Process.run('taskkill', ['/F', '/IM', imageName]);
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
  /// [LaunchConfig.defaultForWindows]'s own doc comment (UNTESTED against a
  /// real Windows machine).
  LaunchConfig _tradingViewLaunchConfig(String home) {
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
  /// in place - branches between the two techniques' own, separately-tuned
  /// enforcement functions (see [enforceSupertrendPlus]'s own doc comment
  /// for why this isn't a single generic function).
  Future<bool> _indicatorsReadyFor(DecisionTechnique technique, CdpClient client) async {
    if (technique.id == DecisionTechnique.supertrendPlus.id) {
      final styleOk = await ensureChartStyle(client, ChartStyle.heikinAshi);
      return styleOk && await isSupertrendPresent(client);
    }
    // Revert to regular candles (2026-10-06, per the user: "make sure once
    // user switch from supertrend to worm/spy, app need to load regular
    // candles not heiken ashi") - without this, switching back to Signal
    // Flip after a stint on Supertrend Plus left the chart stuck on Heikin
    // Ashi forever, since nothing ever set it back. Cheap no-op once
    // already on regular candles (see [ensureChartStyle]).
    final styleOk = await ensureChartStyle(client, ChartStyle.candles);
    return styleOk && await areIndicatorsPresent(client);
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
      final tvLaunchConfig = _tradingViewLaunchConfig(home);
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
      final isSupertrend = technique.id == DecisionTechnique.supertrendPlus.id;
      final enforceResult = isSupertrend
          ? await enforceSupertrendPlus(host, port)
          : await enforceCustomScripts(host, port);
      // Both techniques need exactly two scripts open now - Supertrend
      // Plus needs itself AND worm_9_26 (for its zigzag range data, see
      // enforceSupertrendPlus's own doc comment), Signal Flip needs
      // worm_9_26 AND spy_9_26. Same shape either way.
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
      if (isSupertrend) await ensureChartStyle(client, ChartStyle.heikinAshi);
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
        await _processAllPendingTerminateRequests();
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

    final range = await _readConfirmedRange(cdp, category, tvSymbol, immediate: immediate);
    if (range == null) return;

    await setChartView(cdp, tvSymbol, category.signalResolution);
    var check = await readSwingOscillatorSignals(
      cdp,
      tvSymbol,
      customScripts[0].scriptIdPart,
      onDebugError: (msg) => logger.log('$tvSymbol ($category) signal: $msg'),
    );
    // Same extra-retry treatment as the range read above, same reasoning.
    for (var i = 0; i < 2 && (check.latest == null || check.latestBarTime == null) && immediate; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      check = await readSwingOscillatorSignals(
        cdp,
        tvSymbol,
        customScripts[0].scriptIdPart,
        onDebugError: (msg) => logger.log('$tvSymbol ($category) signal retry: $msg'),
      );
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
            final needsWrite = openSnapshot == null ||
                openSnapshot.tag != trueStartWire ||
                openSnapshot.barTime != trueStart.time;
            if (needsWrite) {
              entrySignals.record(
                auditTicket,
                EntrySignalSnapshot(tag: trueStartWire, barTime: trueStart.time),
              );
              logger.log(
                '$mt5Symbol ($category): ${openSnapshot == null ? "backfilled" : "corrected"} '
                'Start signal for ticket=$auditTicket - $trueStartWire@${trueStart.time}.',
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
            final recheck = await readSwingOscillatorSignals(
              cdp,
              tvSymbol,
              customScripts[0].scriptIdPart,
              onDebugError: (msg) => logger.log('$tvSymbol ($category) audit recheck: $msg'),
            );
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
                final flipGate = risk.gate('open', mt5Symbol, category);
                if (flipGate.allowed) {
                  await _openPosition(category, mapping, trueDirection, range.top, range.bottom, trueStart);
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
      final recheck = await readSwingOscillatorSignals(
        cdp,
        tvSymbol,
        customScripts[0].scriptIdPart,
        onDebugError: (msg) => logger.log('$tvSymbol ($category) signal recheck: $msg'),
      );
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
      final flipGate = risk.gate('open', mt5Symbol, category);
      if (!flipGate.allowed) {
        logger.log('$tvSymbol ($category): risk gate blocked open: ${flipGate.reason}');
        return;
      }
      if (await _openPosition(category, mapping, newDirection, range.top, range.bottom, latest)) {
        pendingSignals.clear(barKey);
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

    final gate = risk.gate('open', mt5Symbol, category);
    if (!gate.allowed) {
      logger.log('$tvSymbol ($category): risk gate blocked open: ${gate.reason}');
      return;
    }

    if (await _openPosition(category, mapping, newDirection, range.top, range.bottom, latest)) {
      pendingSignals.clear(barKey);
      firstOpen.markOpened(seasonKey);
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

    // Own survive-one-candle gate, using the SEPARATE [supertrendPending]
    // store (2026-10-06, per the user: "you have to make same signal check
    // as close a close b .. so you are sure about signal flipping") - never
    // [pendingSignals], so the Dashboard's "Close A"/"Update" columns stay
    // blank for Supertrend-driven pairs with zero changes to that GUI code
    // (see [CoreStorage.supertrendPendingFile]'s own doc comment). Bypassed
    // entirely when [immediate].
    final pending = supertrendPending.get(barKey);
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

    // TP/SL range - "keep using old method" (2026-10-06, per the user): the
    // SAME 60/40 zigzag model, reading worm_9_26's own range data (kept
    // attached alongside Supertrend Plus purely for this - see
    // [enforceSupertrendPlus]'s own doc comment). Identical triple-read
    // confirmation to [_checkOneSymbol]'s own range read - literally the
    // same shared [_readConfirmedRange] helper.
    final range = await _readConfirmedRange(cdp, category, tvSymbol, immediate: immediate);
    if (range == null) return;

    // Supertrend Plus's own Buy/Sell entry signal.
    await setChartView(cdp, tvSymbol, category.signalResolution);
    final check = await readSupertrendSignals(
      cdp,
      tvSymbol,
      supertrendPlusScript.scriptIdPart,
      onDebugError: (msg) => logger.log('$tvSymbol ($category) supertrend signal: $msg'),
    );
    var latest = check.latest;
    // Same extra-retry treatment as the range read above, same reasoning.
    for (var i = 0; i < 2 && latest == null && immediate; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      final retryCheck = await readSupertrendSignals(
        cdp,
        tvSymbol,
        supertrendPlusScript.scriptIdPart,
        onDebugError: (msg) => logger.log('$tvSymbol ($category) supertrend signal retry: $msg'),
      );
      latest = retryCheck.latest;
    }
    if (latest == null) {
      logger.log('$tvSymbol ($category): no supertrend signal yet, skipping cycle.');
      return;
    }

    // TRIPLE-read confirmation, same "1 million sure" rule as
    // [_checkOneSymbol]'s own signal read.
    for (var i = 0; i < 2; i++) {
      await Future<void>.delayed(const Duration(seconds: 10));
      final recheck = await readSupertrendSignals(
        cdp,
        tvSymbol,
        supertrendPlusScript.scriptIdPart,
        onDebugError: (msg) => logger.log('$tvSymbol ($category) supertrend recheck: $msg'),
      );
      final recheckLatest = recheck.latest;
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
    // Bypassed entirely when [immediate].
    final latestWire = signalTagToWire(latest.tag);
    if (!immediate && (pending == null || pending.tag != latestWire || pending.barTime != latest.time)) {
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
      final flipGate = risk.gate('open', mt5Symbol, category);
      if (!flipGate.allowed) {
        logger.log('$tvSymbol ($category): risk gate blocked open: ${flipGate.reason}');
        return;
      }
      if (await _openPosition(category, mapping, newDirection, range.top, range.bottom, latest)) {
        supertrendPending.clear(barKey);
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

    final gate = risk.gate('open', mt5Symbol, category);
    if (!gate.allowed) {
      logger.log('$tvSymbol ($category): risk gate blocked open: ${gate.reason}');
      return;
    }

    if (await _openPosition(category, mapping, newDirection, range.top, range.bottom, latest)) {
      supertrendPending.clear(barKey);
    }
  }

  /// Snapshots the confirmed signal that triggered an open, keyed by the
  /// real position ticket, for [BotHistoryEntry]'s open_signal_* fields
  /// once this position eventually closes.
  void _recordOpenSignal(int ticket, Signal signal) {
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
  }) async {
    await setChartView(cdp, tvSymbol, category.rangeResolution);
    final lines = await readLines(cdp, customScripts[0].scriptIdPart);
    var range = detectZigzagRange(lines, swingCount: config.technique.rangeSwingCount);
    // Extra retries when [immediate] - see the Power-on sweep's own doc
    // comment on [_reverseCheckOnTechniqueSwitchIfNeeded] for why: a
    // one-shot-per-pair skip here would otherwise silently fall this pair
    // back to the slow, normal cadence instead of getting the immediate
    // treatment every other pair in the sweep got.
    for (var i = 0; i < 2 && range == null && immediate; i++) {
      await Future<void>.delayed(const Duration(seconds: 5));
      final retryLines = await readLines(cdp, customScripts[0].scriptIdPart);
      range = detectZigzagRange(retryLines, swingCount: config.technique.rangeSwingCount);
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
      final linesRecheck = await readLines(cdp, customScripts[0].scriptIdPart);
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
        // A real, app-owned position exists for this symbol/category no
        // matter how we got here - always seasoned from this point on,
        // see [FirstOpenStore]'s own doc comment for why this matters.
        firstOpen.markOpened('${category.wireValue}|$tvSymbol');
        return map;
      }
    }
    return null;
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
    Signal openSignal,
  ) async {
    final mt5Symbol = mapping.mt5Symbol;
    final target = await _computeTargetLevels(mt5Symbol, direction, rangeTop, rangeBottom);
    if (target == null) return false;
    final info = target.info;
    final entry = target.entry;
    final bid = target.bid;
    final ask = target.ask;
    final digits = target.digits;
    final sl = target.sl;
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
    final desiredVolume = tradeVolumes.desired(volKey) ?? volumeMin;
    final floorVolume = tradeVolumes.lastApplied(volKey) ?? volumeMin;
    var tryVolume = tradeVolumes.attempt(volKey) ?? desiredVolume;
    if (tryVolume > desiredVolume) tryVolume = desiredVolume;
    if (tryVolume < floorVolume) tryVolume = floorVolume;
    final point = (info['point'] as num?)?.toDouble() ?? 0.0;
    final stopsLevelPoints = (info['trade_stops_level'] as num?)?.toInt() ?? 0;

    logger.log(
      '$mt5Symbol ($category): opening ${direction == TradeDirection.long ? 'BUY' : 'SELL'} '
      'vol=$tryVolume entry=$entry sl=$sl tp=$tp '
      '(range ${rangeBottom.toStringAsFixed(digits)}-${rangeTop.toStringAsFixed(digits)}'
      '${target.widenApplied ? ", widened" : ""})',
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
        // from current price - plus a couple of extra points of safety
        // margin, so the stop order sits just past current price and
        // triggers on essentially the very next tick, matching a real
        // market order in practice.
        final minDistance = point > 0 ? (stopsLevelPoints + 2) * point : entry * 0.0005;
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
      _recordOpenSignal(ticket, openSignal);
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
        _recordOpenSignal(positionTicket, openSignal);
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
  }) async {
    final ticket = _parseTicket(position['position_id'])!;
    logger.log('$mt5Symbol ($category): closing ticket=$ticket ($stopReason).');
    await mt5.closePosition(symbol: mt5Symbol, positionTicket: ticket);
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
    );
    openPositions.forgetPosition(ticket);
    botCategories.forget(ticket);
    widenApplied.forget(ticket);
    risk.closePosition(mt5Symbol, category);
    _finalizeLastTagOnClose(category, tvSymbol);
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
  /// ('opposite_signal' here; 'take_profit'/'stop_loss'/'closed_by_user'
  /// from reconciliation). Reads back [entrySignals]' snapshot taken at
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
  }) {
    final openSnapshot = entrySignals.takeFor(ticket);
    final direction = (position['action'] as String?) == 'sell'
        ? TradeDirection.short
        : TradeDirection.long;
    final entryPrice = (position['price_open'] as num?)?.toDouble() ?? 0.0;
    final exitPrice = (position['price_last'] as num?)?.toDouble();
    final volume = (position['volume'] as num?)?.toDouble();
    final stopLoss = (position['sl'] as num?)?.toDouble();
    final takeProfit = (position['tp'] as num?)?.toDouble();
    final profit = (position['profit'] as num?)?.toDouble();
    final startTime = DateTime.tryParse(
      (position['create_time'] as String?) ?? '',
    ) ?? DateTime.now();
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
        openSignalType: openSnapshot?.tag,
        openSignalAt: openSnapshot?.barTime,
        updateSignalType: openSnapshot?.updateTag,
        updateSignalAt: openSnapshot?.updateTime,
        closeSignalType: closeSignal != null ? signalTagToWire(closeSignal.tag) : null,
        closeSignalAt: closeSignal?.time,
        stopReason: stopReason,
        detail: detail,
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
      ).toJson(),
    );
  }

  void stop() => _stopRequested = true;
}
