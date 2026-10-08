import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/core_storage.dart';
import '../identity/auto_managed_store.dart';
import '../identity/last_tag_store.dart';
import '../identity/pending_signal_store.dart';
import '../identity/retired_store.dart';
import '../identity/supertrend_pending_store.dart';
import '../identity/terminate_request_store.dart';
import '../identity/trade_volume_store.dart';
import '../logging/app_logger.dart';
import '../models/app_config.dart';
import '../models/auto_category.dart';
import '../models/engine_status.dart';

/// GUI-facing control surface — never talks to MT5 directly, only reads the
/// status file the engine writes and toggles the PAUSE/STOP/CHECKNOW/
/// AUTO_PAUSED* control files, exactly like tradingPionex's
/// EngineControlRepository.
///
/// The Dashboard table's per-row Auto/Last toggles and power icon
/// (2026-09-29 spec) go through the SAME identity-store classes the engine
/// itself uses ([AutoManagedStore]/[LastTagStore]/[TerminateRequestStore])
/// rather than duplicating JSON read/write here — both processes already
/// share [CoreStorage]'s file paths, so a plain file write from the GUI is
/// picked up by the engine on its next cycle/poll exactly like any other
/// control file (PAUSE, CHECKNOW, ...).
class EngineControlRepository {
  EngineControlRepository(this._storage)
    : _autoManaged = AutoManagedStore(_storage),
      _lastTag = LastTagStore(_storage),
      _terminateRequests = TerminateRequestStore(_storage),
      _tradeVolumes = TradeVolumeStore(_storage),
      _retired = RetiredStore(_storage),
      _pendingSignals = PendingSignalStore(_storage),
      _supertrendPending = SupertrendPendingStore(_storage),
      _logger = AppLogger(_storage);

  final CoreStorage _storage;
  final AutoManagedStore _autoManaged;
  final LastTagStore _lastTag;
  final TerminateRequestStore _terminateRequests;
  final TradeVolumeStore _tradeVolumes;
  final RetiredStore _retired;
  final PendingSignalStore _pendingSignals;
  final SupertrendPendingStore _supertrendPending;

  /// 2026-10-03, per the user: "if log did not tell you what i did in app
  /// then update/upgrade log to include everything happening auto or by
  /// user or by pc/laptop" - found live that NONE of the Dashboard's
  /// controls ever wrote anything to engine.log, since every method here
  /// was a pure file write with no audit trail; diagnosing a user-reported
  /// "I toggled X" had nothing to go on. [AppLogger] already writes to the
  /// exact same engine.log the engine itself uses (plain append-mode file
  /// writes are safe across the two separate GUI/engine processes - each
  /// log line is well under the OS's atomic-write size), so reusing it here
  /// unifies every action - automatic (engine) and manual (user, via this
  /// class) - into one single timeline instead of two disconnected ones.
  /// Every line is prefixed "[USER]" so it's visually distinct from the
  /// engine's own automatic actions at a glance.
  final AppLogger _logger;

  void _logUserAction(String message) => _logger.log('[USER] $message');

  /// Dashboard Auto toggle — on adds [tvSymbol] back to the auto-managed
  /// list (the engine resumes checking/opening/closing it); off removes it
  /// (the engine skips it entirely, but any currently-open position stays
  /// open until the user closes it manually or via the power icon).
  ///
  /// Turning ON also un-retires [tvSymbol] (2026-10-03, per the user: a
  /// pair picked via "Start Auto Trade" never got checked at all - found
  /// live that ETHUSDT/OPUSDT, re-added this way, sat in
  /// auto-managed-bases.json forever untouched because they were STILL in
  /// retired-pairs.json from a previous Last-tagged close weeks earlier.
  /// [EngineService._runCycle]'s main loop unconditionally skips any
  /// retired base regardless of auto-managed status - re-enabling Auto for
  /// a pair is exactly the explicit "unretire" [RetiredStore]'s own doc
  /// comment describes, so this is the one place that decision belongs).
  void setAutoManaged(String tvSymbol, bool on) {
    if (on) {
      _autoManaged.addBase(tvSymbol);
      final wasRetired = _retired.isRetiredBase(tvSymbol);
      _retired.removeRetiredBases([tvSymbol]);
      // Drop any leftover pending-signal candidate from a PREVIOUS stint
      // under auto-management, for every category (2026-10-08, per the
      // user: "why once user add pair to auto (while technique is
      // supertrend) there is HH/LL in table >>> check adausd, shibusd" -
      // found live: a pair being un-retired/re-added kept showing its old
      // Signal Flip HH/LL candidate in the Dashboard's Close A column
      // until the engine's OWN next cycle happened to check it (itself
      // already fixed to clear the OTHER technique's leftover entry, but
      // only reactively, on that pair's own next check - which could be
      // minutes away depending on how many other pairs are ahead of it).
      // Clearing immediately here, the instant the pair is re-added,
      // means the table is correct right away instead of after an
      // unpredictable wait.
      for (final category in allAutoCategories) {
        final barKey = '${category.wireValue}|$tvSymbol';
        _pendingSignals.clear(barKey);
        _supertrendPending.clear(barKey);
      }
      _logUserAction(
        'Auto turned ON for $tvSymbol (Dashboard)'
        '${wasRetired ? ' - also un-retired (was stuck retired)' : ''}.',
      );
    } else {
      _autoManaged.removeBase(tvSymbol);
      _logUserAction('Auto turned OFF for $tvSymbol (Dashboard).');
    }
  }

