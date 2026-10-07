import 'package:flutter/material.dart';

import '../../data/models/decision_technique.dart';

/// "Read more" screen for a decision technique (2026-10-06, per the user:
/// "below each technique there is read more .. once it is clicked, app
/// will open a screen for details about this decision. with all related
/// clocks and checkups in all cases, power on, power off, auto on, auto
/// off, waiting, filled, not filled, currently running, etc... make read
/// me simple and easy to understand"). Plain, non-technical language only -
/// this is for a human deciding whether to trust the app, not a code
/// comment.
///
/// Redesigned 2026-10-07, per the user ("i want a better design for read me
/// screen"). The original was a flat AppBar title plus an identical
/// bold-title/paragraph block repeated for every section - functional but
/// gave the reader no sense of where the one load-bearing rule was versus
/// background detail. This version adds: a real header (icon + name + the
/// technique's own one-line description, so "a title too" means something
/// specific is answered immediately), a topic icon per section for
/// wayfinding without boxing every section into an identical card, one
/// highlighted callout around the single rule that actually decides
/// open/close, and a readable max text width instead of letting prose
/// stretch edge-to-edge on a wide desktop window.
class TechniqueDetailsScreen extends StatelessWidget {
  const TechniqueDetailsScreen({super.key, required this.technique});

  final DecisionTechnique technique;

