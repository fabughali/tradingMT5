/// The 7 order types MT5's native MCP server supports across
/// `trade_send_market_order` (marketExecution) and `trade_send_pending_order`
/// (the other 6). Only marketExecution is wired up in the New Order screen
/// so far — the rest are listed for the picker but not yet functional
/// (per the user, 2026-09-17: "other options will talk about it later").
enum OrderType {
  marketExecution,
  buyLimit,
  sellLimit,
  buyStop,
  sellStop,
  buyStopLimit,
  sellStopLimit,
}

extension OrderTypeX on OrderType {
  String get label => switch (this) {
    OrderType.marketExecution => 'Market Execution',
    OrderType.buyLimit => 'Buy Limit',
    OrderType.sellLimit => 'Sell Limit',
    OrderType.buyStop => 'Buy Stop',
    OrderType.sellStop => 'Sell Stop',
    OrderType.buyStopLimit => 'Buy Stop Limit',
    OrderType.sellStopLimit => 'Sell Stop Limit',
  };

  bool get isImplemented => this == OrderType.marketExecution;
}
