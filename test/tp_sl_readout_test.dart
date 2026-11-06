import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/identity/user_trigger_store.dart';
import 'package:trading_mt5/widgets/tp_sl_readout.dart';

void main() {
  testWidgets('TP first, then SL; dollar trigger shows the number without "\$"', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 90, // narrow: must wrap, not overflow
          child: TpSlReadout(
            tp: null,
            sl: const UserTrigger(TriggerKind.usd, 0.5),
            defaultTp: 2.6,
            defaultSl: 1.2,
            formatPrice: (v) => v?.toString() ?? '-',
          ),
        ),
      ),
    ));
    final text = tester.widgetList<RichText>(find.byType(RichText)).map((r) => r.text.toPlainText()).join('|');
    expect(text.indexOf('2.6'), lessThan(text.indexOf('+0.50'))); // TP first
    expect(text, isNot(contains('TP'))); // header says TP / SL
    expect(text, isNot(contains('SL')));
    expect(text, contains('+0.50'));
    expect(text, isNot(contains('\$')));
    expect(find.byIcon(Icons.show_chart), findsOneWidget); // default TP
    expect(find.byIcon(Icons.attach_money), findsOneWidget); // user SL $
    expect(tester.takeException(), isNull);
  });

  testWidgets('user price trigger uses a different chart icon than the default', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TpSlReadout(
          tp: const UserTrigger(TriggerKind.price, 2.6),
          sl: const UserTrigger(TriggerKind.pct, -2),
          defaultTp: 2.7,
          defaultSl: 1.2,
          formatPrice: (v) => v?.toString() ?? '-',
        ),
      ),
    ));
    expect(find.byIcon(Icons.candlestick_chart), findsOneWidget);
    expect(find.byIcon(Icons.percent), findsOneWidget);
    expect(find.byIcon(Icons.show_chart), findsNothing);
  });
}
