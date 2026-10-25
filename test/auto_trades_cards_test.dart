import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/models/auto_trade_row.dart';
import 'package:trading_mt5/widgets/auto_trades_card.dart';

AutoTradeRow _running(String sym, double profit, {int ticket = 1}) => AutoTradeRow(
  tvSymbol: '${sym}USDT',
  mt5Symbol: '$sym.lv',
  status: AutoTradeStatus.running,
  isAutoManaged: true,
  isPaused: false,
  isLastTagged: false,
  direction: profit >= 0 ? 'buy' : 'sell',
  price: 2335.6,
  currentPrice: 2344.1,
  stopLoss: 667.8,
  takeProfit: 3447.4,
  profit: profit,
  pnlPercent: profit / 10,
  ticket: ticket,
  openedAt: DateTime.now().subtract(const Duration(hours: 2, minutes: 14)),
  startTag: 'BUY_OPEN1',
  startAt: 1792854000,
  investmentValue: 934.24,
  extraMargin: 11.4,
  liquidationPrice: 1912,
  currentVolume: 0.4,
  volumeMin: 0.01,
  volumeStep: 0.01,
  volumeMax: 100,
);

AutoTradeRow _waiting(String sym, AutoTradeStatus status, {String? reason, bool paused = false}) => AutoTradeRow(
  tvSymbol: '${sym}USDT',
  mt5Symbol: '$sym.lv',
  status: status,
  isAutoManaged: true,
  isPaused: paused,
  isLastTagged: false,
  direction: status == AutoTradeStatus.waitingPending ? 'buy' : null,
  price: status == AutoTradeStatus.waitingPending ? 0.00512 : null,
  ticket: status == AutoTradeStatus.waitingPending ? 1662352578 : null,
  waitingReason: reason,
  desiredVolume: 40,
  volumeMin: 1,
  volumeStep: 1,
  volumeMax: 1000,
);

Widget _host(List<AutoTradeRow> rows, {bool hide = false}) => MaterialApp(
  home: Scaffold(
    body: SingleChildScrollView(
      child: AutoTradesCard(
        rows: rows,
        hideUpdateCloseColumns: hide,
        onTogglePause: (_, _) {},
        onToggleLast: (_, _) {},
        onTerminate: (_) {},
        onChangeVolume: (_, _) {},
        onAddCopy: (_) {},
        onIgnite: (_) {},
        onFavorite: (_, _) {},
        historyPnlSince: 0,
        pnlSinceTimestamp: null,
        onResetPnlSince: () {},
        liveAccountPnl: 1.0,
      ),
    ),
  ),
);

void main() {
  final rows = [
    _running('ETHUSD', 3.42, ticket: 11),
    _running('ATOMUSD', -0.21, ticket: 12),
    _running('BTCUSD', 0, ticket: 13),
    _waiting('GALAUSD', AutoTradeStatus.waitingPending),
    _waiting('ADAUSD', AutoTradeStatus.waitingNoSignal, reason: 'MARGIN GATE: margin level 139.1% <= 150.0%'),
    _waiting('AAVEUSD', AutoTradeStatus.waitingNoSignal),
    _waiting('XRPUSD', AutoTradeStatus.waitingNoSignal, paused: true),
  ];

  for (final width in [420.0, 1000.0, 1500.0]) {
    testWidgets('cards lay out without overflow at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_host(rows));
      expect(tester.takeException(), isNull);
      expect(find.text('ETHUSD.lv'), findsOneWidget);
      expect(find.text('Order resting'), findsOneWidget);
      expect(find.text('Blocked'), findsOneWidget);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.textContaining('3 running · 1 resting · 1 blocked · 2 waiting'), findsOneWidget);
    });
  }

  testWidgets('waiting cards: resting first, then blocked, waiting, paused', (tester) async {
    tester.view.physicalSize = const Size(1500, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(rows));
    final order = ['GALAUSD.lv', 'ADAUSD.lv', 'AAVEUSD.lv', 'XRPUSD.lv']
        .map((s) => tester.getTopLeft(find.text(s)).dx)
        .toList();
    expect(order, [...order]..sort());
  });

  testWidgets('Supertrend technique hides Update/Close on running cards', (tester) async {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(rows, hide: true));
    expect(find.text('Update '), findsNothing);
    await tester.pumpWidget(_host(rows));
    expect(find.text('Update '), findsWidgets);
  });
}
