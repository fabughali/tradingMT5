import '../../core/core_storage.dart';

/// USER RULES (ported from tradingPionex's created-bots.js / PRD §10):
///  1. The human may manually edit or close ANY position the app opened.
///  2. The app may NEVER modify (close/edit) a position that was opened
///     manually — only positions on this list are considered "app-opened".
///  3. The app may open a new position on a symbol even if a MANUAL position
///     is already running there (a manual position never blocks a new app
///     position).
///
/// Persisted to logs/open-positions.json — adapted from tradingPionex's
/// CreatedBotsStore, with the identity concept renamed: tradingPionex tracks
/// a Pionex buOrderId (String); MT5 has no such concept, so this tracks the
/// MT5 position ticket instead — an int returned by the
/// `trade_send_market_order` MCP tool's result. Every position ticket the
/// app itself opens is remembered here so a running position can be told
/// apart from a manually-opened one across restarts.
class OpenPositionStore {
  OpenPositionStore(this._storage) {
    load();
  }

  final CoreStorage _storage;
  final Set<int> _tickets = {};

  /// Reads `open-positions.json`. On a corrupt/unparseable file (as opposed
  /// to one that simply doesn't exist yet), deliberately KEEPS whatever
  /// `_tickets` already holds in memory rather than resetting to empty -
  /// treating corruption as "nothing is app-opened" would make
  /// `isAppOpened` return false for every real app-opened position, which
  /// lets the engine's main loop fall through its "position already
  /// running" guard and open a second real position on an already-live
  /// symbol. Logged to stderr (visible in the process log even without
  /// going through AppLogger) so this never fails silently.
  Set<int> load() {
    List<dynamic> arr;
    try {
      arr = _storage.readJsonArrayStrict(_storage.openPositionsFile);
    } catch (e) {
      // ignore: avoid_print
      print(
        '[CRITICAL] open-positions.json exists but failed to parse ($e) - '
        'keeping the last known-good in-memory app-opened set instead of '
        'treating this as "nothing is app-opened".',
      );
      return _tickets;
    }
    _tickets.clear();
    for (final ticket in arr) {
      if (ticket == null) continue;
      final parsed = ticket is int ? ticket : int.tryParse(ticket.toString());
      if (parsed != null) _tickets.add(parsed);
    }
    return _tickets;
  }

  void _persist() =>
      _storage.writeJson(_storage.openPositionsFile, _tickets.toList());

  bool isAppOpened(int? positionTicket) =>
      positionTicket != null && _tickets.contains(positionTicket);

  bool rememberPosition(int? positionTicket) {
    if (positionTicket == null) return false;
    _tickets.add(positionTicket);
    _persist();
    return true;
  }

  bool forgetPosition(int? positionTicket) {
    if (positionTicket == null) return false;
    final removed = _tickets.remove(positionTicket);
    if (removed) _persist();
    return removed;
  }

  List<int> listAppPositions() => _tickets.toList();
}
