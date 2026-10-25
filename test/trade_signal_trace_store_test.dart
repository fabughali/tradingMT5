import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/core/core_storage.dart';
import 'package:trading_mt5/data/identity/trade_signal_trace_store.dart';
import 'package:trading_mt5/data/models/auto_category.dart';
import 'package:trading_mt5/data/models/bot_history_entry.dart';
import 'package:trading_mt5/data/models/trade_direction.dart';

void main() {
  late Directory dir;
  late TradeSignalTraceStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tmt5_trace_test');
    store = TradeSignalTraceStore(CoreStorage.forRoot(dir.path));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  TradeTraceEntry e(String action, String signal, int bar) =>
      TradeTraceEntry(at: DateTime.utc(2026, 10, 25, 14), action: action, signal: signal, barTime: bar);

  test('every event on a ticket is kept in order, per ticket', () {
    store.add(1, e('open', 'BUY_OPEN1', 100));
    store.add(2, e('open', 'SELL_OPEN1', 200));
    store.add(1, e('update', 'ZIGZAG_BUY', 150));
    expect(store.peek(1).map((x) => x.action), ['open', 'update']);
    expect(store.peek(2).single.signal, 'SELL_OPEN1');
  });

  test('take returns the trace and removes it (trade closed)', () {
    store.add(1, e('open', 'BUY_OPEN1', 100));
    expect(store.take(1).single.barTime, 100);
    expect(store.peek(1), isEmpty);
  });

  test('a late-fill intent survives a restart (new store instance) and is one-shot', () {
    store.rememberIntent(
      '1h|LTCUSD.LV',
      PendingOpenIntent(signal: 'BUY_OPEN1', barTime: 1792854000, worm10: true, placedAt: DateTime.now().toUtc()),
    );
    final reopened = TradeSignalTraceStore(CoreStorage.forRoot(dir.path));
    final intent = reopened.takeIntent('1h|LTCUSD.LV');
    expect(intent?.signal, 'BUY_OPEN1');
    expect(intent?.barTime, 1792854000);
    expect(intent?.worm10, isTrue);
    expect(reopened.takeIntent('1h|LTCUSD.LV'), isNull);
  });

  test('a stale intent is ignored', () {
    store.rememberIntent(
      'k',
      PendingOpenIntent(
        signal: 'HH',
        barTime: 1,
        worm10: false,
        placedAt: DateTime.now().toUtc().subtract(const Duration(days: 4)),
      ),
    );
    expect(store.takeIntent('k'), isNull);
  });

  test('traces and intents do not overwrite each other', () {
    store.add(1, e('open', 'BUY_OPEN1', 100));
    store.rememberIntent('k', PendingOpenIntent(signal: 'HH', barTime: 1, worm10: false, placedAt: DateTime.now().toUtc()));
    expect(store.peek(1), hasLength(1));
    expect(store.takeIntent('k'), isNotNull);
    expect(store.peek(1), hasLength(1));
  });

  test('History entry keeps the trace through JSON', () {
    final entry = BotHistoryEntry(
      id: 'x',
      ts: DateTime.utc(2026, 10, 25),
      mt5Symbol: 'ETHUSD.lv',
      tradingViewSymbol: 'ETHUSDT',
      category: AutoCategory.oneHour,
      ticket: 1,
      direction: TradeDirection.long,
      entryPrice: 1,
      startTime: DateTime.utc(2026, 10, 25),
      signalTrace: [e('open', 'BUY_OPEN1', 100).toJson(), e('close', 'ZIGZAG_SELL', 200).toJson()],
    );
    final back = BotHistoryEntry.fromJson(entry.toJson());
    expect(back.signalTrace?.map((m) => m['action']), ['open', 'close']);
    expect(BotHistoryEntry.fromJson({...entry.toJson()}..remove('signal_trace')).signalTrace, isNull);
  });
}
