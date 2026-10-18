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

  /// SLL column's (i) icon (2026-10-13, per the user: "once user click on
  /// this icon... app will show the sll percent category setup in a
  /// dialog") - the exact ladder `highestSlRatchetThresholdCrossed`/
  /// `slRatioForThreshold` (§10.1) implement, spelled out so there's never
  /// any guessing about what a given rung actually means.
  void _showSllInfoDialog(BuildContext context) {
    const rows = [
      ('0% or below', '-\$5 flat (no percent)'),
      ('+5%', '+2%'),
      ('+10%', '+5%'),
      ('+15%', '+10%'),
      ('+20%', '+15%'),
      ('+25%', '+20%'),
      ('+30% and beyond', 'keeps going: threshold − 5'),
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
                'live P&L% - never loosens once a rung is locked. The '
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

  /// A deterministic background tint shared by every row for the same
  /// pair, so a pair's original trade and its Multiplier copies visually
  /// group together (2026-10-15, per the user: "same trades (same pair)
  /// should have same row color"). Null (no tint - the table's normal
  /// default) whenever a pair has no copies, so an ordinary single-row
  /// pair looks exactly as it always has. Hashing [mt5Symbol] (rather
  /// than a counter) means the same pair gets the same color across
  /// refreshes without needing to track group identity anywhere.
  static Color? _copyGroupColor(AutoTradeRow row, {required bool isOriginal}) {
    if (row.copyCount <= 1) return null;
    // ONE color per symbol group, shaded by opacity - parent darker, every
    // copy lighter (2026-10-16, per the user, after a brief detour through
    // two separate palettes per group: "i asked you to make parent darker
    // for same color. and copied lighter for same color... use same color
    // for parent and X copied trades"). Different GROUPS still get
    // different colors via the hash below.
    const palette = [Colors.amber, Colors.cyan, Colors.purple, Colors.teal, Colors.pink, Colors.indigo];
    final color = palette[row.mt5Symbol.hashCode.abs() % palette.length];
    return color.withValues(alpha: isOriginal ? 0.30 : 0.12);
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

  /// Compact per-pair card for the waiting/unfilled section below the main
  /// table (2026-10-18, per the user: "make the waiting trades (unfilled)
  /// in a card not in table. so auto table contains filled trades and
  /// running trades. and below that table wrapped cards of waiting
  /// unfilled trades sorted by name a-z") - only the controls that still
  /// mean anything for a pair with no real position yet: status, the
  /// next-open volume stepper, Auto play/pause, Ignite, and
  /// Power/terminate (cancels the resting pending order, if any). Reuses
  /// the exact same callbacks/logic as the table's own cells so behavior
  /// never diverges between the two presentations of the same row.
  Widget _buildWaitingCard(BuildContext context, AutoTradeRow row) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = _statusLabel(row, scheme);
    final effective = row.desiredVolume ?? row.currentVolume ?? row.volumeMin;
    final hasCurrent = row.currentVolume != null;
    final current = row.currentVolume ?? effective;
    final showPending = row.desiredVolume != null &&
        hasCurrent &&
        (row.desiredVolume! - row.currentVolume!).abs() > 1e-9;
    // Fixed width AND height (2026-10-18, per the user: "width and height
    // of all cards should be identical"), split into two explicit
    // sections (2026-10-18, per the user: "make card having two
    // sections. upper section (pair title + status) .. bottom section in
    // two rows (volum) (power, ignite, pause)" / "make upper section
    // heigher than fixed bottom section" / "so upper section contains
    // all status text") - the upper section is taller than the bottom
    // one and shows the FULL status text (no ellipsis truncation, a
    // long broker rejection reason just wraps across more lines), while
    // the bottom section (volume stepper + action icons) stays a small,
    // fixed size identical on every card regardless of what's above it.
    const cardHeight = 230.0;
    const cardPadding = 10.0;
    // 2026-10-18, per the user: "the padding from bottom edge of the
    // card to the bottom of action row should be same as the padding
    // from top edge of the card to the top edge of the title" - a fixed
    // `bottomHeight` SizedBox left dead space below the action row
    // whenever the two rows' real content was shorter than that
    // allotment, making the bottom gap bigger than the top one. The
    // bottom section is now sized to its own natural (`min`) content
    // instead, and the upper section is `Expanded` to absorb whatever
    // space is left - so the action row always sits flush against the
    // SAME `cardPadding` the title sits flush against up top, by
    // construction, not by tuning a magic number.
    return Container(
      width: 180,
      height: cardHeight,
      padding: const EdgeInsets.all(cardPadding),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Upper section: pair title + full status text - expands to
          // fill whatever space the fixed-size bottom section doesn't
          // use.
          Expanded(
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
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    // Star icon (2026-10-18, per the user: "add a star
                    // icon for those waiting/unfilled cards where once
                    // this icon is clicked, app will give those pairs
                    // priority in filling once margin is okay") - sits
                    // with the title, not the action row below, since
                    // it's a standing identity preference rather than a
                    // transient per-cycle action.
                    IconButton(
                      icon: Icon(row.isFavorite ? Icons.star : Icons.star_border, size: 20),
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
                const SizedBox(height: 6),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Align(
                      alignment: Alignment.topLeft,
                      child: SingleChildScrollView(
                        child: Text(
                          label,
                          softWrap: true,
                          style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 11),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Bottom section: volume row, then the action-icon row -
          // naturally sized (no dead space), identical on every card
          // since every card has the exact same two rows.
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, size: 22),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      tooltip: 'Decrease next-open volume',
                      onPressed: () => widget.onChangeVolume(
                        row.tvSymbol,
                        (effective - row.volumeStep).clamp(row.volumeMin, row.volumeMax).toDouble(),
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _fmtVolume(current),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              decoration: showPending ? TextDecoration.lineThrough : null,
                              color: showPending ? scheme.onSurfaceVariant : null,
                            ),
                          ),
                          if (showPending)
                            Text(
                              _fmtVolume(effective),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.w700, fontSize: 12),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline, size: 22),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                      tooltip: 'Increase next-open volume',
                      onPressed: () => widget.onChangeVolume(
                        row.tvSymbol,
                        (effective + row.volumeStep).clamp(row.volumeMin, row.volumeMax).toDouble(),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // 2026-10-18, per the user: "make a spacing between each
                // row and next row in the card so user not pressing any
                // icon by mistake since icons you are using are too
                // small ... make them little larger" - bigger icons AND
                // a bigger tap target (32x32, up from the table's
                // compact 28x28) plus real gaps instead of spaceAround's
                // edge-to-edge packing, so an accidental tap on the wrong
                // control (e.g. Power right next to Ignite) is harder.
                // "include last toggle also ... with power, pause,
                // ignite" - the table's own Switch, scaled down to fit
                // alongside the three icon buttons in the same row.
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      icon: Icon(row.isPaused ? Icons.play_arrow : Icons.pause, size: 20),
                      color: row.isPaused ? Colors.green : scheme.onSurfaceVariant,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      tooltip: row.isPaused
                          ? 'Resume — engine will act on this pair again'
                          : 'Pause — engine will take no action on this pair',
                      onPressed: () => widget.onTogglePause(row.tvSymbol, !row.isPaused),
                    ),
                    IconButton(
                      icon: Icon(row.isIgnited ? Icons.bolt : Icons.bolt_outlined, size: 20),
                      color: row.isIgnited ? Colors.amber : scheme.onSurfaceVariant,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      tooltip: row.isIgnited
                          ? 'Ignited - will open regardless of margin level once triggered'
                          : 'Ignite - bypass margin level for this pair\'s next signal',
                      onPressed: () => widget.onIgnite(row.tvSymbol),
                    ),
                    Tooltip(
                      message: 'Last',
                      child: Transform.scale(
                        scale: 0.75,
                        child: Switch(
                          value: row.isLastTagged,
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          onChanged: (on) => widget.onToggleLast(row.tvSymbol, on),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.power_settings_new, size: 20),
                      color: Colors.orange,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      tooltip: 'Cancel this pair\'s pending attempt',
                      onPressed: () => widget.onTerminate(row.tvSymbol),
                    ),
                  ],
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
    // Table holds only real running (filled) positions; every waiting/
    // unfilled pair moves to its own card below instead (2026-10-18, per
    // the user). Card order is always alphabetical, independent of the
    // table's own cycling sort mode.
    final rows = _sorted(widget.rows.where((r) => r.status == AutoTradeStatus.running).toList());
    final waitingRows = widget.rows.where((r) => r.status != AutoTradeStatus.running).toList()
      ..sort((a, b) => a.tvSymbol.compareTo(b.tvSymbol));
    // The original trade in a copy group is whichever ticket is LOWEST -
    // MT5 assigns tickets sequentially as trades open, and a copy can only
    // ever be opened AFTER its original already exists (2026-10-15, per
    // the user: "the parent/original trade color should be darker than
    // the copied"). No separate original/copy tracking needed - this
    // derives it purely from data already on hand.
    final minTicketBySymbol = <String, int>{};
    for (final r in rows) {
      final t = r.ticket;
      if (t == null) continue;
      final current = minTicketBySymbol[r.mt5Symbol];
      if (current == null || t < current) minTicketBySymbol[r.mt5Symbol] = t;
    }
    final running = rows.length;
    final pending = waitingRows.where((r) => r.status == AutoTradeStatus.waitingPending).length;
    final noSignal = waitingRows.where((r) => r.status == AutoTradeStatus.waitingNoSignal).length;

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
            if (rows.isEmpty && waitingRows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No symbols configured yet.'),
              )
            else if (rows.isEmpty)
              const SizedBox.shrink()
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
                  columns: [
                    const DataColumn(label: Text('Symbol')),
                    const DataColumn(label: Text('Trade ID')),
                    const DataColumn(label: Text('Status')),
                    const DataColumn(label: Text('Side')),
                    const DataColumn(label: Text('Price')),
                    const DataColumn(label: Text('SL')),
                    const DataColumn(label: Text('TP')),
                    const DataColumn(label: Text('P&L')),
                    // Leverage/Investment/Extra Margin/Liquidation Price
                    // (2026-10-15, per the user). Leverage is a flat
                    // broker-set constant (Equiti Seychelles: 1:2000),
                    // never computed. Investment Value and Extra Margin
                    // come straight from real MT5 numbers (notional value,
                    // account free margin). Liquidation Price is a real,
                    // grounded ESTIMATE - see [AutoTradeRow.liquidationPrice]'s
                    // own doc comment for the exact formula and why it's an
                    // estimate rather than a fixed per-symbol number.
                    const DataColumn(label: Text('Leverage')),
                    const DataColumn(label: Text('Investment')),
                    const DataColumn(label: Text('Extra Margin')),
                    const DataColumn(label: Text('Liquidation')),
                    DataColumn(
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('SLL'),
                          const SizedBox(width: 2),
                          // 2026-10-13, per the user: "(i) icon... once
                          // user click on this icon... app will show the
                          // sll percent category setup in a dialog" - so
                          // the ladder's exact thresholds are always one
                          // tap away instead of something to remember.
                          InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => _showSllInfoDialog(context),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(
                                Icons.info_outline,
                                size: 14,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const DataColumn(label: Center(child: Text('Volume'))),
                    // Multiplier (2026-10-15, per the user): "+" opens one
                    // more copy trade on this pair - same direction/TP/
                    // volume, tighter -$1 SL - only while P&L is positive.
                    // Shows how many copies currently exist for this pair.
                    const DataColumn(label: Center(child: Text('Multiplier'))),
                    const DataColumn(label: Text('Open')),
                    if (!widget.hideUpdateCloseColumns) ...[
                      const DataColumn(label: Text('Update')),
                      const DataColumn(label: Text('Close A')),
                      const DataColumn(label: Text('Close B')),
                    ],
                    const DataColumn(label: Text('Duration')),
                    const DataColumn(label: Text('Interval')),
                    const DataColumn(label: Text('Check')),
                    const DataColumn(label: Text('Auto')),
                    const DataColumn(label: Text('Last')),
                    // Thunder/ignite icon (2026-10-17, per the user: "add a
                    // thunder icon per each pair .. where user can ignite
                    // any waiting pair") - see [AutoTradeRow.isIgnited]'s
                    // own doc comment.
                    const DataColumn(label: Text('Ignite')),
                    const DataColumn(label: Text('')),
                  ],
                  rows: [
                    for (final row in rows)
                      DataRow(
                        color: WidgetStateProperty.all(
                          _copyGroupColor(row, isOriginal: row.ticket == minTicketBySymbol[row.mt5Symbol]),
                        ),
                        cells: [
                          // 2026-10-18, per the user: "make sure that fav
                          // pairs stay in fav even if they filled and
                          // then running" - the underlying flag already
                          // survives fill/close unconditionally (see
                          // [FavoritePairStore]'s own doc comment, no
                          // consume() exists), this star is just the
                          // visual confirmation of that for a RUNNING
                          // row - the waiting cards' own star icon isn't
                          // reachable once a pair fills and leaves that
                          // view.
                          DataCell(
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (row.isFavorite) ...[
                                  const Icon(Icons.star, size: 14, color: Colors.amber),
                                  const SizedBox(width: 4),
                                ],
                                Text(row.mt5Symbol),
                              ],
                            ),
                          ),
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
                              // 2026-10-14, per the user: "in side column
                              // .. replace sell with short, replace buy
                              // with long" - display only, row.direction
                              // itself stays 'buy'/'sell' for the color
                              // check right below and every other call
                              // site that reads it.
                              switch (row.direction) {
                                'sell' => 'SHORT',
                                'buy' => 'LONG',
                                _ => '—',
                              },
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
                          DataCell(
                            Text(
                              _fmtPrice(row.price),
                              style: TextStyle(
                                color: _isNearLiquidation(row) ? Colors.yellow.shade800 : null,
                                fontWeight: _isNearLiquidation(row) ? FontWeight.w700 : null,
                              ),
                            ),
                          ),
                          DataCell(Text(_fmtPrice(row.stopLoss))),
                          DataCell(Text(_fmtPrice(row.takeProfit))),
                          DataCell(
                            Text(
                              row.profit == null
                                  ? '—'
                                  // 2026-10-13, per the user: value alongside
                                  // percentage, e.g. "2.50 (132.78%)" - the
                                  // percentage is P&L relative to the
                                  // position's own notional value (see
                                  // [AutoTradeRow.pnlPercent]'s own doc
                                  // comment for why, not account margin),
                                  // omitted entirely if it can't be computed.
                                  : '${row.profit! >= 0 ? '+' : ''}${row.profit!.toStringAsFixed(2)}'
                                        '${row.pnlPercent == null ? '' : ' (${row.pnlPercent! >= 0 ? '+' : ''}${row.pnlPercent!.toStringAsFixed(2)}%)'}',
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
                            Text(
                              row.status == AutoTradeStatus.running ? '1:2000' : '—',
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ),
                          DataCell(
                            Text(
                              row.investmentValue == null
                                  ? '—'
                                  : '\$${row.investmentValue!.toStringAsFixed(2)}',
                            ),
                          ),
                          DataCell(
                            Text(
                              row.extraMargin == null
                                  ? '—'
                                  : '\$${row.extraMargin!.toStringAsFixed(2)}',
                              style: TextStyle(
                                color: row.extraMargin == null ? scheme.onSurfaceVariant : null,
                              ),
                            ),
                          ),
                          DataCell(
                            Tooltip(
                              message: row.liquidationPrice == null
                                  ? ''
                                  : 'Estimate: price at which this position alone would reach '
                                      "Equiti's 30% stop-out level, if every other position "
                                      'stayed exactly as it is right now.',
                              child: Text(
                                row.liquidationPrice == null ? '—' : _fmtPrice(row.liquidationPrice),
                                style: TextStyle(
                                  color: row.liquidationPrice == null
                                      ? scheme.onSurfaceVariant
                                      : _isNearLiquidation(row)
                                      ? Colors.yellow.shade800
                                      : null,
                                  fontWeight: _isNearLiquidation(row) ? FontWeight.w700 : null,
                                ),
                              ),
                            ),
                          ),
                          DataCell(
                            // 2026-10-13, per the user: "a column in auto
                            // table to show current sll set... so user know
                            // what is current sll setup without any
                            // guessing" - the SL ratchet rung currently
                            // locked for this position (§10.1), straight
                            // from SlRatchetStore. Null doesn't mean "no SLL
                            // set" for a RUNNING (filled) position though -
                            // it means the ratchet hasn't crossed its first
                            // rung (+5%) yet, so the SL is still whatever
                            // baseline SL (§10.2) was set at ignition: the
                            // flat -$5 baseline. Showing a bare "—"
                            // there used to read as "nothing is protecting
                            // this trade," which isn't true - per the user:
                            // "i want sll column to reflect exactly sll not
                            // a blank." But a WAITING pair (no fill yet - no
                            // ticket, no SL set at all) genuinely has no SLL
                            // to show - per the user: "if pair is not yet
                            // filled then sll should be blank."
                            Text(
                              row.status != AutoTradeStatus.running
                                  ? '—'
                                  : row.slRatchetThreshold == null
                                      // A copy's own baseline SL is -$1, not
                                      // the normal -$5 (2026-10-16, per the
                                      // user: "why in sll for copied trade
                                      // is set -5$ ?? while it should be
                                      // -1$????") - this label was hardcoded
                                      // to the normal baseline everywhere,
                                      // never accounting for a copy's own
                                      // tighter one.
                                      ? (row.isCopy ? '-\$1' : '-\$5')
                                      : '+${row.slRatchetThreshold}%',
                              style: TextStyle(
                                color: row.status == AutoTradeStatus.running &&
                                        row.slRatchetThreshold != null
                                    ? Colors.green
                                    : scheme.onSurfaceVariant,
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
                                // A Multiplier copy's own volume is always
                                // fixed at 1 lot by design (2026-10-16, per
                                // the user: "volum cant be adjusted" - a
                                // copy's row previously still showed the
                                // normal +/- stepper, which silently
                                // adjusted the SYMBOL's shared next-open
                                // volume from a row where that doesn't even
                                // apply, since a copy's own size can never
                                // actually change). Locked, no stepper.
                                if (row.isCopy) {
                                  return SizedBox(
                                    width: 120,
                                    child: Tooltip(
                                      message: 'Copy volume is fixed at 1 lot',
                                      child: Text(
                                        _fmtVolume(row.currentVolume ?? 1),
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: scheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                  );
                                }
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
                            // Blank for a non-running (waiting/not yet
                            // filled) row (2026-10-15, per the user) - the
                            // Multiplier only ever makes sense for an
                            // actual running position to copy.
                            row.status != AutoTradeStatus.running
                                ? const Text('—')
                                : Builder(
                                    builder: (context) {
                                      final canAddCopy =
                                          row.profit != null && row.profit! > 0;
                                      return Row(
                                        mainAxisSize: MainAxisSize.min,
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            '×${row.copyCount}',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                              color: row.copyCount > 1 ? Colors.amber.shade800 : null,
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.add_circle_outline, size: 16),
                                            visualDensity: VisualDensity.compact,
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                            color: canAddCopy ? scheme.primary : scheme.onSurfaceVariant.withValues(alpha: 0.3),
                                            tooltip: canAddCopy
                                                ? 'Open a copy trade (same direction/TP/volume, -\$1 SL)'
                                                : 'Only available while this trade\'s P&L is positive',
                                            onPressed: canAddCopy ? () => widget.onAddCopy(row.tvSymbol) : null,
                                          ),
                                        ],
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
                          if (!widget.hideUpdateCloseColumns) ...[
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
                          ],
                          DataCell(Text(_fmtDuration(row.openedAt))),
                          // Blank for a non-running row (2026-10-15, per
                          // the user) - the interval/timeframe label only
                          // means something once a trade is actually
                          // running on it.
                          DataCell(
                            Text(
                              row.status == AutoTradeStatus.running
                                  ? AutoCategory.oneHour.label
                                  : '—',
                            ),
                          ),
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
                          // Play/Pause button (2026-10-09, per the user:
                          // "it is better to make it a play/pause button
                          // rather than a toggle, so it can show exactly
                          // the action it is doing" - replaces the former
                          // Auto Switch, whose on/off state didn't convey
                          // which action pressing it would take). Paused
                          // (row.isPaused true) shows a Play icon - pressing
                          // it resumes AND queues the instant re-check
                          // (EngineControlRepository.setPaused); active
                          // shows a Pause icon - pressing it pauses in
                          // place, touching nothing about the pair's
                          // current running/waiting state.
                          DataCell(
                            IconButton(
                              icon: Icon(row.isPaused ? Icons.play_arrow : Icons.pause),
                              color: row.isPaused ? Colors.green : scheme.onSurfaceVariant,
                              tooltip: row.isPaused
                                  ? 'Resume — engine will act on this pair again'
                                  : 'Pause — engine will take no action on this pair',
                              onPressed: () => widget.onTogglePause(row.tvSymbol, !row.isPaused),
                            ),
                          ),
                          DataCell(
                            Switch(
                              value: row.isLastTagged,
                              onChanged: (on) => widget.onToggleLast(row.tvSymbol, on),
                            ),
                          ),
                          // Thunder/ignite icon (2026-10-17, per the user):
                          // enabled only for a waiting pair (no running
                          // position), per the user's own follow-up: "ignite
                          // icon is active only for waiting pairs. disabled
                          // for running pairs." Lit amber once armed so the
                          // user can see which pairs are currently bypassing
                          // margin level for their next signal.
                          DataCell(
                            IconButton(
                              icon: Icon(row.isIgnited ? Icons.bolt : Icons.bolt_outlined),
                              color: row.status == AutoTradeStatus.running
                                  ? scheme.onSurfaceVariant.withValues(alpha: 0.3)
                                  : row.isIgnited
                                  ? Colors.amber
                                  : scheme.onSurfaceVariant,
                              tooltip: row.status == AutoTradeStatus.running
                                  ? 'Only available for a waiting pair'
                                  : row.isIgnited
                                  ? 'Ignited - will open regardless of margin level once triggered'
                                  : 'Ignite - bypass margin level for this pair\'s next signal',
                              onPressed: row.status == AutoTradeStatus.running
                                  ? null
                                  : () => widget.onIgnite(row.tvSymbol),
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
            if (waitingRows.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Waiting (unfilled)', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final row in waitingRows) _buildWaitingCard(context, row),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
