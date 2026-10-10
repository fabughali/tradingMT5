import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/models/auto_category.dart';

/// Local filesystem layout for the app's runtime data (config, secrets,
/// logs, control files). Shared verbatim by both entry points — the Flutter
/// GUI and `bin/engine.dart` — so they agree on where PAUSE/STOP/CHECKNOW and
/// the JSON state files live. Mirrors tradingPionex/app/lib/core/core_storage.dart's
/// pattern but starts with only the fields this app actually needs so far —
/// see tradingPionex's version for the full catalog of control-file/state
/// conventions to reach for as MT5-specific state gets added (and per that
/// app's hard-won lesson: any state written here "just for the GUI to
/// display" needs a load-on-startup path too, or a restart silently
/// corrupts it).
class CoreStorage {
  CoreStorage._(this.rootDir);

  final String rootDir;

  static CoreStorage? _instance;

  static CoreStorage get instance =>
      _instance ??= CoreStorage._(_resolveRootDir());

  static String _resolveRootDir() {
    final override = Platform.environment['TRADING_MT5_HOME'];
    if (override != null && override.trim().isNotEmpty) return override;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '.';
    return p.join(home, '.tradingmt5');
  }

  String get configFile => p.join(rootDir, 'config.json');
  String get envFile => p.join(rootDir, '.env');

  /// Default destination for Settings screen exports (2026-10-03, per the
  /// user: "create a app backup folder in the root") - lives INSIDE
  /// rootDir (literally "in the root") but [BackupService] explicitly
  /// excludes it from what gets zipped up, so a backup never ends up
  /// containing earlier backups of itself.
  String get backupsDir => p.join(rootDir, 'backups');

  String get logsDir => p.join(rootDir, 'logs');
  String get logFile => p.join(logsDir, 'engine.log');
  String get stateFile => p.join(logsDir, 'state.json');
  String get statusFile => p.join(logsDir, 'status.json');
  String get heartbeatFile => p.join(logsDir, 'heartbeat');
  String get pidFile => p.join(logsDir, 'engine.pid');

  /// Touched every few seconds by the GUI while it's running (2026-10-05,
  /// per the user: "make engine stop if gui is stopped ... trading view/mt5
  /// should not launch unless user open gui") - the engine treats this
  /// file's staleness as "the GUI isn't open" and goes fully idle (no
  /// TradingView/MT5 launch, no cycle work) until it's fresh again. Same
  /// staleness-check pattern as [heartbeatFile] itself, just written by the
  /// other process.
  String get guiHeartbeatFile => p.join(logsDir, 'gui-heartbeat');

  /// Power-off INTENT marker, toggled by the Dashboard's Power switch via
  /// [EngineControlRepository.pause]/[resume]. No longer read by the
  /// engine itself (2026-10-05) — the engine process only exists at all
  /// because Power was turned on (`systemctl --user start`), and turning
  /// it off actually stops that process rather than idling it, so this
  /// file is purely a fast, synchronous "what did the user last ask for"
  /// read for the toggle's own display, independent of the slower
  /// `systemctl`/heartbeat round-trip that reflects reality.
  String get pauseFile => p.join(rootDir, 'PAUSE');
  String get stopFile => p.join(rootDir, 'STOP');
  String get checknowFile => p.join(rootDir, 'CHECKNOW');

  /// Global Auto off — independent of Power: the engine still runs/
  /// connects/heartbeats, it just skips the auto-category checkup loop
  /// entirely (no automatic opens/closes across any category) while this
  /// is present. Ported convention from tradingPionex's AUTO_PAUSED file.
  String get autoPausedFile => p.join(rootDir, 'AUTO_PAUSED');

  /// Per-category Auto off — same idea as [autoPausedFile] but scoped to
  /// one category, so e.g. 1H can keep auto-trading while 3m is paused.
  /// Checked in addition to (not instead of) the global toggle.
  String autoCategoryPausedFileFor(AutoCategory c) =>
      p.join(rootDir, 'AUTO_PAUSED_${c.wireValue}');

