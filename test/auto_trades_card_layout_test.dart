import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/widgets/auto_trades_card.dart';

/// 2026-10-20, per the user: "x running · y pending · z waiting ±P&L" must
/// sit at the TOP-RIGHT of the Auto card, not mid-card. v1.6.30's first fix
/// shipped without a position check and was still centred on the real
/// screen - this measures the actual layout so that can't happen again.
void main() {
  for (final width in [700.0, 1000.0, 1400.0]) {
    testWidgets('summary hugs the right edge at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AutoTradesCard(
                rows: const [],
                onTogglePause: (_, _) {},
                onToggleLast: (_, _) {},
                onTerminate: (_) {},
                onChangeVolume: (_, _) {},
                onAddCopy: (_) {},
                onIgnite: (_) {},
                onFavorite: (_, _) {},
                historyPnlSince: 0,
                pnlSinceTimestamp: null,
                onResetPnlSince: () {},
                liveAccountPnl: -2.0,
              ),
            ),
          ),
        ),
      );

      final card = tester.getRect(find.byType(Card));
      final pnl = tester.getRect(find.text('-2.00'));
      final summary = tester.getRect(find.textContaining('running ·'));
      // The P&L figure is the right-most item: it must end within the
      // card's own padding (16px margin + 14px padding) of the right edge.
      expect(card.right - pnl.right, lessThan(40),
          reason: 'P&L ends ${card.right - pnl.right}px from the card edge');
      // And the summary text must be in the right half, next to it.
      expect(summary.left, greaterThan(card.center.dx),
          reason: 'summary starts at ${summary.left}, card centre ${card.center.dx}');
    });
  }
}
