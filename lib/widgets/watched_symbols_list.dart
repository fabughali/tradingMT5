import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/core_theme.dart';
import '../data/models/app_config.dart';
import '../data/models/market_watch_snapshot.dart';
import '../data/models/watched_symbol.dart';
import '../data/providers/app_providers.dart';
import '../data/mt5/mt5_client.dart';

/// Grouped Forex/Crypto/Stocks rendering of a live Market Watch snapshot —
/// the Dashboard's one and only pair list (2026-10-03, per the user: "why
/// app is making a separate list for non-auto managed pairs ... I want app
/// to keep same current list of pairs ... within same list it is now
/// forex/stock/crypto ... choose from those three lists and then click on
/// start auto trade" — this replaced the old, narrower `NonAutoPairsCard`,
/// which only covered symbols already in config.json instead of MT5's full
/// live Market Watch). Each row has a checkbox (disabled while the symbol
/// has an open position — see [MarketWatchSnapshot.hasOpenPosition]) and a
/// BUY/SELL tag + volume/SL/TP when one exists. Checking symbols enables
/// two independent actions: "Remove from watch list" (MT5 visibility only
/// — never touches a trade) and "Start Auto Trade" (adds each checked
/// symbol to auto-managed, creating a fresh config.json mapping first if
/// one doesn't exist yet).
class WatchedSymbolsList extends ConsumerStatefulWidget {
  const WatchedSymbolsList({
    super.key,
    required this.snapshot,
    required this.onStartAutoTrade,
    required this.autoManagedBases,
    required this.symbolMappings,
    required this.onRemovePair,
    this.maxPerSection,
  });

  final MarketWatchSnapshot snapshot;

  /// The checked symbols, in full (not just their names) — the caller
  /// needs each one's [WatchedSymbol.isCrypto]/[isForex]/[isStock] and
  /// [WatchedSymbol.derivedTradingViewSymbol] to build the confirmation
  /// dialog and the new config.json mapping, if any.
  final void Function(List<WatchedSymbol>) onStartAutoTrade;

  /// Bare uppercase TradingView bases currently in `auto-managed-bases.json`
  /// (2026-10-04, per the user: "check box should not be clickable if pair
  /// is on waiting or pending ... but they are in auto list" - any state,
  /// not just running, which [MarketWatchSnapshot.hasOpenPosition] already
  /// covers on its own).
  final Set<String> autoManagedBases;

  /// config.json's existing mappings - needed to resolve a symbol's own
  /// TradingView base for the [autoManagedBases] lookup, since a stock has
  /// no automatic derivation ([WatchedSymbol.derivedTradingViewSymbol]
  /// returns null for those) and must fall back to whatever mapping
  /// already exists, if any.
  final List<SymbolMapping> symbolMappings;

  /// "Remove pair" affordance on an already-mapped symbol's card (2026-10-10,
  /// per the user's Add/Remove Pairs request). Second argument is whether
  /// the symbol currently has an open position — the caller refuses the
  /// removal outright in that case rather than stranding a live position
  /// with no engine code path able to manage it.
  final void Function(String tvSymbol, bool hasRunningPosition) onRemovePair;

  /// Cap rows shown per section (e.g. for a Dashboard summary) — null shows
  /// everything.
  final int? maxPerSection;

  @override
  ConsumerState<WatchedSymbolsList> createState() => _WatchedSymbolsListState();
}

class _WatchedSymbolsListState extends ConsumerState<WatchedSymbolsList> {
  final Set<String> _selected = {};
  bool _removing = false;

  void _toggle(String symbol, bool? checked) {
    setState(() {
      if (checked == true) {
        _selected.add(symbol);
      } else {
        _selected.remove(symbol);
      }
    });
  }