  /// The MT5 position tickets the app itself opened (see
  /// data/identity/open_position_store.dart) — the equivalent of
  /// tradingPionex's createdBotsFile, but keyed by an int position ticket
  /// (from the `trade_send_market_order` MCP tool's result) instead of a
  /// String buOrderId.
  String get openPositionsFile => p.join(logsDir, 'open-positions.json');

  /// Ported from tradingPionex's CoreStorage — same reasoning as
  /// [openPositionsFile]/[autoManagedBasesFile]: survives a close so the
  /// next auto-checkup pass still picks the symbol back up. Only removed by
  /// an explicit Stop/Last.
  String get autoManagedBasesFile => p.join(logsDir, 'auto-managed-bases.json');

  /// Which [AutoCategory] each app-opened position belongs to (position
  /// ticket -> category) — MT5 has no such concept natively, this is purely
  /// the app's own record, stamped at open/convert time. Drives the
  /// "(1H)"/"(1m)"/"(1D)" tag shown after a symbol name.
  String get botCategoriesFile => p.join(logsDir, 'bot-categories.json');

  /// Bases (2026-09-29, per the user's Dashboard-table spec) flagged "Last"
  /// — the app finishes the CURRENT trade normally, but once it closes (by
  /// any path: opposite signal, SL/TP, manual, or the power-icon
  /// terminate), the base gets added to [retiredPairsFile] instead of
  /// being picked back up. Toggling this off just clears the flag - it
  /// never un-retires a base that already got retired.
  String get lastTaggedPairsFile => p.join(logsDir, 'last-tagged-pairs.json');

  /// Bases that are still genuinely auto-managed (still in
  /// [autoManagedBasesFile]) but the engine must take NO action on right
  /// now (2026-10-09, per the user: "paused pair is still an auto pair but
  /// the current status is paused so engine will not take any action to
  /// this paired pair unless it is unpaused"). Replaces the Dashboard's old
  /// Auto-toggle-off behavior (which used to remove the base from
  /// [autoManagedBasesFile] entirely, unlisting it) - a paused pair stays
  /// fully visible in the table, in whatever state it already was in
  /// (running or waiting), untouched.
  String get pausedPairsFile => p.join(logsDir, 'paused-pairs.json');

  /// One-shot queue: a base just un-paused via the Dashboard's Play button,
  /// awaiting its immediate "reverse checkup" / "match current
  /// calculations" re-evaluation (2026-10-09, per the user). See
  /// [UnpauseCheckRequestStore]'s own doc comment for the full spec.
  String get unpauseCheckRequestsFile => p.join(logsDir, 'unpause-check-requests.json');

  /// GUI-requested "does this TradingView symbol exist" checks + the
  /// engine's own answers (2026-10-10, Add Pair flow). See
  /// [SymbolResolveStore]'s own doc comment for why this needs the engine
  /// (the sole CDP connection owner) rather than being a direct GUI check.
  String get symbolResolveFile => p.join(logsDir, 'symbol-resolve.json');

  /// Last known-exact reason a base is sitting in "Waiting" with nothing
  /// open (2026-09-29, per the user: "waiting pairs should reflect exact
  /// reason ... not guess ... for example (not enough margin)"). Keyed by
  /// uppercase tvSymbol -> `{reason, at}`; written whenever an open attempt
  /// is rejected (either immediately by MT5, or discovered later via
  /// [Mt5Client.getHistoryOrders] once a pending-order fallback that never
  /// triggered turns out to have been deleted by the broker), cleared the
  /// moment that symbol next opens successfully.
  String get waitingReasonsFile => p.join(logsDir, 'waiting-reasons.json');