  /// Dashboard Last toggle — on means the CURRENT trade is the last one for
  /// this pair; off just clears that pending flag (never un-retires a pair
  /// that already retired from a previous Last-tagged close).
  void setLastTagged(String tvSymbol, bool on) {
    _lastTag.setLastTagged(tvSymbol, on);
    _logUserAction('Last ${on ? 'ON' : 'OFF'} for $tvSymbol (Dashboard).');
  }

  /// Dashboard power icon — asks the engine to terminate [tvSymbol]'s
  /// current position (if any) on its next cycle. Fire-and-forget: the
  /// engine clears the request once handled.
  void requestTerminate(String tvSymbol) {
    _terminateRequests.request(tvSymbol);
    _logUserAction('Terminate pressed for $tvSymbol (Dashboard power icon).');
  }

  /// Dashboard volume +/- (2026-10-03, per the user) — sets the target
  /// volume for [tvSymbol]'s NEXT open (fresh or recycled). Never touches a
  /// currently-running trade's own size. Only the 1H category's table row
  /// exists in the GUI today, same scope as every other per-row control
  /// here (toggleAuto/toggleLast/requestTerminate).
  void setDesiredVolume(String tvSymbol, double volume) {
    _tradeVolumes.setDesired('${AutoCategory.oneHour.wireValue}|$tvSymbol', volume);
    _logUserAction('Volume for $tvSymbol\'s next open set to $volume (Dashboard).');
  }

  /// Called when [tvSymbol] is freshly re-added via "Start Auto Trade"
  /// after having been retired (2026-10-06, per the user: "if pair volume
  /// was more than minimum... and this pair moved out of auto list
  /// (toggled last)... then once user rechoose this pair... and click on
  /// 'start auto trade', then this pair should start with minimum volume
  /// value" / "volume is reset for new auto pairs"). Wipes any leftover
  /// desired/attempt/last-applied state from its PREVIOUS life as an auto
  /// pair, so it starts clean at the broker minimum exactly like a pair
  /// that had never been traded before.
  void resetDesiredVolume(String tvSymbol) {
    _tradeVolumes.clear('${AutoCategory.oneHour.wireValue}|$tvSymbol');
  }

