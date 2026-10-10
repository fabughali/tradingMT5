import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/app_config.dart';
import '../data/models/instrument.dart';
import '../data/mt5/mt5_client.dart';
import '../data/mt5/symbol_resolver.dart';
import '../data/providers/app_providers.dart';

enum _CheckState { idle, checking, pass, fail }

/// "Add Pair" dialog (2026-10-10, per the user: "user should have capability
/// to add/remove pairs in forex/crypto/stock. but be careful, adding a pair
/// should be confirmed from three apps (mt5: if this pair is listed, trading
/// view: if this pair matching the name or need mapping, tradingMT5: if this
/// pair existed in the list or not)"). Three independent checks must all
/// pass before "Add" is enabled:
///  - tradingMT5: a plain local config.json read (instant, no I/O round trip).
///  - MT5: [Mt5Client.findSymbolInFullCatalog] — direct from the GUI, since
///    MT5's MCP protocol safely supports multiple concurrent client
///    connections (unlike TradingView's CDP connection below).
///  - TradingView: routed through [EngineControlRepository.requestSymbolResolve]
///    / [peekSymbolResolve] — the engine owns the one real CDP connection to
///    TradingView, so this dialog can't check directly and instead polls the
///    file-based request/response store until the engine's next cycle
///    answers it.
class AddPairDialog extends ConsumerStatefulWidget {
  const AddPairDialog({super.key});

  @override
  ConsumerState<AddPairDialog> createState() => _AddPairDialogState();
}

class _AddPairDialogState extends ConsumerState<AddPairDialog> {
  AssetClass _assetClass = AssetClass.crypto;
  Instrument? _selectedInstrument;
  final _searchCtrl = TextEditingController();
  final _mt5Ctrl = TextEditingController();
  final _tvCtrl = TextEditingController();

  _CheckState _tmt5Check = _CheckState.idle;
  String? _tmt5Detail;

  _CheckState _mt5Check = _CheckState.idle;
  String? _mt5Detail;
  Map<String, dynamic>? _mt5Record;

  _CheckState _tvCheck = _CheckState.idle;
  String? _tvDetail;

  Timer? _tvPollTimer;
  int _tvPollElapsedMs = 0;
  // 2026-10-10, live-tested: a busy engine cycle (e.g. right after a
  // technique switch triggers several reverse-checks) can take 50s+ to
  // reach this candidate's turn - confirmed live with KASUSDT, which
  // genuinely resolved but only after 55s, well past an earlier 30s
  // timeout that showed a false "timed out" despite the engine's own
  // answer landing correctly moments later. 120s covers a normal cycle
  // with real margin.
  static const _tvPollTimeout = Duration(seconds: 120);

  bool _adding = false;