  /// The last time each running base was genuinely re-evaluated (past the
  /// retry cooldown, a real chart read attempted) - not gated on that
  /// attempt actually producing an action. Feeds the Dashboard table's
  /// per-row "Check" column (2026-09-29, per the user: a mark showing
  /// "checked in the current candle cycle", scoped to running pairs only).
  /// Keyed by uppercase tvSymbol -> ISO timestamp.
  String get lastCheckedFile => p.join(logsDir, 'last-checked.json');

  /// A signal that has been triple-confirmed but is not yet actionable —
  /// it must survive one full additional candle unchanged before the
  /// decision engine is allowed to act on it (2026-09-29, per the user:
  /// "app need to wait for end of next candle once signal appears ... if
  /// this next candle still empty ... then step 3 will applied. other wise
  /// ... make steps 1,2,3 on this new candle"). Keyed by
  /// `${category.wireValue}|$tvSymbol` -> `{tag, bar_time}`, where
  /// `bar_time` is the CANDIDATE signal's own bar - not the candle being
  /// waited out. Cleared the moment its wait resolves (whether that ends
  /// in an action, or in a newer signal replacing it as the fresh
  /// candidate).
  String get pendingSignalsFile => p.join(logsDir, 'pending-signals.json');

  /// Same shape as [pendingSignalsFile] but for the Supertrend Plus
  /// technique's own survive-one-candle wait (2026-10-06, per the user: "by
  /// the way. you have to make same signal check as close a close b .. so
  /// you are sure about signal flipping"). Deliberately a SEPARATE file,
  /// not shared with [pendingSignalsFile] - the Dashboard's "Close A"
  /// column reads only that one, and the user explicitly said this
  /// technique's own Close A/Update columns should always stay blank
  /// ("they are always blank"). The underlying timing safety is identical;
  /// only whether the GUI surfaces it as a live preview differs.
  String get supertrendPendingFile => p.join(logsDir, 'supertrend-pending.json');

  /// Keyed by `${category.wireValue}|$tvSymbol` -> `true`, for every
  /// symbol/category that has EVER achieved a real first open (2026-10-06,
  /// per the user: "this only for new added auto trades not for recycled
  /// ones"). A key present here is fully seasoned - every future
  /// open/recycle behaves exactly as before. A key ABSENT here (and with
  /// no running position) is still waiting out its first-ever entry via
  /// [newPairWaitFile]'s gate. See [FirstOpenStore].
  String get firstOpenFile => p.join(logsDir, 'first-open.json');

  /// Keyed by `${category.wireValue}|$tvSymbol` -> the direction ('long'/
  /// 'short') that was showing the first time a never-yet-opened pair was
  /// checked (2026-10-06, per the user: "create waiting trades OPPOSITE to
  /// current signal... wait the opposite signal to occur... once assured,
  /// fill it"). The app refuses to place that pair's very first entry
  /// until a genuinely opposite, triple-confirmed signal arrives - this is
  /// the one being waited out. Cleared the moment that happens (or the
  /// pair opens), never touched again afterward (see [firstOpenFile]).
  String get newPairWaitFile => p.join(logsDir, 'new-pair-wait.json');

  /// A queue the GUI appends to (one uppercase base per request) and the
  /// engine drains every cycle — the Dashboard table's per-pair power icon:
  /// "terminate this pair's trade right now". Cheap to check even with no
  /// TradingView chart access, so read early in [EngineService._checkOneSymbol]
  /// before any expensive chart work.
  String get terminateRequestsFile => p.join(logsDir, 'terminate-requests.json');

  /// Per `${category.wireValue}|$tvSymbol` manual trade-size override +
  /// step-down retry state (2026-10-03, per the user: "add one more column
  /// about current trade volume ... with plus minus icons"). See
  /// [TradeVolumeStore]'s own doc comment for the `desired`/`attempt`/
  /// `last_applied` field meanings. A currently-RUNNING position's own size
  /// never changes — this only affects the NEXT open (fresh or recycled).
  String get tradeVolumeFile => p.join(logsDir, 'trade-volume.json');

