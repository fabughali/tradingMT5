import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/core_storage.dart';
import '../config/config_loader.dart';
import '../control/engine_control_repository.dart';
import '../models/account_snapshot.dart';
import '../models/app_config.dart';
import '../models/auto_category.dart';
import '../models/auto_trade_row.dart';
import '../models/bot_history_entry.dart';
import '../models/control_toggle_state.dart';
import '../models/decision_technique.dart';
import '../models/engine_status.dart';
import '../models/market_watch_snapshot.dart';
import '../identity/trade_volume_store.dart';
import '../logging/app_logger.dart';
import '../models/signal.dart';
import '../models/watched_symbol.dart';
import '../mt5/mt5_client.dart';

final storageProvider = Provider<CoreStorage>((ref) => CoreStorage.instance);

/// Every closed position's full record, newest first — polls
/// `bot-history.jsonl` (engine-written, GUI-read-only, same split as every
/// other engine-state file) every 5s. A corrupt line is silently skipped by
/// [CoreStorage.readJsonl]; a corrupt/unparseable ENTRY (schema mismatch)
/// is skipped here the same way rather than crashing the whole list.
final botHistoryProvider = StreamProvider.autoDispose<List<BotHistoryEntry>>((
  ref,
) async* {
  final storage = ref.watch(storageProvider);
  while (true) {
    final raw = storage.readJsonl(storage.botHistoryFile);
    final entries = <BotHistoryEntry>[];
    for (final json in raw) {
      try {
        entries.add(BotHistoryEntry.fromJson(json));
      } catch (_) {
        // Skip a corrupt entry rather than failing the whole list.
      }
    }
    entries.sort((a, b) => b.ts.compareTo(a.ts));
    yield entries;
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

final configProvider = Provider<AppConfig>(
  (ref) => loadOrInitConfig(ref.watch(storageProvider)),
);

/// Bare uppercase TradingView bases currently in `auto-managed-bases.json`
/// (2026-10-04, per the user: the Market Watch picker's checkbox "should
/// not be clickable if pair is on waiting or pending ... but they are in
/// auto list" - i.e. ANY state, not just running, which the existing
/// open-position check already covers on its own). Polled fresh every 5s,
/// same cadence as every other file-backed provider here.
final autoManagedTvBasesProvider = StreamProvider.autoDispose<Set<String>>((
  ref,
) async* {
  final storage = ref.watch(storageProvider);
  while (true) {
    yield storage
        .readJsonArrayStrict(storage.autoManagedBasesFile)
        .map((e) => e.toString().toUpperCase())
        .toSet();
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

/// When the user last pressed the "reset" icon on the Dashboard's P&L-since
/// tracker (2026-09-30, per the user: "add a new text with timestamp of
/// history and P&L after this time stamp ... an icon ... press on it, it
/// will reset time stamp"). Null means never reset - the tracker then sums
/// ALL of history rather than nothing, since "how much have I made overall"
/// is the more useful starting state than zero. Pure GUI-side state
/// (mirrors [ThemeModeNotifier]'s own `gui-prefs.json` pattern) - the
/// engine never reads or writes this file.
class PnlSinceNotifier extends Notifier<DateTime?> {
  late final String _file = '${ref.read(storageProvider).rootDir}/pnl-since.json';

  @override
  DateTime? build() {
    final storage = ref.read(storageProvider);
    final json = storage.readJsonObject(_file);
    final raw = json?['since'] as String?;
    return raw == null ? null : DateTime.tryParse(raw);
  }

  void reset() {
    final now = DateTime.now();
    state = now;
    ref.read(storageProvider).writeJson(_file, {'since': now.toIso8601String()});
  }
}

final pnlSinceProvider = NotifierProvider<PnlSinceNotifier, DateTime?>(
  PnlSinceNotifier.new,
);

/// The currently-selected [DecisionTechnique] (2026-10-06, per the user: a
/// picker next to Power for choosing the decision technique, with "Read
/// more" opening a details screen). Pure GUI-side state for now - only one
/// technique exists, so there's nothing for the engine to read yet; once a
/// second technique is added, [select] is also where the "reverse-check
/// every auto trade against its Start signal" pass the user described
/// should be triggered.
class DecisionTechniqueNotifier extends Notifier<DecisionTechnique> {
  @override
  DecisionTechnique build() {
    final storage = ref.read(storageProvider);
    final json = storage.readJsonObject(storage.decisionTechniqueFile);
    final id = json?['id'] as String?;
    return DecisionTechnique.all.firstWhere(
      (t) => t.id == id,
      orElse: () => DecisionTechnique.signalFlip,
    );
  }

  /// Logs every selection the instant it happens (2026-10-06, per the user:
  /// "did you include switching from one technique to another in app
  /// log???" - found live that neither this nor the engine recorded the
  /// raw click itself: the engine only logs a switch when its NEXT cycle
  /// happens to see a value different from what it last recorded, which
  /// misses a round-trip (switch away and back) that resolves before that
  /// next read. Logging HERE, at the moment of the click, catches every
  /// selection unconditionally - round-trips included - regardless of
  /// whether the engine is even running. Reuses [AppLogger] the exact same
  /// way [EngineControlRepository] already does for every other manual
  /// Dashboard action, so this lands in the same unified engine.log
  /// timeline, "[USER]"-prefixed.
  void select(DecisionTechnique technique) {
    final previous = state;
    state = technique;
    final storage = ref.read(storageProvider);
    storage.writeJson(storage.decisionTechniqueFile, {'id': technique.id});
    if (previous.id != technique.id) {
      AppLogger(storage).log('[USER] Decision technique switched: ${previous.name} -> ${technique.name}');
    }
  }
}

final decisionTechniqueProvider =
    NotifierProvider<DecisionTechniqueNotifier, DecisionTechnique>(
  DecisionTechniqueNotifier.new,
);

/// Realized P&L (from [botHistoryProvider], NOT live floating P&L) summed
/// across every closed position whose close time falls after
/// [pnlSinceProvider]'s marker (or everything, if that marker is null) -
/// "how much P&L during this time interval," per the user's own spec.
final historyPnlSinceProvider = Provider.autoDispose<double>((ref) {
  final since = ref.watch(pnlSinceProvider);
  final history = ref.watch(botHistoryProvider).asData?.value ?? const [];
  return history
      .where((e) => since == null || (e.endTime ?? e.ts).isAfter(since))
      .fold<double>(0, (sum, e) => sum + (e.realizedProfit ?? 0));
});

final controlRepositoryProvider = Provider<EngineControlRepository>(
  (ref) => EngineControlRepository(ref.watch(storageProvider)),
);

/// Polls the file-based engine status every 5s. A manual
/// `ref.invalidateSelf()` after any control action forces an immediate
/// refresh instead of waiting.
final engineStatusProvider = StreamProvider.autoDispose<EngineStatus>((
  ref,
) async* {
  final repo = ref.watch(controlRepositoryProvider);
  while (true) {
    yield await repo.status();
    await Future<void>.delayed(repo.statusPollInterval);
  }
});

/// Mirrors MT5's own Market Watch, live. Per the user (2026-09-17): the
/// app's symbol list is never separately maintained — whatever is currently
/// visible in MT5's Market Watch IS the app's list. Add a symbol in MT5 and
/// it appears here within one poll; remove it there and it disappears here.
///
/// Open-position info rides along in the same poll (one connection, two
/// calls) — the checkbox in [WatchedSymbolsList] that lets a symbol be
/// removed from Market Watch is disabled whenever the symbol has an open
/// position, so a running trade's symbol can never be hidden by accident.
/// Also drives the BUY/SELL tag + volume/SL/TP shown per symbol.
final watchedSymbolsProvider =
    StreamProvider.autoDispose<MarketWatchSnapshot>((ref) async* {
      final storage = ref.watch(storageProvider);
      final config = ref.watch(configProvider);
      final env = storage.readEnvFile();
      var lastGood = const MarketWatchSnapshot(
        symbols: [],
        openPositionSides: {},
      );
      while (true) {
        final client = Mt5Client(
          apiKey: env['MT5_MCP_API_KEY'] ?? '',
          host: config.mt5.mcpHost,
          port: config.mt5.mcpPort,
        );
        try {
          await client.connect();
          final rawSymbols = await client.getWatchedSymbols();
          final rawPositions = await client.getOpenPositions();
          final positions = (rawPositions['positions'] as List?) ?? const [];
          lastGood = MarketWatchSnapshot(
            symbols:
                rawSymbols.map(WatchedSymbol.fromJson).toList()
                  ..sort((a, b) => a.symbol.compareTo(b.symbol)),
            openPositionSides: {
              for (final p in positions.cast<Map<String, dynamic>>())
                p['symbol'] as String: OpenPositionInfo(
                  side: p['action'] as String,
                  volume: (p['volume'] as num).toDouble(),
                  // Confirmed live 2026-09-17 that the position object omits
                  // these fields entirely when unset (rather than 0) — field
                  // NAMES (sl/tp) follow MT5's universal convention but
                  // haven't been confirmed against a position that actually
                  // has them set. Verify once a real SL/TP-bearing position
                  // exists.
                  sl: (p['sl'] as num?)?.toDouble(),
                  tp: (p['tp'] as num?)?.toDouble(),
                ),
            },
          );
        } catch (_) {
          // Transient disconnect (MT5 restarting, etc.) — keep showing the
          // last known-good snapshot rather than dying or flashing empty.
        } finally {
          client.close();
        }
        yield lastGood;
        await Future<void>.delayed(const Duration(seconds: 5));
      }
    });

/// One row per symbol in [AppConfig.symbols] (the FULL universe, not just
/// the auto-managed subset — 2026-09-29 spec extension: a pair toggled Auto
/// OFF must still show in the table as manually-managed, not disappear),
/// every 5s — feeds the Dashboard's "Auto-Managed Trades" table (2026-09-29,
/// per the user: "a table .. a list of currenly running trades, filled
/// trades, waiting trades" then extended with start/update signal columns,
/// duration, and per-row Auto/Last toggles + a terminate icon). Reads
/// `auto-managed-bases.json`, `last-tagged-pairs.json`, and
/// `entry-signal.json` fresh every poll (same files the engine itself
/// reloads every cycle) rather than caching them, then a single
/// un-filtered `get_trading_open_positions` call covers every symbol's
/// position AND pending-order state in one MT5 round trip. Only
/// positions/orders carrying this app's own comment tag
/// ('trading_mt5 ONE_HOUR') count - a manually-opened position on the same
/// symbol is invisible here, matching [OpenPositionStore]'s own "never
/// touch what it didn't open" rule elsewhere in the app.
final autoTradesProvider = StreamProvider.autoDispose<List<AutoTradeRow>>((
  ref,
) async* {
  final storage = ref.watch(storageProvider);
  final config = ref.watch(configProvider);
  final env = storage.readEnvFile();
  const tag = 'trading_mt5 ONE_HOUR';
  var lastGood = const <AutoTradeRow>[];
  while (true) {
    final client = Mt5Client(
      apiKey: env['MT5_MCP_API_KEY'] ?? '',
      host: config.mt5.mcpHost,
      port: config.mt5.mcpPort,
    );
    try {
      await client.connect();
      final autoBases = storage
          .readJsonArrayStrict(storage.autoManagedBasesFile)
          .map((e) => e.toString().toUpperCase())
          .toSet();
      final lastTaggedBases = storage
          .readJsonArrayStrict(storage.lastTaggedPairsFile)
          .map((e) => e.toString().toUpperCase())
          .toSet();
      // 2026-09-30, per the user: a RETIRED pair (via the Last+power
      // combo) should actually disappear from the table - distinct from
      // a plain Auto-toggle-off, which per the earlier spec ("toggle off
      // = manual managed ... still needs to be visible") stays visible.
      // RetiredStore is what the engine's own main loop checks to skip a
      // base entirely, so this is the correct "truly done with this pair"
      // signal to hide on.
      final retiredBases = storage
          .readJsonArrayStrict(storage.retiredPairsFile)
          .map((e) => e.toString().toUpperCase())
          .toSet();
      final entrySignalsRaw =
          storage.readJsonObject(storage.entrySignalFile) ?? const {};
      final waitingReasonsRaw =
          storage.readJsonObject(storage.waitingReasonsFile) ?? const {};
      final lastCheckedRaw =
          storage.readJsonObject(storage.lastCheckedFile) ?? const {};
      final pendingSignalsRaw =
          storage.readJsonObject(storage.pendingSignalsFile) ?? const {};
      final tradeVolumes = TradeVolumeStore(storage);
      // One bulk call covers every symbol's volume_min/step/max (2026-10-03)
      // - same data [WatchedSymbol] already parses for the New Order
      // screen's stepper, reused here instead of a per-row MT5 round trip.
      final watchedBySymbol = {
        for (final w in (await client.getWatchedSymbols()).map(WatchedSymbol.fromJson))
          w.symbol.toUpperCase(): w,
      };
      final raw = await client.getOpenPositions();
      final positions = ((raw['positions'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      final orders = ((raw['orders'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      final positionByMt5Symbol = {
        for (final p in positions)
          if (p['comment'] == tag) (p['symbol'] as String).toUpperCase(): p,
      };
      final orderByMt5Symbol = {
        for (final o in orders)
          if (o['comment'] == tag && o['state'] == 'placed')
            (o['symbol'] as String).toUpperCase(): o,
      };
      final rows = <AutoTradeRow>[];
      final seenTvSymbols = <String>{};
      for (final mapping in config.symbols) {
        final tvSymbol = mapping.tradingViewSymbol.toUpperCase();
        if (!seenTvSymbols.add(tvSymbol)) continue;
        // 2026-09-30, per the user: "table only show auto managed pairs" -
        // supersedes the earlier "show the full universe, a manually
        // toggled-off pair stays visible" design. A pair is shown only
        // when it's BOTH in auto-managed-bases.json AND not retired (a
        // retired pair stays listed in auto-managed-bases.json itself -
        // _finalizeLastTagOnClose never removes it from there - so both
        // checks are needed).
        final isAutoManaged = autoBases.contains(tvSymbol);
        if (!isAutoManaged || retiredBases.contains(tvSymbol)) continue;
        final mt5Symbol = mapping.mt5Symbol;
        final isLastTagged = lastTaggedBases.contains(tvSymbol);
        final position = positionByMt5Symbol[mt5Symbol.toUpperCase()];
        final order = orderByMt5Symbol[mt5Symbol.toUpperCase()];
        // Trade-size override (2026-10-03, per the user). `watched` carries
        // this symbol's broker-reported volume bounds/step; falls back to
        // conservative defaults on the (expected-never) case a configured
        // symbol isn't in Market Watch at all.
        final watched = watchedBySymbol[mt5Symbol.toUpperCase()];
        final volumeMinForRow = watched?.volumeMin ?? 0.01;
        final volumeStepForRow = watched?.volumeStep ?? 0.01;
        final volumeMaxForRow = watched?.volumeMax ?? 100;
        final volKey = '${AutoCategory.oneHour.wireValue}|$tvSymbol';
        final desiredVolume = tradeVolumes.desired(volKey);
        final currentVolume = position != null
            ? (position['volume'] as num?)?.toDouble()
            : tradeVolumes.lastApplied(volKey);
        if (position != null) {
          final ticket = int.tryParse('${position['position_id']}');
          final entry = ticket != null
              ? entrySignalsRaw['$ticket'] as Map<String, dynamic>?
              : null;
          // "Close A"/"Close B" (2026-09-30, per the user) - only
          // meaningful when the currently-pending candidate (if any)
          // actually disagrees with this row's running direction, i.e. it
          // would close this trade once confirmed. An agreeing candidate
          // isn't a "close" candidate at all (see AutoTradeRow's doc).
          final pendingEntry =
              pendingSignalsRaw['${AutoCategory.oneHour.wireValue}|$tvSymbol'] as Map<String, dynamic>?;
          String? closeATag;
          int? closeAAt;
          DateTime? closeBEta;
          final pendingWireTag = pendingEntry?['tag'] as String?;
          final pendingBarTime = (pendingEntry?['bar_time'] as num?)?.toInt();
          if (pendingWireTag != null && pendingBarTime != null) {
            final pendingSide = Signal(
              tag: signalTagFromWire(pendingWireTag),
              time: pendingBarTime,
            ).side;
            final pendingDirection = pendingSide == SignalSide.buy ? 'buy' : 'sell';
            if (pendingDirection != (position['action'] as String?)) {
              closeATag = pendingWireTag;
              closeAAt = pendingBarTime;
              closeBEta = DateTime.fromMillisecondsSinceEpoch(
                (pendingBarTime + AutoCategory.oneHour.candlePeriod.inSeconds * 2) * 1000,
                isUtc: true,
              );
            }
          }
          rows.add(
            AutoTradeRow(
              tvSymbol: tvSymbol,
              mt5Symbol: mt5Symbol,
              status: AutoTradeStatus.running,
              isAutoManaged: isAutoManaged,
              isLastTagged: isLastTagged,
              direction: position['action'] as String?,
              price: (position['price_open'] as num?)?.toDouble(),
              stopLoss: (position['stop_loss'] as num?)?.toDouble(),
              takeProfit: (position['take_profit'] as num?)?.toDouble(),
              profit: (position['profit'] as num?)?.toDouble(),
              ticket: ticket,
              openedAt: DateTime.tryParse(
                position['create_time'] as String? ?? '',
              ),
              startTag: entry?['tag'] as String?,
              startAt: (entry?['bar_time'] as num?)?.toInt(),
              updateTag: entry?['update_tag'] as String?,
              updateAt: (entry?['update_time'] as num?)?.toInt(),
              lastCheckedAt: DateTime.tryParse(
                lastCheckedRaw[tvSymbol] as String? ?? '',
              ),
              closeATag: closeATag,
              closeAAt: closeAAt,
              closeBEta: closeBEta,
              desiredVolume: desiredVolume,
              currentVolume: currentVolume,
              volumeMin: volumeMinForRow,
              volumeStep: volumeStepForRow,
              volumeMax: volumeMaxForRow,
            ),
          );
        } else if (order != null) {
          rows.add(
            AutoTradeRow(
              tvSymbol: tvSymbol,
              mt5Symbol: mt5Symbol,
              status: AutoTradeStatus.waitingPending,
              isAutoManaged: isAutoManaged,
              isLastTagged: isLastTagged,
              desiredVolume: desiredVolume,
              currentVolume: currentVolume,
              volumeMin: volumeMinForRow,
              volumeStep: volumeStepForRow,
              volumeMax: volumeMaxForRow,
              direction: (order['type'] as String?)?.contains('sell') == true
                  ? 'sell'
                  : 'buy',
              price: (order['price_order'] as num?)?.toDouble(),
              stopLoss: (order['stop_loss'] as num?)?.toDouble(),
              takeProfit: (order['take_profit'] as num?)?.toDouble(),
              ticket: int.tryParse('${order['order_id']}'),
            ),
          );
        } else {
          final reasonEntry = waitingReasonsRaw[tvSymbol] as Map<String, dynamic>?;
          // "Start candidate" (2026-10-03, per the user: waiting rows with
          // a real triple-confirmed signal already mid-"survive one extra
          // candle" wait looked identical to genuinely idle ones) - unlike
          // Close A/B, there's no running direction to disagree with here,
          // so ANY pending candidate for this symbol/category counts (it's
          // the candidate for this row's own eventual Start).
          final candidateEntry =
              pendingSignalsRaw['${AutoCategory.oneHour.wireValue}|$tvSymbol'] as Map<String, dynamic>?;
          final candidateWireTag = candidateEntry?['tag'] as String?;
          final candidateBarTime = (candidateEntry?['bar_time'] as num?)?.toInt();
          rows.add(
            AutoTradeRow(
              tvSymbol: tvSymbol,
              mt5Symbol: mt5Symbol,
              status: AutoTradeStatus.waitingNoSignal,
              isAutoManaged: isAutoManaged,
              isLastTagged: isLastTagged,
              waitingReason: reasonEntry?['reason'] as String?,
              desiredVolume: desiredVolume,
              currentVolume: currentVolume,
              volumeMin: volumeMinForRow,
              volumeStep: volumeStepForRow,
              volumeMax: volumeMaxForRow,
              startCandidateTag: candidateWireTag,
              startCandidateAt: candidateBarTime,
              startCandidateEta: candidateBarTime == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(
                      (candidateBarTime + AutoCategory.oneHour.candlePeriod.inSeconds * 2) * 1000,
                      isUtc: true,
                    ),
            ),
          );
        }
      }
      rows.sort((a, b) => a.tvSymbol.compareTo(b.tvSymbol));
      lastGood = rows;
    } catch (_) {
      // Transient disconnect - keep showing the last known-good snapshot.
    } finally {
      client.close();
    }
    yield lastGood;
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

/// Live balance/equity/margin/free-margin numbers every 5s (2026-09-29, per
/// the user: shown at the top of the Dashboard's Auto-Managed Trades card,
/// below the running/pending/waiting summary line). Same poll cadence and
/// last-known-good-on-disconnect pattern as [autoTradesProvider] - a
/// separate MT5 connection since Riverpod providers each run independently,
/// but a cheap single `get_trading_account_info` call.
final accountInfoProvider = StreamProvider.autoDispose<AccountSnapshot?>((
  ref,
) async* {
  final storage = ref.watch(storageProvider);
  final config = ref.watch(configProvider);
  final env = storage.readEnvFile();
  AccountSnapshot? lastGood;
  while (true) {
    final client = Mt5Client(
      apiKey: env['MT5_MCP_API_KEY'] ?? '',
      host: config.mt5.mcpHost,
      port: config.mt5.mcpPort,
    );
    try {
      await client.connect();
      final raw = await client.getAccountInfo();
      lastGood = AccountSnapshot.fromJson(raw);
    } catch (_) {
      // Transient disconnect - keep showing the last known-good snapshot.
    } finally {
      client.close();
    }
    yield lastGood;
    await Future<void>.delayed(const Duration(seconds: 5));
  }
});

/// Polls the Power/Auto/per-category toggle files every 2s — pure local
/// reads, fast enough that the Dashboard's switches feel responsive to a
/// tap. A manual `ref.invalidate` after any toggle action forces an
/// immediate refresh instead of waiting out the poll.
final controlToggleStateProvider = StreamProvider.autoDispose<ControlToggleState>((
  ref,
) async* {
  final repo = ref.watch(controlRepositoryProvider);
  while (true) {
    yield ControlToggleState(
      powerOn: repo.isPowerOn,
      autoOn: repo.isAutoOn,
      categoryOn: {
        for (final c in allAutoCategories) c: repo.isCategoryOn(c),
      },
    );
    await Future<void>.delayed(const Duration(seconds: 2));
  }
});

enum AppThemeMode { system, light, dark }

extension AppThemeModeX on AppThemeMode {
  ThemeMode get flutterThemeMode => switch (this) {
    AppThemeMode.system => ThemeMode.system,
    AppThemeMode.light => ThemeMode.light,
    AppThemeMode.dark => ThemeMode.dark,
  };
}

class ThemeModeNotifier extends Notifier<AppThemeMode> {
  late final String _prefsFile =
      '${ref.read(storageProvider).rootDir}/gui-prefs.json';

  @override
  AppThemeMode build() {
    final storage = ref.read(storageProvider);
    final json = storage.readJsonObject(_prefsFile);
    final raw = json?['theme_mode'] as String?;
    return AppThemeMode.values.firstWhere(
      (m) => m.name == raw,
      orElse: () => AppThemeMode.system,
    );
  }

  void setMode(AppThemeMode mode) {
    state = mode;
    ref.read(storageProvider).writeJson(_prefsFile, {'theme_mode': mode.name});
  }
}

final themeModeProvider = NotifierProvider<ThemeModeNotifier, AppThemeMode>(
  ThemeModeNotifier.new,
);
