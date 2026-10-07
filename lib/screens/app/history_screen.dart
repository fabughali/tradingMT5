import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
    'closed_by_user' => 'Closed by user',
    'closed_by_app' => 'Closed by app',
    _ => 'Unknown',
  };

  static Color _reasonColor(String? stopReason, ColorScheme scheme) => switch (stopReason) {
    'opposite_signal' => Colors.blue,
    'take_profit' => Colors.green,
    'stop_loss' => Colors.red,
    'closed_by_user' => Colors.orange,
    'closed_by_app' => Colors.purple,
    _ => scheme.outline,
  };

  static String _fmtTime(DateTime? dt) {
    if (dt == null) return '—';
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  /// [epochSeconds] is a TradingView bar timestamp (UTC seconds), same as
  /// every other TV timestamp shown in this app.
  static String _fmtBarTime(int? epochSeconds) {
    if (epochSeconds == null) return '—';
    return _fmtTime(DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true));
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
    const order = ['opposite_signal', 'take_profit', 'stop_loss', 'closed_by_user', 'closed_by_app'];
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
            Row(
              children: [
                Expanded(
                  // 2026-10-06, per the user: "keep same naming as auto
                  // table .. open price, close price .. so title naming
                  // should match with auto table" - was "Entry"/"Exit".
                  child: _kv('Open price', entry.entryPrice.toString()),
                ),
                Expanded(
                  child: _kv('Close price', entry.exitPrice?.toString() ?? '—'),
                ),
                Expanded(
                  child: _kv(
                    'P&L',
                    profit == null ? '—' : '${profit >= 0 ? '+' : ''}${profit.toStringAsFixed(2)}',
                    valueColor: cardTint ?? profitColor,
                  ),
                ),
              ],
            ),
            // 2026-10-06, per the user: "add volume to history ... also add
            // tp/sl trigger entry price too ... everything should be
            // recorded" - the lot size and SL/TP levels this trade was
            // actually opened with. Null (entries written before these
            // fields existed) shows as "—", never backfilled.
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _kv('Volume', entry.volume?.toString() ?? '—'),
                ),
                Expanded(
                  child: _kv('SL', entry.stopLoss?.toString() ?? '—'),
                ),
                Expanded(
                  child: _kv('TP', entry.takeProfit?.toString() ?? '—'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(child: _kv('Opened', HistoryScreen._fmtTime(entry.startTime))),
                Expanded(child: _kv('Closed', HistoryScreen._fmtTime(entry.endTime))),
                Expanded(child: _kv('Duration', HistoryScreen._duration(entry.startTime, entry.endTime))),
              ],
            ),
            // 2026-10-06, per the user: "i want history to include open
            // signal, update signal, close A signal, close b signal ...
            // and with timestamp (trading view timestamp)" / "everything
            // should be traced" - same Open/Update/Close A/Close B naming
            // as the Auto-Managed Trades table's own columns, every one
            // carrying its TradingView bar timestamp via [_fmtBarTime]
            // (same UTC-bar-time-to-local conversion used everywhere else
            // in the app). "Opened on" (no timestamp) is gone - was
            // missing the one thing this whole section exists to show.
            if (entry.openSignalType != null) ...[
              const Divider(height: 20),
              Text(
                'Open: ${entry.openSignalType} @ ${HistoryScreen._fmtBarTime(entry.openSignalAt)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (entry.updateSignalType != null) ...[
              const SizedBox(height: 2),
              Text(
                'Update: ${entry.updateSignalType} @ ${HistoryScreen._fmtBarTime(entry.updateSignalAt)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            // 2026-09-30, per the user: "Close A" is the candle that
            // carried the disagreeing signal (unchanged data - still
            // [entry.closeSignalType]/[closeSignalAt], just relabeled to
            // match the new "survive one extra candle" confirmation rule's
            // own terminology); "Close B" is the candle right after it
            // coming up empty, which is exactly what actually let the
            // close execute - [entry.endTime] IS that confirmation moment,
            // no new field needed. Only ever populated together, since
            // both only apply to a genuinely signal-driven close
            // (stopReason 'opposite_signal').
            if (entry.closeSignalType != null) ...[
              const SizedBox(height: 4),
              Text(
                'Close A: ${entry.closeSignalType} @ ${HistoryScreen._fmtBarTime(entry.closeSignalAt)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 2),
              Text(
                'Close B: confirmed empty @ ${HistoryScreen._fmtTime(entry.endTime)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (entry.detail != null) ...[
              const SizedBox(height: 6),
              Text(
                entry.detail!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 4),
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
