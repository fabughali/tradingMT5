import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/backtest_row.dart';
import '../data/mt5/mt5_client.dart';
import '../data/providers/app_providers.dart';

enum _ResolveState { idle, checking, pass, fail }

/// Technique Summary screen's "reverse calculation" backtester
/// (2026-10-17, per the user: "i want you to add in summary screen
/// (technique summary screen) i want you to add three inputs and a
/// button. in this 3 inputs user will enter: investment value, pair,
/// number of days. and button will be for execution, then app will make a
/// reverse calculations from that number of days starting from that day
/// up to now"). Re-runs the SAME real worm_10_26 decision logic against
/// historical TradingView data at the volume the user sets, leverage
/// 1:2000, same broker/MT5 rules. Queued through the live engine's own
/// existing CDP connection (not a separate one) so it can never contend
/// with live trading for chart control - per the user's own choice when
/// this trade-off was raised.
///
/// Pair is a free-text field, not limited to already-configured pairs
/// (2026-10-17, per the user: "why user have to choose from drop menu
/// list... so user can apply back test on any (listed or not listed)
/// pairs", then: "app will apply a search (same search technique used for
/// adding a pir) before applying any backtest... pair should be available
/// in both mt5 and trading view"). A pair already in config.json resolves
/// instantly (its known MT5 symbol, no network round trip); an unlisted one
/// runs the SAME MT5-catalog + TradingView-existence search [AddPairDialog]
/// uses (including its USDT->USD candidate fallback - "crypto in mt5 is
/// usd in trading view usdt") - it just never gets ADDED to config.json,
/// only resolved long enough to run this one backtest.
class BacktesterCard extends ConsumerStatefulWidget {
  const BacktesterCard({super.key});

  @override
  ConsumerState<BacktesterCard> createState() => _BacktesterCardState();
}

class _BacktesterCardState extends ConsumerState<BacktesterCard> {
  late final TextEditingController _investmentCtrl;
  late final TextEditingController _daysCtrl;
  late final TextEditingController _volumeCtrl;
  late final TextEditingController _pairCtrl;

  _ResolveState _mt5State = _ResolveState.idle;
  _ResolveState _tvState = _ResolveState.idle;
  String? _resolveDetail;
  String? _resolvedForQuery;
  String? _resolvedTvSymbol;
  String? _resolvedMt5Symbol;
  Timer? _tvPollTimer;
  int _tvPollElapsedMs = 0;
  static const _tvPollTimeout = Duration(seconds: 120);

  // 2026-10-17, per the user, found live testing a real BTC run: "once i
  // click on execute (button has no loading indicator and it is not
  // active once it is clicked).. no results... there should be a status
  // text for what is going on now" - [backtestResultProvider] only ever
  // reports 'running' once the ENGINE has actually picked the request up
  // (via [BacktestResultStore.recordRunning]), which can lag behind a
  // click by however long the engine takes to reach its next drain point -
  // normally a couple seconds, but could briefly be longer right after a
  // restart forces a full re-audit sweep. This covers that gap so the
  // button and status text react the instant the click happens, not only
  // once the engine catches up. Auto-clears once the stream shows
  // 'running' (the engine caught up) or after a short grace period either
  // way, so a stale flag can never get stuck forever.
  bool _waitingForEngine = false;
  Timer? _waitingGraceTimer;

  @override
  void initState() {
    super.initState();
    _investmentCtrl = TextEditingController(text: '100');
    _daysCtrl = TextEditingController(text: '30');
    // 2026-10-17, per the user: default volume=1 is large enough on a
    // high-priced asset (e.g. BTC) that the flat -$5 baseline SL sits only
    // a few dollars from entry - normal intra-candle noise hits it almost
    // immediately, before any real signal-to-signal close (what the user
    // sees by eye on the chart) ever gets a chance to happen. 0.01 is a
    // far more typical real position size, giving the SL real room.
    _volumeCtrl = TextEditingController(text: '0.01');
    _pairCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _tvPollTimer?.cancel();
    _waitingGraceTimer?.cancel();
    _investmentCtrl.dispose();
    _daysCtrl.dispose();
    _volumeCtrl.dispose();
    _pairCtrl.dispose();
    super.dispose();
  }