  /// The category (1m/1H/1D) chosen per symbol via the Next Trade/Check-card
  /// knob — defaults to 1H when a symbol has never been touched.
  String get pairCategoriesFile => p.join(logsDir, 'pair-categories.json');

  /// Every terminated position's full record — mirrors tradingPionex's own
  /// `bot-history.jsonl` (append-only, one JSON object per line, read via
  /// [readJsonl]/written via [appendJsonl]). Never rewritten/pruned, same
  /// as tradingPionex.
  String get botHistoryFile => p.join(logsDir, 'bot-history.jsonl');

  /// The open-side signal snapshot for each currently-open app position,
  /// keyed by ticket — kept only until the position closes, at which point
  /// it's read once (to fill the history entry's open* fields) and
  /// forgotten. No tradingPionex equivalent file name reused directly
  /// (their `EntrySignalStore` uses a different on-disk name) since this is
  /// a fresh port, not a shared format.
  String get entrySignalFile => p.join(logsDir, 'entry-signal.json');

  /// Symbols the engine will never auto-recreate — ported from
  /// tradingPionex's retired-pairs.json. Persisted as uppercase symbol
  /// names.
  String get retiredPairsFile => p.join(logsDir, 'retired-pairs.json');

  /// Remembers which app-opened positions had the 60/40 range-widen
  /// adjustment (see data/technique/liquidation.dart) already applied at
  /// open time, so it isn't re-applied every cycle.
  String get widenAppliedBotsFile => p.join(logsDir, 'widen-applied-bots.json');

  /// The currently-selected [DecisionTechnique.id] (2026-10-06, per the
  /// user: a picker next to Power for choosing the decision technique).
  /// Holds just `{"id": "..."}`. Missing/unreadable means "the only
  /// technique that exists" - there's nothing to actually switch to yet.
  String get decisionTechniqueFile => p.join(logsDir, 'decision-technique.json');

  /// The [DecisionTechnique.id] the engine last fully acted on (2026-10-06,
  /// per the user: "app need to apply a reverse check once new technique is
  /// choosed. so action will be immediately if there is a reverse signal").
  /// Compared against the live [decisionTechniqueFile] every cycle in
  /// [EngineService._runCycle] - a mismatch means the user switched since
  /// the engine last checked, which fires the one-time immediate
  /// reverse-check sweep over every auto-managed pair. Deliberately a
  /// SEPARATE file from [decisionTechniqueFile] (which is GUI-owned, the
  /// engine never writes it) - this one is engine-owned and purely a
  /// "have I already reacted to this value" marker, not the selection
  /// itself. Missing on first-ever run means "nothing to compare against
  /// yet" - initialized to the current value WITHOUT triggering a sweep,
  /// so a fresh install or the very first engine start of this feature
  /// never fires one by accident.
  String get lastSeenTechniqueFile => p.join(logsDir, 'last-seen-technique.json');

  /// Which bases are auto-managed under this specific category — the 1H
  /// category keeps the original filename (matching tradingPionex's
  /// convention); 1m and 1D get their own separate files.
  String autoManagedBasesFileFor(AutoCategory c) => c == AutoCategory.oneHour
      ? autoManagedBasesFile
      : p.join(logsDir, 'auto-managed-bases-${c.wireValue}.json');

  void ensureDir(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
  }

  void ensureRuntimeDirs() {
    ensureDir(rootDir);
    ensureDir(logsDir);
    ensureDir(backupsDir);
  }

  bool fileExists(String path) => File(path).existsSync();

  void touchFile(String path, {String? contents}) {
    ensureDir(p.dirname(path));
    File(
      path,
    ).writeAsStringSync(contents ?? '${DateTime.now().toIso8601String()}\n');
  }

  void deleteFileIfExists(String path) {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
  }

  String? readString(String path) {
    final f = File(path);
    if (!f.existsSync()) return null;
    try {
      return f.readAsStringSync();
    } catch (_) {
      return null;
    }
  }

