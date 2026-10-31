import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/core/core_storage.dart';
import 'package:trading_mt5/data/models/app_config.dart';
import 'package:trading_mt5/data/models/auto_category.dart';
import 'package:trading_mt5/data/risk/risk_gate.dart';

/// 2026-11-01 (v1.6.57): the gate no longer counts total trades. A worm10
/// recycle pre-checks its reopen with `replacingOne: true`, which still frees
/// its own slot under the per-symbol cap; the 150% block still applies.
void main() {
  late Directory dir;
  late RiskGate gate;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tmt5_gate_test');
    gate = RiskGate(CoreStorage.forRoot(dir.path), AppConfig.defaultConfig.risk);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void openOthers(int n) {
    for (var i = 0; i < n; i++) {
      gate.openPosition('SYM$i.lv', AutoCategory.oneHour);
    }
  }

  test('many open at 168% no longer blocks a different pair by count', () {
    openOthers(14);
    gate.updateMarginLevel(168.6);
    expect(gate.gate('open', 'BNBUSD.lv', AutoCategory.oneHour).allowed, isTrue);
  });

  test('at or below 150% every open is blocked, recycle included', () {
    gate.openPosition('BNBUSD.lv', AutoCategory.oneHour);
    gate.updateMarginLevel(150);
    expect(gate.gate('open', 'ETHUSD.lv', AutoCategory.oneHour).allowed, isFalse);
    expect(gate.gate('open', 'BNBUSD.lv', AutoCategory.oneHour, replacingOne: true).allowed, isFalse);
  });

  test('per-symbol cap: a plain reopen is blocked, a recycle is allowed', () {
    final max = AppConfig.defaultConfig.risk.maxPerSymbol;
    for (var i = 0; i < max; i++) {
      gate.openPosition('BNBUSD.lv', AutoCategory.oneHour);
    }
    gate.updateMarginLevel(250);
    expect(gate.gate('open', 'BNBUSD.lv', AutoCategory.oneHour).allowed, isFalse);
    expect(gate.gate('open', 'BNBUSD.lv', AutoCategory.oneHour, replacingOne: true).allowed, isTrue);
  });
}