  /// Unified pair-picker "Start Auto Trade" (2026-10-03, per the user) —
  /// appends [mapping] to config.json's `symbols` array if no mapping for
  /// this tvSymbol exists yet (a newly-picked crypto/forex pair the engine
  /// has never seen before). No-op if it's already there. The engine
  /// already hot-reloads this file every cycle ([EngineService._loadSymbolsFresh])
  /// so no restart is needed for the new mapping to take effect.
  void addSymbolMapping(SymbolMapping mapping) {
    final json = Map<String, dynamic>.from(
      _storage.readJsonObject(_storage.configFile) ?? AppConfig.defaultConfig.toJson(),
    );
    final symbols = ((json['symbols'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .toList();
    final exists = symbols.any(
      (s) => (s['tradingview_symbol'] as String?)?.toUpperCase() ==
          mapping.tradingViewSymbol.toUpperCase(),
    );
    if (exists) return;
    symbols.add(mapping.toJson());
    json['symbols'] = symbols;
    _storage.writeJson(_storage.configFile, json);
    _logUserAction(
      'New symbol mapping added: ${mapping.tradingViewSymbol} -> '
      '${mapping.mt5Symbol} (Dashboard "Start Auto Trade").',
    );
  }

  /// Settings screen "Connection Configurations" (2026-10-03, per the user:
  /// "add connection configurations section ... user can edit trading view
  /// port and ip, mt5 key ... editable fields where user can modify and
  /// save") - edits config.json's `cdp` block directly, preserving every
  /// other key. NOTE: the engine only reads `config.mt5`/`config.cdp` ONCE
  /// at its own startup (unlike `config.symbols`, which hot-reloads every
  /// cycle - see [EngineService._loadSymbolsFresh]) - a changed host/port
  /// here needs an engine restart to actually take effect, which the
  /// Settings screen must say explicitly rather than implying it's instant.
  void updateCdpConfig({required String host, required int port}) {
    final json = Map<String, dynamic>.from(
      _storage.readJsonObject(_storage.configFile) ?? AppConfig.defaultConfig.toJson(),
    );
    json['cdp'] = {'host': host, 'port': port};
    _storage.writeJson(_storage.configFile, json);
    _logUserAction('TradingView connection config saved: $host:$port (Settings).');
  }

  /// Same as [updateCdpConfig] but for `config.json`'s `mt5` block
  /// (host/port only - the API key lives in `.env`, see
  /// [updateMt5ApiKey]). Same restart caveat applies.
  void updateMt5Config({required String host, required int port}) {
    final json = Map<String, dynamic>.from(
      _storage.readJsonObject(_storage.configFile) ?? AppConfig.defaultConfig.toJson(),
    );
    json['mt5'] = {'mcp_host': host, 'mcp_port': port};
    _storage.writeJson(_storage.configFile, json);
    _logUserAction('MT5 connection config saved: $host:$port (Settings).');
  }

  /// Updates `.env`'s `MT5_MCP_API_KEY` - read fresh only when the engine
  /// rebuilds its MT5 client (a failed connect, or engine restart), not on
  /// every cycle, so this also needs a restart to be guaranteed in effect.
  void updateMt5ApiKey(String apiKey) {
    _storage.updateEnvValue('MT5_MCP_API_KEY', apiKey);
    _logUserAction('MT5 API key updated (Settings).');
  }

  AppConfig get currentConfig =>
      AppConfig.fromJson(_storage.readJsonObject(_storage.configFile) ?? AppConfig.defaultConfig.toJson());

  String get currentMt5ApiKey => _storage.readEnvFile()['MT5_MCP_API_KEY'] ?? '';

  Duration get statusPollInterval => const Duration(seconds: 5);

  Future<EngineStatus> status() async {
    final json = _storage.readJsonObject(_storage.statusFile);
    if (json == null) return EngineStatus.disconnected;
    return EngineStatus.fromJson(json);
  }

  bool get engineRunning => _storage.fileExists(_storage.heartbeatFile);

  /// The systemd --user unit the engine process runs as — see
  /// ~/.config/systemd/user/tradingmt5-engine.service. Not auto-started on
  /// login any more (2026-10-05): it only ever starts via [resume] below.
  static const _engineServiceName = 'tradingmt5-engine.service';

  /// Power — now the engine PROCESS's own on/off switch (2026-10-05, per
  /// the user: "make app closing engine instantly once power toggle off...
  /// once user toggle power on, app will launch the engine and then all
  /// cycle started"). Off asks systemd to stop the service (SIGTERM, with
  /// its own short force-exit watchdog in bin/engine.dart as a backstop);
  /// on asks it to start a fresh process, which immediately runs the full
  /// internet -> MT5 -> TradingView -> indicators sequence from scratch
  /// (see [EngineService.run] - there's no more internal PAUSE-file gate
  /// for it to sit behind). [isPowerOn] stays a plain, instant file read
  /// purely so the toggle reflects the user's INTENT the moment they click
  /// it, without waiting on a shell round-trip - [engineRunning]/the
  /// status poll reflect whether that intent has actually landed yet.
  bool get isPowerOn => !_storage.fileExists(_storage.pauseFile);

  Future<void> pause() async {
    _storage.touchFile(_storage.pauseFile);
    _logUserAction('Power turned OFF (Dashboard) — stopping the engine.');
    await _setEngineServiceActive(false);
  }

  Future<void> resume() async {
    _storage.deleteFileIfExists(_storage.pauseFile);
    _logUserAction('Power turned ON (Dashboard) — starting the engine.');
    await _setEngineServiceActive(true);
  }

  Future<void> _setEngineServiceActive(bool active) async {
    if (Platform.isWindows) {
      return active ? _startEngineWindows() : _stopEngineWindows();
    }
    final action = active ? 'start' : 'stop';
    try {
      final result = await Process.run('systemctl', [
        '--user',
        action,
        _engineServiceName,
      ]);
      if (result.exitCode != 0) {
        _logger.log(
          'systemctl --user $action $_engineServiceName exited '
          '${result.exitCode}: ${result.stderr}',
          level: 'ERROR',
        );
      }
    } catch (e) {
      _logger.log('Failed to $action the engine service: $e', level: 'ERROR');
    }
  }

  /// Windows has no systemd (2026-10-07, Windows port, UNTESTED against a
  /// real Windows machine) - there's no service to ask to start/stop, so
  /// Power directly spawns/kills the engine PROCESS itself instead. The
  /// engine exe is expected to sit right next to the GUI's own exe (the
  /// installer/CI build ships both in the same folder) - [_enginePath]
  /// resolves that relative to [Platform.resolvedExecutable] rather than
  /// hardcoding an absolute install path.
  String get _enginePath {
    final dir = p.dirname(Platform.resolvedExecutable);
    return p.join(dir, 'tradingmt5_engine.exe');
  }

  Future<void> _startEngineWindows() async {
    try {
      await Process.start(_enginePath, const [], mode: ProcessStartMode.detached);
    } catch (e) {
      _logger.log('Failed to start the engine process: $e', level: 'ERROR');
    }
  }

  /// Graceful-then-forceful stop, same philosophy as bin/engine.dart's own
  /// `forceExitAfter` watchdog (sigterm isn't available on Windows at all,
  /// so there's no graceful signal to send here - this just gives the
  /// engine's OWN heartbeat-staleness/PAUSE-file self-stop a short window
  /// before falling back to a hard kill).
  Future<void> _stopEngineWindows() async {
    final pidRaw = _storage.readString(_storage.pidFile);
    final pid = int.tryParse((pidRaw ?? '').trim());
    if (pid == null) return;
    await Future<void>.delayed(const Duration(seconds: 2));
    try {
      await Process.run('taskkill', ['/F', '/PID', '$pid']);
    } catch (e) {
      _logger.log('Failed to stop the engine process (pid=$pid): $e', level: 'ERROR');
    }
  }

  void stop() {
    _storage.touchFile(_storage.stopFile);
    _logUserAction('Stop pressed (Dashboard).');
  }

  void checkNow() {
    _storage.touchFile(_storage.checknowFile);
    _logUserAction('Check-now pressed (Dashboard).');
  }

  /// Auto — independent of Power: engine keeps running/connecting, just
  /// skips the auto-category checkup loop while off.
  bool get isAutoOn => !_storage.fileExists(_storage.autoPausedFile);
  void pauseAuto() {
    _storage.touchFile(_storage.autoPausedFile);
    _logUserAction('Auto (global) turned OFF (Dashboard).');
  }

  void resumeAuto() {
    _storage.deleteFileIfExists(_storage.autoPausedFile);
    _logUserAction('Auto (global) turned ON (Dashboard).');
  }

  /// Per-category Auto — lets one category (e.g. 3m) be paused while
  /// others keep running, independent of the global Auto toggle.
  bool isCategoryOn(AutoCategory category) =>
      !_storage.fileExists(_storage.autoCategoryPausedFileFor(category));
  void pauseCategory(AutoCategory category) {
    _storage.touchFile(_storage.autoCategoryPausedFileFor(category));
    _logUserAction('Auto turned OFF for category ${category.wireValue} (Dashboard).');
  }

  void resumeCategory(AutoCategory category) {
    _storage.deleteFileIfExists(_storage.autoCategoryPausedFileFor(category));
    _logUserAction('Auto turned ON for category ${category.wireValue} (Dashboard).');
  }
}
