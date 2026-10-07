/// One selectable decision technique — the rules the engine uses to decide
/// when to open, ignore, or close+reopen a position (2026-10-06, per the
/// user: "create a knob in power toggle section where user can choose from
/// a list one option of decision technique"). Only one exists today;
/// [DecisionTechnique.all] is the single place a future technique gets
/// added to the picker.
class DecisionTechnique {
  const DecisionTechnique({
    required this.id,
    required this.name,
    required this.shortDescription,
  });

  /// Stable, never-renamed identifier — used for persistence, so renaming
  /// [name] later never loses the user's selection.
  final String id;

  /// What shows in the picker and the "Read more" screen's title.
  final String name;

  /// One line under the picker, before "Read more" is clicked.
  final String shortDescription;

  /// Every technique the picker can offer. The engine reads
  /// [CoreStorage.decisionTechniqueFile] fresh each cycle (same file this
  /// picker writes) to decide which one is active - see
  /// `EngineService._activeTechnique`.
  static const all = [signalFlip, supertrendPlus];

  static const signalFlip = DecisionTechnique(
    id: 'signal_flip_hh_ll_buy_sell',
    name: 'Signal Flip (HH/LL + BUY/SELL)',
    shortDescription:
        'Reacts immediately to the newest HH/LL/BUY/SELL tag: opens, ignores, '
        'or closes-and-reopens opposite.',
  );

  /// Added 2026-10-06, per the user: Supertrend Plus on Heikin Ashi candles
  /// - a single Buy/Sell signal pair that alternates cleanly (a Buy is
  /// always the close of the last Sell and vice versa), so there's no
  /// separate "Update" (agreeing re-confirmation) concept at all, and the
  /// Dashboard's live "Close A" preview never shows anything for these
  /// pairs either - see [EngineService]'s own technique-specific pending
  /// tracker for why.
  static const supertrendPlus = DecisionTechnique(
    id: 'supertrend_plus_heikin_ashi',
    name: 'Supertrend Plus (Heikin Ashi)',
    shortDescription:
        'A Buy signal opens long and is the close for any running short; a '
        'Sell signal does the reverse. No separate confirmation signal.',
  );
}