  void _markSubmitted() {
    _waitingGraceTimer?.cancel();
    setState(() => _waitingForEngine = true);
    _waitingGraceTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) setState(() => _waitingForEngine = false);
    });
  }

  void _resetResolution() {
    _tvPollTimer?.cancel();
    _mt5State = _ResolveState.idle;
    _tvState = _ResolveState.idle;
    _resolveDetail = null;
    _resolvedForQuery = null;
    _resolvedTvSymbol = null;
    _resolvedMt5Symbol = null;
  }

  Future<void> _execute() async {
    final investment = double.tryParse(_investmentCtrl.text.trim());
    final days = int.tryParse(_daysCtrl.text.trim());
    final volume = double.tryParse(_volumeCtrl.text.trim());
    final query = _pairCtrl.text.trim().toUpperCase();
    if (investment == null || investment <= 0 || days == null || days <= 0 || volume == null || volume <= 0 || query.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid investment, pair, volume, and number of days.')),
      );
      return;
    }

    // Already resolved for this exact typed pair - go straight to the run.
    if (_resolvedForQuery == query && _resolvedMt5Symbol != null && _resolvedTvSymbol != null) {
      ref.read(controlRepositoryProvider).requestBacktest(
        tvSymbol: _resolvedTvSymbol!,
        mt5Symbol: _resolvedMt5Symbol!,
        investment: investment,
        days: days,
        volume: volume,
      );
      _markSubmitted();
      return;
    }

    // Fast path: already a known pair in config.json - no search needed.
    final config = ref.read(configProvider);
    for (final m in config.symbols) {
      if (m.tradingViewSymbol.toUpperCase() == query) {
        setState(() {
          _resetResolution();
          _mt5State = _ResolveState.pass;
          _tvState = _ResolveState.pass;
          _resolveDetail = 'Already configured (${m.mt5Symbol}).';
          _resolvedForQuery = query;
          _resolvedTvSymbol = m.tradingViewSymbol;
          _resolvedMt5Symbol = m.mt5Symbol;
        });
        ref.read(controlRepositoryProvider).requestBacktest(
          tvSymbol: m.tradingViewSymbol,
          mt5Symbol: m.mt5Symbol,
          investment: investment,
          days: days,
          volume: volume,
        );
        _markSubmitted();
        return;
      }
    }

    // Unlisted pair - same MT5-catalog + TradingView-existence search as
    // Add Pair, just never written to config.json.
    await _resolveAndRun(query, investment: investment, days: days, volume: volume);
  }

  Future<void> _resolveAndRun(
    String query, {
    required double investment,
    required int days,
    required double volume,
  }) async {
    setState(() {
      _resetResolution();
      _mt5State = _ResolveState.checking;
    });

    // Same USDT->USD fallback [AddPairDialog] uses - MT5 quotes every
    // crypto pair against plain USD, never USDT (2026-10-17, per the
    // user: "crypto in mt5 is usd in trading view usdt").
    final candidates = <String>[query];
    if (query.endsWith('USDT') && query.length > 4) {
      candidates.add(query.substring(0, query.length - 1));
    }

    final storage = ref.read(storageProvider);
    final config = ref.read(configProvider);
    final env = storage.readEnvFile();
    final client = Mt5Client(
      apiKey: env['MT5_MCP_API_KEY'] ?? '',
      host: config.mt5.mcpHost,
      port: config.mt5.mcpPort,
    );
    Map<String, dynamic>? record;
    try {
      await client.connect();
      for (final candidate in candidates) {
        record = await client.findSymbolInFullCatalog(candidate);
        if (record != null) break;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mt5State = _ResolveState.fail;
        _resolveDetail = 'MT5 check failed: $e';
      });
      return;
    } finally {
      client.close();
    }
    if (!mounted) return;
    if (record == null) {
      setState(() {
        _mt5State = _ResolveState.fail;
        _resolveDetail = 'No symbol found for "$query" in MT5\'s catalog.';
      });
      return;
    }
    final mt5Symbol = record['symbol'] as String? ?? query;
    setState(() {
      _mt5State = _ResolveState.pass;
      _resolveDetail = 'Found in MT5 as "$mt5Symbol" - confirming on TradingView...';
      _tvState = _ResolveState.checking;
    });

    ref.read(controlRepositoryProvider).requestSymbolResolve(query);
    _tvPollElapsedMs = 0;
    _tvPollTimer?.cancel();
    _tvPollTimer = Timer.periodic(
      const Duration(milliseconds: 1500),
      (_) => _pollTv(query, mt5Symbol, investment: investment, days: days, volume: volume),
    );
  }

  void _pollTv(
    String tvSymbol,
    String mt5Symbol, {
    required double investment,
    required int days,
    required double volume,
  }) {
    final result = ref.read(controlRepositoryProvider).peekSymbolResolve(tvSymbol);
    _tvPollElapsedMs += 1500;
    if (result == null || result.isPending) {
      if (_tvPollElapsedMs >= _tvPollTimeout.inMilliseconds) {
        _tvPollTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _tvState = _ResolveState.fail;
          _resolveDetail = 'TradingView check timed out for "$tvSymbol".';
        });
      }
      return;
    }
    _tvPollTimer?.cancel();
    ref.read(controlRepositoryProvider).clearSymbolResolve(tvSymbol);
    if (!mounted) return;
    if (!result.isFound) {
      setState(() {
        _tvState = _ResolveState.fail;
        _resolveDetail = 'TradingView has no chart for "$tvSymbol".';
      });
      return;
    }
    final resolvedTv = result.resolvedSymbol ?? tvSymbol;
    setState(() {
      _tvState = _ResolveState.pass;
      _resolveDetail = 'Resolved: $resolvedTv -> $mt5Symbol';
      _resolvedForQuery = _pairCtrl.text.trim().toUpperCase();
      _resolvedTvSymbol = resolvedTv;
      _resolvedMt5Symbol = mt5Symbol;
    });
    ref.read(controlRepositoryProvider).requestBacktest(
      tvSymbol: resolvedTv,
      mt5Symbol: mt5Symbol,
      investment: investment,
      days: days,
      volume: volume,
    );
    _markSubmitted();
  }

  // 2026-10-17, per the user: "i want app readings 100% same as my eyes" -
  // this is a TradingView bar timestamp, shown in the SAME clock
  // TradingView itself displays (UTC) rather than converted to the
  // system's local timezone - a 3-hour local-vs-chart mismatch was
  // reading as "the app's timing isn't accurate" when the underlying bar
  // time was correct the whole time, just displayed in the wrong zone.
  String _fmtTime(int epochSeconds) {
    final l = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final backtestAsync = ref.watch(backtestResultProvider);
    final backtest = backtestAsync.asData?.value;
    final isRunning = backtest?.status == 'running';
    final isResolving = _mt5State == _ResolveState.checking || _tvState == _ResolveState.checking;
    // The engine caught up and reported 'running' itself - the local
    // grace-period flag has done its job, let the real status take over
    // (scheduled for AFTER this build via a post-frame callback, since
    // build() must stay a pure read of current state, never trigger a
    // setState of its own mid-build).
    if (_waitingForEngine && isRunning) {
      _waitingGraceTimer?.cancel();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _waitingForEngine = false);
      });
    }
    final isBusy = isRunning || isResolving || _waitingForEngine;

    return Card(
      margin: const EdgeInsets.only(top: 16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history_toggle_off, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Backtest this technique',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Re-runs the real decision logic against historical data - '
              'pure signal to signal: a trade opens on a confirmed Open '
              'signal and closes on the next opposing signal, exactly '
              'like reading the chart by eye. Does not simulate SL/TP or '
              'the live profit-lock ratchet.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _investmentCtrl,
                    enabled: !isBusy,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Investment (\$)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                // Free-text (2026-10-17, per the user: "why user have to
                // choose from drop menu list... so user can apply back
                // test on any (listed or not listed) pairs") - typing a
                // new pair re-arms resolution (see [_resetResolution]).
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _pairCtrl,
                    enabled: !isBusy,
                    textCapitalization: TextCapitalization.characters,
                    onChanged: (_) => setState(_resetResolution),
                    onSubmitted: (_) => _execute(),
                    decoration: const InputDecoration(
                      labelText: 'Pair (e.g. BTCUSDT)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _daysCtrl,
                    enabled: !isBusy,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Days back',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                // 2026-10-17, per the user's own follow-up: "in back
                // tester, make sure can adjust volum, not fixed 1" -
                // supersedes the original spec's flat v=1.
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _volumeCtrl,
                    enabled: !isBusy,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'Volume',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                // 2026-10-17, per the user: "when engine is busy, make the
                // check button disabled. when button is doing a check, make
                // loading indicator" - disabled + spinner while the engine
                // has a run in flight OR this pair is still being resolved
                // against MT5/TradingView.
                FilledButton.icon(
                  onPressed: isBusy ? null : _execute,
                  icon: isBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: Text(
                    isRunning
                        ? 'Running…'
                        : isResolving
                        ? 'Resolving…'
                        : _waitingForEngine
                        ? 'Queued…'
                        : 'Execute',
                  ),
                ),
              ],
            ),
            // Explicit status line (2026-10-17, per the user: "there
            // should be a status text for what is going on now... engine
            // busy, calculating") - spells out which phase is in progress,
            // not just a spinner with no explanation.
            if (isBusy) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text(
                    isResolving
                        ? 'Resolving this pair against MT5/TradingView…'
                        : isRunning
                        ? 'Engine is calculating the backtest…'
                        : 'Queued — waiting for the engine to pick it up…',
                    style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
            // MT5/TradingView resolution status (2026-10-17, per the user:
            // "pair should be available in both mt5 and trading view") -
            // only shown once a search for an unlisted pair has started;
            // a listed pair resolves silently and instantly.
            if (_mt5State != _ResolveState.idle) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  _ResolveChip(label: 'MT5', state: _mt5State),
                  const SizedBox(width: 8),
                  _ResolveChip(label: 'TradingView', state: _tvState),
                  if (_resolveDetail != null) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _resolveDetail!,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ],
              ),
            ],
            if (backtest?.result != null) ...[
              const SizedBox(height: 20),
              _BacktestResultView(result: backtest!.result!, fmtTime: _fmtTime),
            ],
          ],
        ),
      ),
    );
  }
}

