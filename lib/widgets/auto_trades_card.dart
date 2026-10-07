import 'package:flutter/material.dart';

import '../data/models/auto_category.dart';
import '../data/models/auto_trade_row.dart';
import '../utilities/auto_cycle.dart';

/// Dashboard card (2026-09-29, per the user: "a table .. a list of
/// currenly running trades, filled trades, waiting trades", extended the
/// same day with start/update signal columns, duration, a per-row Auto/Last
/// toggle + power/terminate icon, an account-numbers strip, and a cycling
/// sort button) — one row per symbol in [AppConfig.symbols], showing
/// whether it's a real running position (filled), a resting pending order
/// (waiting to trigger), or still waiting for a confirmed signal.
class AutoTradesCard extends StatefulWidget {
  const AutoTradesCard({
    super.key,
    required this.rows,
    required this.onToggleAuto,
    required this.onToggleLast,
    required this.onTerminate,
    required this.onChangeVolume,
    required this.historyPnlSince,
    required this.pnlSinceTimestamp,
    required this.onResetPnlSince,
    required this.liveAccountPnl,
  });

  final List<AutoTradeRow> rows;

  /// tvSymbol, new Auto state.
  final void Function(String, bool) onToggleAuto;

  /// tvSymbol, new Last state.
  final void Function(String, bool) onToggleLast;

  /// tvSymbol — terminate this pair's current trade right now.
  final void Function(String) onTerminate;

  /// tvSymbol, new desired volume (2026-10-03, per the user) — the target
  /// size for this pair's NEXT open. Never touches a currently-running
  /// trade's own size.
  final void Function(String, double) onChangeVolume;

  /// Realized (history-based, NOT live) P&L summed since [pnlSinceTimestamp]
  /// (2026-09-30, per the user). Null timestamp means "since the
  /// beginning" (never reset).
  final double historyPnlSince;
  final DateTime? pnlSinceTimestamp;
  final VoidCallback onResetPnlSince;

  /// The SAME live floating P&L the Engine status section shows
  /// (`equity - balance`, whole account) - added 2026-10-06, per the user:
  /// "i want p&L in auto is similar as in engine" / "same number" -
  /// explicitly NOT a replacement for [historyPnlSince] ("dont touch p&l
  /// for history timestamp"), just a second, separate figure sitting next
  /// to it so both are visible at once. Null while the account snapshot
  /// hasn't loaded yet.
  final double? liveAccountPnl;

  @override
  State<AutoTradesCard> createState() => _AutoTradesCardState();
}

/// Cycle order (2026-09-29, per the user: "a-z, if clicked again z-a, again
/// positive P&L, again negative P&L", extended same-day with "add duration
/// sorting") - tapping the sort icon advances one step through this list,
/// wrapping back to [symbolAsc] after [durationDesc]. Kept as UI-only state
/// (not persisted) - purely a local re-sort of whatever rows the provider
/// already yielded, same as sorting any other table.
enum _SortMode { symbolAsc, symbolDesc, plDesc, plAsc, durationDesc }

extension on _SortMode {
  _SortMode get next => switch (this) {
    _SortMode.symbolAsc => _SortMode.symbolDesc,
    _SortMode.symbolDesc => _SortMode.plDesc,
    _SortMode.plDesc => _SortMode.plAsc,
    _SortMode.plAsc => _SortMode.durationDesc,
    _SortMode.durationDesc => _SortMode.symbolAsc,
  };

  IconData get icon => switch (this) {
    _SortMode.symbolAsc => Icons.arrow_upward,
    _SortMode.symbolDesc => Icons.arrow_downward,
    _SortMode.plDesc => Icons.trending_up,
    _SortMode.plAsc => Icons.trending_down,
    _SortMode.durationDesc => Icons.timer_outlined,
  };

  String get label => switch (this) {
    _SortMode.symbolAsc => 'Sorted A-Z (tap for Z-A)',
    _SortMode.symbolDesc => 'Sorted Z-A (tap for P&L high-to-low)',
    _SortMode.plDesc => 'Sorted P&L high-to-low (tap for low-to-high)',
    _SortMode.plAsc => 'Sorted P&L low-to-high (tap for longest-running)',
    _SortMode.durationDesc => 'Sorted longest-running first (tap for A-Z)',
  };
}

