import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/engine/volume_step.dart';

void main() {
  group('snapVolumeToStep - broker volume grid (volume_min + k*volume_step)', () {
    test('an already-legal volume is unchanged', () {
      expect(snapVolumeToStep(0.3, volumeMin: 0.1, volumeStep: 0.1), 0.3);
      expect(snapVolumeToStep(300, volumeMin: 100, volumeStep: 100), 300);
      expect(snapVolumeToStep(0.003, volumeMin: 0.001, volumeStep: 0.001), 0.003);
    });

    test('margin-scaled off-grid sizes floor to the grid, never round up', () {
      expect(snapVolumeToStep(0.3 * 0.66, volumeMin: 0.1, volumeStep: 0.1), 0.1); // 0.198
      expect(snapVolumeToStep(300 * 0.5, volumeMin: 100, volumeStep: 100), 100); // 150
      expect(snapVolumeToStep(0.29, volumeMin: 0.01, volumeStep: 0.01), 0.29);
      expect(snapVolumeToStep(0.299, volumeMin: 0.01, volumeStep: 0.01), 0.29);
    });

    test('float noise from step-down subtraction does not drop a whole step', () {
      expect(snapVolumeToStep(0.30000000000000004, volumeMin: 0.1, volumeStep: 0.1), 0.3);
      expect(snapVolumeToStep(0.3 - 0.1, volumeMin: 0.1, volumeStep: 0.1), 0.2);
      expect(snapVolumeToStep(0.7 - 0.1, volumeMin: 0.1, volumeStep: 0.1), 0.6);
    });

    test('the grid is anchored at volume_min, not at zero', () {
      // min 0.03, step 0.02 -> legal sizes 0.03, 0.05, 0.07 ...
      expect(snapVolumeToStep(0.06, volumeMin: 0.03, volumeStep: 0.02), 0.05);
      expect(snapVolumeToStep(0.07, volumeMin: 0.03, volumeStep: 0.02), 0.07);
    });

    test('below the minimum snaps up to the minimum (smallest legal size)', () {
      expect(snapVolumeToStep(0.05, volumeMin: 0.1, volumeStep: 0.1), 0.1);
      expect(snapVolumeToStep(0, volumeMin: 0.001, volumeStep: 0.001), 0.001);
    });

    test('a missing/zero step leaves the volume alone (only enforces the min)', () {
      expect(snapVolumeToStep(0.123, volumeMin: 0.1, volumeStep: 0), 0.123);
      expect(snapVolumeToStep(0.05, volumeMin: 0.1, volumeStep: 0), 0.1);
    });
  });
}