  /// Atomic write: writes to a sibling temp file, then renames it over
  /// [path]. `rename` is atomic on the same filesystem (POSIX), so a
  /// concurrent reader never sees a torn/partial write.
  void writeString(String path, String contents) {
    ensureDir(p.dirname(path));
    final tmp = File('$path.tmp-${DateTime.now().microsecondsSinceEpoch}');
    tmp.writeAsStringSync(contents);
    tmp.renameSync(path);
  }

  void appendString(String path, String contents) {
    ensureDir(p.dirname(path));
    File(path).writeAsStringSync(contents, mode: FileMode.append);
  }

  Map<String, dynamic>? readJsonObject(String path) {
    final raw = readString(path);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  List<dynamic>? readJsonArray(String path) {
    final raw = readString(path);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Same data as [readJsonArray], but for callers where "the file exists
  /// but failed to parse" must NOT collapse into the same outcome as "the
  /// file doesn't exist yet" — e.g. `open-positions.json`/`retired-pairs.json`,
  /// where silently treating corruption as "empty" would let the engine
  /// forget a real open position's app-initiated/retired status and act on
  /// real money as if it were a fresh symbol. Returns `[]` only when [path]
  /// genuinely doesn't exist; throws [FormatException] when it exists but
  /// couldn't be parsed as a JSON array, so the caller can keep its
  /// last-known-good in-memory state instead of resetting to empty. Ported
  /// from tradingPionex's CoreStorage.
  List<dynamic> readJsonArrayStrict(String path) {
    if (!fileExists(path)) return const [];
    final raw = readString(path);
    if (raw == null) {
      throw FormatException('$path exists but could not be read');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw FormatException('$path does not contain a JSON array');
    }
    return decoded;
  }

  void writeJson(String path, Object value) {
    writeString(
      path,
      '${const JsonEncoder.withIndent('  ').convert(value)}\n',
    );
  }

  List<Map<String, dynamic>> readJsonl(String path) {
    final raw = readString(path);
    if (raw == null) return const [];
    final out = <Map<String, dynamic>>[];
    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) out.add(decoded);
      } catch (_) {
        // Skip a corrupt line rather than failing the whole read.
      }
    }
    return out;
  }

  void appendJsonl(String path, Map<String, dynamic> entry) {
    appendString(path, '${jsonEncode(entry)}\n');
  }

  /// Rewrites the WHOLE .jsonl file from [entries] - unlike [appendJsonl],
  /// this replaces every line (2026-09-30, per the user: deleting a single
  /// History card needs to remove just that one entry, not the whole
  /// file).
  void writeJsonl(String path, List<Map<String, dynamic>> entries) {
    writeString(path, entries.map((e) => '${jsonEncode(e)}\n').join());
  }

  /// `.env`-style `KEY=value` parsing (no quoting/escaping support).
  Map<String, String> readEnvFile() {
    final raw = readString(envFile);
    if (raw == null) return const {};
    final out = <String, String>{};
    final pattern = RegExp(r'^([A-Z_][A-Z0-9_]*)=(.*)$');
    for (final line in raw.split('\n')) {
      final match = pattern.firstMatch(line);
      if (match != null) out[match.group(1)!] = match.group(2)!;
    }
    return out;
  }

  /// Updates (or adds) a single `KEY=value` line in `.env`, preserving
  /// every other line (2026-10-03, per the user: Settings screen's
  /// connection-config editor needs to save the MT5 API key without
  /// clobbering anything else in the file). No quoting/escaping support,
  /// matching [readEnvFile]'s own simple format.
  void updateEnvValue(String key, String value) {
    final current = Map<String, String>.from(readEnvFile());
    current[key] = value;
    writeString(envFile, '${current.entries.map((e) => '${e.key}=${e.value}').join('\n')}\n');
  }

  String expandHome(String path) {
    if (!path.startsWith('~')) return path;
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    return p.join(home, path.substring(1).replaceFirst(RegExp(r'^/'), ''));
  }
}