  Future<void> _removeSelected() async {
    if (_selected.isEmpty || _removing) return;
    setState(() => _removing = true);
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
      for (final symbol in _selected.toList()) {
        await client.removeMarketWatchSymbol(symbol);
      }
    } finally {
      client.close();
    }
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _removing = false;
    });
    ref.invalidate(watchedSymbolsProvider);
  }

  /// Resolves [s]'s TradingView base the same way [EngineControlRepository.
  /// addSymbolMapping] would (an existing config.json mapping first, else
  /// the automatic crypto/forex derivation), then checks it against
  /// [WatchedSymbolsList.autoManagedBases] (2026-10-04, per the user: a
  /// pair already auto-managed - running, waiting, or pending, any state -
  /// shouldn't be re-selectable here).
  bool _isAlreadyAutoManaged(WatchedSymbol s) {
    final tv = _mappedTvSymbol(s);
    if (tv == null || tv.isEmpty) return false;
    return widget.autoManagedBases.contains(tv.toUpperCase());
  }

  /// [s]'s tradingview_symbol per config.json's own mapping, if one exists
  /// yet — unlike [_isAlreadyAutoManaged], this is true for any mapped
  /// symbol regardless of auto-managed status, since "Remove pair" targets
  /// the mapping itself (config.json's `symbols` array), not auto-management.
  String? _mappedTvSymbol(WatchedSymbol s) {
    final existing = widget.symbolMappings.where(
      (m) => m.mt5Symbol.toUpperCase() == s.symbol.toUpperCase(),
    );
    return existing.isNotEmpty ? existing.first.tradingViewSymbol : null;
  }

  @override
  Widget build(BuildContext context) {
    final symbols = widget.snapshot.symbols;
    if (symbols.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Nothing in MT5 Market Watch yet.'),
      );
    }
    final forex = symbols.where((s) => s.isForex).toList();
    final crypto = symbols.where((s) => s.isCrypto).toList();
    final stocks = symbols.where((s) => s.isStock).toList();
    final autoManagedMt5Symbols = {
      for (final s in symbols)
        if (_isAlreadyAutoManaged(s)) s.symbol,
    };
    final mappedTvSymbols = {
      for (final s in symbols)
        if (_mappedTvSymbol(s) case final tv?) s.symbol: tv,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_selected.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () {
                    widget.onStartAutoTrade(
                      symbols.where((s) => _selected.contains(s.symbol)).toList(),
                    );
                    setState(_selected.clear);
                  },
                  icon: const Icon(Icons.play_arrow, size: 18),
                  label: Text('Start Auto Trade (${_selected.length})'),
                ),
                OutlinedButton.icon(
                  onPressed: _removing ? null : _removeSelected,
                  icon: _removing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.remove_circle_outline),
                  label: Text('Remove from watch list (${_selected.length})'),
                ),
              ],
            ),
          ),
        _Section(
          title: 'Forex',
          symbols: forex,
          max: widget.maxPerSection,
          snapshot: widget.snapshot,
          selected: _selected,
          onToggle: _toggle,
          autoManagedMt5Symbols: autoManagedMt5Symbols,
          mappedTvSymbols: mappedTvSymbols,
          onRemovePair: widget.onRemovePair,
          accent: context.tradingColors.forex,
          accentContainer: context.tradingColors.forexContainer,
        ),
        _Section(
          title: 'Crypto',
          symbols: crypto,
          max: widget.maxPerSection,
          snapshot: widget.snapshot,
          selected: _selected,
          onToggle: _toggle,
          autoManagedMt5Symbols: autoManagedMt5Symbols,
          mappedTvSymbols: mappedTvSymbols,
          onRemovePair: widget.onRemovePair,
          accent: context.tradingColors.crypto,
          accentContainer: context.tradingColors.cryptoContainer,
        ),
        _Section(
          title: 'Stocks',
          symbols: stocks,
          max: widget.maxPerSection,
          snapshot: widget.snapshot,
          selected: _selected,
          onToggle: _toggle,
          autoManagedMt5Symbols: autoManagedMt5Symbols,
          mappedTvSymbols: mappedTvSymbols,
          onRemovePair: widget.onRemovePair,
          accent: context.tradingColors.stock,
          accentContainer: context.tradingColors.stockContainer,
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.symbols,
    required this.snapshot,
    required this.selected,
    required this.onToggle,
    required this.autoManagedMt5Symbols,
    required this.mappedTvSymbols,
    required this.onRemovePair,
    required this.accent,
    required this.accentContainer,
    this.max,
  });

  final String title;
  final List<WatchedSymbol> symbols;
  final MarketWatchSnapshot snapshot;
  final Set<String> selected;
  final void Function(String symbol, bool? checked) onToggle;
  final Set<String> autoManagedMt5Symbols;
  final Map<String, String> mappedTvSymbols;
  final void Function(String tvSymbol, bool hasRunningPosition) onRemovePair;
  final Color accent;
  final Color accentContainer;
  final int? max;

  @override
  Widget build(BuildContext context) {
    if (symbols.isEmpty) return const SizedBox.shrink();
    final shown = max != null && symbols.length > max!
        ? symbols.sublist(0, max)
        : symbols;
    final hiddenCount = symbols.length - shown.length;
    // 2026-10-06, per the user: "make the cards (crypto, forex, stock)
    // expanded" (the section containers, not the pair cards inside them) -
    // "still narrow, make it full width" - no horizontal inset at all now,
    // the section runs edge-to-edge with whatever width its parent gives
    // it.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        // 2026-10-06, per the user: "the blue/yellow card is not full
        // width" - the Container was sizing itself to fit its content (the
        // wrapped pair cards), which stops short of the screen edge once
        // the Wrap's last row is partial. Forcing the full available width
        // explicitly, regardless of how the cards inside happen to wrap.
        width: double.infinity,
        decoration: BoxDecoration(
          color: accentContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border(left: BorderSide(color: accent, width: 4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Text(
                '$title (${symbols.length})',
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(color: accent, fontWeight: FontWeight.bold),
              ),
            ),
            // Card grid (2026-10-06, per the user: "each pair inside a
            // card, the card will work as selection checkbox ... rounded
            // corner cards ... cards are wrapped to save some area") -
            // replaces the old one-row-per-symbol ListTile list. Each card
            // IS the selection control (the whole card is the tap target,
            // no separate checkbox), and [Wrap] fills the available width
            // with as many as fit per line instead of a single column.
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in shown)
                    _SymbolCard(
                      symbol: s,
                      position: snapshot.openPositionSides[s.symbol],
                      alreadyAutoManaged: autoManagedMt5Symbols.contains(s.symbol),
                      mappedTvSymbol: mappedTvSymbols[s.symbol],
                      checked: selected.contains(s.symbol),
                      accent: accent,
                      onToggle: (checked) => onToggle(s.symbol, checked),
                      onRemovePair: onRemovePair,
                    ),
                ],
              ),
            ),
            if (hiddenCount > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Text(
                  '+$hiddenCount more — see the Symbols tab',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

/// One pair, as a tappable selection card (2026-10-06, per the user: "each
/// pair inside a card, the card will work as selection checkbox ... rounded
/// corner cards ... in the card has all details ... cards are wrapped to
/// save some area") - replaces the former ListTile+Checkbox row. The whole
/// card is the tap target; there's no separate checkbox control any more.
class _SymbolCard extends StatelessWidget {
  const _SymbolCard({
    required this.symbol,
    required this.position,
    required this.alreadyAutoManaged,
    required this.mappedTvSymbol,
    required this.checked,
    required this.accent,
    required this.onToggle,
    required this.onRemovePair,
  });

  final WatchedSymbol symbol;
  final OpenPositionInfo? position;

  /// 2026-10-04, per the user: "check box should not be clickable if pair
  /// is on waiting or pending ... but they are in auto list" - true for
  /// ANY state (running, waiting, pending), not just a live position.
  final bool alreadyAutoManaged;

  /// This symbol's tradingview_symbol per config.json's own mapping, if any
  /// - non-null means a "Remove pair" affordance should show (2026-10-10).
  final String? mappedTvSymbol;
  final bool checked;
  final Color accent;
  final ValueChanged<bool?> onToggle;
  final void Function(String tvSymbol, bool hasRunningPosition) onRemovePair;

  @override
  Widget build(BuildContext context) {
    final colors = context.tradingColors;
    final scheme = Theme.of(context).colorScheme;
    final disabled = position != null || alreadyAutoManaged;

    final Color background;
    final Color border;
    if (disabled) {
      background = scheme.surfaceContainerHighest.withValues(alpha: 0.4);
      border = Colors.transparent;
    } else if (checked) {
      background = accent.withValues(alpha: 0.16);
      border = accent;
    } else {
      background = scheme.surface;
      border = scheme.outlineVariant;
    }

    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: disabled ? null : () => onToggle(!checked),
          child: Container(
            width: 172,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: border, width: checked ? 1.5 : 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        symbol.symbol,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (checked)
                      Icon(Icons.check_circle, size: 16, color: accent)
                    else if (!disabled && mappedTvSymbol == null)
                      Icon(Icons.circle_outlined, size: 16, color: scheme.outlineVariant),
                    if (mappedTvSymbol != null)
                      Tooltip(
                        message: position != null
                            ? 'Cannot remove — a position is currently running'
                            : 'Remove pair',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => onRemovePair(mappedTvSymbol!, position != null),
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(
                              Icons.delete_outline,
                              size: 16,
                              color: position != null ? scheme.outlineVariant : scheme.error,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'bid ${symbol.bid.toStringAsFixed(symbol.digits)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  'ask ${symbol.ask.toStringAsFixed(symbol.digits)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (position != null) ...[
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: position!.isBuy ? colors.profitContainer : colors.lossContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          position!.isBuy ? 'BUY' : 'SELL',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: position!.isBuy ? colors.profit : colors.loss,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    'vol ${position!.volume}'
                    '${position!.sl != null ? '  SL ${position!.sl!.toStringAsFixed(symbol.digits)}' : ''}'
                    '${position!.tp != null ? '  TP ${position!.tp!.toStringAsFixed(symbol.digits)}' : ''}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ] else if (alreadyAutoManaged) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'AUTO · waiting',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
