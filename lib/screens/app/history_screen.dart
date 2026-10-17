import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/engine/worm10_decision.dart';
import '../../data/models/auto_category.dart';
import '../../data/models/bot_history_entry.dart';
import '../../data/models/trade_direction.dart';
import '../../data/providers/app_providers.dart';

/// Every closed position's full record — id, direction, entry/exit price,
/// P&L, open/close signal detail, and exactly how it ended (2026-09-27,
/// per the user: "same history record for bot as tradingPionex" with
/// "termination stamp, termination reason, P&L... start signal, close
/// signal... start price, close price... everything").
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  static Future<bool> _confirmDelete(BuildContext context, {required String title, required String body}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _confirmDeleteAll(BuildContext context, WidgetRef ref) async {
    final ok = await _confirmDelete(
      context,
      title: 'Delete all history?',
      body: 'This permanently deletes every closed-position record. This cannot be undone.',
    );
    if (ok) {
      ref.read(storageProvider).deleteFileIfExists(ref.read(storageProvider).botHistoryFile);
      ref.invalidate(botHistoryProvider);
    }
  }

  Future<void> _confirmDeleteOne(BuildContext context, WidgetRef ref, BotHistoryEntry target) async {
    final ok = await _confirmDelete(
      context,
      title: 'Delete this record?',
      body: '${target.mt5Symbol} (ticket ${target.ticket}) will be permanently removed from history.',
    );
    if (ok) {
      final storage = ref.read(storageProvider);
      final remaining = storage
          .readJsonl(storage.botHistoryFile)
          .where((json) => json['id'] != target.id)
          .toList();
      storage.writeJsonl(storage.botHistoryFile, remaining);
      ref.invalidate(botHistoryProvider);
    }
  }

  static String _reasonLabel(String? stopReason) => switch (stopReason) {
    'opposite_signal' => 'Opposite signal',
    'take_profit' => 'Take profit',
    'stop_loss' => 'Stop loss',
    // 2026-10-15, per the user - added when the reconciliation mislabeling
    // bug was fixed (see engine_service.dart's own doc comment on this
    // exact stop reason): a genuine broker-forced margin stop-out is a
    // materially more serious event than a normal SL hit or a manual
    // close, so it gets its own distinct label here too, not folded into
    // either.
    'margin_stop_out' => 'Margin stop-out',
    'closed_by_user' => 'Closed by user',
    'closed_by_app' => 'Closed by app',
    // 2026-10-16, per the user: "if parent is triggered close... all copy
    // trades should be close" - a copy closed this way gets its own
    // distinct label so it's clear in History why it ended, not confused
    // with its own SL/TP hitting on its own.
    'parent_closed' => 'Closed with parent',
    // 2026-10-17 REDESIGN, per the user: the flat -$5 floor and the
    // profit-lock ratchet no longer modify the real MT5 SL - they close
    // the position directly once live P&L crosses the relevant threshold
    // (see EngineService._applySlRatchet's own doc comment on this date).
    'sll_baseline' => 'SLL: -\$5 baseline',
    'sll_ratchet' => 'SLL: ratchet lock',
    _ => 'Unknown',
  };

  static Color _reasonColor(String? stopReason, ColorScheme scheme) => switch (stopReason) {
    'opposite_signal' => Colors.blue,
    'take_profit' => Colors.green,
    'stop_loss' => Colors.red,
    'margin_stop_out' => Colors.deepOrange,
    'closed_by_user' => Colors.orange,
    'closed_by_app' => Colors.purple,
    'parent_closed' => Colors.indigo,
    'sll_baseline' || 'sll_ratchet' => Colors.red,
    _ => scheme.outline,
  };

  /// Same digit-count-by-magnitude logic as the Dashboard's own
  /// `_fmtPrice` (auto_trades_card.dart), kept separate per-file rather
  /// than shared since both are tiny, display-only formatters.
  static String _fmtPrice(double? v) {
    if (v == null) return '—';
    if (v == 0) return '0';
    if (v.abs() < 0.001) return v.toStringAsFixed(8);
    if (v.abs() < 1) return v.toStringAsFixed(5);
    return v.toStringAsFixed(v.abs() < 100 ? 4 : 2);
  }

  static String _fmtTime(DateTime? dt) {
    if (dt == null) return '—';
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  /// [epochSeconds] is a TradingView bar timestamp (UTC seconds), same as
  /// every other TV timestamp shown in this app. Shown in UTC directly -
  /// NOT routed through [_fmtTime] (which converts to local for real MT5
  /// times) - 2026-10-17, per the user: "i want app readings 100% same as
  /// my eyes" - TradingView itself displays in UTC, so converting this to
  /// local time read as a timing error when the underlying bar time was
  /// correct the whole time.
  static String _fmtBarTime(int? epochSeconds) {
    if (epochSeconds == null) return '—';
    final l = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  static String _duration(DateTime start, DateTime? end) {
    if (end == null) return '—';
    final d = end.difference(start);
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(botHistoryProvider);
    final scheme = Theme.of(context).colorScheme;
    final pnlSince = ref.watch(pnlSinceProvider);
    final pnlSinceSum = ref.watch(historyPnlSinceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete all history',
            onPressed: () => _confirmDeleteAll(context, ref),
          ),
        ],
      ),
      body: history.when(
        data: (entries) {
          if (entries.isEmpty) {
            return const Center(child: Text('No closed positions yet.'));
          }
          // 2026-09-30, per the user: a horizontal marker line showing
          // "P&L since <timestamp>" inserted at the exact point in this
          // newest-first list where entries cross the Dashboard's P&L-since
          // marker - plus a dot on a custom scrollbar track so the line's
          // position is visible without scrolling to it. [entries] is
          // sorted newest-first, so the marker sits right after the last
          // entry still newer than [pnlSince] (or at the very top/bottom if
          // every entry is on one side of it).
          final markerIndex = pnlSince == null
              ? -1
              : entries.indexWhere((e) => (e.endTime ?? e.ts).isBefore(pnlSince));
          final effectiveMarkerIndex = pnlSince == null
              ? -1
              : (markerIndex == -1 ? entries.length : markerIndex);
          final itemCount = entries.length + (effectiveMarkerIndex >= 0 ? 1 : 0);

          return Column(
            children: [
              _ReasonSummaryBar(entries: entries, scheme: scheme),
              const Divider(height: 1),
              Expanded(
                child: Stack(
                  children: [
                    ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: itemCount,
                      itemBuilder: (context, i) {
                        if (effectiveMarkerIndex >= 0 && i == effectiveMarkerIndex) {
                          return _PnlDividerLine(since: pnlSince!, sum: pnlSinceSum, scheme: scheme);
                        }
                        final entryIndex = (effectiveMarkerIndex >= 0 && i > effectiveMarkerIndex) ? i - 1 : i;
                        final target = entries[entryIndex];
                        return _HistoryCard(
                          entry: target,
                          scheme: scheme,
                          onDelete: () => _confirmDeleteOne(context, ref, target),
                        );
                      },
                    ),
                    if (effectiveMarkerIndex >= 0)
                      Positioned(
                        top: 0,
                        bottom: 0,
                        right: 2,
                        width: 10,
                        child: IgnorePointer(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final fraction = itemCount == 0 ? 0.0 : effectiveMarkerIndex / itemCount;
                              return Stack(
                                children: [
                                  Positioned(
                                    top: (fraction * constraints.maxHeight - 4).clamp(
                                      0.0,
                                      constraints.maxHeight - 8,
                                    ),
                                    child: Container(
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        color: Colors.amber,
                                        shape: BoxShape.circle,
                                        border: Border.all(color: scheme.surface, width: 1.5),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
      ),
    );
  }
}

/// The "P&L since <marker>" horizontal divider line (2026-09-30, per the
/// user: "a horizontal line ... text in center of this horizontal line").
/// Top-of-screen summary (2026-09-30, per the user: "closed by user (10) :
/// +0.1 / opposite signal (13): -12 ... and so on") - every closed
/// position grouped by [BotHistoryEntry.stopReason], each group showing
/// its count and total realized P&L.
class _ReasonSummaryBar extends StatelessWidget {
  const _ReasonSummaryBar({required this.entries, required this.scheme});

  final List<BotHistoryEntry> entries;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final counts = <String?, int>{};
    final sums = <String?, double>{};
    for (final e in entries) {
      counts[e.stopReason] = (counts[e.stopReason] ?? 0) + 1;
      sums[e.stopReason] = (sums[e.stopReason] ?? 0) + (e.realizedProfit ?? 0);
    }
    // Stable, meaningful order rather than whatever order reasons first
    // appeared in.
    const order = [
      'opposite_signal',
      'take_profit',
      'stop_loss',
      'sll_baseline',
      'sll_ratchet',
      'closed_by_user',
      'closed_by_app',
    ];
    final reasons = [
      ...order.where(counts.containsKey),
      ...counts.keys.where((r) => !order.contains(r)),
    ];

    if (reasons.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          for (final reason in reasons)
            Builder(
              builder: (context) {
                final sum = sums[reason] ?? 0;
                final color = sum < 0 ? Colors.red : sum > 0 ? Colors.green : scheme.onSurfaceVariant;
                return RichText(
                  text: TextSpan(
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    children: [
                      TextSpan(text: '${HistoryScreen._reasonLabel(reason)} (${counts[reason]}): '),
                      TextSpan(
                        text: '${sum >= 0 ? '+' : ''}${sum.toStringAsFixed(2)}',
                        style: TextStyle(color: color, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _PnlDividerLine extends StatelessWidget {
  const _PnlDividerLine({required this.since, required this.sum, required this.scheme});

  final DateTime since;
  final double sum;
  final ColorScheme scheme;

  static String _fmt(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final color = sum < 0 ? Colors.red : sum > 0 ? Colors.green : Colors.amber;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(child: Divider(color: color.withValues(alpha: 0.6), thickness: 1.5)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              'P&L since ${_fmt(since)}: ${sum >= 0 ? '+' : ''}${sum.toStringAsFixed(2)}',
              style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
            ),
          ),
          Expanded(child: Divider(color: color.withValues(alpha: 0.6), thickness: 1.5)),
        ],
      ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.entry, required this.scheme, required this.onDelete});

  final BotHistoryEntry entry;
  final ColorScheme scheme;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final profit = entry.realizedProfit;
    // 2026-10-06, per the user: "any trade with loss, card should be in
    // red. and trade with profit, card should be in green. any card with
    // zero p&l card is yellow." - a genuine zero is its own case (not
    // folded into profit, which would misleadingly green a break-even
    // trade), distinct from [profitColor] below, which keeps the EARLIER
    // green/grey/red rule for just the P&L figure's own text.
    final profitColor = profit == null
        ? scheme.onSurfaceVariant
        : profit >= 0
        ? Colors.green
        : Colors.red;
    final cardTint = profit == null
        ? null
        : profit > 0
        ? Colors.green
        : profit < 0
        ? Colors.red
        : Colors.amber;
    final directionLabel = entry.direction == TradeDirection.long ? 'BUY' : 'SELL';
    final directionColor = entry.direction == TradeDirection.long ? Colors.green : Colors.red;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: cardTint?.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: cardTint == null
            ? BorderSide.none
            : BorderSide(color: cardTint.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  entry.mt5Symbol,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: directionColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    directionLabel,
                    style: TextStyle(color: directionColor, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(entry.category.label, style: const TextStyle(fontSize: 12)),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: HistoryScreen._reasonColor(entry.stopReason, scheme).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    HistoryScreen._reasonLabel(entry.stopReason),
                    style: TextStyle(
                      color: HistoryScreen._reasonColor(entry.stopReason, scheme),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  tooltip: 'Delete this record',
                  visualDensity: VisualDensity.compact,
                  onPressed: onDelete,
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Restructured 2026-10-17, per the user's own exact spec: "open
            // trading view : close trading view: , open MT5, close MT5 /
            // open trading view reflect the open signal and it timestamp,
            // along with signal itself / close trading view reflect the
            // close signal and it timestamp, along with signal itself /
            // open mt5: open trade in mt5 and time stamp and direction and
            // volum and leverage, including entry price and all other
            // detials / close mt5: close trade in mt5 and time stamp and
            // direction and P&L in value and %, including closed price and
            // all other detials." Replaces the former "above the line"
            // (MT5 execution) / "above a Divider, below the line"
            // (TradingView signal) split - that layout mixed reasons and
            // left open which side was the actual decision (see this
            // conversation's own back-and-forth: "which one was the
            // decision - above live or below line?"). The four sections
            // below ARE now that answer, spelled out instead of implied by
            // position on the card. Close A/Close B collapse into one
            // "Close" line - per the user's own backtester spec, a
            // historical close is always already confirmed, so there's
            // nothing left to show as separately "pending."
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _section('Open TradingView', [
                    if (entry.openSignalType != null)
                      _kv(
                        worm10DisplayLabelOrRaw(entry.openSignalType) ?? '—',
                        HistoryScreen._fmtBarTime(entry.openSignalAt),
                      )
                    else
                      _kv('Signal', '—'),
                    if (entry.updateSignalType != null) ...[
                      const SizedBox(height: 6),
                      _kv(
                        'Update: ${worm10DisplayLabelOrRaw(entry.updateSignalType)}',
                        HistoryScreen._fmtBarTime(entry.updateSignalAt),
                      ),
                    ],
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _section('Close TradingView', [
                    if (entry.closeSignalType != null)
                      _kv(
                        worm10DisplayLabelOrRaw(entry.closeSignalType) ?? '—',
                        HistoryScreen._fmtBarTime(entry.closeSignalAt),
                      )
                    else
                      _kv('Signal', '— (not signal-driven)'),
                  ]),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _section('Open MT5', [
                    _kv('Opened', HistoryScreen._fmtTime(entry.startTime)),
                    const SizedBox(height: 6),
                    _kv('Direction', directionLabel, valueColor: directionColor),
                    const SizedBox(height: 6),
                    _kv('Entry price', entry.entryPrice.toString()),
                    const SizedBox(height: 6),
                    _kv('Volume', entry.volume?.toString() ?? '—'),
                    const SizedBox(height: 6),
                    _kv('Leverage', '1:2000'),
                    const SizedBox(height: 6),
                    _kv('SL / TP', '${entry.stopLoss?.toString() ?? '—'} / ${entry.takeProfit?.toString() ?? '—'}'),
                    if (entry.investmentValue != null) ...[
                      const SizedBox(height: 6),
                      _kv('Investment', '\$${entry.investmentValue!.toStringAsFixed(2)}'),
                    ],
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _section('Close MT5', [
                    _kv('Closed', HistoryScreen._fmtTime(entry.endTime)),
                    const SizedBox(height: 6),
                    _kv('Direction', directionLabel, valueColor: directionColor),
                    const SizedBox(height: 6),
                    _kv(
                      'P&L',
                      // 2026-10-14, per the user: "include the P&L value in
                      // history card once bot terminated, +11.02
                      // (+33.45%)" - same value+percent shape as the
                      // Auto-Managed Trades table's own live P&L column.
                      profit == null
                          ? '—'
                          : '${profit >= 0 ? '+' : ''}${profit.toStringAsFixed(2)}'
                                '${entry.realizedProfitPercent != null ? ' (${entry.realizedProfitPercent! >= 0 ? '+' : ''}${entry.realizedProfitPercent!.toStringAsFixed(2)}%)' : ''}',
                      valueColor: cardTint ?? profitColor,
                    ),
                    const SizedBox(height: 6),
                    _kv('Close price', entry.exitPrice?.toString() ?? '—'),
                    const SizedBox(height: 6),
                    _kv('Duration', HistoryScreen._duration(entry.startTime, entry.endTime)),
                    // SLL/Extra margin/Liquidation (2026-10-14/15, per the
                    // user) - all closing-side details, same as the P&L
                    // itself: only known/meaningful once the trade ends.
                    if (entry.sllAtTermination != null) ...[
                      const SizedBox(height: 6),
                      _kv('SLL', entry.sllAtTermination!),
                    ],
                    if (entry.extraMargin != null) ...[
                      const SizedBox(height: 6),
                      _kv('Extra margin', '\$${entry.extraMargin!.toStringAsFixed(2)}'),
                    ],
                    if (entry.liquidationPrice != null) ...[
                      const SizedBox(height: 6),
                      _kv('Liquidation', HistoryScreen._fmtPrice(entry.liquidationPrice)),
                    ],
                  ]),
                ),
              ],
            ),
            if (entry.detail != null) ...[
              const SizedBox(height: 10),
              Text(
                entry.detail!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 10),
            // 2026-09-30, per the user: "trade id should be a selectable
            // text" - the ticket number itself is SelectableText so it can
            // be copied; the "Ticket " label stays plain Text.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Ticket ',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                ),
                SelectableText(
                  '${entry.ticket}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// One of the card's four labeled blocks (Open/Close TradingView, Open/
  /// Close MT5) - a bold section title over its own small stack of [_kv]
  /// rows, visually separated so which side of the trade a given line
  /// belongs to is never ambiguous (2026-10-17, per the user's own 4-part
  /// card spec).
  Widget _section(String title, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.primary),
        ),
        const SizedBox(height: 6),
        ...rows,
      ],
    );
  }

  Widget _kv(String label, String value, {Color? valueColor}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(fontWeight: FontWeight.w600, color: valueColor),
        ),
      ],
    );
  }
}
