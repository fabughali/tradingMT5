import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_storage.dart';
import '../data/identity/pnl_series_store.dart';
import '../data/models/auto_trade_row.dart';
import '../data/providers/app_providers.dart';
import 'pnl_chart.dart';

/// Live P&L chart for one running trade (2026-10-25, per the user: "chart
/// need to act instantly according to changes in P&L"). The engine's
/// recorded series (every SLL sweep) plus every 5s Dashboard poll of the
/// same position, so the line moves as the P&L moves.
Future<void> showLivePnlDialog(BuildContext context, AutoTradeRow row) => showDialog<void>(
  context: context,
  builder: (_) => _LivePnlDialog(ticket: row.ticket!, title: '${row.mt5Symbol} #${row.ticket}'),
);

class _LivePnlDialog extends ConsumerStatefulWidget {
  const _LivePnlDialog({required this.ticket, required this.title});

  final int ticket;
  final String title;

  @override
  ConsumerState<_LivePnlDialog> createState() => _LivePnlDialogState();
}

class _LivePnlDialogState extends ConsumerState<_LivePnlDialog> {
  late final PnlSeriesStore _store = PnlSeriesStore(CoreStorage.instance);
  List<PnlPoint> _recorded = const [];
  final List<PnlPoint> _live = [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _reload();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _reload());
  }

  void _reload() {
    final recorded = _store.read(widget.ticket);
    if (!mounted) return;
    setState(() => _recorded = recorded);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = ref.watch(autoTradesProvider).value ?? const <AutoTradeRow>[];
    final row = rows.where((r) => r.ticket == widget.ticket).firstOrNull;
    if (row?.profit != null) {
      final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      final last = _live.isEmpty ? null : _live.last;
      if (last == null || last.profit != row!.profit || now - last.time >= 5) {
        _live.add(PnlPoint(time: now, profit: row!.profit!, percent: row.pnlPercent));
      }
    }
    final lastRecorded = _recorded.isEmpty ? 0 : _recorded.last.time;
    final points = [..._recorded, ..._live.where((p) => p.time > lastRecorded)];
    final current = points.isEmpty ? null : points.last;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (current != null)
              Text(
                '${current.profit >= 0 ? '+' : ''}${current.profit.toStringAsFixed(2)}'
                '${current.percent == null ? '' : '  (${current.percent! >= 0 ? '+' : ''}${current.percent!.toStringAsFixed(2)}%)'}',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: current.profit >= 0 ? Colors.green : Colors.red,
                ),
              ),
            if (row == null)
              Text('Trade no longer open.', style: TextStyle(color: scheme.outline)),
            const SizedBox(height: 10),
            PnlChart(points: points, height: 220),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
    );
  }
}
