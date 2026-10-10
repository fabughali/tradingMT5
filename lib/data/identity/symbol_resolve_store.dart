import '../../core/core_storage.dart';

/// One GUI-requested "does this TradingView symbol genuinely exist"
/// check, and the engine's own answer to it (2026-10-10, per the user's
/// Add Pair flow: "confirmed from three apps (... trading view: if this
/// pair matching the name or need mapping ...)"). TradingView's CDP
/// connection is a strictly single-attach resource the engine already owns
/// exclusively (see `EngineService._ensureCdpUpInFlight`'s own doc comment
/// on why a second concurrent connection was deliberately never built) —
/// so, unlike the MT5-catalog check (plain MCP, which safely supports
/// multiple concurrent client connections, already proven throughout
/// `app_providers.dart`), this one can't be done directly from the GUI. It
/// goes through the exact same safe file-based request/response pattern
/// already used for [TerminateRequestStore]/[UnpauseCheckRequestStore]:
/// the GUI writes a 'pending' entry, the engine (which already holds the
/// one real CDP connection) drains it on its next cycle by switching the
/// shared chart to the candidate symbol and reporting back what it found.
class SymbolResolveResult {
  const SymbolResolveResult({required this.status, this.resolvedSymbol});

  /// `'pending'` | `'found'` | `'not_found'`.
  final String status;

  /// TradingView's own fully-resolved symbol string (e.g. a bare request
  /// of `"ETHUSDT"` can resolve to `"BINANCE:ETHUSDT"`) - only set when
  /// [status] is `'found'`. Shown back to the user as proof of exactly
  /// what TradingView itself considers this candidate to mean.
  final String? resolvedSymbol;

  bool get isPending => status == 'pending';
  bool get isFound => status == 'found';
}

class SymbolResolveStore {
  SymbolResolveStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _readRaw() =>
      _storage.readJsonObject(_storage.symbolResolveFile) ?? const {};

  void _write(Map<String, dynamic> map) =>
      _storage.writeJson(_storage.symbolResolveFile, map);

  /// GUI side: asks the engine to check [candidate] on its next cycle.
  /// Always resets to `'pending'`, overwriting any earlier result for the
  /// same candidate (a fresh request always wins over a stale answer).
  void request(String candidate) {
    final map = Map<String, dynamic>.from(_readRaw());
    map[candidate.toUpperCase()] = {
      'status': 'pending',
      'requested_at': DateTime.now().toUtc().toIso8601String(),
    };
    _write(map);
  }

  /// GUI side: polls for the engine's answer. Null means no request was
  /// ever made for this candidate (or it was cleared).
  SymbolResolveResult? peek(String candidate) {
    final entry = _readRaw()[candidate.toUpperCase()] as Map<String, dynamic>?;
    if (entry == null) return null;
    return SymbolResolveResult(
      status: entry['status'] as String? ?? 'pending',
      resolvedSymbol: entry['resolved_symbol'] as String?,
    );
  }

  /// Engine side: every candidate currently awaiting a check, drained each
  /// cycle - same "GUI appends, engine drains" shape as
  /// [TerminateRequestStore.loadPending].
  List<String> loadPending() {
    final raw = _readRaw();
    return [
      for (final entry in raw.entries)
        if ((entry.value as Map<String, dynamic>)['status'] == 'pending') entry.key,
    ];
  }

  /// Engine side: records the real answer for [candidate].
  void recordResult(String candidate, {required bool found, String? resolvedSymbol}) {
    final map = Map<String, dynamic>.from(_readRaw());
    map[candidate.toUpperCase()] = {
      'status': found ? 'found' : 'not_found',
      if (resolvedSymbol != null) 'resolved_symbol': resolvedSymbol,
      'checked_at': DateTime.now().toUtc().toIso8601String(),
    };
    _write(map);
  }

  /// GUI side: tidies up once a result has been shown to the user (or the
  /// Add Pair dialog is dismissed) - this store is a transient scratch
  /// pad, not a permanent record, so nothing relies on old entries
  /// sticking around.
  void clear(String candidate) {
    final map = Map<String, dynamic>.from(_readRaw());
    if (map.remove(candidate.toUpperCase()) != null) _write(map);
  }
}