  IconData get _heroIcon => switch (technique.id) {
    _ when technique.id == DecisionTechnique.supertrendPlus.id => Icons.insights_outlined,
    _ => Icons.candlestick_chart_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final sections = switch (technique.id) {
      _ when technique.id == DecisionTechnique.signalFlip.id => _signalFlipSections(context),
      _ when technique.id == DecisionTechnique.supertrendPlus.id => _supertrendPlusSections(context),
      _ => _fallbackSections(context),
    };
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('How this technique works')),
      body: ListView(
        padding: const EdgeInsets.all(0),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 28, 24, 36),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header: real title + what it does in one line.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: scheme.primaryContainer,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Icon(_heroIcon, size: 26, color: scheme.onPrimaryContainer),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                technique.name,
                                style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                technique.shortDescription,
                                style: textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),
                    const Divider(height: 1),
                    const SizedBox(height: 28),
                    ...sections,
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _fallbackSections(BuildContext context) => [
    const Text('No details written for this technique yet.'),
  ];

  List<Widget> _supertrendPlusSections(BuildContext context) => [
    const _Section(
      icon: Icons.visibility_outlined,
      title: 'What it watches',
      body:
          'Two things on the TradingView chart: the "Supertrend Plus" '
          'indicator, set to Heikin Ashi candles instead of regular ones. '
          'That indicator marks just two events — a "Buy" and a "Sell" — '
          'and nothing else is read from it. A second indicator '
          '("worm_9_26") stays loaded alongside it, but only for its range '
          'data, used to work out where to put the stop-loss and '
          'take-profit — it has no say in when a trade opens or closes '
          'under this technique.',
    ),
    const _Section(
      icon: Icons.alt_route_outlined,
      title: 'The basic rule',
      highlight: true,
      body:
          'A Buy means "go long." A Sell means "go short." These two '
          'never happen back to back — a Buy is always followed, at some '
          'point, by a Sell, and vice versa — so the moment the opposite '
          'one shows up, it IS the signal to end the current trade, not a '
          'separate close step. For each pair the app manages:\n\n'
          '•  Nothing running yet → it opens a trade in the new signal\'s '
          'direction, straight away — even for a brand-new pair that has '
          'never traded before (see below).\n'
          '•  Already running, and a confirmed Buy/Sell shows up in the '
          'SAME direction → nothing happens.\n'
          '•  Already running, and the opposite one shows up → the current '
          'trade is closed immediately and a new one opens in the other '
          'direction.\n\n'
          'There is no separate "Update" confirmation signal in this '
          'technique the way the other one has — the dashboard\'s Update '
          'and Close A columns are always left blank for pairs running '
          'under Supertrend Plus. The open and close are still fully '
          'recorded in the History screen, just not shown live in those '
          'two particular columns.',
    ),
    const _Section(
      icon: Icons.verified_outlined,
      title: 'Before anything is trusted',
      body:
          'Exactly the same two-step proof the other technique uses, '
          'applied to the Buy/Sell signal instead:\n\n'
          '1.  It\'s read three separate times, 10 seconds apart, and has '
          'to come back identical all three times. If it changes even '
          'once, the app throws the read away and waits for the next '
          'one.\n'
          '2.  Once confirmed, it still has to survive one full extra '
          'candle — the app waits for an entire candle to pass with '
          'nothing newer appearing before it finally acts.\n\n'
          'Only after both checks pass does the app actually open or '
          'close anything.',
    ),
    const _Section(
      icon: Icons.fiber_new_outlined,
      title: 'A brand-new pair',
      body:
          'Unlike the other technique, a pair being managed for the very '
          'first time under Supertrend Plus does NOT wait for an opposite '
          'signal first. It simply looks at whichever signal — Buy or '
          'Sell — is currently confirmed, and opens in that direction '
          'right away, same as a pair that\'s traded before.',
    ),
    const _Section(
      icon: Icons.history_outlined,
      title: 'The hourly double-check',
      body:
          'The app still re-arms itself once an hour (15 minutes before '
          'the next hourly candle) and every time it\'s reopened, the same '
          'as the other technique — but there is no historical replay to '
          'run for this one. Because a Buy/Sell signal never repeats '
          'itself before its opposite shows up, every single 3-minute '
          'check already re-reads the latest confirmed signal and '
          'compares it against the running trade from scratch — that '
          'ongoing comparison already is the reverse-check, with nothing '
          'left over to catch later.',
    ),
    const _Section(
      icon: Icons.power_settings_new_outlined,
      title: 'Power switch',
      body:
          'Power OFF means the engine itself isn\'t running at all — '
          'nothing is read from the chart, nothing opens, nothing closes, '
          'full stop. Power ON starts the engine fresh, and before it '
          'looks at a single pair it checks, in order: internet '
          'connection, then MT5, then TradingView, then that Supertrend '
          'Plus is loaded AND the chart is set to Heikin Ashi candles. '
          'Only once all four pass does it start checking pairs. The '
          'instant it reaches that point, it also runs an immediate '
          'reverse-check over every pair it manages against this '
          'technique\'s own signal — no waiting for the next regular cycle.',
    ),
    const _Section(
      icon: Icons.smart_toy_outlined,
      title: 'Auto switch',
      body:
          'Auto is separate from Power. Turning Auto OFF (the big switch) '
          'leaves the engine running and still watching its own health, '
          'but it stops checking any pair for new signals — no new '
          'trades, and nothing already running gets closed either; it '
          'just sits as-is until Auto is back on. Each time-frame chip '
          '(1H, etc.) can also be turned off on its own, which only '
          'pauses pairs in that time-frame.',
    ),
    const _StatusGrid(
      rows: [
        ('Waiting', 'No confirmed Buy/Sell yet for that pair.', 'Rechecked fresh every 3 minutes.'),
        (
          'Not filled',
          'An order was placed but hasn\'t triggered yet.',
          'Rechecked every 3 minutes; a stale order (signal moved on) is cancelled and replaced.',
        ),
        (
          'Filled / Running',
          'A real trade is open under this pair.',
          'Checked every 3 minutes for the opposite signal showing up.',
        ),
      ],
    ),
    const _Section(
      icon: Icons.exit_to_app_outlined,
      title: 'Closing the app',
      body:
          'Closing the app window stops the engine completely, the same '
          'as turning Power off — under any circumstance, including a '
          'crash or the computer restarting. Nothing runs unattended. '
          'Reopening the app always comes back with Power off by default; '
          'turning it back on starts everything fresh and immediately '
          'goes back to reading the current Buy/Sell signal for every '
          'running trade, the same as any other cycle.',
    ),
  ];

  List<Widget> _signalFlipSections(BuildContext context) => [
    const _Section(
      icon: Icons.visibility_outlined,
      title: 'What it watches',
      body:
          'One indicator on the TradingView chart, four signals: '
          '"New Higher High" (HH), "New Lower Low" (LL), BUY, and SELL. '
          'Nothing else on the chart is read — no other indicator, no '
          'price pattern, nothing you haven\'t put on that chart yourself.',
    ),
    const _Section(
      icon: Icons.alt_route_outlined,
      title: 'The basic rule',
      highlight: true,
      body:
          'HH and SELL both mean "go short." LL and BUY both mean "go '
          'long." For each pair the app manages:\n\n'
          '•  Nothing running yet → it opens a trade in the new signal\'s '
          'direction.\n'
          '•  Already running, and the new signal agrees → nothing '
          'happens. It\'s just noted as confirmation.\n'
          '•  Already running, and the new signal disagrees → the current '
          'trade is closed immediately and a new one opens in the other '
          'direction.',
    ),
    const _Section(
      icon: Icons.verified_outlined,
      title: 'Before anything is trusted',
      body:
          'A signal has to prove itself twice before the app acts on it:\n\n'
          '1.  It\'s read three separate times, 10 seconds apart, and has '
          'to come back identical all three times. If it changes even '
          'once, the app throws the read away and waits for the next '
          'one.\n'
          '2.  Once confirmed, it still has to survive one full extra '
          'candle — the app waits for an entire candle to pass with '
          'nothing newer appearing before it finally acts. This is what '
          'the dashboard table calls "Close A" (the candle that carried '
          'the signal) and "Close B" (the empty candle right after it '
          'that confirms nothing changed).\n\n'
          'Only after both checks pass does the app actually open or '
          'close anything.',
    ),
    const _Section(
      icon: Icons.fiber_new_outlined,
      title: 'A brand-new pair gets one more layer',
      body:
          'The very first time a pair is added, the app does NOT take '
          'whatever signal happens to be showing right then — that signal '
          'could already be old and about to flip. Instead it waits for a '
          'genuinely opposite signal to show up first, confirms it the '
          'same way as above, and only then takes its first-ever trade. A '
          'pair that\'s already been traded before (recycled) skips this '
          '— it reacts immediately like normal.',
    ),
    const _Section(
      icon: Icons.history_outlined,
      title: 'The hourly double-check',
      body:
          'On top of everything above, every running trade gets a full '
          'replay once an hour (15 minutes before the next hourly candle) '
          'and every time the app is reopened: starting from the exact '
          'signal that opened it, the app walks forward through every '
          'single HH/LL/BUY/SELL that has happened since, applying the '
          'same rule at each one. If that full replay says the trade '
          'should be running the other way, it closes and flips — even '
          'if that was missed in real time (for example, while the app '
          'was briefly closed or restarting).',
    ),
    const _Section(
      icon: Icons.power_settings_new_outlined,
      title: 'Power switch',
      body:
          'Power OFF means the engine itself isn\'t running at all — '
          'nothing is read from the chart, nothing opens, nothing closes, '
          'full stop. Power ON starts the engine fresh, and before it '
          'looks at a single pair it checks, in order: internet '
          'connection, then MT5, then TradingView, then that the two '
          'required indicators are actually loaded on the chart. Only '
          'once all four pass does it start checking pairs. The instant '
          'it reaches that point, it also runs an immediate reverse-check '
          'over every pair it manages against this technique\'s own '
          'signal — no waiting for the next regular cycle.',
    ),
    const _Section(
      icon: Icons.smart_toy_outlined,
      title: 'Auto switch',
      body:
          'Auto is separate from Power. Turning Auto OFF (the big switch) '
          'leaves the engine running and still watching its own health, '
          'but it stops checking any pair for new signals — no new '
          'trades, and nothing already running gets closed either; it '
          'just sits as-is until Auto is back on. Each time-frame chip '
          '(1H, etc.) can also be turned off on its own, which only '
          'pauses pairs in that time-frame.',
    ),
    const _StatusGrid(
      rows: [
        ('Waiting', 'No confirmed signal yet for that pair.', 'Rechecked fresh every 3 minutes.'),
        (
          'Not filled',
          'An order was placed but hasn\'t triggered yet.',
          'Rechecked every 3 minutes; a stale order (signal moved on) is cancelled and replaced.',
        ),
        (
          'Filled / Running',
          'A real trade is open under this pair.',
          'Checked every 3 minutes for a disagreeing signal, plus the hourly full replay as a backup.',
        ),
      ],
    ),
    const _Section(
      icon: Icons.exit_to_app_outlined,
      title: 'Closing the app',
      body:
          'Closing the app window stops the engine completely, the same '
          'as turning Power off — under any circumstance, including a '
          'crash or the computer restarting. Nothing runs unattended. '
          'Reopening the app always comes back with Power off by default; '
          'turning it back on starts everything fresh and immediately '
          're-checks every running trade from its own start signal '
          'forward, exactly like the hourly double-check above.',
    ),
  ];
}

