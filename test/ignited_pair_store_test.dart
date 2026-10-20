import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/core/core_storage.dart';
import 'package:trading_mt5/data/identity/ignited_pair_store.dart';

void main() {
  late Directory dir;
  late IgnitedPairStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tmt5_ignite_test');
    store = IgnitedPairStore(CoreStorage.forRoot(dir.path));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('ignite arms the pair (case-insensitive)', () {
    store.ignite('ethusdt');
    expect(store.isIgnited('ETHUSDT'), isTrue);
  });

  test('consume = one-shot used up OR user cancel - pair is off again', () {
    store.ignite('ETHUSDT');
    store.consume('ETHUSDT');
    expect(store.isIgnited('ETHUSDT'), isFalse);
  });

  test('consuming one pair never touches another ignited pair', () {
    store.ignite('ETHUSDT');
    store.ignite('BTCUSDT');
    store.consume('BTCUSDT');
    expect(store.isIgnited('ETHUSDT'), isTrue);
    expect(store.isIgnited('BTCUSDT'), isFalse);
  });

  test('state survives a fresh store instance (GUI and engine are separate processes)', () {
    store.ignite('ETHUSDT');
    final other = IgnitedPairStore(CoreStorage.forRoot(dir.path));
    expect(other.isIgnited('ETHUSDT'), isTrue);
    other.consume('ETHUSDT');
    expect(store.isIgnited('ETHUSDT'), isFalse);
  });
}
