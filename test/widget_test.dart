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
        // check rejects.
        overrides: [
          engineStatusProvider.overrideWith((ref) => const Stream.empty()),
          watchedSymbolsProvider.overrideWith((ref) => const Stream.empty()),
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
