import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/core/core_storage.dart';
import 'package:trading_mt5/data/engine/volume_step.dart';
import 'package:trading_mt5/data/identity/trade_volume_store.dart';

void main() {
  late Directory dir;
  late TradeVolumeStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tmt5_vol_test');
    store = TradeVolumeStore(CoreStorage.forRoot(dir.path));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('clearAllAttempts drops step-downs only, keeps desired + last_applied', () {
    store.setDesired('ONE_HOUR|DOTUSDT', 3);
    store.setAttempt('ONE_HOUR|DOTUSDT', 1);
    store.setDesired('ONE_HOUR|XRPUSDT', 300);
    store.recordApplied('ONE_HOUR|XRPUSDT', 100);
    final cleared = store.clearAllAttempts();
    expect(cleared, ['ONE_HOUR|DOTUSDT']);
    expect(store.attempt('ONE_HOUR|DOTUSDT'), isNull);
    expect(store.desired('ONE_HOUR|DOTUSDT'), 3);
    expect(store.lastApplied('ONE_HOUR|XRPUSDT'), 100);
    expect(store.desired('ONE_HOUR|XRPUSDT'), 300);
  });

  test('recordApplied (also used for late fills now) clears the step-down', () {
    store.setDesired('ONE_HOUR|DOTUSDT', 3);
    store.setAttempt('ONE_HOUR|DOTUSDT', 1);
    store.recordApplied('ONE_HOUR|DOTUSDT', 1);
    expect(store.attempt('ONE_HOUR|DOTUSDT'), isNull);
    expect(store.lastApplied('ONE_HOUR|DOTUSDT'), 1);
  });

  group('the Dashboard -/+ stepper math (same snap the card now uses)', () {
    double step(double effective, int dir, double min, double stepSize, double max) =>
        snapVolumeToStep((effective + dir * stepSize).clamp(min, max).toDouble(), volumeMin: min, volumeStep: stepSize);

    test('XRP at its real minimum 100 (step 100): "-" stays at 100, never 99.99', () {
      expect(step(100, -1, 100, 100, 100000), 100);
    });

    test('off-grid stored values come out clean', () {
      expect(step(0.30000000000000004, 1, 0.1, 0.1, 100), 0.4);
      expect(step(0.30000000000000004, -1, 0.1, 0.1, 100), 0.2);
    });
  });
}
