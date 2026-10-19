import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/risk/risk_gate.dart';

/// Covers only RiskGate's pure, static, zero-I/O margin-tier helpers
/// (positionCapFor / marginSizeScaleFor). RiskGate.gate() itself needs a
/// real CoreStorage-backed state file and is intentionally left for a
/// later integration-style test - see the engine's own doc comment on
/// CoreStorage.instance being a singleton resolved from $HOME/.tradingmt5
/// (or $TRADING_MT5_HOME) for why that needs its own setup.
void main() {
  group('RiskGate.positionCapFor - margin-tiered concurrent-position cap', () {
    test('no live margin reading yet (null) never caps - unrestricted until the first real snapshot', () {
      expect(RiskGate.positionCapFor(null), isNull);
    });

    test('above 300% is fully unrestricted', () {
      expect(RiskGate.positionCapFor(301), isNull);
      expect(RiskGate.positionCapFor(1000), isNull);
    });

    test('between 200% and 300% caps at 6', () {
      expect(RiskGate.positionCapFor(300), 6);
      expect(RiskGate.positionCapFor(201), 6);
    });

    test('between the margin-gate threshold (150%) and 200% caps at 3', () {
      expect(RiskGate.positionCapFor(200), 3);
      expect(RiskGate.positionCapFor(151), 3);
    });

    test('at or below the margin-gate threshold (150%) caps at 0 - moot anyway, gate() blocks every open there', () {
      expect(RiskGate.positionCapFor(150), 0);
      expect(RiskGate.positionCapFor(50), 0);
      expect(RiskGate.positionCapFor(0), 0);
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
