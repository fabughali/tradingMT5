import 'dart:io';

/// Cheap internet reachability probe — a DNS lookup against a small set of
/// well-known, highly-available hosts (never a single point of failure), so
/// one host having a bad day doesn't falsely report the whole connection
/// down. Checked FIRST in the Power health check (2026-09-20, per the
/// user): neither MT5 nor TradingView can meaningfully be "down" versus
/// merely unreachable if there's no internet at all.
Future<bool> hasInternetConnection({
  Duration timeout = const Duration(seconds: 5),
}) async {
  for (final host in const ['cloudflare.com', 'google.com', '1.1.1.1']) {
    try {
      final result = await InternetAddress.lookup(host).timeout(timeout);
      if (result.isNotEmpty && result.first.rawAddress.isNotEmpty) {
        return true;
      }
    } catch (_) {
      // Try the next host — a single failed lookup isn't conclusive.
    }
  }
  return false;
}
