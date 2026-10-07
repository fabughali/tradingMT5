import 'package:flutter/material.dart';

import 'core_colors.dart';

/// Trading-specific semantic colors (profit/loss/warning, asset-class
/// accents) exposed as a [ThemeExtension] so they respect light/dark mode
/// the same way the rest of the M3 [ColorScheme] does. Access via
/// `context.tradingColors`.
@immutable
class TradingColors extends ThemeExtension<TradingColors> {
  const TradingColors({
    required this.profit,
    required this.profitContainer,
    required this.loss,
    required this.lossContainer,
    required this.warning,
    required this.warningContainer,
    required this.forex,
    required this.forexContainer,
    required this.crypto,
    required this.cryptoContainer,
    required this.stock,
    required this.stockContainer,
  });

  final Color profit;
  final Color profitContainer;
  final Color loss;
  final Color lossContainer;
  final Color warning;
  final Color warningContainer;

  /// Asset-class accents — one distinct hue per Market Watch section.
  final Color forex;
  final Color forexContainer;
  final Color crypto;
  final Color cryptoContainer;
  final Color stock;
  final Color stockContainer;

  static const light = TradingColors(
    profit: CoreColors.profit,
    profitContainer: CoreColors.profitContainer,
    loss: CoreColors.loss,
    lossContainer: CoreColors.lossContainer,
    warning: CoreColors.warning,
    warningContainer: CoreColors.warningContainer,
    forex: CoreColors.forex,
    forexContainer: CoreColors.forexContainer,
    crypto: CoreColors.crypto,
    cryptoContainer: CoreColors.cryptoContainer,
    stock: CoreColors.stock,
    stockContainer: CoreColors.stockContainer,
  );

  static const dark = TradingColors(
    profit: CoreColors.profitDark,
    profitContainer: CoreColors.profitContainerDark,
    loss: CoreColors.lossDark,
    lossContainer: CoreColors.lossContainerDark,
    warning: CoreColors.warningDark,
    warningContainer: CoreColors.warningContainerDark,
    forex: CoreColors.forexDark,
    forexContainer: CoreColors.forexContainerDark,
    crypto: CoreColors.cryptoDark,
    cryptoContainer: CoreColors.cryptoContainerDark,
    stock: CoreColors.stockDark,
    stockContainer: CoreColors.stockContainerDark,
  );

  @override
  TradingColors copyWith({
    Color? profit,
    Color? profitContainer,
    Color? loss,
    Color? lossContainer,
    Color? warning,
    Color? warningContainer,
    Color? forex,
    Color? forexContainer,
    Color? crypto,
    Color? cryptoContainer,
    Color? stock,
    Color? stockContainer,
  }) {
    return TradingColors(
      profit: profit ?? this.profit,
      profitContainer: profitContainer ?? this.profitContainer,
      loss: loss ?? this.loss,
      lossContainer: lossContainer ?? this.lossContainer,
      warning: warning ?? this.warning,
      warningContainer: warningContainer ?? this.warningContainer,
      forex: forex ?? this.forex,
      forexContainer: forexContainer ?? this.forexContainer,
      crypto: crypto ?? this.crypto,
      cryptoContainer: cryptoContainer ?? this.cryptoContainer,
      stock: stock ?? this.stock,
      stockContainer: stockContainer ?? this.stockContainer,
    );
  }

  @override
  TradingColors lerp(ThemeExtension<TradingColors>? other, double t) {
    if (other is! TradingColors) return this;
    return TradingColors(
      profit: Color.lerp(profit, other.profit, t)!,
      profitContainer: Color.lerp(profitContainer, other.profitContainer, t)!,
      loss: Color.lerp(loss, other.loss, t)!,
      lossContainer: Color.lerp(lossContainer, other.lossContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer: Color.lerp(
        warningContainer,
        other.warningContainer,
        t,
      )!,
      forex: Color.lerp(forex, other.forex, t)!,
      forexContainer: Color.lerp(forexContainer, other.forexContainer, t)!,
      crypto: Color.lerp(crypto, other.crypto, t)!,
      cryptoContainer: Color.lerp(cryptoContainer, other.cryptoContainer, t)!,
      stock: Color.lerp(stock, other.stock, t)!,
      stockContainer: Color.lerp(stockContainer, other.stockContainer, t)!,
    );
  }
}

extension TradingColorsX on BuildContext {
  TradingColors get tradingColors =>
      Theme.of(this).extension<TradingColors>()!;
}

/// Builds the app's Material 3 light/dark themes from a single seed color.
class CoreTheme {
  CoreTheme._();

  static ThemeData light() => _build(Brightness.light, TradingColors.light);
  static ThemeData dark() => _build(Brightness.dark, TradingColors.dark);

  static ThemeData _build(
    Brightness brightness,
    TradingColors tradingColors,
  ) {
    final scheme = ColorScheme.fromSeed(
      seedColor: CoreColors.seed,
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      extensions: [tradingColors],
      // 2026-10-03, per the user: "the text fields should look as field not
      // underline" - Material 3's own default is still UnderlineInputBorder
      // unless overridden; a filled, rounded box reads as a field at a
      // glance the way the bare underline doesn't. Applied app-wide (not
      // just Settings) for the same "consistent affordances across the
      // surface" reason every other control here follows one vocabulary.
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
    );
  }
}
