import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/core/core_storage.dart';
import 'package:trading_mt5/data/identity/pnl_series_store.dart';
import 'package:trading_mt5/widgets/pnl_chart.dart';

void main() {
  late Directory dir;
  late PnlSeriesStore store;
  final t0 = DateTime.utc(2026, 10, 25, 14);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tmt5_pnl_test');
    store = PnlSeriesStore(CoreStorage.forRoot(dir.path));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('records every change, one file per ticket, in order', () {
    expect(store.record(1, -0.5, -2.0, now: t0), isTrue);
    expect(store.record(1, -0.3, -1.2, now: t0.add(const Duration(seconds: 5))), isTrue);
    expect(store.record(2, 1.0, null, now: t0), isTrue);
    final s = store.read(1);
    expect(s.map((p) => p.profit), [-0.5, -0.3]);
    expect(s.last.percent, -1.2);
    expect(store.read(2).single.percent, isNull);
  });

  test('an unchanged P&L inside the gap is skipped, then sampled again after it', () {
    store.record(1, 2.0, 1.0, now: t0);
    expect(store.record(1, 2.0, 1.0, now: t0.add(const Duration(seconds: 10))), isFalse);
    expect(store.record(1, 2.0, 1.0, now: t0.add(const Duration(seconds: 16))), isTrue);
    expect(store.read(1), hasLength(2));
  });

  test('series survives an engine restart (new store instance reads the file)', () {
    store.record(7, 3.0, 2.0, now: t0);
    expect(PnlSeriesStore(CoreStorage.forRoot(dir.path)).read(7).single.profit, 3.0);
  });

  testWidgets('chart paints with negative and positive points without throwing', (tester) async {
    final points = [
      for (var i = 0; i < 20; i++)
        PnlPoint(time: 1792900000 + i * 600, profit: (i - 8) * 0.3, percent: (i - 8) * 1.5),
    ];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 400, child: PnlChart(points: points)))));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PnlChart(points: [points.first]))));
    expect(find.textContaining('not enough samples'), findsOneWidget);
  });
}
