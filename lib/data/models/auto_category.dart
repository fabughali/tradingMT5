/// The Auto engine — reduced 2026-09-22, per the user ("i dont wat app to
/// check 3m, 5m, 15m, 1D... i want only 1H chart cheackup" / "nope remove
/// them from the code ... i dont need it"): originally five independent
/// timeframes ported from tradingPionex (3m/5m/15m/1H/1D), now only 1H
/// remains. Kept as an enum (rather than removing the type entirely) since
/// every call site already generically loops over [allAutoCategories]/
/// switches on [AutoCategory] — shrinking the enum to one value cleanly
/// removes the other four everywhere without touching those call sites.
enum AutoCategory { oneHour }

extension AutoCategoryX on AutoCategory {
  /// Short display tag shown after a symbol name wherever an auto position
  /// from this category appears (e.g. "ETHUSDm (1H)").
  String get label => switch (this) { AutoCategory.oneHour => '1H' };

  /// Stable identifier used in file names and persisted JSON — never the
  /// display [label], which could change wording without warning.
  String get wireValue => switch (this) { AutoCategory.oneHour => 'ONE_HOUR' };

  /// TradingView chart resolution this category reads its BUY/SELL signal
  /// from — matches its own cadence.
  String get signalResolution => switch (this) { AutoCategory.oneHour => '60' };

  /// TradingView chart resolution this category computes its MSB/OB price
  /// range from — one level above [signalResolution] (1H->1D).
  String get rangeResolution => switch (this) { AutoCategory.oneHour => 'D' };

  /// Real wall-clock cadence between this category's own candle boundaries.
  Duration get candlePeriod => switch (this) {
    AutoCategory.oneHour => const Duration(hours: 1),
  };
}

AutoCategory? autoCategoryFromWire(String? value) => switch (value) {
  'ONE_HOUR' => AutoCategory.oneHour,
  _ => null,
};

const allAutoCategories = AutoCategory.values;
