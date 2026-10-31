import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/risk/risk_gate.dart';

/// Covers only RiskGate's pure, static, zero-I/O margin-tier helpers
/// (projectedMarginLevel / marginSizeScaleFor). RiskGate.gate() itself needs a
/// real CoreStorage-backed state file and is intentionally left for a
/// later integration-style test - see the engine's own doc comment on
/// CoreStorage.instance being a singleton resolved from $HOME/.tradingmt5
/// (or $TRADING_MT5_HOME) for why that needs its own setup.
void main() {
  group('RiskGate.projectedMarginLevel - the 150% floor', () {
    // Live account figures, 2026-10-31: equity 49.93, margin 21.08 on 538.75.
    double? after(double notional) => RiskGate.projectedMarginLevel(
      equity: 49.93,
      margin: 21.08,
      exposureNotional: 538.75,
      newNotional: notional,
    );

    test('no new exposure gives the live level', () {
      expect(after(0), closeTo(236.9, 0.1));
    });

    test('a small trade stays above the floor, a big one does not', () {
      expect(after(30)!, greaterThan(RiskGate.marginGateThresholdPct)); // DOGE-sized
      expect(after(310)!, greaterThan(RiskGate.marginGateThresholdPct)); // BTC-sized
      expect(after(77000)!, lessThan(RiskGate.marginGateThresholdPct)); // a 1-lot BTC copy
    });

    test('the trade count alone never blocks: 11 about-\$75 trades on \$50 fit, 12 do not', () {
      double? withOpen(int n) => RiskGate.projectedMarginLevel(
        equity: 50,
        margin: n * 3.0,
        exposureNotional: n * 75.0,
        newNotional: 75,
      );
      expect(withOpen(10)!, greaterThan(150));
      expect(withOpen(11)!, lessThanOrEqualTo(150));
    });

    test('nothing open means nothing to measure from - never blocks', () {
      expect(RiskGate.projectedMarginLevel(equity: 50, margin: 0, exposureNotional: 0, newNotional: 100), isNull);
    });
  });


  group('RiskGate.marginSizeScaleFor - the companion trade-size scale', () {
    test('no live reading yet (null) is full size - never shrinks before the first real snapshot', () {
      expect(RiskGate.marginSizeScaleFor(null), 1.0);
    });

    test('mirrors positionCapFor\'s own tier boundaries exactly', () {
      expect(RiskGate.marginSizeScaleFor(301), 1.0);
      expect(RiskGate.marginSizeScaleFor(300), 0.6);
      expect(RiskGate.marginSizeScaleFor(201), 0.6);
      expect(RiskGate.marginSizeScaleFor(200), 0.3);
      expect(RiskGate.marginSizeScaleFor(151), 0.3);
      expect(RiskGate.marginSizeScaleFor(150), 0.0);
      expect(RiskGate.marginSizeScaleFor(0), 0.0);
    });
  });

  group('GateResult', () {
    test('.allowed() carries no reason', () {
      const result = GateResult.allowed();
      expect(result.allowed, isTrue);
      expect(result.reason, isNull);
    });

    test('.blocked() always carries its reason', () {
      const result = GateResult.blocked('KILL SWITCH: STOP file present');
      expect(result.allowed, isFalse);
      expect(result.reason, 'KILL SWITCH: STOP file present');
    });
  });
}
