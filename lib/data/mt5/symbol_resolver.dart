import '../models/instrument.dart';

/// Turns a TradingView-style instrument identifier into the candidate MT5
/// symbol name for THIS broker (Equiti) — confirmed live 2026-09-17 against
/// the full `get_marketwatch_symbols` catalog (2247 symbols). Naming
/// conventions are broker-specific; re-verify if the broker ever changes.
///
/// Confirmed suffix conventions:
///  - forex:  BASEQUOTE + '.sd'  (e.g. EURUSD.sd) — with two known
///    exceptions (USDINR, USDKRW) that carry NO suffix at all.
///  - crypto: BASE + 'USD.lv'    (e.g. BTCUSD.lv) — MT5 has no USDT, every
///    crypto pair quotes against plain USD instead (per the user).
///  - stocks: full company name, NOT the ticker (e.g. NVDA -> "NVIDIA").
///    Too ambiguous to derive automatically (many near-miss false
///    positives when fuzzy-matching — see ARCHITECTURE.md) so this is an
///    explicit, hand-verified map. Add new tickers here after confirming
///    the exact spelling live.
class SymbolResolver {
  SymbolResolver._();

  /// Forex pairs where MT5 quotes the pair in reverse of common convention,
  /// or without the usual '.sd' suffix. Key is the pair AS WRITTEN by the
  /// user (e.g. 'USD/NZD'); value is the exact MT5 symbol.
  static const Map<String, String> _forexExceptions = {
    'USD/NZD': 'NZDUSD.sd', // MT5 only quotes NZD as base, never as quote.
    'USD/INR': 'USDINR', // No '.sd' suffix on this one.
    'USD/KRW': 'USDKRW', // No '.sd' suffix on this one.
  };

  /// Pairs with no equivalent on this broker at all, but a close working
  /// substitute exists — surfaced as a suggestion, not silently swapped in.
  static const Map<String, String> forexSubstitutes = {
    'USD/CNY': 'USDCNH.sd — offshore yuan, closest available substitute',
  };

  static const Map<String, String> _stockNames = {
    'NVDA': 'NVIDIA',
    'TSLA': 'Tesla',
    'AAPL': 'Apple',
    'AMZN': 'Amazon',
    'AMD': 'AMD',
    'MSFT': 'Microsoft',
    'GOOGL': 'Alphabet',
    'META': 'Facebook', // MT5 still lists it under the old name.
    'AVGO': 'Broadcom',
    'INTC': 'Intel',
    'PLTR': 'Palantir',
    'MU': 'Micron',
    'ORCL': 'Oracle',
    'NFLX': 'Netflix',
    'AMAT': 'AppliedMat',
    'QCOM': 'Qualcom', // Sic — MT5's own spelling, one 'm'.
    'MSTR': 'MicroStrat',
    'BAC': 'BankAmerica',
    'JPM': 'JPMorgan',
    'F': 'Ford',
    'NIO': 'NIO',
    'COIN': 'Coinbase',
    'MARA': 'Marathon Digital',
    'SMCI': 'Super Micro Computer',
    'PLUG': 'PlugPower',
    'PFE': 'Pfizer',
    'C': 'Citigroup',
    'WMT': 'Walmart',
    'XOM': 'Exxon',
  };

  /// Returns the candidate MT5 symbol for [instrument], or null if this
  /// asset class/key combination has no known resolution rule (stocks not
  /// yet in [_stockNames]).
  static String? candidateFor(Instrument instrument) {
    switch (instrument.assetClass) {
      case AssetClass.forex:
        final exception = _forexExceptions[instrument.key];
        if (exception != null) return exception;
        return '${instrument.key.replaceAll('/', '')}.sd';
      case AssetClass.crypto:
        return '${instrument.key}USD.lv';
      case AssetClass.stock:
        return _stockNames[instrument.key];
    }
  }
}