  @override
  void dispose() {
    _tvPollTimer?.cancel();
    // Tidy up the scratch request so a stale answer never confuses the
    // NEXT Add Pair attempt for the same candidate.
    if (_tvCtrl.text.trim().isNotEmpty) {
      ref.read(controlRepositoryProvider).clearSymbolResolve(_tvCtrl.text.trim());
    }
    _searchCtrl.dispose();
    _mt5Ctrl.dispose();
    _tvCtrl.dispose();
    super.dispose();
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

  void _pickInstrument(Instrument instrument) {
    setState(() {
      _selectedInstrument = instrument;
      _searchCtrl.text = instrument.displayName;
      _mt5Ctrl.text = SymbolResolver.candidateFor(instrument) ?? '';
      _tvCtrl.text = _defaultTvGuess(instrument) ?? '';
      _resetChecks();
    });
  }

  void _resetChecks() {
    _tmt5Check = _CheckState.idle;
    _tmt5Detail = null;
    _mt5Check = _CheckState.idle;
    _mt5Detail = null;
    _mt5Record = null;
    _tvCheck = _CheckState.idle;
    _tvDetail = null;
    _tvPollTimer?.cancel();
  }

  Future<void> _runChecks() async {
    final mt5Symbol = _mt5Ctrl.text.trim();
    final tvSymbol = _tvCtrl.text.trim().toUpperCase();
    if (mt5Symbol.isEmpty || tvSymbol.isEmpty) return;

    setState(() {
      _resetChecks();
      _tmt5Check = _CheckState.checking;
      _mt5Check = _CheckState.checking;
      _tvCheck = _CheckState.checking;
      _tvDetail = 'Waiting for the engine\'s next cycle — can take up to a minute or two';
    });

    // tradingMT5: instant local check against config.json's own mappings.
    final config = ref.read(controlRepositoryProvider).currentConfig;
    final duplicate = config.symbols.any(
      (s) =>
          s.tradingViewSymbol.toUpperCase() == tvSymbol ||
          s.mt5Symbol.toUpperCase() == mt5Symbol.toUpperCase(),
    );
    setState(() {
      _tmt5Check = duplicate ? _CheckState.fail : _CheckState.pass;
      _tmt5Detail = duplicate ? 'Already mapped in tradingMT5' : 'Not yet in tradingMT5 — OK to add';
    });

    // MT5: direct GUI-side call (safe — MT5's MCP protocol allows multiple
    // concurrent client connections, unlike TradingView's CDP connection).
    unawaited(_checkMt5(mt5Symbol));

    // TradingView: routed through the engine's one CDP connection.
    ref.read(controlRepositoryProvider).requestSymbolResolve(tvSymbol);
    _tvPollElapsedMs = 0;
    _tvPollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _pollTv(tvSymbol));
  }

