import '../../core/core_storage.dart';

/// One line of a trade's signal trace - what happened, on which signal, when.
class TradeTraceEntry {
  const TradeTraceEntry({
    required this.at,
    required this.action,
    this.signal,
    this.barTime,
    this.note,
  });

  /// When the app recorded it (UTC).
  final DateTime at;

  /// `open`, `open_late_fill`, `open_backfilled`, `open_corrected`,
  /// `update`, `close`.
  final String action;

  /// Signal wire string (e.g. `BUY_OPEN1`, `ZIGZAG_SELL`, `HH`).
  final String? signal;

  /// The signal's own bar time (epoch seconds).
  final int? barTime;
  final String? note;

  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'action': action,
    if (signal != null) 'signal': signal,
    if (barTime != null) 'bar_time': barTime,
    if (note != null) 'note': note,
  };

  factory TradeTraceEntry.fromJson(Map<String, dynamic> json) => TradeTraceEntry(
    at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    action: json['action'] as String? ?? '?',
    signal: json['signal'] as String?,
    barTime: (json['bar_time'] as num?)?.toInt(),
    note: json['note'] as String?,
  );
}

/// The signal an order was placed on, remembered until it fills - an order
/// that doesn't trigger within [EngineService._openPosition]'s 20s window
/// is only picked up later by reconciliation, which knew nothing about why
/// it was placed (2026-10-25, found live: LTC 1662352100 ran with a blank
/// Open and was closed without one ever being recorded).
class PendingOpenIntent {
  const PendingOpenIntent({
    required this.signal,
    required this.barTime,
    required this.worm10,
    required this.placedAt,
  });

  final String signal;
  final int barTime;

  /// True when [signal] is a worm10 event kind wire string, false for a
  /// Signal Flip / Supertrend tag.
  final bool worm10;
  final DateTime placedAt;

  Map<String, dynamic> toJson() => {
    'signal': signal,
    'bar_time': barTime,
    'worm10': worm10,
    'placed_at': placedAt.toUtc().toIso8601String(),
  };

  static PendingOpenIntent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final signal = raw['signal'];
    final barTime = raw['bar_time'];
    if (signal is! String || barTime is! num) return null;
    return PendingOpenIntent(
      signal: signal,
      barTime: barTime.toInt(),
      worm10: raw['worm10'] == true,
      placedAt: DateTime.tryParse(raw['placed_at'] as String? ?? '') ?? DateTime.now().toUtc(),
    );
  }
}

/// Per-ticket record of every signal event on a trade, so each trade can be
/// traced from open to close (2026-10-25, per the user: "app need to have a
/// record of all open closed signals for the single trade so it can be
/// traced"). Taken into the History entry when the trade closes. Also holds
/// [PendingOpenIntent]s, keyed `${category.wireValue}|$mt5Symbol` (one
/// resting app order per pair/category).
class TradeSignalTraceStore {
  TradeSignalTraceStore(this._storage);

  final CoreStorage _storage;

  Map<String, dynamic> _read() => _storage.readJsonObject(_storage.tradeSignalTraceFile) ?? {};

  void _write(Map<String, dynamic> map) => _storage.writeJson(_storage.tradeSignalTraceFile, map);

  Map<String, dynamic> _section(Map<String, dynamic> root, String name) =>
      Map<String, dynamic>.from((root[name] as Map?) ?? const {});

  void add(int ticket, TradeTraceEntry entry) {
    final root = _read();
    final traces = _section(root, 'traces');
    final list = List<dynamic>.from((traces['$ticket'] as List?) ?? const []);
    list.add(entry.toJson());
    traces['$ticket'] = list;
    root['traces'] = traces;
    _write(root);
  }

  List<TradeTraceEntry> peek(int ticket) {
    final list = (_section(_read(), 'traces')['$ticket'] as List?) ?? const [];
    return list.whereType<Map>().map((m) => TradeTraceEntry.fromJson(Map<String, dynamic>.from(m))).toList();
  }

  /// Returns and removes [ticket]'s trace (called when it closes).
  List<TradeTraceEntry> take(int ticket) {
    final entries = peek(ticket);
    final root = _read();
    final traces = _section(root, 'traces');
    if (traces.remove('$ticket') != null) {
      root['traces'] = traces;
      _write(root);
    }
    return entries;
  }

  void rememberIntent(String key, PendingOpenIntent intent) {
    final root = _read();
    final intents = _section(root, 'intents');
    intents[key] = intent.toJson();
    root['intents'] = intents;
    _write(root);
  }

  /// Returns and removes the intent for [key]; null if none or older than
  /// [maxAge] (a resting order is never left that long in practice).
  PendingOpenIntent? takeIntent(String key, {Duration maxAge = const Duration(days: 3)}) {
    final root = _read();
    final intents = _section(root, 'intents');
    final intent = PendingOpenIntent.fromJson(intents.remove(key));
    root['intents'] = intents;
    _write(root);
    if (intent == null) return null;
    if (DateTime.now().toUtc().difference(intent.placedAt) > maxAge) return null;
    return intent;
  }
}
