import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/tradingview/chart_state.dart';

void main() {
  List<int> bars(int last, int step, [int n = 6]) => [for (var i = 0; i < n; i++) last - i * step];

  group('chartDataMismatchReason - is the chart DATA really this pair?', () {
    test('2026-10-25 incident: label XLMUSDT 1H, series stuck loading on LTC daily', () {
      expect(
        chartDataMismatchReason(
          loading: true,
          symbolInfoName: null,
          expectedSymbol: 'XLMUSDT',
          recentBarTimes: bars(1792886400, 86400),
          resolution: '60',
        ),
        'series still loading',
      );
    });

    test('loaded but holding another pair', () {
      expect(
        chartDataMismatchReason(
          loading: false,
          symbolInfoName: 'LTCUSDT',
          expectedSymbol: 'NEARUSDT',
          recentBarTimes: bars(1792926000, 3600),
          resolution: '60',
        ),
        contains('LTCUSDT'),
      );
    });

    test('right pair but daily bars under a 1H request', () {
      expect(
        chartDataMismatchReason(
          loading: false,
          symbolInfoName: 'NEARUSDT',
          expectedSymbol: 'NEARUSDT',
          recentBarTimes: bars(1792886400, 86400),
          resolution: '60',
        ),
        contains('expected 3600s'),
      );
    });

    test('no symbol info is refused', () {
      expect(
        chartDataMismatchReason(
          loading: false,
          symbolInfoName: null,
          expectedSymbol: 'ETHUSDT',
          recentBarTimes: bars(1792926000, 3600),
          resolution: '60',
        ),
        isNotNull,
      );
    });

    test('healthy 1H read passes, exchange prefix and bare ticker both match', () {
      expect(
        chartDataMismatchReason(
          loading: false,
          symbolInfoName: 'ETHUSDT',
          expectedSymbol: 'BINANCE:ETHUSDT',
          recentBarTimes: bars(1792926000, 3600),
          resolution: '60',
        ),
        isNull,
      );
    });

    test('healthy daily range read passes', () {
      expect(
        chartDataMismatchReason(
          loading: false,
          symbolInfoName: 'LTCUSDT',
          expectedSymbol: 'LTCUSDT',
          recentBarTimes: bars(1792886400, 86400),
          resolution: 'D',
        ),
        isNull,
      );
    });

    test('one missing bar does not fail the spacing check (smallest gap wins)', () {
      final times = [1792926000, 1792922400, 1792915200, 1792911600];
      expect(
        chartDataMismatchReason(
          loading: false,
          symbolInfoName: 'BTCUSDT',
          expectedSymbol: 'BTCUSDT',
          recentBarTimes: times,
          resolution: '60',
        ),
        isNull,
      );
    });

    test('no resolution given -> only load state and symbol are checked', () {
      expect(
        chartDataMismatchReason(
          loading: false,
          symbolInfoName: 'SUSDT',
          expectedSymbol: 'MEXC:SUSDT',
          recentBarTimes: const [],
        ),
        isNull,
      );
    });
  });

  test('resolutionSeconds', () {
    expect(resolutionSeconds('60'), 3600);
    expect(resolutionSeconds('D'), 86400);
    expect(resolutionSeconds('1D'), 86400);
    expect(resolutionSeconds('W'), 604800);
    expect(resolutionSeconds('M'), isNull);
  });
}
