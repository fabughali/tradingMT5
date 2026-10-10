import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/app_config.dart';
import '../data/models/instrument.dart';
import '../data/models/watched_symbol.dart';
import '../data/mt5/mt5_client.dart';
import '../data/mt5/symbol_resolver.dart';
import '../data/providers/app_providers.dart';

enum _CheckState { idle, checking, pass, fail }

/// "Add Pair" dialog (2026-10-10, per the user's Add/Remove Pairs request,
/// then reworked the same day per further feedback: "user need to choose if
/// to add the pair to crypto or to forex or to stock... I believe app
/// should be smart enough to understand... why there are 3 search
/// textfield??? there should be only one"). A single query field drives
/// the whole flow:
///  1. tradingMT5 — an instant local check against config.json's existing
///     mappings. A match shows a SnackBar and stops right here; MT5/
///     TradingView are never even contacted for a pair already known.
///  2. MT5 — [Mt5Client.findSymbolInFullCatalog] (direct from the GUI; see
///     that method's own doc comment for why it's safe to call MT5 directly
///     but not TradingView). The real broker record this returns is also
///     how the asset class gets detected automatically: a `.lv` suffix is
///     crypto, `.sd` is forex (see [SymbolResolver]'s own doc comment for
///     this broker's confirmed naming conventions) - only when neither
///     matches (ambiguous between a forex no-suffix exception and a stock)
///     does a manual Forex/Crypto/Stock picker appear at all.
///  3. TradingView — routed through [EngineControlRepository.requestSymbolResolve]
///     / [peekSymbolResolve] (the engine owns the one real CDP connection,
///     this dialog can't check directly) using a symbol derived the same
///     way [WatchedSymbol.derivedTradingViewSymbol] already does in
///     reverse. If that guess doesn't resolve, a one-off override field
///     appears so the user can correct it without starting over - the one
///     case (stocks) this broker's own catalog names can't auto-derive.
/// "Add" enables only once MT5 and TradingView both pass.
class AddPairDialog extends ConsumerStatefulWidget {
  const AddPairDialog({super.key});

  @override
  ConsumerState<AddPairDialog> createState() => _AddPairDialogState();
}

class _AddPairDialogState extends ConsumerState<AddPairDialog> {
  final _queryCtrl = TextEditingController();
  final _tvOverrideCtrl = TextEditingController();

  bool _searching = false;
  bool _searchStarted = false;

  _CheckState _mt5Check = _CheckState.idle;
  String? _mt5Detail;
  Map<String, dynamic>? _mt5Record;

  _CheckState _tvCheck = _CheckState.idle;
  String? _tvDetail;
  String? _tvCandidate;
  bool _needsTvOverride = false;

  AssetClass? _resolvedClass;
  bool _needsManualClass = false;

  Timer? _tvPollTimer;
  int _tvPollElapsedMs = 0;
  // 2026-10-10, live-tested: a busy engine cycle (e.g. right after a
  // technique switch triggers several reverse-checks) can take 50s+ to
  // reach this candidate's turn - confirmed live with KASUSDT, which
  // genuinely resolved but only after 55s. 120s covers a normal cycle with
  // real margin.
  static const _tvPollTimeout = Duration(seconds: 120);

  bool _adding = false;

  @override
  void dispose() {
    _tvPollTimer?.cancel();
    // Tidy up the scratch request so a stale answer never confuses the
    // NEXT Add Pair attempt for the same candidate.
    if (_tvCandidate != null) {
      ref.read(controlRepositoryProvider).clearSymbolResolve(_tvCandidate!);
    }
    _queryCtrl.dispose();
    _tvOverrideCtrl.dispose();
    super.dispose();
  }

