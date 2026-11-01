import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/engine/close_fill.dart';

void main() {
  group('closeRejectedReason', () {
    test('the live AVAX refusals are caught', () {
      expect(
        closeRejectedReason({'retcode': 10018, 'retcode_details': 'Market closed'}),
        'retcode=10018 Market closed',
      );
      expect(closeRejectedReason({'retcode': 10031}), 'retcode=10031');
    });

    test('a done close is not a refusal', () {
      expect(closeRejectedReason({'retcode': 10009}), isNull);
      expect(closeRejectedReason({'retcode': 10008}), isNull);
    });

    test('no retcode is left to the open-positions re-check', () {
      expect(closeRejectedReason({}), isNull);
    });
  });
}
