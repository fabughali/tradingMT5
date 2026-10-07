/// Which "check cycle" the current 1H candle belongs to — a pure wall-clock
/// computation (2026-09-29, per the user: "first cycle is one check...
/// fourth cycle is one check and so on"). Deliberately NOT engine-persisted
/// state: TradingView/MT5's 1H bars are confirmed live to always align to
/// exact UTC hour boundaries (every bar time seen is a multiple of 3600),
/// so both the engine and the GUI can derive the same cycle number
/// independently from [DateTime.now()] alone — no coordination file
/// needed, and no risk of the two ever disagreeing.
int currentAutoCycle([DateTime? now]) {
  final epochHour = (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch ~/ 3600000;
  return (epochHour % 3) + 1;
}

/// Time remaining until the next 1H candle boundary (the next UTC hour
/// mark) — feeds the 1H button's countdown (2026-09-29, per the user: "add
/// inside 1H button a count down timer according to candle timing in
/// trading view").
Duration timeUntilNextHourlyCandle([DateTime? now]) {
  final n = (now ?? DateTime.now()).toUtc();
  final nextHour = DateTime.utc(n.year, n.month, n.day, n.hour).add(const Duration(hours: 1));
  return nextHour.difference(n);
}

/// True when [checkedAt] falls within the SAME UTC hour as [now] — i.e.
/// "checked in the current candle cycle" (2026-09-29, per the user's
/// Dashboard "Check" column spec). A timestamp from an earlier hour reads
/// as stale/not-checked without any explicit per-cycle reset needed.
bool isWithinCurrentCandle(DateTime? checkedAt, [DateTime? now]) {
  if (checkedAt == null) return false;
  final n = (now ?? DateTime.now()).toUtc();
  final c = checkedAt.toUtc();
  return n.year == c.year && n.month == c.month && n.day == c.day && n.hour == c.hour;
}