  Future<void> _checkMt5(String mt5Symbol) async {
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
      final record = await client.findSymbolInFullCatalog(mt5Symbol);
      if (!mounted) return;
      setState(() {
        _mt5Record = record;
        _mt5Check = record != null ? _CheckState.pass : _CheckState.fail;
        _mt5Detail = record != null
            ? 'Found in MT5\'s full catalog as "${record['symbol']}"'
            : 'No symbol named "$mt5Symbol" in MT5\'s catalog';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mt5Check = _CheckState.fail;
        _mt5Detail = 'MT5 check failed: $e';
      });
    } finally {
      client.close();
    }
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
    });
  }

  bool get _allPass =>
      _tmt5Check == _CheckState.pass &&
      _mt5Check == _CheckState.pass &&
      _tvCheck == _CheckState.pass;

  Future<void> _addPair() async {
    if (!_allPass || _adding) return;
    setState(() => _adding = true);
    final tvSymbol = _tvCtrl.text.trim().toUpperCase();
    final mt5Symbol = (_mt5Record?['symbol'] as String?) ?? _mt5Ctrl.text.trim();
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
        // concurrently. A blind retry can hit the exact same slow window
        // and time out again. The only answer that's actually trustworthy
        // is asking MT5 directly afterward whether the symbol is visible
        // now, regardless of whether the add call itself reported success
        // - up to 3 attempts, 3s apart, since the first add may still be
        // settling server-side even after its own client call already
        // timed out once.
        var visible = false;
        for (var attempt = 0; attempt < 3 && !visible; attempt++) {
          try {
            await client.addMarketWatchSymbol(mt5Symbol);
          } catch (_) {
            // Ignored here - checked for real via getWatchedSymbols below
            // instead of trusting this call's own success/failure.
            // Deliberately NOT findSymbolInFullCatalog - that checks the
            // broker's full 2000+-symbol universe (include_hidden: true),
            // which GALAUSD.lv (and most candidates) is already IN before
            // ever being added to Market Watch, so it would report
            // "visible" even when addMarketWatchSymbol had done nothing at
            // all. getWatchedSymbols only returns what's actually selected
            // into Market Watch right now - the real thing being checked.
          }
          try {
            final watched = await client.getWatchedSymbols();
            visible = watched.any(
              (s) => (s['symbol'] as String? ?? '').toUpperCase() == mt5Symbol.toUpperCase(),
            );
          } catch (_) {
            // This verification call can be just as slow under the same
            // concurrent MT5 load as the add call above - a transient
            // failure here just means "try the whole thing again," not
            // "give up."
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
    final filtered = requestedInstruments
        .where((i) => i.assetClass == _assetClass)
        .where(
          (i) =>
              _searchCtrl.text.isEmpty ||
              i.displayName.toLowerCase().contains(_searchCtrl.text.toLowerCase()) ||
              i.key.toLowerCase().contains(_searchCtrl.text.toLowerCase()),
        )
        .toList();

    return AlertDialog(
      title: const Text('Add Pair'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<AssetClass>(
                key: const ValueKey('assetClassPicker'),
                segments: const [
                  ButtonSegment(value: AssetClass.forex, label: Text('Forex')),
                  ButtonSegment(value: AssetClass.crypto, label: Text('Crypto')),
                  ButtonSegment(value: AssetClass.stock, label: Text('Stock')),
                ],
                selected: {_assetClass},
                onSelectionChanged: (s) => setState(() {
                  _assetClass = s.first;
                  _selectedInstrument = null;
                  _resetChecks();
                }),
              ),
              const SizedBox(key: ValueKey('gap1'), height: 12),
              TextField(
                key: const ValueKey('searchField'),
                controller: _searchCtrl,
                decoration: const InputDecoration(
                  labelText: 'Search',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              // 2026-10-10, live-tested bug: this box used to be a plain
              // conditional sibling with no key, so every keystroke that
              // flipped it in/out shifted the MT5/TradingView fields below
              // to a different position in the Column's children list -
              // Flutter's unkeyed-list reconciliation then tore down and
              // rebuilt THEIR element (and focus/keystrokes with it) every
              // time this box appeared or disappeared, so typed text in
              // those fields kept vanishing. A stable key on every sibling
              // here (this one included, via KeyedSubtree) makes Flutter
              // match each child by identity instead of position, so the
              // fields below keep their focus regardless of what this box
              // is doing.
              if (_searchCtrl.text.isNotEmpty && _selectedInstrument == null)
                KeyedSubtree(
                  key: const ValueKey('suggestionsBox'),
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 160),
                    margin: const EdgeInsets.only(top: 4),
                    decoration: BoxDecoration(
                      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: filtered.isEmpty
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text('No match — enter the MT5/TradingView symbols manually below.'),
                          )
                        : ListView(
                            shrinkWrap: true,
                            children: [
                              for (final i in filtered)
                                ListTile(
                                  dense: true,
                                  title: Text(i.displayName),
                                  subtitle: Text(i.key),
                                  onTap: () => _pickInstrument(i),
                                ),
                            ],
                          ),
                  ),
                ),
              const SizedBox(key: ValueKey('gap2'), height: 12),
              TextField(
                key: const ValueKey('mt5Field'),
                controller: _mt5Ctrl,
                decoration: const InputDecoration(
                  labelText: 'MT5 symbol (candidate)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(_resetChecks),
              ),
              const SizedBox(key: ValueKey('gap3'), height: 8),
              TextField(
                key: const ValueKey('tvField'),
                controller: _tvCtrl,
                decoration: const InputDecoration(
                  labelText: 'TradingView symbol (candidate)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                textCapitalization: TextCapitalization.characters,
                onChanged: (_) => setState(_resetChecks),
              ),
              const SizedBox(key: ValueKey('gap4'), height: 12),
              FilledButton.tonal(
                key: const ValueKey('checkAvailabilityButton'),
                onPressed: _mt5Ctrl.text.trim().isEmpty || _tvCtrl.text.trim().isEmpty
                    ? null
                    : _runChecks,
                child: const Text('Check availability'),
              ),
              const SizedBox(key: ValueKey('gap5'), height: 12),
              _CheckRow(key: const ValueKey('tmt5Check'), label: 'tradingMT5', state: _tmt5Check, detail: _tmt5Detail),
              _CheckRow(key: const ValueKey('mt5Check'), label: 'MT5', state: _mt5Check, detail: _mt5Detail),
              _CheckRow(key: const ValueKey('tvCheck'), label: 'TradingView', state: _tvCheck, detail: _tvDetail),
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
  const _CheckRow({super.key, required this.label, required this.state, this.detail});

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
