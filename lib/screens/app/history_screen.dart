import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/core_storage.dart';
import '../../data/engine/worm10_decision.dart';
import '../../data/identity/pnl_series_store.dart';
import '../../data/models/auto_category.dart';
import '../../data/models/bot_history_entry.dart';
import '../../data/models/trade_direction.dart';
import '../../data/providers/app_providers.dart';
import '../../widgets/pnl_chart.dart';

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
    // 2026-10-21, per the user ("BNB trade ... the reason is unknown"): the
    // engine has written this reason since the worm10 technique shipped,
    // but it was never given a label here - 39 recycles showed "Unknown".
    'worm10_recycle' => 'Recycled (same signal)',
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
    'worm10_recycle' => Colors.teal,
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
          final filter = ref.watch(_historyFilterProvider);
          final shown = entries.where((e) => switch (filter) {
            _HistoryFilter.all => true,
            _HistoryFilter.wins => (e.realizedProfit ?? 0) > 0,
            _HistoryFilter.losses => (e.realizedProfit ?? 0) < 0,
          }).toList();
          final markerIndex = pnlSince == null
              ? -1
              : shown.indexWhere((e) => (e.endTime ?? e.ts).isBefore(pnlSince));
          final effectiveMarkerIndex = pnlSince == null
              ? -1
              : (markerIndex == -1 ? shown.length : markerIndex);
          final itemCount = shown.length + (effectiveMarkerIndex >= 0 ? 1 : 0);

          return Column(
            children: [
              _TotalsBar(
                entries: entries,
                scheme: scheme,
                filter: filter,
                onFilter: ref.read(_historyFilterProvider.notifier).set,
              ),
              _ReasonSummaryBar(entries: entries, scheme: scheme),
              const Divider(height: 1),
              Expanded(
                child: Stack(
                  children: [
                    // Wrapped grid, up to 3 cards per row (2026-10-25, per
                    // the user), built a row at a time so long histories
                    // stay lazy; the "P&L since" divider keeps its own row.
                    LayoutBuilder(
                      builder: (context, constraints) {
                        const gap = 10.0;
                        final usable = constraints.maxWidth - 24;
                        final cols = (usable / 360).floor().clamp(1, 3);
                        final cardWidth = (usable - gap * (cols - 1)) / cols;
                        final rows = <Object>[];
                        var group = <BotHistoryEntry>[];
                        void flush() {
                          for (var i = 0; i < group.length; i += cols) {
                            rows.add(group.sublist(i, (i + cols).clamp(0, group.length)));
                          }
                          group = [];
                        }

                        for (var i = 0; i < itemCount; i++) {
                          if (effectiveMarkerIndex >= 0 && i == effectiveMarkerIndex) {
                            flush();
                            rows.add('marker');
                            continue;
                          }
                          final entryIndex = (effectiveMarkerIndex >= 0 && i > effectiveMarkerIndex) ? i - 1 : i;
                          group.add(shown[entryIndex]);
                        }
                        flush();
                        return ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: rows.length,
                          itemBuilder: (context, i) {
                            final row = rows[i];
                            if (row is! List<BotHistoryEntry>) {
                              return _PnlDividerLine(since: pnlSince!, sum: pnlSinceSum, scheme: scheme);
                            }
                            return Padding(
                              padding: const EdgeInsets.only(bottom: gap),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (var c = 0; c < row.length; c++) ...[
                                    if (c > 0) const SizedBox(width: gap),
                                    SizedBox(
                                      width: cardWidth,
                                      child: _HistoryCard(
                                        entry: row[c],
                                        scheme: scheme,
                                        onDelete: () => _confirmDeleteOne(context, ref, row[c]),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          },
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
      'worm10_recycle',
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


enum _HistoryFilter { all, wins, losses }

class _HistoryFilterNotifier extends Notifier<_HistoryFilter> {
  @override
  _HistoryFilter build() => _HistoryFilter.all;

  void set(_HistoryFilter filter) => state = filter;
}

final _historyFilterProvider = NotifierProvider<_HistoryFilterNotifier, _HistoryFilter>(_HistoryFilterNotifier.new);

/// "42 closed · win 26 · loss 16 · net +18.40" plus the All/Wins/Losses
/// filter (2026-10-25 History redesign).
class _TotalsBar extends StatelessWidget {
  const _TotalsBar({required this.entries, required this.scheme, required this.filter, required this.onFilter});

  final List<BotHistoryEntry> entries;
  final ColorScheme scheme;
  final _HistoryFilter filter;
  final void Function(_HistoryFilter) onFilter;

  @override
  Widget build(BuildContext context) {
    final wins = entries.where((e) => (e.realizedProfit ?? 0) > 0).length;
    final losses = entries.where((e) => (e.realizedProfit ?? 0) < 0).length;
    final net = entries.fold<double>(0, (s, e) => s + (e.realizedProfit ?? 0));
    final netColor = net > 0 ? Colors.green : net < 0 ? Colors.red : scheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                children: [
                  TextSpan(text: '${entries.length} closed  ·  win $wins  ·  loss $losses  ·  net '),
                  TextSpan(
                    text: '${net >= 0 ? '+' : ''}${net.toStringAsFixed(2)}',
                    style: TextStyle(color: netColor, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
          SegmentedButton<_HistoryFilter>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: const [
              ButtonSegment(value: _HistoryFilter.all, label: Text('All')),
              ButtonSegment(value: _HistoryFilter.wins, label: Text('Wins')),
              ButtonSegment(value: _HistoryFilter.losses, label: Text('Losses')),
            ],
            selected: {filter},
            onSelectionChanged: (s) => onFilter(s.first),
          ),
        ],
      ),
    );
  }
}

/// One closed trade (2026-10-25 redesign, per the user: "history card should
/// be wrapped list 3 cards per each row" + "there should be a below section
/// in each card ... for details about anything required ... like: remarks,
/// more details about close or status"). Same style as the Dashboard's
/// running cards: green / red / neutral by realized P&L; header with pair,
/// side, leverage, close-reason chip and a more menu (signal trace, delete);
/// investment and realized P&L; the P&L chart; three equal columns (open /
/// close / trade); a bottom remarks section.
class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.entry, required this.scheme, required this.onDelete});

  final BotHistoryEntry entry;
  final ColorScheme scheme;
  final VoidCallback onDelete;

  static String _short(DateTime? dt) {
    if (dt == null) return '—';
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  /// TradingView bar time, UTC (same rule as [HistoryScreen._fmtBarTime]).
  static String _shortBar(int? epochSeconds) {
    if (epochSeconds == null) return '';
    final l = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  static String _signal(String? type, int? at) =>
      type == null ? '—' : '${worm10DisplayLabelOrRaw(type)} ${_shortBar(at)}'.trim();

  static String _money(double? v) => v == null ? '—' : '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)}';

  /// The close explained in plain words, for the remarks section.
  static String _closeExplained(String? stopReason) => switch (stopReason) {
    'opposite_signal' => 'An opposite signal closed it.',
    'worm10_recycle' => 'The same open signal fired again - closed and reopened fresh.',
    'take_profit' => 'MT5 hit the take-profit price.',
    'stop_loss' => 'MT5 hit the stop-loss price.',
    'margin_stop_out' => 'The broker closed it at its margin stop-out level.',
    'closed_by_user' => 'Closed by you (Dashboard or MT5).',
    'closed_by_app' => 'Closed by the app.',
    'parent_closed' => 'Closed together with its parent trade.',
    'sll_ratchet' => 'SLL closed it after profit fell back to the locked level.',
    'sll_baseline' => 'Old -\$5 SLL baseline close (before v1.6.38).',
    _ => 'Close reason not recorded.',
  };

  Widget _label(String text) =>
      Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant));

  Widget _value(String text, {Color? color}) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(fontSize: 12, color: color),
  );

  Widget _cell(String label, String value, {Color? color}) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [_label(label), const SizedBox(height: 1), _value(value, color: color)],
    ),
  );

  Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(5)),
    child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
  );

  void _showTrace(BuildContext context) {
    final trace = entry.signalTrace ?? const <Map<String, dynamic>>[];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${entry.mt5Symbol} #${entry.ticket} - signal trace'),
        content: SizedBox(
          width: 520,
          child: trace.isEmpty
              ? const Text('No signal trace recorded (trades closed before v1.6.43 have none).')
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final t in trace)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: SelectableText(_traceLine(t), style: const TextStyle(fontSize: 12)),
                        ),
                    ],
                  ),
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final profit = entry.realizedProfit;
    final tint = profit == null || profit == 0 ? null : (profit > 0 ? Colors.green : Colors.red);
    final pnlColor = tint == null ? scheme.onSurface : (profit! > 0 ? Colors.green.shade700 : Colors.red.shade700);
    final isLong = entry.direction == TradeDirection.long;
    final reasonColor = HistoryScreen._reasonColor(entry.stopReason, scheme);

    final points = PnlSeriesStore(CoreStorage.instance).read(entry.ticket);
    final end = entry.endTime;
    if (points.isNotEmpty && end != null && profit != null) {
      final t = end.toUtc().millisecondsSinceEpoch ~/ 1000;
      if (t > points.last.time) {
        points.add(PnlPoint(time: t, profit: profit, percent: entry.realizedProfitPercent));
      }
    }
    final maxPnl = points.isEmpty ? null : points.map((p) => p.profit).reduce((a, b) => a > b ? a : b);
    final minPnl = points.isEmpty ? null : points.map((p) => p.profit).reduce((a, b) => a < b ? a : b);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: tint?.withValues(alpha: 0.08) ?? scheme.surfaceContainerLow,
        border: Border.all(color: tint?.withValues(alpha: 0.7) ?? scheme.outlineVariant, width: tint == null ? 1 : 1.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(entry.mt5Symbol, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                    ),
                    _badge(isLong ? 'LONG' : 'SHORT', isLong ? Colors.green : Colors.red),
                    _badge('1:2000', scheme.outline),
                    _badge(HistoryScreen._reasonLabel(entry.stopReason), reasonColor),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'More',
                onSelected: (v) => v == 'trace' ? _showTrace(context) : onDelete(),
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'trace',
                    child: Row(children: [Icon(Icons.timeline, size: 20), SizedBox(width: 10), Text('Signal trace')]),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete_outline, size: 20, color: Colors.red),
                        SizedBox(width: 10),
                        Text('Delete record', style: TextStyle(color: Colors.red)),
                      ],
                    ),
                  ),
                ],
                child: Icon(Icons.more_vert, size: 20, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Wrap(
            children: [
              SelectableText(
                '#${entry.ticket}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
              Text(
                '  ·  ${entry.category.label}  ·  ${HistoryScreen._duration(entry.startTime, entry.endTime)}',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _label('Investment'),
                          _value(entry.investmentValue == null ? '—' : '\$${entry.investmentValue!.toStringAsFixed(2)}'),
                        ],
                      ),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      color: (tint ?? scheme.outline).withValues(alpha: 0.12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _label('Realized P&L'),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${_money(profit)}'
                              '${entry.realizedProfitPercent == null ? '' : ' (${entry.realizedProfitPercent! >= 0 ? '+' : ''}${entry.realizedProfitPercent!.toStringAsFixed(2)}%)'}',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: pnlColor),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (points.length >= 2)
            PnlChart(points: points, height: 110)
          else
            SizedBox(
              height: 40,
              child: Center(
                child: Text(
                  'No P&L chart recorded for this trade',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ),
            ),
          const SizedBox(height: 10),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _cell('Opened', _short(entry.startTime)),
                      _cell('Entry', HistoryScreen._fmtPrice(entry.entryPrice)),
                      _cell('Open signal', _signal(entry.openSignalType, entry.openSignalAt)),
                    ],
                  ),
                ),
                VerticalDivider(width: 14, color: scheme.outlineVariant),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _cell('Closed', _short(entry.endTime)),
                      _cell('Close price', HistoryScreen._fmtPrice(entry.exitPrice)),
                      _cell('Close signal', _signal(entry.closeSignalType, entry.closeSignalAt)),
                    ],
                  ),
                ),
                VerticalDivider(width: 14, color: scheme.outlineVariant),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _cell('Volume', entry.volume?.toString() ?? '—'),
                      _cell(
                        'SL / TP',
                        '${HistoryScreen._fmtPrice(entry.stopLoss)} / ${HistoryScreen._fmtPrice(entry.takeProfit)}',
                      ),
                      _cell('Max / min P&L', maxPnl == null ? '—' : '${_money(maxPnl)} / ${_money(minPnl)}'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Bottom remarks section (2026-10-25, per the user: "a below
          // section in each card ... for details about anything required").
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _label('Remarks'),
                const SizedBox(height: 2),
                Text(_closeExplained(entry.stopReason), style: const TextStyle(fontSize: 12)),
                if (entry.detail != null) ...[
                  const SizedBox(height: 2),
                  Text(entry.detail!, style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ],
                const SizedBox(height: 4),
                Wrap(
                  spacing: 12,
                  runSpacing: 2,
                  children: [
                    if (entry.updateSignalType != null)
                      Text(
                        'Update: ${_signal(entry.updateSignalType, entry.updateSignalAt)}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    Text('SLL at close: ${entry.sllAtTermination ?? '—'}', style: const TextStyle(fontSize: 11)),
                    if (entry.extraMargin != null)
                      Text('Extra margin: \$${entry.extraMargin!.toStringAsFixed(2)}', style: const TextStyle(fontSize: 11)),
                    if (entry.liquidationPrice != null)
                      Text(
                        'Liquidation: ${HistoryScreen._fmtPrice(entry.liquidationPrice)}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    if (entry.signalTrace != null)
                      Text('Trace: ${entry.signalTrace!.length} events', style: const TextStyle(fontSize: 11)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// One trace line: "2026-10-25 14:08:00  Close  LL @ bar time  (opposite_signal)".
  String _traceLine(Map<String, dynamic> t) {
    final at = DateTime.tryParse(t['at'] as String? ?? '');
    final action = switch (t['action'] as String?) {
      'open' => 'Open',
      'open_late_fill' => 'Open (late fill)',
      'open_backfilled' => 'Open (recorded by audit)',
      'open_corrected' => 'Open corrected',
      'update' => 'Update',
      'close' => 'Close',
      final other => other ?? '?',
    };
    final signal = t['signal'] as String?;
    final bar = (t['bar_time'] as num?)?.toInt();
    final note = t['note'] as String?;
    return [
      HistoryScreen._fmtTime(at?.toLocal()),
      action,
      if (signal != null) '${worm10DisplayLabelOrRaw(signal)} @ ${HistoryScreen._fmtBarTime(bar)}',
      if (note != null) '($note)',
    ].join('  ');
  }
}
