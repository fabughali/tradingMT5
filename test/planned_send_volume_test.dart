import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/engine/volume_step.dart';

void main() {
  group('plannedSendVolume - what a (re-)placed order sends now', () {
    double plan({double? desired, double scale = 1.0, double? attempt, double? lastApplied}) =>
        plannedSendVolume(
          desired: desired,
          marginScale: scale,
          attempt: attempt,
          lastApplied: lastApplied,
          volumeMin: 1,
          volumeStep: 1,
        );

    test('a card volume changed while waiting is what gets sent', () {
      expect(plan(desired: 3, lastApplied: 1), 3);
      expect(plan(desired: 5, lastApplied: 1), 5);
    });

    test('never set -> broker minimum', () {
      expect(plan(), 1);
    });

    test('margin scaling shrinks the card volume, snapped to the grid', () {
      expect(plan(desired: 10, scale: 0.3), 3);
      expect(plan(desired: 5, scale: 0.6), 3);
    });

    test('a step-down attempt is capped by the (new) card volume', () {
      expect(plan(desired: 2, attempt: 4), 2);
      expect(plan(desired: 6, attempt: 4), 4);
    });

    test('the last filled size is the floor', () {
      expect(plan(desired: 3, lastApplied: 4), 4);
      expect(plan(desired: 10, scale: 0.3, lastApplied: 4), 4);
    });

    test('fractional grid', () {
      expect(
        plannedSendVolume(
          desired: 0.3,
          marginScale: 0.66,
          attempt: null,
          lastApplied: null,
          volumeMin: 0.1,
          volumeStep: 0.1,
        ),
        0.1,
      );
    });
  });
}
