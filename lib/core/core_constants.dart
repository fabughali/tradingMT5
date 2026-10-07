/// App-wide constants that aren't naturally part of any single data-layer
/// file. Keep this small — most constants belong next to the code that
/// actually uses them (e.g. poll intervals live in the provider that polls).
class CoreConstants {
  CoreConstants._();

  static const appName = 'TradingMT5';

  // Ported from tradingPionex — used by data/tradingview/cdp_client.dart,
  // which is broker-agnostic and shared unchanged by both apps.
  //
  // Lowered from 60s 2026-10-05, per the user ("fix the bug so the engine
  // will never stuck for 5 min") — confirmed live that a single stuck CDP
  // request (`Runtime.enable`) at the old 60s timeout, retried up to 5
  // times by connectToChart, could block the engine's entire health-check
  // step for up to 5 minutes. A live, responsive CDP target answers in
  // milliseconds; 8s is already generous slack for a loaded machine while
  // failing fast enough that the retry ladder below stays short.
  static const Duration cdpRequestTimeout = Duration(seconds: 8);
  static const Duration cdpJsonListTimeout = Duration(seconds: 10);
}