  String _normalize(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  Instrument? _matchCuratedInstrument(String query) {
    final q = query.trim().toLowerCase().replaceAll('/', '');
    final matches = requestedInstruments.where(
      (i) => i.displayName.toLowerCase() == query.trim().toLowerCase() || i.key.toLowerCase().replaceAll('/', '') == q,
    );
    return matches.isEmpty ? null : matches.first;
  }

  String? _defaultTvGuess(Instrument instrument) {
    switch (instrument.assetClass) {
      case AssetClass.forex:
        return instrument.key.replaceAll('/', '').toUpperCase();
      case AssetClass.crypto:
        return '${instrument.key.toUpperCase()}USDT';
      case AssetClass.stock:
        return instrument.key.toUpperCase();
    }
  }

  void _resetChecks() {
    _mt5Check = _CheckState.idle;
    _mt5Detail = null;
    _mt5Record = null;
    _tvCheck = _CheckState.idle;
    _tvDetail = null;
    _tvCandidate = null;
    _needsTvOverride = false;
    _resolvedClass = null;
    _needsManualClass = false;
    _searchStarted = false;
    _tvPollTimer?.cancel();
  }

  void _pickSuggestion(Instrument instrument) {
    setState(() {
      _queryCtrl.text = instrument.displayName;
      _resetChecks();
    });
    _runSearch();
  }

  Future<void> _runSearch() async {
    final query = _queryCtrl.text.trim();
    if (query.isEmpty || _searching) return;
    FocusScope.of(context).unfocus();

    // tradingMT5: instant local check against config.json's own mappings,
    // BEFORE any network call to MT5 or TradingView (2026-10-10, per the
    // user: "app need to check if pair is already listed in tradingmt5
    // before checking with mt5 and trading view ... if it is listed...
    // snack bar will appear").
    final config = ref.read(controlRepositoryProvider).currentConfig;
    final normQuery = _normalize(query);
    final duplicate = config.symbols.any((s) {
      final tv = _normalize(s.tradingViewSymbol);
      final mt5 = _normalize(s.mt5Symbol);
      return tv == normQuery || mt5 == normQuery || tv.contains(normQuery) || mt5.contains(normQuery);
    });
    if (duplicate) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Already in tradingMT5 — nothing to add.')),
      );
      return;
    }

    setState(() {
      _resetChecks();
      _searchStarted = true;
      _searching = true;
      _mt5Check = _CheckState.checking;
    });

    final matched = _matchCuratedInstrument(query);
    final mt5Candidate = matched != null ? (SymbolResolver.candidateFor(matched) ?? query) : query;

    // 2026-10-10, per the user: typing a TradingView-style crypto symbol
    // ("GALAUSDT") must still find MT5's own "GALAUSD.lv" - MT5 quotes
    // every crypto pair against plain USD, never USDT (see
    // [SymbolResolver]'s own doc comment). [_lookupMt5] already tries
    // appending a `.lv`/`.sd` suffix, but that alone can't bridge a
    // trailing "USDT" down to "USD" first, so a second candidate - the
    // query with a trailing "USDT" shortened to "USD" - is tried right
    // after the literal query whenever it looks like a TradingView-style
    // crypto name.
    final mt5Candidates = <String>[mt5Candidate];
    final upperCandidate = mt5Candidate.toUpperCase();
    if (upperCandidate.endsWith('USDT') && upperCandidate.length > 4) {
      mt5Candidates.add(upperCandidate.substring(0, upperCandidate.length - 1));
    }

    Map<String, dynamic>? record;
    for (final candidate in mt5Candidates) {
      record = await _lookupMt5(candidate);
      if (record != null) break;
    }
    if (!mounted) return;
    if (record == null) {
      setState(() {
        _searching = false;
        _mt5Check = _CheckState.fail;
        _mt5Detail ??= 'No symbol found for "$query" in MT5\'s catalog.';
      });
      return;
    }
    final realMt5Symbol = record['symbol'] as String? ?? mt5Candidate;
    setState(() {
      _mt5Record = record;
      _mt5Check = _CheckState.pass;
      _mt5Detail = 'Found in MT5 as "$realMt5Symbol"';
    });

