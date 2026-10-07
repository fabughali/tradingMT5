import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/auto_category.dart';
import '../data/models/decision_technique.dart';
import '../data/providers/app_providers.dart';
import '../screens/app/technique_details_screen.dart';
import '../utilities/auto_cycle.dart';
import 'power_toggle.dart';

/// Power / Auto / per-category (3m/5m/15m/1H/1D) toggles, via
/// EngineControlRepository. Auto off (independent of Power) skips just the
/// auto-category checkup loop; each category can additionally be paused on
/// its own even while Auto is globally on. Power is different from the
/// other two (2026-10-05): off actually stops the engine process itself
/// (`systemctl --user stop`), on starts it fresh — see
/// [EngineControlRepository.pause]/[resume].
class ControlTogglesBar extends ConsumerWidget {
  const ControlTogglesBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toggles = ref.watch(controlToggleStateProvider);
    final repo = ref.read(controlRepositoryProvider);

    return toggles.when(
      data: (state) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const PowerToggle(),
              const SizedBox(width: 24),
              Switch(
                value: state.autoOn,
                onChanged: (on) {
                  on ? repo.resumeAuto() : repo.pauseAuto();
                  ref.invalidate(controlToggleStateProvider);
                },
              ),
              const SizedBox(width: 4),
              const Text('Auto'),
              // 2026-10-06, per the user: "place drop down at the top
              // right of power toggle section" - same row as Power/Auto,
              // pushed to the far right via Spacer rather than sitting on
              // its own row below.
              const Spacer(),
              const _DecisionTechniquePicker(),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final category in allAutoCategories)
                FilterChip(
                  label: category == AutoCategory.oneHour
                      ? const _HourlyCandleLabel()
                      : Text(category.label),
                  selected: state.categoryOn[category] ?? true,
                  onSelected: (on) {
                    on
                        ? repo.resumeCategory(category)
                        : repo.pauseCategory(category);
                    ref.invalidate(controlToggleStateProvider);
                  },
                ),
            ],
          ),
        ],
      ),
      loading: () => const SizedBox(
        height: 24,
        width: 24,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (e, _) => Text('Error: $e'),
    );
  }
}

/// The 1H chip's label — the category tag plus a live countdown to the next
/// hourly candle and the current check-cycle mark (2026-09-29, per the
/// user: "add inside 1H button a count down timer according to candle
/// timing in trading view" / "once cycle started, icon changed in 1H
/// button"). Ticks every second on its own [Timer] - the cycle mark itself
/// only actually changes once an hour, but the seconds countdown needs a
/// real per-second tick, and [currentAutoCycle]/[timeUntilNextHourlyCandle]
/// are cheap pure functions of wall-clock time (see auto_cycle.dart) so
/// recomputing both every tick costs nothing.
class _HourlyCandleLabel extends StatefulWidget {
  const _HourlyCandleLabel();

  @override
  State<_HourlyCandleLabel> createState() => _HourlyCandleLabelState();
}

class _HourlyCandleLabelState extends State<_HourlyCandleLabel> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remaining = timeUntilNextHourlyCandle();
    final m = remaining.inMinutes.toString().padLeft(2, '0');
    final s = (remaining.inSeconds % 60).toString().padLeft(2, '0');
    final cycle = currentAutoCycle();
    return Text('1H ${'✓' * cycle} $m:$s');
  }
}

/// Decision-technique picker, next to Power (2026-10-06, per the user:
/// "create a knob in power toggle section where user can choose from a
/// list one option of decision technique ... below each technique there is
/// read more"). Redesigned 2026-10-07, per the user ("make the design of
/// drop down technique selection better... a title too") - the original was
/// a bare native [DropdownButton] with an inline gray label and a
/// zero-padding text link easy to miss entirely; this gives the whole
/// control group real visual weight (a bordered, filled card of its own,
/// matching the app's existing [InputDecorationTheme] rather than
/// inventing a one-off look) and makes "read more" an actual button with a
/// real tap target instead of near-invisible text.
class _DecisionTechniquePicker extends ConsumerWidget {
  const _DecisionTechniquePicker();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(decisionTechniqueProvider);
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // The control group's own title - a native field label instead
          // of a separate floating line, so there's exactly one place the
          // eye reads "what is this" (per the user: "a title too").
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.psychology_outlined, size: 15, color: scheme.primary),
              const SizedBox(width: 6),
              Text(
                'DECISION TECHNIQUE',
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 260,
                child: DropdownButtonHideUnderline(
                  child: DropdownButtonFormField<DecisionTechnique>(
                    value: selected,
                    isDense: true,
                    icon: const Icon(Icons.expand_more, size: 20),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    items: [
                      for (final t in DecisionTechnique.all)
                        DropdownMenuItem(
                          value: t,
                          child: Text(
                            t.name,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyMedium,
                          ),
                        ),
                    ],
                    selectedItemBuilder: (context) => [
                      for (final t in DecisionTechnique.all)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            t.name,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                    ],
                    onChanged: (t) {
                      if (t != null) ref.read(decisionTechniqueProvider.notifier).select(t);
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonalIcon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => TechniqueDetailsScreen(technique: selected),
                  ),
                ),
                icon: const Icon(Icons.menu_book_outlined, size: 17),
                label: const Text('How it works'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // One-line "what this does right now" dek - lets the user confirm
          // the active behavior without opening the full explanation.
          SizedBox(
            width: 260,
            child: Text(
              selected.shortDescription,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
