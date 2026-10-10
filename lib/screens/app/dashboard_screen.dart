import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/account_snapshot.dart';
import '../../data/models/app_config.dart';
import '../../data/models/decision_technique.dart';
import '../../data/models/power_health.dart';
import '../../data/models/watched_symbol.dart';
import '../../data/mt5/mt5_client.dart';
import '../../data/providers/app_providers.dart';
import '../../utilities/util_date.dart';
import '../../widgets/add_pair_dialog.dart';
import '../../widgets/auto_trades_card.dart';
import '../../widgets/control_toggles_bar.dart';
import '../../widgets/reuse_status_light.dart';
import '../../widgets/start_auto_trade_dialog.dart';
import '../../widgets/watched_symbols_list.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(engineStatusProvider);
    final watched = ref.watch(watchedSymbolsProvider);
    final autoTrades = ref.watch(autoTradesProvider);
    final account = ref.watch(accountInfoProvider);
    final pnlSince = ref.watch(pnlSinceProvider);
    final config = ref.watch(configProvider);
    final autoManagedBases = ref.watch(autoManagedTvBasesProvider).asData?.value ?? const <String>{};
    final historyPnlSince = ref.watch(historyPnlSinceProvider);
    final decisionTechnique = ref.watch(decisionTechniqueProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: status.when(
                    data: (s) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ReuseStatusLight(on: s.running, label: 'Engine'),
                        const SizedBox(height: 8),
                        ReuseStatusLight(on: s.connected, label: 'MT5 connected'),
                        const SizedBox(height: 8),
                        // 2026-09-30, per the user: a dedicated circle for
                        // TradingView, same as Engine/MT5 - derived from the
                        // existing health field (no engine change needed):
                        // PowerHealthState.ready means ALL three layers
                        // (internet/MT5/TradingView) just passed THIS
                        // cycle, so TradingView specifically was verified.
                        // Every other state (including tradingViewProblem)
                        // shows off, since otherwise its status this cycle
                        // is either explicitly failed or not yet reached.
                        ReuseStatusLight(
                          on: s.health == PowerHealthState.ready,
                          label: 'TradingView connected',
                        ),
                        const SizedBox(height: 8),
                        Text('Last cycle: ${UtilDate.relative(s.lastCycleAt)}'),
                        if (s.message != null) ...[
                          const SizedBox(height: 8),
                          Text(s.message!),
                        ],
                      ],
                    ),
                    loading: () => const CircularProgressIndicator(),
                    error: (e, _) => Text('Error: $e'),
                  ),
                ),
                // 2026-09-29, per the user: account numbers at the top right
                // of the engine status section (moved here from the
                // Auto-Managed Trades card per the same-day follow-up).
                if (account.asData?.value case final acct?) _AccountStatsColumn(account: acct),
              ],
            ),
          ),
          const Divider(height: 1),
          const Padding(
            padding: EdgeInsets.all(16),
            child: ControlTogglesBar(),
          ),
          const Divider(height: 1),
          // 2026-09-29, per the user: "the card should be after engine
          // status section and power/auto section" - moved below the two
          // sections above (was previously the very first item).
          autoTrades.when(
            data: (rows) => AutoTradesCard(
              rows: rows,
              hideUpdateCloseColumns: decisionTechnique.id == DecisionTechnique.supertrendPlus.id,
              onTogglePause: (tvSymbol, paused) {
                ref.read(controlRepositoryProvider).setPaused(tvSymbol, paused);
                ref.invalidate(autoTradesProvider);
              },
              onToggleLast: (tvSymbol, on) {
                ref.read(controlRepositoryProvider).setLastTagged(tvSymbol, on);
                ref.invalidate(autoTradesProvider);
              },
              onTerminate: (tvSymbol) {
                ref.read(controlRepositoryProvider).requestTerminate(tvSymbol);
                ref.invalidate(autoTradesProvider);
              },
              onChangeVolume: (tvSymbol, volume) {
                ref.read(controlRepositoryProvider).setDesiredVolume(tvSymbol, volume);
                ref.invalidate(autoTradesProvider);
              },
              historyPnlSince: historyPnlSince,
              pnlSinceTimestamp: pnlSince,
              onResetPnlSince: () => ref.read(pnlSinceProvider.notifier).reset(),
              liveAccountPnl: switch (account.asData?.value) {
                final acct? => acct.equity - acct.balance,
                null => null,
              },
            ),
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error: $e'),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Text(
                  'Market Watch',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                // 2026-10-10, per the user: "user should have capability to
                // add/remove pairs in forex/crypto/stock" - unlike "Start
                // Auto Trade" below (which only covers symbols already
                // visible in MT5's Market Watch), this adds a pair MT5 may
                // not even know about yet, confirmed across all three apps
                // first (see AddPairDialog).
                OutlinedButton.icon(
                  onPressed: () => _addPair(context, ref),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Pair'),
                ),
              ],
            ),
          ),
          watched.when(
            data: (snapshot) => WatchedSymbolsList(
              snapshot: snapshot,
              // 2026-10-03, per the user: "why app is making a separate
              // list for non-auto managed pairs ... I want app to keep
              // same current list of pairs ... choose from those three
              // lists and then click on start auto trade" - this IS that
              // single list (replaced the old, narrower NonAutoPairsCard).
              onStartAutoTrade: (symbols) => _startAutoTrade(context, ref, symbols),
              // 2026-10-04, per the user: a pair already auto-managed -
              // running, waiting, or pending, any state - shouldn't be
              // re-selectable here at all.
              autoManagedBases: autoManagedBases,
              symbolMappings: config.symbols,
              onRemovePair: (symbol, tvSymbol) => _removePair(context, ref, symbol, tvSymbol),
            ),
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: CircularProgressIndicator(),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error: $e'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _startAutoTrade(
    BuildContext context,
    WidgetRef ref,
    List<WatchedSymbol> symbols,
  ) async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => StartAutoTradeDialog(symbols: symbols),
    );
    if (result == null || result.isEmpty) return;
    final repo = ref.read(controlRepositoryProvider);
    for (final entry in result.entries) {
      final mt5Symbol = entry.key;
      final tvSymbol = entry.value;
      repo.addSymbolMapping(
        SymbolMapping(tradingViewSymbol: tvSymbol, mt5Symbol: mt5Symbol),
      );
      repo.setAutoManaged(tvSymbol);
      // 2026-10-06, per the user: a pair re-added here after having been
      // retired (Last-tagged + closed) should start fresh at the broker
      // minimum volume, not silently resume whatever custom volume it had
      // during its previous life as an auto pair.
      repo.resetDesiredVolume(tvSymbol);
      // 2026-10-04, per the user: "dont let app to do cosmetic work" - no
      // longer queues a Red-list add here. Confirmed the same day that
      // Red-list membership has zero bearing on signal reading or any
      // trading decision, so there's nothing functional this was ever
      // doing beyond a cosmetic TradingView-side listing.
    }
    // 2026-10-03, per the user: "app did not add this to auto list" - a new
    // mapping just written to config.json was genuinely there (the engine,
    // which re-reads config.json fresh every cycle, picked it up and
    // started working it immediately) but invisible on the Dashboard,
    // because [configProvider] is a plain (non-autoDispose, non-stream)
    // Provider - computed once at app startup and never re-read after,
    // unlike every other control here. [autoTradesProvider] builds its rows
    // from that same cached `config.symbols`, so a brand-new mapping never
    // appeared in the table until the whole app restarted. Invalidating it
    // here forces a fresh read, which cascades to autoTradesProvider since
    // it `ref.watch`es configProvider.
    ref.invalidate(configProvider);
    ref.invalidate(autoTradesProvider);
  }

  Future<void> _addPair(BuildContext context, WidgetRef ref) async {
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => const AddPairDialog(),
    );
    if (added == true) {
      ref.invalidate(configProvider);
      ref.invalidate(watchedSymbolsProvider);
      ref.invalidate(autoTradesProvider);
      // 2026-10-10, per the user: "once user click on add, pair added ...
      // add dialog disappear and snack bar show success" - shown here
      // rather than inside the dialog itself, since the dialog's own
      // context is already gone by the time this runs.
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pair added.')),
        );
      }
    }
  }

  /// "Remove pair" trash icon on a `WatchedSymbolsList` card (2026-10-10,
  /// per the user: "all already existed pairs in forex/crypto/stock should
  /// have trash icon (can be deleted) ... only pairs in auto cant be
  /// deleted"). The card itself already refuses the tap while auto-managed
  /// or running, so by the time this runs removal is always safe. Fully
  /// deletes the pair: unmaps it from tradingMT5 (if [tvSymbol] is non-null
  /// — a symbol with no mapping yet has nothing to unmap) AND removes it
  /// from THIS machine's own MT5 Market Watch, so it's gone from every one
  /// of the three apps the Add Pair flow confirms a new pair against.
  Future<void> _removePair(BuildContext context, WidgetRef ref, WatchedSymbol symbol, String? tvSymbol) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove pair'),
        content: Text(
          'Remove ${symbol.symbol} entirely?'
          '${tvSymbol != null ? ' Unmaps it from tradingMT5 and' : ' Removes it'} '
          'from MT5\'s Market Watch.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Remove')),
        ],
      ),
    );
    if (confirmed != true) return;

    if (tvSymbol != null) {
      ref.read(controlRepositoryProvider).removeSymbolMapping(tvSymbol, hasRunningPosition: false);
    }
    final storage = ref.read(storageProvider);
    final config = ref.read(configProvider);
    final env = storage.readEnvFile();
    final client = Mt5Client(
      apiKey: env['MT5_MCP_API_KEY'] ?? '',
      host: config.mt5.mcpHost,
      port: config.mt5.mcpPort,
    );
    try {
      await client.connect();
      await client.removeMarketWatchSymbol(symbol.symbol);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Removed from tradingMT5, but MT5 Market Watch removal failed: $e')),
        );
      }
    } finally {
      client.close();
    }

    ref.invalidate(configProvider);
    ref.invalidate(watchedSymbolsProvider);
    ref.invalidate(autoTradesProvider);
  }
}

