import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/core/core_storage.dart';
import 'package:trading_mt5/data/models/auto_category.dart';
import 'package:trading_mt5/data/models/bot_history_entry.dart';
import 'package:trading_mt5/data/models/trade_direction.dart';
import 'package:trading_mt5/data/providers/app_providers.dart';
import 'package:trading_mt5/screens/app/history_screen.dart';

BotHistoryEntry _entry(int i, double profit) => BotHistoryEntry(
  id: 'id$i',
  ts: DateTime.utc(2026, 10, 25, 17, i),
  mt5Symbol: 'ETHUSD.lv',
  tradingViewSymbol: 'ETHUSDT',
  category: AutoCategory.oneHour,
  ticket: 1662352500 + i,
  direction: i.isEven ? TradeDirection.long : TradeDirection.short,
  entryPrice: 2335.6,
  exitPrice: 2356.9,
  volume: 0.4,
  stopLoss: 667.8,
  takeProfit: 3447.4,
  realizedProfit: profit,
  realizedProfitPercent: profit / 10,
  startTime: DateTime.utc(2026, 10, 25, 14),
  endTime: DateTime.utc(2026, 10, 25, 17, i),
  openSignalType: 'BUY_OPEN1',
  openSignalAt: 1792854000,
  closeSignalType: 'ZIGZAG_SELL',
  closeSignalAt: 1792900800,
  stopReason: i % 3 == 0 ? 'closed_by_user' : 'opposite_signal',
  detail: 'Closed automatically on an opposite worm10 event (ZIGZAG_SELL).',
  sllAtTermination: '+\$5',
  investmentValue: 934.24,
  extraMargin: 11.4,
  liquidationPrice: 1912,
  signalTrace: const [
    {'at': '2026-10-25T14:00:00Z', 'action': 'open', 'signal': 'BUY_OPEN1', 'bar_time': 1792854000},
    {'at': '2026-10-25T17:00:00Z', 'action': 'close', 'signal': 'ZIGZAG_SELL', 'note': 'opposite_signal'},
  ],
);

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('tmt5_history_test');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  final entries = [for (var i = 0; i < 7; i++) _entry(i, i == 3 ? 0 : (i.isEven ? 7.04 : -1.23))];

  Widget host() => ProviderScope(
    overrides: [
      storageProvider.overrideWithValue(CoreStorage.forRoot(dir.path)),
      botHistoryProvider.overrideWith((ref) => Stream.value(entries)),
    ],
    child: const MaterialApp(home: HistoryScreen()),
  );

  for (final (width, perRow) in [(500.0, 1), (900.0, 2), (1500.0, 3)]) {
    testWidgets('history cards: $perRow per row at width $width, no overflow', (tester) async {
      tester.view.physicalSize = Size(width, 4000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(host());
      await tester.pump();
      expect(tester.takeException(), isNull);
      final remarks = find.text('Remarks');
      expect(remarks, findsWidgets);
      final firstRowY = tester.getTopLeft(remarks.first).dy;
      final sameRow = remarks.evaluate().where((e) => (tester.getTopLeft(find.byWidget(e.widget).first).dy - firstRowY).abs() < 1).length;
      expect(sameRow, perRow);
    });
  }

  testWidgets('totals line and the wins / losses filter', (tester) async {
    tester.view.physicalSize = const Size(1500, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.pump();
    expect(find.textContaining('7 closed  ·  win 4  ·  loss 2'), findsOneWidget);
    expect(find.text('Remarks'), findsNWidgets(7));
    await tester.tap(find.text('Wins'));
    await tester.pump();
    expect(find.text('Remarks'), findsNWidgets(4));
    await tester.tap(find.text('Losses'));
    await tester.pump();
    expect(find.text('Remarks'), findsNWidgets(2));
  });

  testWidgets('more menu opens the signal trace', (tester) async {
    tester.view.physicalSize = const Size(1500, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Signal trace'));
    await tester.pumpAndSettle();
    expect(find.textContaining('signal trace'), findsOneWidget);
    expect(find.textContaining('Open  LL'), findsOneWidget);
  });
}
