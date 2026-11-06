import 'package:flutter/material.dart';

import '../data/identity/user_trigger_store.dart';

/// TP then SL, each with an icon for who set it (2026-11-06, per the user):
/// grey line chart = the trade's default level (follows the pair price);
/// blue candlestick = the user's price trigger; blue % = P&L % trigger;
/// blue $ = dollar trigger (number only, no "$" text). Wraps onto a second
/// line instead of cutting text off. Shared by the Dashboard card and
/// History.
class TpSlReadout extends StatelessWidget {
  const TpSlReadout({
    super.key,
    required this.tp,
    required this.sl,
    required this.defaultTp,
    required this.defaultSl,
    required this.formatPrice,
    this.showDefaults = true,
  });

  final UserTrigger? tp;
  final UserTrigger? sl;
  final double? defaultTp;
  final double? defaultSl;
  final String Function(double?) formatPrice;

  /// False for a waiting pair with no order yet: it has no default level,
  /// so only the user's own sides show.
  final bool showDefaults;

  static String valueText(UserTrigger t, String Function(double?) formatPrice) => switch (t.kind) {
        TriggerKind.price => formatPrice(t.value),
        TriggerKind.pct => t.describe(),
        TriggerKind.usd => '${t.value >= 0 ? '+' : '-'}${t.value.abs().toStringAsFixed(2)}',
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sides = [
      if (showDefaults || tp != null) _side('TP', tp, defaultTp, scheme),
      if (showDefaults || sl != null) _side('SL', sl, defaultSl, scheme),
    ];
    return Wrap(spacing: 10, runSpacing: 2, children: sides);
  }

  Widget _side(String label, UserTrigger? user, double? fallback, ColorScheme scheme) {
    final userColor = Colors.blue.shade600;
    final (IconData icon, Color color, String text, String tip) = switch (user?.kind) {
      null => (Icons.show_chart, scheme.onSurfaceVariant, formatPrice(fallback), 'Default $label (pair price)'),
      TriggerKind.price => (Icons.candlestick_chart, userColor, valueText(user!, formatPrice), 'User $label trigger - price'),
      TriggerKind.pct => (Icons.percent, userColor, valueText(user!, formatPrice), 'User $label trigger - P&L %'),
      TriggerKind.usd => (Icons.attach_money, userColor, valueText(user!, formatPrice), 'User $label trigger - P&L dollars'),
    };
    return Tooltip(
      message: tip,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label ',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: scheme.onSurfaceVariant),
            ),
            WidgetSpan(alignment: PlaceholderAlignment.middle, child: Icon(icon, size: 13, color: color)),
            TextSpan(
              text: text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: user == null ? FontWeight.w400 : FontWeight.w600,
                color: user == null ? null : userColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
