/// The app's own closes record history from the last live snapshot taken
/// BEFORE the close was sent, so the exit price and profit were the quote of
/// that moment, not the real fill (found live 2026-10-27: BCH ticket
/// 1662352559 recorded exit 290.45, MT5 filled at 290.25). Returns a copy of
/// [position] with `price_last`/`profit` replaced by the matching closed
/// record from MT5's position history ([history], the `positions` list of
/// `get_trading_history_positions`), or [position] unchanged when [ticket]
/// isn't in it yet.
Map<String, dynamic> withActualCloseFill(
  Map<String, dynamic> position,
  List<dynamic> history,
  int ticket,
) {
  for (final h in history) {
    if (h is! Map<String, dynamic>) continue;
    if ('${h['position_id']}' != '$ticket') continue;
    final closePrice = h['close_price'] as num?;
    final profit = h['profit'] as num?;
    if (closePrice == null && profit == null) return position;
    return {
      ...position,
      if (closePrice != null) 'price_last': closePrice,
      if (profit != null) 'profit': profit,
    };
  }
  return position;
}
