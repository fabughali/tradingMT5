import 'watched_symbol.dart';

/// A running position's side/size/SL/TP — enough for a BUY/SELL tag plus
/// the volume and stop levels, without pulling in the full raw MT5 position
/// object.
class OpenPositionInfo {
  const OpenPositionInfo({
    required this.side,
    required this.volume,
    this.sl,
    this.tp,
  });

  /// 'buy' or 'sell', exactly as MT5 reports it.
  final String side;
  final double volume;
  final double? sl;
  final double? tp;

  bool get isBuy => side.toLowerCase() == 'buy';
}

/// One poll's worth of live MT5 state: what's in Market Watch, plus which
/// of those symbols currently have an open position (and its side/volume/
/// SL/TP) — fetched together so the GUI never shows one without the other
/// out of sync.
class MarketWatchSnapshot {
  const MarketWatchSnapshot({
    required this.symbols,
    required this.openPositionSides,
  });

  final List<WatchedSymbol> symbols;
  final Map<String, OpenPositionInfo> openPositionSides;

  bool hasOpenPosition(String symbol) => openPositionSides.containsKey(symbol);
}
