import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/core/core_storage.dart';
import 'package:trading_mt5/data/models/app_config.dart';
import 'package:trading_mt5/data/risk/risk_gate.dart';

/// 2026-10-25, per the user: untriggered pending orders are cancelled once
/// margin level is below 200% (it used to be only at the 150% hard gate).
void main() {
  late Directory dir;
  late RiskGate gate;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tmt5_margin_test');
    gate = RiskGate(CoreStorage.forRoot(dir.path), AppConfig.defaultConfig.risk);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('below 200% cancels resting orders; the hard open block stays at 150%', () {
    gate.updateMarginLevel(199.9);
    expect(gate.shouldCancelRestingOrders, isTrue);
    expect(gate.marginGateTripped, isFalse);
    gate.updateMarginLevel(150);
    expect(gate.shouldCancelRestingOrders, isTrue);
    expect(gate.marginGateTripped, isTrue);
  });

  test('at or above 200% resting orders are left alone', () {
    gate.updateMarginLevel(200);
    expect(gate.shouldCancelRestingOrders, isFalse);
    gate.updateMarginLevel(290);
    expect(gate.shouldCancelRestingOrders, isFalse);
  });

  test('no exposure (no margin reading) never cancels', () {
    gate.updateMarginLevel(null);
    expect(gate.shouldCancelRestingOrders, isFalse);
  });
}
