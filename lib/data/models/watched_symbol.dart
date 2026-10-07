/// One symbol currently in MT5's Market Watch, as reported live by
/// `get_marketwatch_symbols`. Asset class is inferred from this broker's
/// own naming convention (confirmed live 2026-09-17): crypto uses a `.lv`
/// suffix, forex uses `.sd` (with two known no-suffix exceptions), stocks
/// have neither.
class WatchedSymbol {
  const WatchedSymbol({
    required this.symbol,
    required this.bid,
    required this.ask,
    required this.digits,
    required this.volumeMin,
    required this.volumeMax,
    required this.volumeStep,
  });

  final String symbol;
  final double bid;
  final double ask;
  final int digits;

  /// The three fields the New Order screen's volume stepper needs — min/max
  /// bounds and the increment/decrement size, all broker-reported per
  /// symbol (confirmed live 2026-09-17: these vary a lot, e.g. BTCUSD.lv is
  /// 0.001/4/0.001 while XRPUSD.lv is 100/40000/100).
  final double volumeMin;
  final double volumeMax;
  final double volumeStep;

  factory WatchedSymbol.fromJson(Map<String, dynamic> json) => WatchedSymbol(
    symbol: json['symbol'] as String,
    bid: (json['bid'] as num?)?.toDouble() ?? 0,
    ask: (json['ask'] as num?)?.toDouble() ?? 0,
    digits: (json['digits'] as num?)?.toInt() ?? 2,
    volumeMin: (json['volume_min'] as num?)?.toDouble() ?? 0.01,
    volumeMax: (json['volume_max'] as num?)?.toDouble() ?? 100,
    volumeStep: (json['volume_step'] as num?)?.toDouble() ?? 0.01,
  );

  /// A few forex pairs on this broker carry no suffix at all (USDINR,
  /// USDKRW — see symbol_resolver.dart) — called out explicitly here so
  /// they don't get miscategorized as stocks.
  static const _noSuffixForexPairs = {'USDINR', 'USDKRW'};

  bool get isCrypto => symbol.endsWith('.lv');
  bool get isForex => symbol.endsWith('.sd') || _noSuffixForexPairs.contains(symbol);
  bool get isStock => !isCrypto && !isForex;

  /// Reverse of `SymbolResolver.candidateFor` — this broker's MT5 symbol ->
  /// candidate TradingView symbol, for a symbol not yet in config.json's
  /// explicit mapping (2026-10-03, per the user: "if app added any new
  /// crypto pair to app crypto list, for example KKKusd.lv, then in
  /// trading view it should be KKKusdt [no binance]"). Crypto strips the
  /// '.lv' suffix and turns the trailing USD into USDT (confirmed live
  /// against every existing config.json mapping — BTCUSD.lv -> BTCUSDT,
  /// etc.); forex strips '.sd' (or is used as-is for the two no-suffix
  /// exceptions). Stocks have no safe automatic rule — this broker's stock
  /// `symbol` values are its own display names ("PlugPower", "MicroStrat"),
  /// not real tickers — so this returns null and the caller must ask the
  /// user for the real TradingView ticker by hand.
  String? get derivedTradingViewSymbol {
    if (isCrypto) {
      final base = symbol.substring(0, symbol.length - '.lv'.length).toUpperCase();
      if (base.endsWith('USD')) {
        return '${base.substring(0, base.length - 3)}USDT';
      }
      return '${base}T';
    }
    if (isForex) {
      if (symbol.toUpperCase().endsWith('.SD')) {
        return symbol.substring(0, symbol.length - '.sd'.length).toUpperCase();
      }
      return symbol.toUpperCase();
    }
    return null;
  }
}
