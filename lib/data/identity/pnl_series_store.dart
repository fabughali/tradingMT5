import '../../core/core_storage.dart';

/// One P&L sample of a running trade.
class PnlPoint {
  const PnlPoint({required this.time, required this.profit, this.percent});

  /// Epoch seconds (UTC).
  final int time;

  /// Floating P&L in account currency.
  final double profit;

  /// [profit] as % of the position's notional, when known.
  final double? percent;

  Map<String, dynamic> toJson() => {
    't': time,
    'p': profit,
    if (percent != null) 'pct': percent,
  };

  static PnlPoint? fromJson(Map<String, dynamic> json) {
    final t = json['t'];
    final p = json['p'];
    if (t is! num || p is! num) return null;
    return PnlPoint(time: t.toInt(), profit: p.toDouble(), percent: (json['pct'] as num?)?.toDouble());
  }
}

/// P&L of each trade over its whole life, one append-only file per ticket
/// (2026-10-25, per the user: "app need to have a record for P&L run
/// through trade duration" - drawn as the History card's P&L chart, and live
/// on the Dashboard). The engine samples every SLL sweep (~30s); a point is
/// skipped only when it is both recent ([minGap]) and unchanged, so moves
/// are never lost and a flat trade still gets a point every [minGap].
class PnlSeriesStore {
  PnlSeriesStore(this._storage, {this.minGap = const Duration(seconds: 15)});

  final CoreStorage _storage;
  final Duration minGap;
  final Map<int, PnlPoint> _last = {};

  /// Returns true if the point was written.
  bool record(int ticket, double profit, double? percent, {DateTime? now}) {
    final t = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 1000;
    final last = _last[ticket];
    if (last != null) {
      final recent = t - last.time < minGap.inSeconds;
      final unchanged = (profit - last.profit).abs() < 0.005;
      if (t <= last.time || (recent && unchanged)) return false;
    }
    final point = PnlPoint(time: t, profit: profit, percent: percent);
    _storage.appendJsonl(_storage.pnlSeriesFile(ticket), point.toJson());
    _last[ticket] = point;
    return true;
  }

  List<PnlPoint> read(int ticket) => _storage
      .readJsonl(_storage.pnlSeriesFile(ticket))
      .map(PnlPoint.fromJson)
      .whereType<PnlPoint>()
      .toList();
}
