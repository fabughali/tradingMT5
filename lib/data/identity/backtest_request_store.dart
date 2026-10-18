import '../../core/core_storage.dart';

/// The Technique Summary screen's "reverse calculation" backtester
/// (2026-10-17, per the user: "add three inputs and a button... investment
/// value, pair, number of days... app will make a reverse calculations").
/// One request slot at a time, by design - a backtest is a deliberate,
/// one-off analysis action, not something queued up repeatedly; a fresh
/// request simply overwrites whatever was pending. Drained by the engine's
/// own CDP connection (never a separate one - see [BacktestResultStore]'s
/// own doc comment for why), so it's queued through the SAME
/// request/response file pattern every other GUI action already uses.
class BacktestRequestStore {
  BacktestRequestStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic>? _readRaw() => _storage.readJsonObject(_storage.backtestRequestFile);

  void request({
    required String tvSymbol,
    // 2026-10-17, per the user: "why user have to choose from drop menu
    // list while i request you to make text field for pair... so user can
    // apply back test on any (listed or not listed pairs)" - the GUI now
    // resolves an unlisted pair's real MT5 symbol itself (same MT5+
    // TradingView search Add Pair uses) BEFORE ever sending this request,
    // so the engine never needs to look [tvSymbol] up in config.json's own
    // mappings - it just trades this exact pair.
    required String mt5Symbol,
    required double investment,
    required int days,
    // 2026-10-18, per the user: "inputs are investment, pair, days,
    // volum" - real, independent input, same as a live trade's own lot
    // size (see [EngineService._runBacktest]'s own doc comment for how
    // this feeds the real P&L math).
    required double volume,
  }) {
    _storage.writeJson(_storage.backtestRequestFile, {
      'tv_symbol': tvSymbol,
      'mt5_symbol': mt5Symbol,
      'investment': investment,
      'days': days,
      'volume': volume,
      'requested_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  /// Engine side: the one pending request, if any.
  Map<String, dynamic>? loadPending() => _readRaw();

  void clear() => _storage.deleteFileIfExists(_storage.backtestRequestFile);
}