    // Asset class: the curated instrument's own class if this matched one,
    // otherwise detected from the REAL matched symbol's own suffix - this
    // broker's confirmed naming convention (see SymbolResolver), not a
    // guess from the free-typed query.
    if (matched != null) {
      await _proceedWithClass(matched.assetClass, _defaultTvGuess(matched) ?? query.toUpperCase());
      return;
    }
    final probe = WatchedSymbol(
      symbol: realMt5Symbol,
      bid: 0,
      ask: 0,
      digits: 2,
      volumeMin: 0,
      volumeMax: 0,
      volumeStep: 0,
    );
    if (probe.isCrypto) {
      await _proceedWithClass(AssetClass.crypto, probe.derivedTradingViewSymbol ?? query.toUpperCase());
    } else if (probe.isForex) {
      await _proceedWithClass(AssetClass.forex, probe.derivedTradingViewSymbol ?? query.toUpperCase());
    } else {
      // No suffix - ambiguous between a stock and this broker's own
      // no-suffix forex exceptions (SymbolResolver already names them:
      // USDINR/USDKRW carry no '.sd' at all).
      final upper = realMt5Symbol.toUpperCase();
      if (upper == 'USDINR' || upper == 'USDKRW') {
        await _proceedWithClass(AssetClass.forex, upper);
      } else {
        setState(() {
          _searching = false;
          _needsManualClass = true;
        });
      }
    }
  }

  Future<Map<String, dynamic>?> _lookupMt5(String candidate) async {
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
      return await client.findSymbolInFullCatalog(candidate);
    } catch (e) {
      if (mounted) _mt5Detail = 'MT5 check failed: $e';
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _proceedWithClass(AssetClass cls, String tvGuess) async {
    if (!mounted) return;
    setState(() {
      _resolvedClass = cls;
      _needsManualClass = false;
      _searching = false;
    });
    await _runTvCheck(tvGuess);
  }

  Future<void> _runTvCheck(String tvCandidate) async {
    setState(() {
      _tvCandidate = tvCandidate;
      _tvCheck = _CheckState.checking;
      _tvDetail = 'Waiting for the engine\'s next cycle — can take up to a minute or two';
      _needsTvOverride = false;
    });
    ref.read(controlRepositoryProvider).requestSymbolResolve(tvCandidate);
    _tvPollElapsedMs = 0;
    _tvPollTimer?.cancel();
    _tvPollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _pollTv(tvCandidate));
  }

  void _pollTv(String tvSymbol) {
    final result = ref.read(controlRepositoryProvider).peekSymbolResolve(tvSymbol);
    _tvPollElapsedMs += 1500;
    if (result == null || result.isPending) {
      if (_tvPollElapsedMs >= _tvPollTimeout.inMilliseconds) {
        _tvPollTimer?.cancel();
        if (!mounted) return;
        setState(() {
          _tvCheck = _CheckState.fail;
          _tvDetail = 'TradingView check timed out';
          _needsTvOverride = true;
        });
      }
      return;
    }
    _tvPollTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _tvCheck = result.isFound ? _CheckState.pass : _CheckState.fail;
      _tvDetail = result.isFound
          ? 'TradingView resolves it as "${result.resolvedSymbol ?? tvSymbol}"'
          : 'TradingView has no chart for "$tvSymbol"';
      _needsTvOverride = !result.isFound;
    });
  }

  bool get _allPass => _mt5Check == _CheckState.pass && _tvCheck == _CheckState.pass;

  Future<void> _addPair() async {
    if (!_allPass || _adding || _mt5Record == null || _tvCandidate == null) return;
    setState(() => _adding = true);
    final tvSymbol = _tvCandidate!;
    final mt5Symbol = _mt5Record!['symbol'] as String;
    try {
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
        // 2026-10-10, caught live TWICE (a same-session retry wasn't
        // enough the first time) - addMarketWatchSymbol can succeed on
        // MT5's own side (confirmed server-side - "selected": true in the
        // catalog moments later) while the client-side HTTP call itself
        // still times out, under the combined load of the engine's own
        // ~5s polling plus every other GUI provider also hitting MT5's MCP
        // concurrently. Verifies the REAL state via getWatchedSymbols
        // afterward instead of trusting the add call's own success/
        // failure at all - up to 3 attempts, 3s apart.
        var visible = false;
        for (var attempt = 0; attempt < 3 && !visible; attempt++) {
          try {
            await client.addMarketWatchSymbol(mt5Symbol);
          } catch (_) {
            // Ignored - checked for real via getWatchedSymbols below.
          }
          try {
            final watched = await client.getWatchedSymbols();
            visible = watched.any(
              (s) => (s['symbol'] as String? ?? '').toUpperCase() == mt5Symbol.toUpperCase(),
            );
          } catch (_) {
            // Transient - the retry loop will try again.
          }
          if (!visible && attempt < 2) {
            await Future<void>.delayed(const Duration(seconds: 3));
          }
        }
        if (!visible) {
          throw Mt5ClientException(
            'MT5 never confirmed "$mt5Symbol" became visible in Market Watch.',
          );
        }
      } finally {
        client.close();
      }
      final repo = ref.read(controlRepositoryProvider);
      repo.addSymbolMapping(SymbolMapping(tradingViewSymbol: tvSymbol, mt5Symbol: mt5Symbol));
      repo.clearSymbolResolve(tvSymbol);
      ref.invalidate(configProvider);
      ref.invalidate(watchedSymbolsProvider);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _adding = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to add pair: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _queryCtrl.text.trim();
    final filtered = query.isEmpty || _searchStarted
        ? const <Instrument>[]
        : requestedInstruments
              .where(
                (i) =>
                    i.displayName.toLowerCase().contains(query.toLowerCase()) ||
                    i.key.toLowerCase().contains(query.toLowerCase()),
              )
              .toList();

    return AlertDialog(
      title: const Text('Add Pair'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                key: const ValueKey('searchRow'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _queryCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Pair (e.g. "Gala", "EUR/USD", "NVDA")',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      textCapitalization: TextCapitalization.characters,
                      onSubmitted: (_) => _runSearch(),
                      onChanged: (_) => setState(_resetChecks),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: query.isEmpty || _searching ? null : _runSearch,
                    child: _searching
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Search'),
                  ),
                ],
              ),
              // 2026-10-10, live-tested bug (fixed once already for the old
              // 3-field layout, same fix applies here): a conditional
              // sibling with no key shifts every field below it in the
              // Column's position list on every appear/disappear, and
              // Flutter's unkeyed reconciliation tears down and rebuilds
              // their element - focus and in-flight keystrokes included -
              // whenever that happens. Every conditional block below carries
              // a stable key for exactly this reason.
              if (filtered.isNotEmpty)
                KeyedSubtree(
                  key: const ValueKey('suggestionsBox'),
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 160),
                    margin: const EdgeInsets.only(top: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final i in filtered)
                          ListTile(
                            dense: true,
                            title: Text(i.displayName),
                            subtitle: Text('${i.key} · ${i.assetClass.name}'),
                            onTap: () => _pickSuggestion(i),
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(key: ValueKey('gap1'), height: 12),
              if (_mt5Check != _CheckState.idle)
                KeyedSubtree(
                  key: const ValueKey('mt5CheckRow'),
                  child: _CheckRow(label: 'MT5', state: _mt5Check, detail: _mt5Detail),
                ),
              if (_needsManualClass)
                KeyedSubtree(
                  key: const ValueKey('classPicker'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Found in MT5, but couldn\'t tell which list it belongs in — pick one:',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<AssetClass>(
                          segments: const [
                            ButtonSegment(value: AssetClass.forex, label: Text('Forex')),
                            ButtonSegment(value: AssetClass.crypto, label: Text('Crypto')),
                            ButtonSegment(value: AssetClass.stock, label: Text('Stock')),
                          ],
                          selected: _resolvedClass != null ? {_resolvedClass!} : const {},
                          emptySelectionAllowed: true,
                          onSelectionChanged: (s) =>
                              _proceedWithClass(s.first, _queryCtrl.text.trim().toUpperCase()),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_tvCheck != _CheckState.idle)
                KeyedSubtree(
                  key: const ValueKey('tvCheckRow'),
                  child: _CheckRow(label: 'TradingView', state: _tvCheck, detail: _tvDetail),
                ),
              if (_needsTvOverride)
                KeyedSubtree(
                  key: const ValueKey('tvOverrideRow'),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _tvOverrideCtrl,
                            decoration: const InputDecoration(
                              labelText: 'TradingView symbol (correct guess)',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            textCapitalization: TextCapitalization.characters,
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonal(
                          onPressed: () {
                            final v = _tvOverrideCtrl.text.trim().toUpperCase();
                            if (v.isNotEmpty) _runTvCheck(v);
                          },
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _adding ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _allPass && !_adding ? _addPair : null,
          child: _adding
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.state, this.detail});

  final String label;
  final _CheckState state;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget icon;
    switch (state) {
      case _CheckState.idle:
        icon = Icon(Icons.circle_outlined, size: 18, color: scheme.outlineVariant);
      case _CheckState.checking:
        icon = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      case _CheckState.pass:
        icon = Icon(Icons.check_circle, size: 18, color: Colors.green);
      case _CheckState.fail:
        icon = Icon(Icons.cancel, size: 18, color: scheme.error);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          icon,
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                if (detail != null)
                  Text(detail!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
