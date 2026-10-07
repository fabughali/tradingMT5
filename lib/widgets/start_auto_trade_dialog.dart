import 'package:flutter/material.dart';

import '../data/models/watched_symbol.dart';

/// Shown when the user checks pairs in the Dashboard's Market Watch list
/// and presses "Start Auto Trade" (2026-10-03, per the user: "app should
/// show dialog for those pairs not listed in redlist in trading view once
/// user choose pairs to be auto managed"). Crypto/forex symbols already
/// have a safe, automatic TradingView-symbol derivation
/// ([WatchedSymbol.derivedTradingViewSymbol]) and just need confirming;
/// stocks don't (this broker's stock `symbol` values are its own display
/// names, not real tickers — see that getter's own doc comment), so each
/// one gets an editable field instead. Returns a `{mt5Symbol: tvSymbol}`
/// map of everything the user actually confirmed — a stock left blank is
/// dropped, not defaulted to anything guessed.
class StartAutoTradeDialog extends StatefulWidget {
  const StartAutoTradeDialog({super.key, required this.symbols});

  final List<WatchedSymbol> symbols;

  @override
  State<StartAutoTradeDialog> createState() => _StartAutoTradeDialogState();
}

class _StartAutoTradeDialogState extends State<StartAutoTradeDialog> {
  late final Map<String, TextEditingController> _stockControllers = {
    for (final s in widget.symbols)
      if (s.isStock) s.symbol: TextEditingController(),
  };

  @override
  void dispose() {
    for (final c in _stockControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Start Auto Trade'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Confirm the TradingView ticker for each pair below, then '
              'these start auto-trading immediately.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final s in widget.symbols)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: s.isStock
                            ? Row(
                                children: [
                                  Expanded(flex: 2, child: Text(s.symbol)),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    flex: 3,
                                    child: TextField(
                                      controller: _stockControllers[s.symbol],
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        hintText: 'TradingView ticker',
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : Row(
                                children: [
                                  Expanded(child: Text(s.symbol)),
                                  Icon(Icons.arrow_forward, size: 14, color: scheme.onSurfaceVariant),
                                  const SizedBox(width: 8),
                                  Text(
                                    s.derivedTradingViewSymbol ?? '—',
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Stocks have no automatic TradingView ticker (this broker\'s '
              'own display names aren\'t real tickers) — type the correct '
              'one, or leave blank to skip that symbol.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final result = <String, String>{};
            for (final s in widget.symbols) {
              final tv = s.isStock
                  ? _stockControllers[s.symbol]!.text.trim().toUpperCase()
                  : s.derivedTradingViewSymbol;
              if (tv == null || tv.isEmpty) continue;
              result[s.symbol] = tv;
            }
            Navigator.of(context).pop(result);
          },
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
