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
    required this.colorValue,
  });

  /// Stable, never-renamed identifier — used for persistence, so renaming
  /// [name] later never loses the user's selection.
  final String id;

  /// What shows in the picker and the "Read more" screen's title.
  final String name;

  /// One line under the picker, before "Read more" is clicked.
  final String shortDescription;

  /// Each technique's own accent color, as a plain 0xAARRGGBB int
  /// (2026-10-14, per the user: "the technique card in the auto card need
  /// to have different color each time user choose technique") - used for
  /// the Dashboard's Decision Technique card (border/icon tint) so which
  /// one is active reads at a glance, not just from the dropdown text.
  /// Deliberately a plain int, not `package:flutter/material.dart`'s
  /// `Color` - this model is shared with the pure-Dart engine binary
  /// (`EngineService` imports it for [id]), and a Flutter import here
  /// broke `dart compile exe bin/engine.dart` outright the first time
  /// (confirmed live - the AOT compiler can't resolve Flutter's Skia
  /// bindings outside a Flutter build). The GUI wraps this back into a
  /// real `Color` at the one call site that needs it
  /// (`control_toggles_bar.dart`).
  final int colorValue;

  /// Every technique the picker can offer. The engine reads
  /// [CoreStorage.decisionTechniqueFile] fresh each cycle (same file this
  /// picker writes) to decide which one is active - see
  /// `EngineService._activeTechnique`.
  static const all = [signalFlip, supertrendPlus, worm10];

  static const signalFlip = DecisionTechnique(
    id: 'signal_flip_hh_ll_buy_sell',
    name: 'Signal Flip (HH/LL + BUY/SELL)',
    shortDescription:
        'Reacts immediately to the newest HH/LL/BUY/SELL tag: opens, ignores, '
        'or closes-and-reopens opposite.',
    colorValue: 0xFF2196F3, // Material Colors.blue
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
    colorValue: 0xFF673AB7, // Material Colors.deepPurple
  );

  /// Added 2026-10-14, per the user: a third technique built around a
  /// custom script they wrote, "worm_10_26" (merging worm_9_26's own
  /// MSB/OB/HH/LL/BUY/SELL plots with Supertrend Plus's discrete Buy/Sell
  /// into one script), paired with spy_9_26's RSI zone plots - genuinely
  /// using RSI for entry/exit this time (unlike Signal Flip, where
  /// spy_9_26 is attached but never read). Also Heikin Ashi, same as
  /// Supertrend Plus. See [EngineService._checkOneSymbolWorm10] and
  /// `lib/data/engine/worm10_decision.dart` for the full spec - confirmed
  /// across multiple corrected rounds directly with the user.
  // 2026-10-14, per the user: "rename the new technique to hybrid
  // decision" - [id] stays unchanged (worm10_spy9_heikin_ashi) per this
  // class's own doc comment on why [id] never renames, only [name] does.
  static const worm10 = DecisionTechnique(
    id: 'worm10_spy9_heikin_ashi',
    name: 'Hybrid Decision',
    shortDescription:
        'Confluence entry (Supertrend state + HH/LL + RSI zone) with a '
        'weaker single-signal exit; a repeat entry signal recycles the '
        'same direction fresh instead of just confirming it.',
    colorValue: 0xFFFF9800, // Material Colors.orange
  );
}
