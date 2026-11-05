import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/engine/auto_volume.dart';

void main() {
  group('autoPairWeights (dollars, 30 days)', () {
    test('top third x2, middle x1, bottom x0.5, losers x0.5, thin history x1', () {
      final w = autoPairWeights({
        'A': const PairHistory(pnl: 10, trades: 10),
        'B': const PairHistory(pnl: 5, trades: 10),
        'C': const PairHistory(pnl: 3, trades: 10),
        'D': const PairHistory(pnl: 2, trades: 10),
        'E': const PairHistory(pnl: 1, trades: 10),
        'F': const PairHistory(pnl: -4, trades: 10),
        'G': const PairHistory(pnl: 50, trades: 2),
      });
      expect(w['A'], 2.0);
      expect(w['B'], 2.0);
      expect(w['C'], 1.0);
      expect(w['D'], 1.0);
      expect(w['E'], 0.5);
      expect(w['F'], 0.5);
      expect(w['G'], 1.0, reason: 'fewer than 5 trades = neutral');
    });

    test('a loser in the top third is still x0.5', () {
      final w = autoPairWeights({
        'A': const PairHistory(pnl: -1, trades: 9),
        'B': const PairHistory(pnl: -2, trades: 9),
        'C': const PairHistory(pnl: -3, trades: 9),
      });
      expect(w.values.toSet(), {0.5});
    });
  });

  group('autoVolumeFor', () {
    // equity 300, margin 100 -> 300%; rate = 100/2000 = 0.05 -> floor 0.07.
    AutoVolume run({double weight = 1, double total = 1, double reserved = 0, double resting = 0, double max = 0}) =>
        autoVolumeFor(
          equity: 300,
          margin: 100,
          exposureNotional: 2000,
          restingNotional: resting,
          reservedMargin: reserved,
          weight: weight,
          totalWeight: total,
          price: 10,
          contractSize: 1,
          volumeMin: 1,
          volumeMax: max,
          volumeStep: 1,
          safety: 1,
        );

    test('uses all room above 150% when it is the only pair', () {
      // room = 300/1.5 - 100 = 100 margin $; per lot 0.07*10 = 0.7 -> 142.8 -> 142
      final r = run();
      expect(r.fits, isTrue);
      expect(r.volume, 142);
      // Margin level after: 300 / (100 + 142*0.7) = 150.3% -> above the floor.
      expect(300 / (100 + 142 * 0.7) * 100, greaterThan(150));
    });

    test('shares room by weight among waiting auto pairs', () {
      expect(run(weight: 2, total: 4).volume, 71); // half the room
      expect(run(weight: 0.5, total: 4).volume, 17);
    });

    test('room reserved for fixed pairs and resting orders is not used', () {
      expect(run(reserved: 50).volume, 71);
      expect(run(resting: 1000).volume, 42); // 100 - 70 = 30 -> 42.8
    });

    test('capped at volume_max', () {
      expect(run(max: 20).volume, 20);
    });

    test('no room or below the minimum -> volumeMin and fits=false', () {
      final none = autoVolumeFor(
        equity: 140, margin: 100, exposureNotional: 2000, restingNotional: 0, reservedMargin: 0,
        weight: 1, totalWeight: 1, price: 10, contractSize: 1, volumeMin: 1, volumeMax: 0, volumeStep: 1,
      );
      expect(none.fits, isFalse);
      expect(none.volume, 1);
      expect(run(weight: 0.001, total: 1).fits, isFalse);
    });
  });

  test('reserveForFixed keeps room only for fixed pairs that fit, smallest first', () {
    // room 100, rate 0.1: needs 300 (30$), 500 (50$), 5000 (500$ - ETH-like).
    final r = reserveForFixed(room: 100, rate: 0.1, needs: const [
      FixedNeed('eth', 5000),
      FixedNeed('b', 500),
      FixedNeed('a', 300),
    ]);
    expect(r, closeTo(80, 1e-9));
  });
}
