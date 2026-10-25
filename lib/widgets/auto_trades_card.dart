import 'dart:async';

import 'package:flutter/material.dart';

import '../core/core_storage.dart';
import '../data/identity/pnl_series_store.dart';
import '../data/models/auto_category.dart';
import '../data/engine/volume_step.dart';
import '../data/models/auto_trade_row.dart';
import '../utilities/auto_cycle.dart';
import 'live_pnl_dialog.dart';
import 'pnl_chart.dart';

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
    required this.onTogglePause,
    required this.onToggleLast,
    required this.onTerminate,
    required this.onChangeVolume,
    required this.onAddCopy,
    required this.onIgnite,
    required this.onFavorite,
    required this.historyPnlSince,
    required this.pnlSinceTimestamp,
    required this.onResetPnlSince,
    required this.liveAccountPnl,
    this.hideUpdateCloseColumns = false,
  });

  final List<AutoTradeRow> rows;

  /// Hides the Update/Close A/Close B columns entirely (2026-10-08, per the
  /// user: "hide close a, close b columns... once supertrend technique
  /// choosen", then "and update too") when the active [DecisionTechnique] is
  /// Supertrend Plus - all three columns are Signal Flip-only concepts
  /// (cross-tag confirmation, and the "survive one extra candle" preview)
  /// that were already always blank for a Supertrend-driven pair even
  /// before this flag existed (see [AutoTradeRow.closeATag]'s own doc
  /// comment: "they are always blank" by design, never written). Close A/B
  /// are now doubly meaningless for a currently-running Supertrend trade
  /// specifically, since that wait no longer applies to one at all (see
  /// EngineService._checkOneSymbolSupertrend's own doc comment on
  /// `skipExtraCandleWait`) - rather than show three columns that can never
  /// hold anything for this technique, hide them outright. Caller passes
  /// this based on [decisionTechniqueProvider]; this widget has no
  /// technique awareness of its own.
  final bool hideUpdateCloseColumns;

  /// tvSymbol, new paused state (2026-10-09, per the user — replaces the
  /// former Auto toggle's add/remove semantics with pause/resume; see
  /// [AutoTradeRow.isPaused]'s own doc comment).
  final void Function(String, bool) onTogglePause;

  /// tvSymbol, new Last state.
  final void Function(String, bool) onToggleLast;

  /// tvSymbol — terminate this pair's current trade right now.
  final void Function(String) onTerminate;

  /// tvSymbol, new desired volume (2026-10-03, per the user) — the target
  /// size for this pair's NEXT open. Never touches a currently-running
  /// trade's own size.
  final void Function(String, double) onChangeVolume;

  /// tvSymbol — Multiplier column's "+" control (2026-10-15, per the
  /// user): request one additional copy trade on this pair, same
  /// direction/TP/volume as what's already running, tighter -$1 SL. Only
  /// enabled in the UI while the row's live P&L is positive.
  final void Function(String) onAddCopy;

  /// tvSymbol — thunder icon: ignite this waiting pair (2026-10-17, per the
  /// user). Only ever called for a non-running row - the icon is disabled
  /// in the UI for a running row.
  final void Function(String) onIgnite;

  /// tvSymbol, new starred state (2026-10-18, per the user: "add a star
  /// icon for those waiting/unfilled cards where once this icon is
  /// clicked, app will give those pairs priority in filling once margin
  /// is okay"). A standing toggle, not one-shot like [onIgnite] - only
  /// ever shown on a waiting card, since a running trade has nothing left
  /// to be prioritized for.
  final void Function(String, bool) onFavorite;

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

  /// 2026-10-19, per the Impeccable design critique (P0): the running-row
  /// power icon fired `onTerminate` straight from `onPressed` for a LIVE
  /// trade - the exact same one-tap cost as the Pause toggle right next
  /// to it, with no undo anywhere in the app. The far lower-stakes
  /// "Reset P&L tracking" action above already gets a confirm dialog;
  /// closing a real position with real money didn't. Only gates the
  /// RUNNING case - cancelling a merely pending/waiting attempt (the
  /// orange variant, tooltip "Cancel this pair's pending attempt") stays
  /// a direct one-tap action, since there's no live position to lose.
  Future<void> _confirmTerminate(BuildContext context, AutoTradeRow row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Terminate ${row.mt5Symbol}?'),
        content: const Text(
          'This closes the running position right now, at the current market '
          'price. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Terminate'),
          ),
        ],
      ),
    );
    if (confirmed == true) widget.onTerminate(row.tvSymbol);
  }

  /// SLL column's (i) icon (2026-10-13, per the user: "once user click on
  /// this icon... app will show the sll percent category setup in a
  /// dialog") - the exact ladder `highestSlRatchetThresholdCrossed`/
  /// `slRatioForThreshold` (§10.1) implement, spelled out so there's never
  /// any guessing about what a given rung actually means.
  void _showSllInfoDialog(BuildContext context) {
    // Dollar ladder since v1.6.32 (2026-10-20, per the user).
    const rows = [
      ('below +\$5', 'no SLL action (v1.6.38)'),
      ('+\$5', '+\$2'),
      ('+\$10', '+\$5'),
      ('+\$15', '+\$10'),
      ('+\$20', '+\$15'),
      ('+\$25', '+\$20'),
      ('+\$30 and beyond', 'keeps going: threshold − \$5'),
    ];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('SL Ratchet (SLL)'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Tightening-only protection, keyed off each trade\'s own '
                'live profit in dollars - never loosens once a rung is locked. The '
                'real MT5 SL/TP stay fixed at the 60/40 model\'s levels '
                'the whole time (2026-10-17 redesign) - this closes the '
                'position directly once P&L crosses the rung, it never '
                'modifies the broker order.',
              ),
              const SizedBox(height: 12),
              Table(
                columnWidths: const {0: FlexColumnWidth(1), 1: FlexColumnWidth(1)},
                children: [
                  const TableRow(
                    children: [
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text('Floating P&L', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text('Closes at', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  for (final r in rows)
                    TableRow(
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(r.$1),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(r.$2),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
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

  static String _fmtPrice(double? v) {
    if (v == null) return '—';
    if (v == 0) return '0';
    if (v.abs() < 0.001) return v.toStringAsFixed(8);
    if (v.abs() < 1) return v.toStringAsFixed(5);
    return v.toStringAsFixed(v.abs() < 100 ? 4 : 2);
  }

  /// True once the LIVE price is within 20% of the estimated liquidation
  /// price, measured against the trade's own TP-to-SL distance as the
  /// 100% reference range (2026-10-15, per the user: "from tp price to
  /// sl price .. this is 100% price range. so if current price is 20%
  /// close to liquidation price ... then color the current price +
  /// liquidation price in yellow" - corrected from an earlier entry-to-
  /// liquidation range, which isn't what the user meant).
  static bool _isNearLiquidation(AutoTradeRow row) {
    if (row.liquidationPrice == null ||
        row.currentPrice == null ||
        row.takeProfit == null ||
        row.stopLoss == null) {
      return false;
    }
    final fullRange = (row.takeProfit! - row.stopLoss!).abs();
    if (fullRange == 0) return false;
    final remainingBuffer = (row.currentPrice! - row.liquidationPrice!).abs();
    return remainingBuffer / fullRange * 100 <= 20;
  }

  static String _fmtTag(String? tag) => tag == null ? '—' : tag.toUpperCase();

  /// Trims trailing zeros rather than a fixed decimal count, since volume
  /// steps vary wildly by symbol (e.g. BTCUSD.lv 0.001 vs XRPUSD.lv 100 -
  /// see [WatchedSymbol]'s own doc comment).
  /// One -/+ click (2026-10-20, per the user: "-" took XRP from its 100
  /// minimum to 99.99): step, clamp to the broker's bounds, then snap onto
  /// the broker's legal grid (volume_min + k*volume_step) - the same
  /// [snapVolumeToStep] the engine applies before sending, so the stored
  /// value is always one MT5 accepts, with no float noise like
  /// 0.30000000000000004.
  static double _steppedVolume(AutoTradeRow row, double effective, int direction) {
    final raw = (effective + direction * row.volumeStep).clamp(row.volumeMin, row.volumeMax).toDouble();
    return snapVolumeToStep(raw, volumeMin: row.volumeMin, volumeStep: row.volumeStep);
  }

  static String _volumeTooltip(AutoTradeRow row, String normal) => row.volumeLimitsKnown
      ? normal
      : '${row.mt5Symbol} is not in MT5 Market Watch - its real volume limits are '
            'unknown. Add it in MT5 (Market Watch > Symbols > Show) to adjust volume.';

  static bool _hasActiveStepDown(AutoTradeRow row, double effective) =>
      row.attemptVolume != null && (row.attemptVolume! - effective).abs() > 1e-9;

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
  /// (see [BotHistoryEntry]'s open/close signal times). Shown in UTC
  /// directly, NOT converted to local time - 2026-10-17, per the user:
  /// "i want app readings 100% same as my eyes" - TradingView itself
  /// displays in UTC, so converting this to local time read as a timing
  /// error when the underlying bar time was correct the whole time.
  static String _fmtTvTime(int? epochSeconds) {
    if (epochSeconds == null) return '';
    final l = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000, isUtc: true);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  /// Same format/UTC reasoning as [_fmtTvTime], but for an already-resolved
  /// [DateTime] (Close B's ETA) rather than a raw TV bar timestamp - this
  /// ETA is itself computed FROM a TV bar time (barTime + 2 candles), so it
  /// stays in the same clock as the signal it's relative to.
  static String _fmtTvTimeExact(DateTime dt) {
    final l = dt.toUtc();
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

  /// Card colour (2026-10-25, per the user): "filled and not yet triggered
  /// cards are yellow, running cards with P&L positive are green ... P&L
  /// negative are red. P&L zero are neutral color. non filled cards are
  /// neutral color". Null = neutral.
  static Color? _cardTint(AutoTradeRow row) {
    if (row.status == AutoTradeStatus.waitingPending) return Colors.amber;
    if (row.status == AutoTradeStatus.running && row.profit != null && row.profit != 0) {
      return row.profit! > 0 ? Colors.green : Colors.red;
    }
    return null;
  }

  static BoxDecoration _cardDecoration(ColorScheme scheme, Color? tint) => BoxDecoration(
    color: tint?.withValues(alpha: 0.08) ?? scheme.surfaceContainerLow,
    border: Border.all(color: tint?.withValues(alpha: 0.7) ?? scheme.outlineVariant, width: tint == null ? 1 : 1.4),
    borderRadius: BorderRadius.circular(12),
  );

  static Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(5)),
    child: Text(text, style: TextStyle(fontSize: 11, color: color, fontWeight: FontWeight.w600)),
  );

  static String _ago(DateTime? t) {
    if (t == null) return 'not checked yet';
    final d = DateTime.now().difference(t);
    if (d.inHours > 0) return 'checked ${d.inHours}h ${d.inMinutes % 60}m ago';
    if (d.inMinutes > 0) return 'checked ${d.inMinutes}m ago';
    return 'checked just now';
  }

  /// Label over a value - one cell of a card's level grid.
  static Widget _kv(String label, Widget value, ColorScheme scheme) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant)),
      const SizedBox(height: 2),
      value,
    ],
  );

  static Widget _kt(String label, String value, ColorScheme scheme, {Color? color}) => _kv(
    label,
    Text(
      value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      // 2026-10-25, per the user: "text title should be more thick than
      // value text" - labels bold (see [_kv]), values regular.
      style: TextStyle(fontWeight: FontWeight.w400, fontSize: 13, color: color),
    ),
    scheme,
  );

  /// One signal in a card's signal line: "Open LL 10-24 11:00".
  static Widget _sig(String label, String? tag, String time, ColorScheme scheme, {Color? color}) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('$label ', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
      Text(_fmtTag(tag), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: tag == null ? null : color)),
      if (time.isNotEmpty) Text(' $time', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    ],
  );

  /// Next-open volume -/+ (same rules as the old table cell): a copy's
  /// volume is fixed; a pending change shows the current size struck
  /// through with the new one under it; an active step-down shows "sends X".
  Widget _volumeControl(AutoTradeRow row, ColorScheme scheme) {
    if (row.isCopy) {
      return Tooltip(
        message: 'Copy volume is fixed at 1 lot',
        child: Text(
          _fmtVolume(row.currentVolume ?? 1),
          style: TextStyle(fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
        ),
      );
    }
    final effective = row.desiredVolume ?? row.currentVolume ?? row.volumeMin;
    final hasCurrent = row.currentVolume != null;
    final current = row.currentVolume ?? effective;
    final showPending =
        row.desiredVolume != null && hasCurrent && (row.desiredVolume! - row.currentVolume!).abs() > 1e-9;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              tooltip: _volumeTooltip(row, 'Decrease next-open volume'),
              onPressed: row.volumeLimitsKnown
                  ? () => widget.onChangeVolume(row.tvSymbol, _steppedVolume(row, effective, -1))
                  : null,
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 36),
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
              icon: const Icon(Icons.add_circle_outline, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
              tooltip: _volumeTooltip(row, 'Increase next-open volume'),
              onPressed: row.volumeLimitsKnown
                  ? () => widget.onChangeVolume(row.tvSymbol, _steppedVolume(row, effective, 1))
                  : null,
            ),
          ],
          ),
        ),
        if (showPending)
          Text(
            'next open ${_fmtVolume(effective)}',
            style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.w700, fontSize: 11),
          ),
        // The size the next order will really send, and why (2026-10-25, per
        // the user: ADA's card said 400 while the order went out at 200).
        if (row.sendVolume != null && (row.sendVolume! - effective).abs() > 1e-9)
          Text(
            'sends ${_fmtVolume(row.sendVolume!)}${row.sendWhy == null ? '' : ' (${row.sendWhy})'}',
            softWrap: true,
            style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.w700, fontSize: 11),
          )
        else if (row.sendVolume == null && _hasActiveStepDown(row, effective))
          Tooltip(
            message: 'MT5 rejected a larger size earlier - the next order will be sent at this size',
            child: Text(
              'sends ${_fmtVolume(row.attemptVolume!)}',
              style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.w700, fontSize: 11),
            ),
          ),
      ],
    );
  }

  Widget _pauseButton(AutoTradeRow row, ColorScheme scheme) => IconButton(
    icon: Icon(row.isPaused ? Icons.play_arrow : Icons.pause, size: 20),
    color: row.isPaused ? Colors.green : scheme.onSurfaceVariant,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
    tooltip: row.isPaused
        ? 'Resume — engine will act on this pair again'
        : 'Pause — engine will take no action on this pair',
    onPressed: () => widget.onTogglePause(row.tvSymbol, !row.isPaused),
  );

  Widget _lastSwitch(AutoTradeRow row, ColorScheme scheme) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Transform.scale(
        scale: 0.75,
        child: Switch(
          value: row.isLastTagged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onChanged: (on) => widget.onToggleLast(row.tvSymbol, on),
        ),
      ),
      Text('Last', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
    ],
  );

  /// One running trade (2026-10-25, per the user: "instead of using rows,
  /// i want you to use cards. in this card, chart is there. and all other
  /// data"). Header, investment/P&L (tap = live chart), live P&L chart,
  /// levels, signals, controls - every item the old table row had.
  Widget _buildRunningCard(BuildContext context, AutoTradeRow row) {
    final scheme = Theme.of(context).colorScheme;
    final tint = _cardTint(row);
    final small = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    final side = switch (row.direction) {
      'sell' => ('SHORT', Colors.red),
      'buy' => ('LONG', Colors.green),
      _ => ('—', scheme.outline),
    };
    final near = _isNearLiquidation(row);
    final nearColor = near ? Colors.yellow.shade800 : null;
    final pnlColor = row.profit == null || row.profit == 0
        ? scheme.onSurface
        : row.profit! > 0
        ? Colors.green.shade700
        : Colors.red.shade700;
    final pnlText = row.profit == null
        ? '—'
        : '${row.profit! >= 0 ? '+' : ''}${row.profit!.toStringAsFixed(2)}'
              '${row.pnlPercent == null ? '' : ' (${row.pnlPercent! >= 0 ? '+' : ''}${row.pnlPercent!.toStringAsFixed(2)}%)'}';
    final sll = row.slRatchetThreshold == null
        ? '—'
        : '+\$${row.slRatchetThreshold == 5 ? 2 : row.slRatchetThreshold! - 5}';
    final checked = isWithinCurrentCandle(row.lastCheckedAt);
    return _CardShell(
      paused: row.isPaused,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: _cardDecoration(scheme, tint),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Pair name is never cut off: when space runs out, the badges
              // wrap to a second line instead (2026-10-25, LAST badge added).
              Expanded(
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (row.isFavorite) const Icon(Icons.star, size: 16, color: Colors.amber),
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        row.mt5Symbol,
                        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                      ),
                    ),
                    _badge(side.$1, side.$2),
                    _badge('1:2000', scheme.outline),
                    if (row.isLastTagged) _badge('LAST', Colors.deepOrange),
                    if (row.isCopy) _badge('copy', Colors.amber.shade800),
                  ],
                ),
              ),
              if (checked)
                Tooltip(
                  message: 'Checked in this candle\'s cycle ${currentAutoCycle()}',
                  child: Text(
                    '✓' * currentAutoCycle(),
                    style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w700),
                  ),
                ),
              // Hourly check mark sits just left of the more icon, with a gap
              // (2026-10-25, per the user).
              const SizedBox(width: 10),
              _runningMoreMenu(context, row, scheme),
            ],
          ),
          const SizedBox(height: 2),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SelectableText('#${row.ticket ?? '—'}', style: small),
              Text(
                '  ·  ${AutoCategory.oneHour.label}  ·  lasting ${_fmtDuration(row.openedAt)}',
                style: small,
              ),
            ],
          ),
          const SizedBox(height: 10),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: row.ticket != null && row.profit != null ? () => showLivePnlDialog(context, row) : null,
            child: Container(
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
                        child: _kt(
                          'Investment',
                          row.investmentValue == null ? '—' : '\$${row.investmentValue!.toStringAsFixed(2)}',
                          scheme,
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
                            Text('P&L', style: small),
                            const SizedBox(height: 2),
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                pnlText,
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: pnlColor),
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
          ),
          const SizedBox(height: 14),
          _CardPnlChart(ticket: row.ticket, profit: row.profit, percent: row.pnlPercent),
          const SizedBox(height: 14),
          // Three equal columns, divided (2026-10-25, per the user: "those 3
          // columns should be separated equally"): entry/now + liquidation,
          // SL/TP + extra margin, SLL lock + volume.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _kt('Entry / now', '${_fmtPrice(row.price)} / ${_fmtPrice(row.currentPrice)}', scheme,
                          color: nearColor),
                      const SizedBox(height: 8),
                      Tooltip(
                        message: row.liquidationPrice == null
                            ? ''
                            : 'Estimate: price at which this position alone would reach '
                                  "Equiti's 30% stop-out level, if every other position "
                                  'stayed exactly as it is right now.',
                        child: _kt('Liquidation', _fmtPrice(row.liquidationPrice), scheme, color: nearColor),
                      ),
                    ],
                  ),
                ),
                VerticalDivider(width: 16, color: scheme.outlineVariant),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _kt('SL / TP', '${_fmtPrice(row.stopLoss)} / ${_fmtPrice(row.takeProfit)}', scheme),
                      const SizedBox(height: 8),
                      _kt(
                        'Extra margin',
                        row.extraMargin == null ? '—' : '\$${row.extraMargin!.toStringAsFixed(2)}',
                        scheme,
                      ),
                    ],
                  ),
                ),
                VerticalDivider(width: 16, color: scheme.outlineVariant),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _kv(
                        'SLL lock',
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              sll,
                              style: TextStyle(
                                fontSize: 13,
                                color: row.slRatchetThreshold != null ? Colors.green : scheme.onSurfaceVariant,
                              ),
                            ),
                            InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => _showSllInfoDialog(context),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(Icons.info_outline, size: 14, color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ],
                        ),
                        scheme,
                      ),
                      const SizedBox(height: 8),
                      _kv('Volume', _volumeReadout(row, scheme), scheme),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 18),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              _sig('Open', row.startTag, _fmtTvTime(row.startAt), scheme),
              if (!widget.hideUpdateCloseColumns) ...[
                _sig('Update', row.updateTag, _fmtTvTime(row.updateAt), scheme),
                _sig('Close A', row.closeATag, _fmtTvTime(row.closeAAt), scheme, color: Colors.orange),
                if (row.closeBEta != null)
                  Text('Close B watching · ${_fmtTvTimeExact(row.closeBEta!)}', style: small),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// Current volume on a running card, read-only (2026-10-25, per the
  /// user: the -/+ moved to the more menu, "still auto card need to show
  /// current volum"): the running size, the next-open size if it differs,
  /// and what that next order will really send.
  /// Per the user (2026-10-25): "once volum updated ... i dont need many
  /// text... i want current volum with centrlined and new volum ... extra
  /// info is not required" - the running size struck through, then the new
  /// size, nothing else.
  Widget _volumeReadout(AutoTradeRow row, ColorScheme scheme) {
    final current = row.currentVolume ?? row.desiredVolume ?? row.volumeMin;
    final next = row.desiredVolume;
    final changed = !row.isCopy && next != null && (next - current).abs() > 1e-9;
    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          _fmtVolume(current),
          style: TextStyle(
            fontSize: 13,
            decoration: changed ? TextDecoration.lineThrough : null,
            color: changed ? scheme.onSurfaceVariant : null,
          ),
        ),
        if (changed)
          Text(
            _fmtVolume(next),
            style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.w700, fontSize: 13),
          ),
      ],
    );
  }

  /// The running card's "more" menu (2026-10-25, per the user: "more icon
  /// at the top right where once it is pressed it will show (pause, last
  /// toggle, multiplier copy, volume controls -/+ with current volume
  /// setting, power off)"). The volume and Last rows keep the menu open and
  /// update in place; the other items act and close it.
  Widget _runningMoreMenu(BuildContext context, AutoTradeRow row, ColorScheme scheme) {
    final canAddCopy = row.profit != null && row.profit! > 0;
    // `child`, not `icon`: an icon button adds its own padding, which pushed
    // the icon further from the card edge than the title is (2026-10-25,
    // per the user: "the more icon should have same padding as title from
    // the edge of the card").
    return PopupMenuButton<String>(
      tooltip: 'More',
      constraints: const BoxConstraints(minWidth: 240),
      child: Icon(Icons.more_vert, size: 20, color: scheme.onSurfaceVariant),
      onSelected: (value) {
        switch (value) {
          case 'pause':
            widget.onTogglePause(row.tvSymbol, !row.isPaused);
          case 'copy':
            widget.onAddCopy(row.tvSymbol);
          case 'terminate':
            _confirmTerminate(context, row);
        }
      },
      itemBuilder: (context) {
        var last = row.isLastTagged;
        return [
        PopupMenuItem(
          value: 'pause',
          child: Row(
            children: [
              Icon(row.isPaused ? Icons.play_arrow : Icons.pause, size: 20, color: row.isPaused ? Colors.green : null),
              const SizedBox(width: 10),
              Text(row.isPaused ? 'Resume' : 'Pause'),
            ],
          ),
        ),
        PopupMenuItem(
          child: StatefulBuilder(
            builder: (context, setLocal) => Row(
              children: [
                const Icon(Icons.flag_outlined, size: 20),
                const SizedBox(width: 10),
                const Expanded(child: Text('Last')),
                Switch(
                  value: last,
                  onChanged: (on) {
                    widget.onToggleLast(row.tvSymbol, on);
                    setLocal(() => last = on);
                  },
                ),
              ],
            ),
          ),
        ),
        if (!row.isCopy)
          PopupMenuItem(
            child: _MenuVolumeStepper(
              row: row,
              initial: row.desiredVolume ?? row.currentVolume ?? row.volumeMin,
              format: _fmtVolume,
              step: (v, dir) => _steppedVolume(row, v, dir),
              tooltip: (s) => _volumeTooltip(row, s),
              onChange: (v) => widget.onChangeVolume(row.tvSymbol, v),
            ),
          )
        else
          const PopupMenuItem(enabled: false, child: Text('Copy volume is fixed at 1 lot')),
        PopupMenuItem(
          value: 'copy',
          enabled: canAddCopy,
          child: Row(
            children: [
              const Icon(Icons.add_circle_outline, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(canAddCopy ? 'Add copy trade' : 'Add copy (P&L must be positive)')),
              Text('×${row.copyCount}', style: TextStyle(color: row.copyCount > 1 ? Colors.amber.shade800 : null)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'terminate',
          child: Row(
            children: [
              Icon(Icons.power_settings_new, size: 20, color: Colors.red),
              SizedBox(width: 10),
              Text('Terminate trade', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
        ];
      },
    );
  }

  /// One waiting (unfilled) pair (2026-10-25, per the user's card design).
  /// Yellow when its order is resting in MT5, neutral otherwise. Same fixed
  /// height on every waiting card (2026-10-18 rule); the "why" box scrolls.
  Widget _buildWaitingCard(BuildContext context, AutoTradeRow row) {
    final scheme = Theme.of(context).colorScheme;
    final tint = _cardTint(row);
    final small = TextStyle(fontSize: 11, color: scheme.onSurfaceVariant);
    final resting = row.status == AutoTradeStatus.waitingPending;
    final blocked = !resting && row.waitingReason != null;
    final (state, stateColor) = row.isPaused
        ? ('Paused', scheme.outline)
        : resting
        ? ('Order resting', Colors.amber.shade800)
        : blocked
        ? ('Blocked', scheme.onSurfaceVariant)
        : ('Waiting', scheme.outline);
    final side = switch (row.direction) {
      'sell' => 'SELL',
      'buy' => 'BUY',
      _ => '',
    };
    final why = resting
        ? '$side STOP #${row.ticket ?? '—'} at ${_fmtPrice(row.price)} - fills when price reaches it.'
              '${row.waitingReason == null ? '' : '\n${row.waitingReason}'}'
        : blocked
        ? row.waitingReason!
        : row.startCandidateTag != null
        ? 'Signal ${_fmtTag(row.startCandidateTag)} confirming'
              '${row.startCandidateEta == null ? '' : ' - acts after ${_fmtTvTimeExact(row.startCandidateEta!)}'}.'
        : 'No open signal yet.';
    final signalTag = row.startTag ?? row.startCandidateTag;
    final signalTime = row.startTag != null ? _fmtTvTime(row.startAt) : '';
    return _CardShell(
      paused: row.isPaused,
      height: 300,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: _cardDecoration(scheme, tint),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  row.mt5Symbol,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
              if (row.isLastTagged) ...[_badge('LAST', Colors.deepOrange), const SizedBox(width: 4)],
              _badge(state, stateColor),
              IconButton(
                icon: Icon(row.isFavorite ? Icons.star : Icons.star_border, size: 18),
                color: row.isFavorite ? Colors.amber : scheme.onSurfaceVariant,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                tooltip: row.isFavorite
                    ? 'Favorited - checked first among waiting pairs once margin allows'
                    : 'Favorite - give this pair priority once margin allows',
                onPressed: () => widget.onFavorite(row.tvSymbol, !row.isFavorite),
              ),
            ],
          ),
          Text(_ago(row.lastCheckedAt), style: small),
          const SizedBox(height: 6),
          Expanded(
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: (tint ?? scheme.outline).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(child: Text(why, style: const TextStyle(fontSize: 12))),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _kt(
                  resting ? 'Open signal' : 'Signal',
                  signalTag == null ? '—' : '${_fmtTag(signalTag)} $signalTime'.trim(),
                  scheme,
                ),
              ),
              Expanded(
                child: resting
                    ? _kt('SL / TP', '${_fmtPrice(row.stopLoss)} / ${_fmtPrice(row.takeProfit)}', scheme)
                    : _kt('Direction', side.isEmpty ? '—' : side, scheme),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _kv('Volume', _volumeControl(row, scheme), scheme),
          Row(
            children: [
              _pauseButton(row, scheme),
              IconButton(
                icon: Icon(row.isIgnited ? Icons.bolt : Icons.bolt_outlined, size: 20),
                color: row.isIgnited ? Colors.amber : scheme.onSurfaceVariant,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                tooltip: row.isIgnited
                    ? 'Ignited - will open regardless of margin level once triggered. Click to cancel.'
                    : 'Ignite - bypass margin level for this pair\'s next signal',
                onPressed: () => widget.onIgnite(row.tvSymbol),
              ),
              _lastSwitch(row, scheme),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.power_settings_new, size: 20),
                color: Colors.orange,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
                tooltip: 'Cancel this pair\'s pending attempt',
                onPressed: () => widget.onTerminate(row.tvSymbol),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Running cards use the cycling sort (per the user: "sorting of running
    // cards should be same sorting technique as sorting in auto running
    // trades"); waiting cards: order resting, blocked, waiting, paused,
    // then A-Z (2026-10-25 card design).
    final rows = _sorted(widget.rows.where((r) => r.status == AutoTradeStatus.running).toList());
    int waitRank(AutoTradeRow r) => r.isPaused
        ? 3
        : r.status == AutoTradeStatus.waitingPending
        ? 0
        : r.waitingReason != null
        ? 1
        : 2;
    final waitingRows = widget.rows.where((r) => r.status != AutoTradeStatus.running).toList()
      ..sort((a, b) {
        final byRank = waitRank(a).compareTo(waitRank(b));
        return byRank != 0 ? byRank : a.tvSymbol.compareTo(b.tvSymbol);
      });
    final running = rows.length;
    final pending = waitingRows.where((r) => r.status == AutoTradeStatus.waitingPending).length;
    final blocked = waitingRows.where((r) => waitRank(r) == 1).length;
    final noSignal = waitingRows.length - pending - blocked;

    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 2026-10-20, per the user: "this text should be to the right
            // top .. currently it looks like it is in the center". Root
            // cause: the title was a Flexible, which is ALLOTTED a share of
            // the free space but only uses its own text width - Flutter
            // leaves the unused remainder at the END of the Row, so the
            // stats group always ended mid-card (a first fix that only
            // right-aligned inside an Expanded still did; caught by
            // test/auto_trades_card_layout_test.dart, which measures it).
            // Now: title+sort icon as one left group, stats+P&L as one
            // right group, and spaceBetween pushes ALL leftover space
            // between them - the right group always ends at the card edge.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // 2026-10-19, found by finally running this project's own
                // widget test for the first time all session: a
                // RenderFlex overflow in this exact Row, pre-existing (not
                // caused by anything edited today) and never caught since
                // nothing had run `flutter test` against it before. The
                // title is the one piece safe to truncate on a narrow
                // window - the live summary stats and P&L figures to its
                // right matter more moment-to-moment and must stay fully
                // visible.
                Flexible(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          'Auto-Managed Trades',
                          style: Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: Icon(_sortMode.icon, size: 18),
                        tooltip: _sortMode.label,
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(() => _sortMode = _sortMode.next),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                // Scales down rather than overflowing on a very narrow window.
                Flexible(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '$running running · $pending resting · $blocked blocked · $noSignal waiting',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          // Live P&L (2026-10-06, per the user: "i want p&L
                          // in auto is similar as in engine" / "same number"
                          // / "i need only one number. engine number") - the
                          // Engine status section's own equity-balance
                          // number. The "Since timestamp" realized tracker
                          // below is a different, untouched thing - "dont
                          // touch p&l for history timestamp".
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
                    ),
                  ),
                ),
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
            if (rows.isEmpty && waitingRows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No symbols configured yet.'),
              )
            else
              // Cards instead of a table (2026-10-25, per the user). Running
              // cards keep the table's own cycling sort; waiting cards go
              // resting -> blocked -> waiting -> paused, then A-Z.
              LayoutBuilder(
                builder: (context, constraints) {
                  const gap = 12.0;
                  int cols(double minWidth, int max) => (constraints.maxWidth / minWidth).floor().clamp(1, max);
                  double width(int c) => (constraints.maxWidth - gap * (c - 1)) / c;
                  final runWidth = width(cols(330, 4));
                  final waitWidth = width(cols(290, 4));
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (rows.isNotEmpty)
                        Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final row in rows) SizedBox(width: runWidth, child: _buildRunningCard(context, row)),
                          ],
                        ),
                      if (waitingRows.isNotEmpty) ...[
                        const SizedBox(height: 18),
                        Text('Waiting (unfilled)', style: Theme.of(context).textTheme.titleSmall),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (final row in waitingRows) SizedBox(width: waitWidth, child: _buildWaitingCard(context, row)),
                          ],
                        ),
                      ],
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

/// The live P&L chart inside a running card: the engine's recorded series
/// (re-read every 15s) plus the card's own live P&L as the latest point, so
/// the line moves with every Dashboard poll (2026-10-25, per the user).
class _CardPnlChart extends StatefulWidget {
  const _CardPnlChart({required this.ticket, required this.profit, required this.percent});

  final int? ticket;
  final double? profit;
  final double? percent;

  @override
  State<_CardPnlChart> createState() => _CardPnlChartState();
}

class _CardPnlChartState extends State<_CardPnlChart> {
  final PnlSeriesStore _store = PnlSeriesStore(CoreStorage.instance);
  List<PnlPoint> _recorded = const [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _reload();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _reload());
  }

  void _reload() {
    final ticket = widget.ticket;
    if (ticket == null) return;
    final recorded = _store.read(ticket);
    if (mounted) setState(() => _recorded = recorded);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final points = [..._recorded];
    final now = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    if (widget.profit != null && (points.isEmpty || now > points.last.time)) {
      points.add(PnlPoint(time: now, profit: widget.profit!, percent: widget.percent));
    }
    return PnlChart(points: points, height: 170);
  }
}

/// Volume -/+ inside the running card's more menu - keeps its own value so
/// repeated clicks update in place while the menu stays open (2026-10-25).
class _MenuVolumeStepper extends StatefulWidget {
  const _MenuVolumeStepper({
    required this.row,
    required this.initial,
    required this.format,
    required this.step,
    required this.tooltip,
    required this.onChange,
  });

  final AutoTradeRow row;
  final double initial;
  final String Function(double) format;
  final double Function(double value, int direction) step;
  final String Function(String normal) tooltip;
  final void Function(double) onChange;

  @override
  State<_MenuVolumeStepper> createState() => _MenuVolumeStepperState();
}

class _MenuVolumeStepperState extends State<_MenuVolumeStepper> {
  late double _value = widget.initial;

  void _bump(int direction) {
    final next = widget.step(_value, direction);
    widget.onChange(next);
    setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.row.volumeLimitsKnown;
    return Row(
      children: [
        const Icon(Icons.stacked_bar_chart, size: 20),
        const SizedBox(width: 10),
        const Expanded(child: Text('Volume')),
        IconButton(
          icon: const Icon(Icons.remove_circle_outline, size: 20),
          tooltip: widget.tooltip('Decrease next-open volume'),
          onPressed: enabled ? () => _bump(-1) : null,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 40),
          child: Text(widget.format(_value), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        IconButton(
          icon: const Icon(Icons.add_circle_outline, size: 20),
          tooltip: widget.tooltip('Increase next-open volume'),
          onPressed: enabled ? () => _bump(1) : null,
        ),
      ],
    );
  }
}

/// A card's frame. While its pair is paused the card blinks slowly between
/// yellow and neutral (2026-10-25, per the user: "once user activate pause
/// .. card color will go blinking in slow ... yellow and neutral").
class _CardShell extends StatefulWidget {
  const _CardShell({
    required this.paused,
    required this.padding,
    required this.decoration,
    required this.child,
    this.height,
  });

  final bool paused;
  final EdgeInsets padding;
  final BoxDecoration decoration;
  final Widget child;
  final double? height;

  @override
  State<_CardShell> createState() => _CardShellState();
}

class _CardShellState extends State<_CardShell> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.paused) _blink.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _CardShell old) {
    super.didUpdateWidget(old);
    if (widget.paused && !_blink.isAnimating) {
      _blink.repeat(reverse: true);
    } else if (!widget.paused && _blink.isAnimating) {
      _blink
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.paused) {
      return Container(
        height: widget.height,
        padding: widget.padding,
        decoration: widget.decoration,
        child: widget.child,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _blink,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_blink.value);
        return Container(
          height: widget.height,
          padding: widget.padding,
          decoration: BoxDecoration(
            color: Color.lerp(scheme.surfaceContainerLow, Colors.amber.withValues(alpha: 0.22), t),
            border: Border.all(color: Color.lerp(scheme.outlineVariant, Colors.amber, t)!, width: 1.4),
            borderRadius: BorderRadius.circular(12),
          ),
          child: child,
        );
      },
      child: widget.child,
    );
  }
}
