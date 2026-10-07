/// Live MT5 account numbers (2026-09-29, per the user: shown at the top of
/// the Dashboard's Auto-Managed Trades card, right below the
/// running/pending/waiting summary line) — straight from
/// `get_trading_account_info`'s `account` object, no derived state except
/// [marginLevel] (MT5 doesn't return that field itself; it's the standard
/// `equity / margin * 100` computation, same formula the MT5 terminal UI
/// itself uses).
class AccountSnapshot {
  const AccountSnapshot({
    required this.balance,
    required this.equity,
    required this.margin,
    required this.marginFree,
    required this.currency,
  });

  final double balance;
  final double equity;
  final double margin;
  final double marginFree;
  final String currency;

  /// Null when [margin] is 0 (no open exposure) - MT5 itself shows this as
  /// blank/infinite rather than a number in that case.
  double? get marginLevel => margin > 0 ? (equity / margin) * 100 : null;

  factory AccountSnapshot.fromJson(Map<String, dynamic> json) {
    final account = (json['account'] as Map<String, dynamic>?) ?? json;
    return AccountSnapshot(
      balance: (account['balance'] as num?)?.toDouble() ?? 0,
      equity: (account['equity'] as num?)?.toDouble() ?? 0,
      margin: (account['margin'] as num?)?.toDouble() ?? 0,
      marginFree: (account['margin_free'] as num?)?.toDouble() ?? 0,
      currency: account['currency'] as String? ?? '',
    );
  }
}
