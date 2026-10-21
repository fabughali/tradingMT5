import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/core/core_storage.dart';
import 'package:trading_mt5/data/models/app_config.dart';
import 'package:trading_mt5/data/models/auto_category.dart';
import 'package:trading_mt5/data/risk/risk_gate.dart';

/// 2026-10-21 (v1.6.35): a worm10 recycle pre-checks its reopen with
/// `replacingOne: true` - the position being recycled is freed by the close,
/// so a recycle at exactly the cap must pass, while one far over the cap
/// (the live BNB case: 14 open, cap 3) must still be blocked.
void main() {
  late Directory dir;
  late RiskGate gate;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tmt5_gate_test');
    gate = RiskGate(CoreStorage.forRoot(dir.path), AppConfig.defaultConfig.risk);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void openN(int n) {
    for (var i = 0; i < n; i++) {
      gate.openPosition('SYM$i.lv', AutoCategory.oneHour);
    }
  }

  test('BNB live case: 14 open, cap 3 (margin 168.6%) - recycle pre-check blocks', () {
    openN(13);
    gate.openPosition('BNBUSD.lv', AutoCategory.oneHour);
    gate.updateMarginLevel(168.6);
    final r = gate.gate('open', 'BNBUSD.lv', AutoCategory.oneHour, replacingOne: true);
    expect(r.allowed, isFalse);
  });

  test('exactly at the cap: a plain open is blocked, a recycle (replacing one) is allowed', () {
    openN(5);
    gate.openPosition('BNBUSD.lv', AutoCategory.oneHour); // 6 open, cap 6 at 250%
    gate.updateMarginLevel(250);
    expect(gate.gate('open', 'BNBUSD.lv', AutoCategory.oneHour).allowed, isFalse);
    expect(gate.gate('open', 'BNBUSD.lv', AutoCategory.oneHour, replacingOne: true).allowed, isTrue);
  });
}
