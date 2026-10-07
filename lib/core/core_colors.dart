import 'package:flutter/material.dart';

/// Brand seed and semantic (non-Material) color tokens. Structural colors
/// (surface, outline, etc.) come from [ColorScheme.fromSeed] in
/// core_theme.dart — this file only holds the seed and the trading-specific
/// semantics M3 doesn't model (profit/loss, risk severity). Seed is
/// deliberately different from tradingPionex's (0xFF3762F0) — separate app,
/// separate identity.
class CoreColors {
  CoreColors._();

  static const seed = Color(0xFF0E7490);

  static const profit = Color(0xFF1DB975);
  static const profitContainer = Color(0xFFD8F5E6);
  static const loss = Color(0xFFE5484D);
  static const lossContainer = Color(0xFFFBE0E0);
  static const warning = Color(0xFFE0A62B);
  static const warningContainer = Color(0xFFFBEDCB);

  static const profitDark = Color(0xFF3DDC97);
  static const profitContainerDark = Color(0xFF0F3D2A);
  static const lossDark = Color(0xFFFF6B6E);
  static const lossContainerDark = Color(0xFF4A1416);
  static const warningDark = Color(0xFFF2C14E);
  static const warningContainerDark = Color(0xFF473307);

  // Asset-class tokens — one distinct hue per Market Watch section
  // (Forex/Crypto/Stocks), per the user's request for visually distinct
  // category cards.
  static const forex = Color(0xFF2563EB);
  static const forexContainer = Color(0xFFDCE6FD);
  static const crypto = Color(0xFFD97706);
  static const cryptoContainer = Color(0xFFFCE9CC);
  static const stock = Color(0xFF7C3AED);
  static const stockContainer = Color(0xFFE9DDFC);

  static const forexDark = Color(0xFF7AA2F7);
  static const forexContainerDark = Color(0xFF16244A);
  static const cryptoDark = Color(0xFFF2B25C);
  static const cryptoContainerDark = Color(0xFF473208);
  static const stockDark = Color(0xFFB794F6);
  static const stockContainerDark = Color(0xFF33205C);
}
