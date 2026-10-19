import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:trading_mt5/data/providers/app_providers.dart';
import 'package:trading_mt5/main.dart';

void main() {
  testWidgets('App boots to the dashboard', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        // These all otherwise poll forever on a real Future.delayed loop
        // (watchedSymbolsProvider also making a real MT5 network call),
        // which leaves a pending Timer flutter_test's end-of-test invariant
        // check rejects. 2026-10-19, found by finally running this test for
        // the first time all session: only 3 of the Dashboard's 9 polling
        // providers were overridden here - the other 6 left exactly the
        // pending-timer failure this comment already warned about for the
        // first 3, just not caught until the test was actually run.
        overrides: [
          botHistoryProvider.overrideWith((ref) => const Stream.empty()),
          autoManagedTvBasesProvider.overrideWith((ref) => const Stream.empty()),
          engineStatusProvider.overrideWith((ref) => const Stream.empty()),
          addCopyResultsProvider.overrideWith((ref) => const Stream.empty()),
          backtestResultProvider.overrideWith((ref) => const Stream.empty()),
          watchedSymbolsProvider.overrideWith((ref) => const Stream.empty()),
          autoTradesProvider.overrideWith((ref) => const Stream.empty()),
          accountInfoProvider.overrideWith((ref) => const Stream.empty()),
          controlToggleStateProvider.overrideWith((ref) => const Stream.empty()),
        ],
        child: const TradingMt5App(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Dashboard'), findsWidgets);
  });
}