class _AutoTradesCardState extends State<AutoTradesCard> {
  _SortMode _sortMode = _SortMode.symbolAsc;

  Future<void> _confirmResetPnlSince(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset P&L tracking?'),
        content: const Text(
          'This marks right now as the new starting point. P&L shown here and in '
          'History will only count trades closed after this moment - already-counted '
          'history is not lost, just no longer included in this running total.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onResetPnlSince();
  }

  List<AutoTradeRow> _sorted(List<AutoTradeRow> rows) {
    final out = [...rows];
    switch (_sortMode) {
      case _SortMode.symbolAsc:
        out.sort((a, b) => a.tvSymbol.compareTo(b.tvSymbol));
      case _SortMode.symbolDesc:
        out.sort((a, b) => b.tvSymbol.compareTo(a.tvSymbol));
      case _SortMode.plDesc:
        // Highest positive P&L first; rows with no P&L (waiting/pending)
        // sink to the bottom regardless of direction.
        out.sort((a, b) {
          if (a.profit == null && b.profit == null) return 0;
          if (a.profit == null) return 1;
          if (b.profit == null) return -1;
          return b.profit!.compareTo(a.profit!);
        });
      case _SortMode.plAsc:
        // Most negative P&L first; rows with no P&L still sink to the
        // bottom rather than being treated as "more negative than real
        // losses."
        out.sort((a, b) {
          if (a.profit == null && b.profit == null) return 0;
          if (a.profit == null) return 1;
          if (b.profit == null) return -1;
          return a.profit!.compareTo(b.profit!);
        });
      case _SortMode.durationDesc:
        // Longest-running trade first; rows with no open time (waiting/
        // pending) sink to the bottom.
        out.sort((a, b) {
          if (a.openedAt == null && b.openedAt == null) return 0;
          if (a.openedAt == null) return 1;
          if (b.openedAt == null) return -1;
          return a.openedAt!.compareTo(b.openedAt!);
        });
    }
    return out;
  }

  /// [waitingReason] (2026-09-29, per the user: "waiting pairs should
  /// reflect exact reason ... not guess ... for example (not enough
  /// margin)") replaces the generic "Waiting · no signal" label with the
  /// broker's own literal rejection text whenever one is on record.
  static (String, Color) _statusLabel(AutoTradeRow row, ColorScheme scheme) =>
      switch (row.status) {
        AutoTradeStatus.running => ('Running', Colors.green),
        AutoTradeStatus.waitingPending => ('Waiting · pending order', Colors.orange),
        AutoTradeStatus.waitingNoSignal => (
          row.waitingReason != null ? 'Waiting · ${row.waitingReason}' : 'Waiting · no signal',
          row.waitingReason != null ? Colors.red : scheme.outline,
        ),
      };

  static String _fmtPrice(double? v) {
    if (v == null) return '—';
    if (v == 0) return '0';
    if (v.abs() < 0.001) return v.toStringAsFixed(8);
    if (v.abs() < 1) return v.toStringAsFixed(5);
    return v.toStringAsFixed(v.abs() < 100 ? 4 : 2);
  }

  static String _fmtTag(String? tag) => tag == null ? '—' : tag.toUpperCase();

  /// Trims trailing zeros rather than a fixed decimal count, since volume
  /// steps vary wildly by symbol (e.g. BTCUSD.lv 0.001 vs XRPUSD.lv 100 -
  /// see [WatchedSymbol]'s own doc comment).
  static String _fmtVolume(double v) {
    var s = v.toStringAsFixed(3);
    while (s.contains('.') && s.endsWith('0')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
  }

  /// [epochSeconds] is a TradingView bar timestamp (UTC seconds) — same
  /// clock as every other TV timestamp already shown in this app
  /// (see [BotHistoryEntry]'s open/close signal times).
  static String _fmtTvTime(int? epochSeconds) {
    if (epochSeconds == null) return '';
    final l = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  /// Same format as [_fmtTvTime] but for an already-resolved [DateTime]
  /// (Close B's ETA) rather than a raw TV bar timestamp.
  static String _fmtTvTimeExact(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  /// Full date+time (not just month/day like [_fmtTvTimeExact]) - the
  /// P&L-since marker can be days old, so the year/date matters here.
  static String _fmtSinceTimestamp(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  static String _fmtDuration(DateTime? openedAt) {
    if (openedAt == null) return '—';
    final d = DateTime.now().difference(openedAt);
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours % 24}h';
    if (d.inHours > 0) return '${d.inHours}h ${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '${d.inMinutes}m ${d.inSeconds % 60}s';
    return '${d.inSeconds}s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = _sorted(widget.rows);
    final running = rows.where((r) => r.status == AutoTradeStatus.running).length;
    final pending = rows.where((r) => r.status == AutoTradeStatus.waitingPending).length;
    final noSignal = rows.where((r) => r.status == AutoTradeStatus.waitingNoSignal).length;

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Auto-Managed Trades', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(_sortMode.icon, size: 18),
                  tooltip: _sortMode.label,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _sortMode = _sortMode.next),
                ),
                const Spacer(),
                Text(
                  '$running running · $pending pending · $noSignal waiting',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                // Live P&L (2026-10-06, per the user: "i want p&L in auto
                // is similar as in engine" / "same number" / "i need only
                // one number. engine number") - this IS now the Engine
                // status section's own equity-balance number, replacing
                // the card's former separate figure (sum of this card's
                // own rows' profit) entirely rather than sitting next to
                // it. The "Since timestamp" realized tracker below is a
                // different, untouched thing - "dont touch p&l for history
                // timestamp".
                if (widget.liveAccountPnl != null) ...[
                  const SizedBox(width: 10),
                  Text(
                    '${widget.liveAccountPnl! >= 0 ? '+' : ''}'
                    '${widget.liveAccountPnl!.toStringAsFixed(2)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: widget.liveAccountPnl! < 0
                          ? Colors.red
                          : widget.liveAccountPnl! > 0
                          ? Colors.green
                          : Colors.amber,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
            // P&L-since tracker (2026-09-30, per the user: "add a new text
            // with time stamp of history and P&L after this time stamp
            // ... an icon ... press on it, it will reset time stamp ...
            // the P&L calculations will be from history not from live").
            Padding(
              padding: const EdgeInsets.only(top: 2),
              // 2026-09-30, per the user: this row must sit at the right
              // edge, same as the summary row above it - switched from a
              // leading Spacer() to Align+mainAxisSize.min, which forces
              // the group to hug the right edge regardless of any
              // assumption about how much space the Row is actually given.
              child: Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                  Text(
                    widget.pnlSinceTimestamp == null
                        ? 'Since: all history'
                        : 'Since ${_fmtSinceTimestamp(widget.pnlSinceTimestamp!)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${widget.historyPnlSince >= 0 ? '+' : ''}${widget.historyPnlSince.toStringAsFixed(2)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: widget.historyPnlSince < 0
                          ? Colors.red
                          : widget.historyPnlSince > 0
                          ? Colors.green
                          : Colors.amber,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.restart_alt, size: 16),
                    tooltip: 'Reset P&L tracking to now',
                    visualDensity: VisualDensity.compact,
                    // 2026-09-30, per the user: "show a dialog once history
                    // reset icon clicked. so if user click this icon by
                    // mistake, nothing change."
                    onPressed: () => _confirmResetPnlSince(context),
                  ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No symbols configured yet.'),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 32,
                  // 2026-10-04, per the user: "dont cut the text for reason
                  // of waiting or not opening ... make sure there is a
                  // spacing between each row content and horizontal lines" -
                  // raised from 36 so every row (wrapped or not) gets more
                  // breathing room against the divider lines, and max height
                  // is now unbounded (was a fixed 56) so a long wrapped
                  // rejection reason can never be clipped, however many
                  // lines it needs.
                  dataRowMinHeight: 48,
                  dataRowMaxHeight: double.infinity,
                  // Tightened from 18, per the user: "status text is
                  // pushing all other next columns ... table should fit in
                  // screen width" - reclaims a little width on every one of
                  // the table's ~18 columns, which adds up.
                  columnSpacing: 14,
                  columns: const [
                    DataColumn(label: Text('Symbol')),
                    DataColumn(label: Text('Trade ID')),
                    DataColumn(label: Text('Status')),
                    DataColumn(label: Text('Side')),
                    DataColumn(label: Text('Price')),
                    DataColumn(label: Text('SL')),
                    DataColumn(label: Text('TP')),
                    DataColumn(label: Text('P&L')),
                    DataColumn(label: Center(child: Text('Volume'))),
                    DataColumn(label: Text('Open')),
                    DataColumn(label: Text('Update')),
                    DataColumn(label: Text('Close A')),
                    DataColumn(label: Text('Close B')),
                    DataColumn(label: Text('Duration')),
                    DataColumn(label: Text('Interval')),
                    DataColumn(label: Text('Check')),
                    DataColumn(label: Text('Auto')),
                    DataColumn(label: Text('Last')),
                    DataColumn(label: Text('')),
                  ],
                  rows: [
                    for (final row in rows)
                      DataRow(
                        cells: [
                          DataCell(Text(row.mt5Symbol)),
                          // 2026-09-30, per the user: "add one column in
                          // auto trade table for trade number 'trade id'.
                          // this number also should be in history too" -
                          // reuses the existing MT5 position/order ticket
                          // (already the exact number History shows as
                          // "Ticket {n}") rather than inventing a second,
                          // parallel ID system.
                          // 2026-09-30, per the user: "trade id should be
                          // a selectable text" - SelectableText, not Text,
                          // so the user can copy the real MT5 ticket.
                          DataCell(SelectableText(row.ticket?.toString() ?? '—')),
                          DataCell(
                            Builder(
                              builder: (context) {
                                final (label, color) = _statusLabel(row, scheme);
                                // 2026-10-04, per the user: "status text is
                                // pushing all other next columns ... i need
                                // status column to have wrapped text" - a
                                // long broker rejection reason used to force
                                // this ENTIRE column (and so the whole
                                // table) as wide as its longest single-line
                                // message. Capping the width and letting the
                                // text wrap keeps the column's width fixed
                                // regardless of message length.
                                return Container(
                                  width: 120,
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    label,
                                    softWrap: true,
                                    style: TextStyle(
                                      color: color,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 12,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                          DataCell(
                            Text(
                              row.direction?.toUpperCase() ?? '—',
                              style: TextStyle(
                                color: row.direction == 'sell'
                                    ? Colors.red
                                    : row.direction == 'buy'
                                    ? Colors.green
                                    : scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          DataCell(Text(_fmtPrice(row.price))),
                          DataCell(Text(_fmtPrice(row.stopLoss))),
                          DataCell(Text(_fmtPrice(row.takeProfit))),
                          DataCell(
                            Text(
                              row.profit == null
                                  ? '—'
                                  : '${row.profit! >= 0 ? '+' : ''}${row.profit!.toStringAsFixed(2)}',
                              style: TextStyle(
                                color: row.profit == null
                                    ? scheme.onSurfaceVariant
                                    : row.profit! >= 0
                                    ? Colors.green
                                    : Colors.red,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          DataCell(
                            Builder(
                              builder: (context) {
                                // Trade-size override (2026-10-03, per the
                                // user): minus sits left of the number,
                                // plus sits right of it; once a pending
                                // change differs from what's currently in
                                // play, the current number shows struck
                                // through up top and the new value appears
                                // as its own line BELOW this row, in
                                // yellow. Fixed-width container (2026-10-03,
                                // per the user: "column items should have
                                // fixed width so everything is inlined
                                // below each other") keeps the icons/number
                                // pinned in the same x-position on every
                                // row regardless of digit count or whether
                                // a pending line is showing.
                                final effective = row.desiredVolume ?? row.currentVolume ?? row.volumeMin;
                                final hasCurrent = row.currentVolume != null;
                                final current = row.currentVolume ?? effective;
                                final showPending = row.desiredVolume != null &&
                                    hasCurrent &&
                                    (row.desiredVolume! - row.currentVolume!).abs() > 1e-9;
                                return SizedBox(
                                  width: 120,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.center,
                                    children: [
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.remove_circle_outline, size: 16),
                                            visualDensity: VisualDensity.compact,
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                            tooltip: 'Decrease next-open volume',
                                            onPressed: () => widget.onChangeVolume(
                                              row.tvSymbol,
                                              (effective - row.volumeStep)
                                                  .clamp(row.volumeMin, row.volumeMax)
                                                  .toDouble(),
                                            ),
                                          ),
                                          SizedBox(
                                            width: 46,
                                            child: Text(
                                              _fmtVolume(current),
                                              textAlign: TextAlign.center,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w600,
                                                decoration: showPending ? TextDecoration.lineThrough : null,
                                                color: showPending ? scheme.onSurfaceVariant : null,
                                              ),
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.add_circle_outline, size: 16),
                                            visualDensity: VisualDensity.compact,
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                            tooltip: 'Increase next-open volume',
                                            onPressed: () => widget.onChangeVolume(
                                              row.tvSymbol,
                                              (effective + row.volumeStep)
                                                  .clamp(row.volumeMin, row.volumeMax)
                                                  .toDouble(),
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (showPending)
                                        Text(
                                          _fmtVolume(effective),
                                          style: const TextStyle(
                                            color: Colors.amber,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                          DataCell(
                            row.startTag == null && row.startCandidateTag != null
                                // "Start candidate" (2026-10-03, per the
                                // user: a waiting row with a real
                                // triple-confirmed signal already mid-
                                // "survive one extra candle" wait looked
                                // identical to a genuinely idle one) -
                                // orange like Close A/B, since it's not
                                // confirmed yet, just progressing.
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _fmtTag(row.startCandidateTag),
                                        style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.orange),
                                      ),
                                      if (row.startCandidateEta != null)
                                        Text(
                                          'watching · ${_fmtTvTimeExact(row.startCandidateEta!)}',
                                          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                                        ),
                                    ],
                                  )
                                : Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(_fmtTag(row.startTag), style: const TextStyle(fontWeight: FontWeight.w600)),
                                      if (row.startAt != null)
                                        Text(
                                          _fmtTvTime(row.startAt),
                                          style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                                        ),
                                    ],
                                  ),
                          ),
                          DataCell(
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_fmtTag(row.updateTag), style: const TextStyle(fontWeight: FontWeight.w600)),
                                if (row.updateAt != null)
                                  Text(
                                    _fmtTvTime(row.updateAt),
                                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                                  ),
                              ],
                            ),
                          ),
                          DataCell(
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _fmtTag(row.closeATag),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: row.closeATag != null ? Colors.orange : null,
                                  ),
                                ),
                                if (row.closeAAt != null)
                                  Text(
                                    _fmtTvTime(row.closeAAt),
                                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                                  ),
                              ],
                            ),
                          ),
                          DataCell(
                            row.closeBEta == null
                                ? const Text('—')
                                : Text(
                                    'watching · ${_fmtTvTimeExact(row.closeBEta!)}',
                                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                                  ),
                          ),
                          DataCell(Text(_fmtDuration(row.openedAt))),
                          DataCell(Text(AutoCategory.oneHour.label)),
                          DataCell(
                            Builder(
                              builder: (context) {
                                final checked = row.status == AutoTradeStatus.running &&
                                    isWithinCurrentCandle(row.lastCheckedAt);
                                if (!checked) return const SizedBox.shrink();
                                final cycle = currentAutoCycle();
                                return Tooltip(
                                  message: 'Checked in this candle\'s cycle $cycle',
                                  child: Text(
                                    '✓' * cycle,
                                    style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w700),
                                  ),
                                );
                              },
                            ),
                          ),
                          DataCell(
                            Switch(
                              value: row.isAutoManaged,
                              onChanged: (on) => widget.onToggleAuto(row.tvSymbol, on),
                            ),
                          ),
                          DataCell(
                            Switch(
                              value: row.isLastTagged,
                              onChanged: (on) => widget.onToggleLast(row.tvSymbol, on),
                            ),
                          ),
                          DataCell(
                            IconButton(
                              icon: const Icon(Icons.power_settings_new),
                              // 2026-09-30, per the user: "pending orders,
                              // waiting trades should have active power
                              // button too not disabled one" - the button
                              // was never actually disabled (onPressed is
                              // always set below), but the muted grey
                              // color for non-running rows read as
                              // disabled. Orange now marks it as a live,
                              // pressable action for those rows too - red
                              // stays reserved for "this will close a real
                              // running trade."
                              // 2026-09-30 (revised same day): the action
                              // is identical to the running-row case
                              // (cancel/close, then retire only if Last is
                              // on) - only the color differs, to
                              // distinguish "closing a live trade" (red)
                              // from "cancelling a pending/waiting
                              // attempt" (orange).
                              color: row.status == AutoTradeStatus.running ? Colors.red : Colors.orange,
                              tooltip: row.status == AutoTradeStatus.running
                                  ? 'Terminate this pair\'s trade'
                                  : 'Cancel this pair\'s pending attempt',
                              onPressed: () => widget.onTerminate(row.tvSymbol),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
