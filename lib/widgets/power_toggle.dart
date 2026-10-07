import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/power_health.dart';
import '../data/providers/app_providers.dart';

/// The Power switch plus its live health indicator (2026-09-20, per the
/// user). Power always starts off whenever the GUI (re)launches — forced in
/// main.dart's startup hook, not anything this widget does — so closing
/// tradingMT5 and reopening it always comes back to red, never resuming
/// trading silently. Switching it on now actually starts the engine PROCESS
/// itself (2026-10-05 — see `EngineControlRepository.resume`/`pause` and
/// `EngineService.run`'s own doc comment for the full lifecycle), which
/// immediately kicks off a layered health check (internet, then MT5, then
/// TradingView/its two required indicators) that keeps re-running every
/// engine cycle for as long as it stays running — so this widget's color
/// can move between green/yellow/blue/orange later too, not just at
/// startup. Switching it off stops that process outright, not just an
/// internal pause.
///
/// Colors: red = off, green (blinking only for the very first check right
/// after switch-on, steady once a result lands) = healthy, yellow = no
/// internet, blue = MT5 unreachable, orange = TradingView/indicators
/// unreachable — applied directly to the Switch itself (thumb/track/outline
/// color), not a separate dot. The small text below always shows the
/// engine's own current status message.
class PowerToggle extends ConsumerStatefulWidget {
  const PowerToggle({super.key});

  @override
  ConsumerState<PowerToggle> createState() => _PowerToggleState();
}

class _PowerToggleState extends ConsumerState<PowerToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final toggles = ref.watch(controlToggleStateProvider).value;
    final status = ref.watch(engineStatusProvider).value;
    final repo = ref.read(controlRepositoryProvider);

    final powerOn = toggles?.powerOn ?? false;

    final PowerHealthState health;
    final String message;
    if (!powerOn) {
      health = PowerHealthState.off;
      message = 'Off';
    } else {
      health = status?.health ?? PowerHealthState.checking;
      message = status?.message ?? 'Checking connection…';
    }

    final color = switch (health) {
      PowerHealthState.off => Colors.red,
      PowerHealthState.checking => Colors.green,
      PowerHealthState.ready => Colors.green,
      PowerHealthState.internetProblem => Colors.yellow.shade700,
      PowerHealthState.mt5Problem => Colors.blue,
      PowerHealthState.tradingViewProblem => Colors.orange,
    };
    final blinking = health == PowerHealthState.checking;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            AnimatedBuilder(
              animation: _blink,
              builder: (context, _) {
                final shown = blinking
                    ? color.withValues(alpha: 0.35 + 0.65 * _blink.value)
                    : color;
                return Switch(
                  value: powerOn,
                  thumbColor: WidgetStateProperty.all(shown),
                  trackColor: WidgetStateProperty.all(
                    shown.withValues(alpha: 0.5),
                  ),
                  trackOutlineColor: WidgetStateProperty.all(shown),
                  onChanged: (on) {
                    on ? repo.resume() : repo.pause();
                    ref.invalidate(controlToggleStateProvider);
                    ref.invalidate(engineStatusProvider);
                  },
                );
              },
            ),
            const SizedBox(width: 4),
            const Text('Power'),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 2),
          child: Text(
            message,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}