class _BacktestResultView extends StatelessWidget {
  const _BacktestResultView({required this.result, required this.fmtTime});

  final BacktestResult result;
  final String Function(int) fmtTime;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (result.error != null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('Backtest failed: ${result.error}', style: TextStyle(color: scheme.onErrorContainer)),
      );
    }

    if (result.rows.isEmpty) {
      return Text(
        'No qualifying trades for ${result.tvSymbol} in the last ${result.days} day(s).',
        style: TextStyle(color: scheme.onSurfaceVariant),
      );
    }

    final totalColor = result.totalProfitUsd >= 0 ? Colors.green : Colors.red;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            Text(
              '${result.tvSymbol} · ${result.days}d · \$${result.investment.toStringAsFixed(2)} invested · '
              'volume ${result.volume}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(
              'Total: \$${result.totalProfitUsd.toStringAsFixed(2)} '
              '(${result.totalProfitPercent >= 0 ? '+' : ''}${result.totalProfitPercent.toStringAsFixed(2)}%)',
              style: TextStyle(color: totalColor, fontWeight: FontWeight.w700),
            ),
            Text('${result.winCount}W / ${result.lossCount}L', style: TextStyle(color: scheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columnSpacing: 20,
            columns: const [
              DataColumn(label: Text('Side')),
              DataColumn(label: Text('Open')),
              DataColumn(label: Text('Update')),
              DataColumn(label: Text('Close A')),
              DataColumn(label: Text('Close B')),
              DataColumn(label: Text('Entry')),
              DataColumn(label: Text('Exit')),
              DataColumn(label: Text('Reason')),
              DataColumn(label: Text('P&L')),
            ],
            rows: [
              for (final row in result.rows)
                DataRow(
                  cells: [
                    DataCell(
                      Text(
                        row.direction == 'buy' ? 'LONG' : 'SHORT',
                        style: TextStyle(
                          color: row.direction == 'buy' ? Colors.green : Colors.red,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    DataCell(Text('${row.openTag}\n${fmtTime(row.openAt)}', style: const TextStyle(fontSize: 11))),
                    DataCell(
                      Text(
                        row.updateTag != null ? '${row.updateTag}\n${fmtTime(row.updateAt!)}' : '—',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    DataCell(
                      Text(
                        row.stillRunning ? '—' : '${row.closeTag}\n${fmtTime(row.closeAt)}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    // Close B - always shown as already-confirmed in a
                    // backtest (2026-10-17, per the user: "close b is just
                    // for show up ... since the read is historical, then
                    // close b always confirmed") - there's nothing left to
                    // wait on for data that already happened.
                    DataCell(
                      Text(
                        row.stillRunning ? 'Still open' : 'Confirmed',
                        style: TextStyle(
                          fontSize: 11,
                          color: row.stillRunning ? Colors.amber.shade800 : scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    DataCell(Text(row.entryPrice.toStringAsFixed(5))),
                    DataCell(Text(row.exitPrice.toStringAsFixed(5))),
                    DataCell(
                      Text(
                        switch (row.exitReason) {
                          'signal_close' => 'Signal',
                          _ => 'Still running',
                        },
                      ),
                    ),
                    DataCell(
                      Text(
                        '\$${row.profitUsd.toStringAsFixed(2)} '
                        '(${row.profitPercent >= 0 ? '+' : ''}${row.profitPercent.toStringAsFixed(2)}%)',
                        style: TextStyle(
                          color: row.profitUsd >= 0 ? Colors.green : Colors.red,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Small pass/checking/fail indicator for the Pair field's MT5/TradingView
/// resolution (2026-10-17) - same shape as [AddPairDialog]'s own
/// `_CheckRow`, just compact enough to sit inline next to the Execute
/// button instead of its own stacked dialog rows.
class _ResolveChip extends StatelessWidget {
  const _ResolveChip({required this.label, required this.state});

  final String label;
  final _ResolveState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget icon;
    switch (state) {
      case _ResolveState.idle:
        icon = Icon(Icons.circle_outlined, size: 14, color: scheme.outlineVariant);
      case _ResolveState.checking:
        icon = const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2));
      case _ResolveState.pass:
        icon = const Icon(Icons.check_circle, size: 14, color: Colors.green);
      case _ResolveState.fail:
        icon = Icon(Icons.cancel, size: 14, color: scheme.error);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [icon, const SizedBox(width: 4), Text(label, style: const TextStyle(fontSize: 12))],
    );
  }
}
