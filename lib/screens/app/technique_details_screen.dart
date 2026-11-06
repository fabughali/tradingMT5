import 'package:flutter/material.dart';

import '../../data/models/decision_technique.dart';
import '../../widgets/backtester_card.dart';

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
    _ when technique.id == DecisionTechnique.worm10.id => Icons.hub_outlined,
    _ => Icons.candlestick_chart_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final sections = switch (technique.id) {
      _ when technique.id == DecisionTechnique.worm10.id => _worm10Sections(context),
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
              // Widened 2026-10-17, per the user ("make the screen in
              // summary expanded") - the backtester's result table (9+
              // columns) was cramped inside the original 720px prose
              // column; the "How this technique works" text itself still
              // reads fine at this width, it just no longer caps the
              // whole screen.
              constraints: const BoxConstraints(maxWidth: 1200),
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
                    // Technique Summary screen's backtester (2026-10-17,
                    // per the user) - re-runs this SAME decision logic
                    // against real historical data. Worm10/Hybrid Decision
                    // only: it's built directly on [worm10DecisionFor] and
                    // [deriveWorm10Events], which the other two techniques
                    // don't use.
                    if (technique.id == DecisionTechnique.worm10.id) const BacktesterCard(),
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

  /// Margin-tiered risk controls (2026-10-15, per the user: "how it works
  /// screen" - after a real Equiti margin stop-out forced BNBUSD.lv closed
  /// and the app's own global position cap turned out to have been set
  /// but never actually enforced). Applies the SAME regardless of which technique is active,
  /// so it's one shared section included in every technique's own list
  /// rather than three separately-maintained copies that could drift.
  static const _Section _marginRiskSection = _Section(
    icon: Icons.shield_outlined,
    title: 'Margin protection',
    body:
        'This applies no matter which technique is active. The app '
        'watches the account\'s live margin level and automatically '
        'pulls back on NEW trades as it tightens - it never closes a '
        'trade that\'s already running just because margin got tight. '
        'There is no limit on the number of trades: before each new trade '
        'the app works out what margin would be after it, and only opens '
        'the trade if margin stays above 150%. New trades open at full '
        'size above 300% margin, 60% size between 200-300%, and 30% size '
        'between 150-200%. At 150% or below, no new trade can open and '
        'untriggered orders are cancelled until margin recovers. Even with all of this, the '
        'broker\'s own hard stop-out (forced closure of the worst-losing '
        'trade) still exists underneath as a last resort if margin ever '
        'falls all the way to 30% - these rules make that far less '
        'likely, not impossible, since trades already running can still '
        'move against the account regardless of what new trades are '
        'allowed.',
  );

  List<Widget> _worm10Sections(BuildContext context) => [
    const _Section(
      icon: Icons.visibility_outlined,
      title: 'What it watches',
      body:
          'Two custom indicators on the TradingView chart, set to Heikin '
          'Ashi candles. The first, "worm_10_26," is one script that '
          'carries four separate things at once: a Higher-High/Lower-Low '
          'swing marker (the same kind the first technique uses), a plain '
          'BUY/SELL tag (also from that same swing logic), and a separate, '
          'sparser Buy/Sell entry signal from a Supertrend-style '
          'calculation. The second, "spy_9_26," reads the RSI and sorts it '
          'into five zones: Blue and Purple (oversold), White (neutral), '
          'Green and Yellow (overbought) — Blue and Yellow are the '
          'stronger ends of each pair.',
    ),
    const _Section(
      icon: Icons.alt_route_outlined,
      title: 'The basic rule',
      highlight: true,
      body:
          'A trade only ever opens on a genuine three-part agreement: the '
          'Supertrend-style signal pointing one way, a fresh swing low or '
          'high showing up, and the RSI sitting in the matching zone — '
          'e.g. a long opens when Supertrend is reading Sell, a fresh Low '
          'just printed, and RSI is Blue or Purple. That same three-part '
          'agreement, minus the Supertrend requirement, is enough on its '
          'own to CLOSE a running trade — a weaker bar for closing than '
          'for opening.\n\n'
          'What happens for a pair the app is already managing:\n\n'
          '•  Nothing running yet → only the full three-part agreement '
          'opens a trade. A bare BUY/SELL tag by itself never opens '
          'anything from a standing start.\n'
          '•  Already running, and that SAME three-part agreement fires '
          'again → the trade is closed and immediately reopened fresh in '
          'the same direction, resetting its entry to the new price.\n'
          '•  Already running, and the weaker two-part version (swing + '
          'RSI, no Supertrend) fires for the OPPOSITE direction → the '
          'trade is closed and flipped to the opposite side right away.\n'
          '•  Already running, and a bare opposite BUY/SELL tag shows up '
          'with none of the above → that alone is still enough to close '
          'and flip — just the single tag, no RSI or Supertrend needed.\n'
          '•  Already running, and a bare SAME-direction BUY/SELL tag '
          'shows up → nothing happens, just noted as confirmation.',
    ),
    const _Section(
      icon: Icons.verified_outlined,
      title: 'Before anything is trusted',
      body:
          'The same two-step proof every technique here uses:\n\n'
          '1.  Read three separate times, 10 seconds apart, has to come '
          'back identical all three times.\n'
          '2.  Once confirmed, it still has to survive one full extra '
          'candle before the app finally acts — unlike the Supertrend '
          'technique, this one does NOT skip that wait for an already-'
          'running trade; every action goes through the full wait, same '
          'as the very first technique.',
    ),
    const _Section(
      icon: Icons.fiber_new_outlined,
      title: 'A brand-new pair',
      body:
          'Same as the first technique: nothing opens until a genuine '
          'three-part agreement happens for that pair. A pair sitting in '
          'waiting (an order placed but not yet filled, or nothing placed '
          'at all) stays there until that real signal shows up — a bare '
          'BUY/SELL tag alone is never enough to open the first trade.',
    ),
    const _Section(
      icon: Icons.history_outlined,
      title: 'The hourly double-check',
      body:
          'Every running trade also gets re-walked once an hour (15 '
          'minutes before the next hourly candle) and every time the app '
          'is reopened — starting from whatever actually opened it, '
          'replaying every relevant event since in order, the same reverse-'
          'check style the first technique uses.',
    ),
    const _Section(
      icon: Icons.power_settings_new_outlined,
      title: 'Power switch',
      body:
          'Power OFF means the engine itself isn\'t running at all — '
          'nothing is read from the chart, nothing opens, nothing closes, '
          'full stop. Power ON starts the engine fresh, and before it '
          'looks at a single pair it checks, in order: internet '
          'connection, then MT5, then TradingView, then that both '
          'worm_10_26 and spy_9_26 are loaded AND the chart is set to '
          'Heikin Ashi candles. Only once all four pass does it start '
          'checking pairs, and it immediately runs a reverse-check over '
          'every pair this technique manages.',
    ),
    const _Section(
      icon: Icons.smart_toy_outlined,
      title: 'Auto switch',
      body:
          'Auto is separate from Power. Turning Auto OFF (the big switch) '
          'leaves the engine running and still watching its own health, '
          'but it stops checking any pair for new signals — no new '
          'trades, and nothing already running gets closed either; it '
          'just sits as-is until Auto is back on.',
    ),
    const _StatusGrid(
      rows: [
        ('Waiting', 'No confirmed three-part agreement yet for that pair.', 'Rechecked fresh every 3 minutes.'),
        (
          'Not filled',
          'An order was placed but hasn\'t triggered yet.',
          'Rechecked every 3 minutes; a stale order (signal moved on) is cancelled and replaced.',
        ),
        (
          'Filled / Running',
          'A real trade is open under this pair.',
          'Checked every 3 minutes for a recycle, flip, or update event, plus the hourly full replay as a backup.',
        ),
      ],
    ),
    _marginRiskSection,
    const _Section(
      icon: Icons.exit_to_app_outlined,
      title: 'Closing the app',
      body:
          'Closing the app window stops the engine completely, the same '
          'as turning Power off — under any circumstance, including a '
          'crash or the computer restarting. Reopening the app always '
          'comes back with Power off by default; turning it back on '
          'starts everything fresh and re-checks every running trade from '
          'its own start event forward, exactly like the hourly double-'
          'check above.',
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
