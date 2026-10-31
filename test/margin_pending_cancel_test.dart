import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/core/core_storage.dart';
import 'package:trading_mt5/data/models/app_config.dart';
import 'package:trading_mt5/data/risk/risk_gate.dart';

/// 2026-11-01 (v1.6.57): untriggered pending orders are cancelled at the same
/// 150% floor that blocks new opens (they were cancelled below 200% before,
/// which would delete the stop orders the floor now allows between 150-200%).
void main() {
  late Directory dir;
  late RiskGate gate;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tmt5_margin_test');
    gate = RiskGate(CoreStorage.forRoot(dir.path), AppConfig.defaultConfig.risk);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('at or below 150% cancels resting orders and blocks opens', () {
    gate.updateMarginLevel(150);
    expect(gate.shouldCancelRestingOrders, isTrue);
    expect(gate.marginGateTripped, isTrue);
  });

  test('above 150% resting orders are left alone', () {
    gate.updateMarginLevel(150.1);
    expect(gate.shouldCancelRestingOrders, isFalse);
    gate.updateMarginLevel(199.9);
    expect(gate.shouldCancelRestingOrders, isFalse);
  });

  test('no exposure (no margin reading) never cancels', () {
    gate.updateMarginLevel(null);
    expect(gate.shouldCancelRestingOrders, isFalse);
  });
}
