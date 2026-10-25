import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/engine/volume_step.dart';

void main() {
  ({double volume, String? why}) plan({
    double? desired = 400,
    double scale = 1.0,
    double? margin,
    bool ignited = false,
    double? attempt,
    double? lastApplied,
  }) => explainPlannedSend(
    desired: desired,
    marginScale: scale,
    marginLevel: margin,
    ignited: ignited,
    attempt: attempt,
    lastApplied: lastApplied,
    volumeMin: 1,
    volumeStep: 1,
  );

  test('2026-10-25 ADA: card 400, 30% at 196.7% margin, last fill 200 -> sends 200, says why', () {
    final r = plan(scale: 0.3, margin: 196.7, lastApplied: 200);
    expect(r.volume, 200);
    expect(r.why, '30% at 197% margin, min = last fill 200');
  });

  test('ignited: full card volume regardless of margin', () {
    final r = plan(scale: 0.3, margin: 196.7, ignited: true, lastApplied: 200);
    expect(r.volume, 400);
    expect(r.why, isNull);
  });

  test('ignited at <=150% margin (scale 0) still sends the full card volume', () {
    expect(plan(scale: 0.0, margin: 139, ignited: true).volume, 400);
  });

  test('not ignited, scale only', () {
    final r = plan(scale: 0.6, margin: 250);
    expect(r.volume, 240);
    expect(r.why, '60% at 250% margin');
  });

  test('same as card -> no explanation', () {
    expect(plan().why, isNull);
    expect(plan().volume, 400);
  });

  test('step-down after a rejection is explained', () {
    final r = plan(attempt: 300);
    expect(r.volume, 300);
    expect(r.why, 'stepped down after a broker rejection');
  });

  test('last fill above the card volume is the floor', () {
    final r = plan(desired: 100, lastApplied: 200);
    expect(r.volume, 200);
    expect(r.why, 'min = last fill 200');
  });
}