class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.body,
    this.highlight = false,
  });

  final IconData icon;
  final String title;
  final String body;

  /// Marks the ONE rule per technique that actually decides open/close -
  /// everything else is context, timing, or edge-case detail. Rendered as a
  /// tinted callout so the reader's eye has exactly one place to land,
  /// rather than every section competing for the same weight.
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 19, color: highlight ? scheme.primary : scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: highlight ? scheme.primary : scheme.onSurface,
            ),
          ),
        ),
      ],
    );
    final content = Padding(
      padding: const EdgeInsets.only(top: 8, left: 29),
      child: Text(body, style: textTheme.bodyMedium?.copyWith(height: 1.5)),
    );

    if (!highlight) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [header, content]),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [header, content]),
      ),
    );
  }
}

/// Compact status matrix for "waiting / not filled / filled" - this is
/// genuinely tabular information (per the user's original spec listing
/// exactly these states), so it gets a real grid instead of being forced
/// into the same prose-paragraph shape as every other section.
class _StatusGrid extends StatelessWidget {
  const _StatusGrid({required this.rows});

  final List<(String, String, String)> rows;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pending_actions_outlined, size: 19, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Text(
                'Waiting, not filled, filled, running',
                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: i.isEven ? scheme.surface : scheme.surfaceContainerLow,
                      border: i == 0
                          ? null
                          : Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.6))),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 118,
                          child: Text(
                            rows[i].$1,
                            style: textTheme.labelLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(rows[i].$2, style: textTheme.bodyMedium),
                              const SizedBox(height: 3),
                              Text(
                                rows[i].$3,
                                style: textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