/// Balance/Equity/Margin/Free Margin/Margin Level, top-right of the engine
/// status section (2026-09-29, per the user) - extended 2026-09-30 with a
/// P&L line (equity - balance, the standard floating-P&L definition) below
/// the rest, and a color rule on the Balance figure itself: red when
/// balance > equity (floating P&L negative), yellow when exactly equal,
/// green when balance < equity (floating P&L positive).
class _AccountStatsColumn extends StatelessWidget {
  const _AccountStatsColumn({required this.account});

  final AccountSnapshot account;

  static String _money(double v, String currency) => '${v.toStringAsFixed(2)} $currency'.trim();

  static String _percent(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)}%';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    Widget stat(String label, String value, {Color? valueColor}) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        textAlign: TextAlign.right,
        text: TextSpan(
          style: style,
          children: [
            TextSpan(text: '$label: '),
            TextSpan(
              text: value,
              style: TextStyle(fontWeight: FontWeight.w600, color: valueColor ?? scheme.onSurface),
            ),
          ],
        ),
      ),
    );

    final balanceColor = account.balance > account.equity
        ? Colors.red
        : account.balance == account.equity
        ? Colors.amber
        : Colors.green;
    final pnl = account.equity - account.balance;
    final pnlColor = pnl < 0
        ? Colors.red
        : pnl > 0
        ? Colors.green
        : Colors.amber;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        stat('Balance', _money(account.balance, account.currency), valueColor: balanceColor),
        stat('Equity', _money(account.equity, account.currency)),
        stat('Margin', _money(account.margin, account.currency)),
        stat('Free Margin', _money(account.marginFree, account.currency)),
        stat('Margin Level', _percent(account.marginLevel)),
        stat(
          'P&L',
          '${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)} ${account.currency}'.trim(),
          valueColor: pnlColor,
        ),
      ],
    );
  }
}
