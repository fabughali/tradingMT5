import 'auto_category.dart';
import 'trade_direction.dart';

/// One closed position's full record — ported from tradingPionex's own
/// `BotHistoryEntry`/`bot-history.jsonl` (2026-09-27, per the user: "i want
/// app to have same history record for bot as tradingPionex"), adapted for
/// MT5: Pionex-only fields (leverage, gridCount, liquidationPrice,
/// extraMargin, initial/actualInvestment — none of which exist in this
/// app's no-investment-sizing model) are dropped; `buOrderId` becomes the
/// MT5 position ticket (an int, not a String).
///
/// [stopReason] identifies exactly how the position ended, per the user's
/// spec ("closed by app/user/sl/tp/opposite signal"):
/// - `'opposite_signal'` — the engine's own signal-flip close.
/// - `'take_profit'` / `'stop_loss'` — MT5 itself closed it hitting the
///   order's own TP/SL price (detected by reconciliation: the app-tracked
///   position vanished from MT5 without the engine ever closing it, and
///   the close price matches the recorded TP/SL).
/// - `'closed_by_user'` — vanished from MT5 without matching TP/SL and
///   without the engine closing it (a human closed it manually in MT5).
/// - `'closed_by_app'` — the engine closed it for a reason other than an
///   opposite signal (reserved for future use — no call site does this
///   today; every current app-initiated close is `'opposite_signal'`).
class BotHistoryEntry {
  const BotHistoryEntry({
    required this.id,
    required this.ts,
    required this.mt5Symbol,
    required this.tradingViewSymbol,
    required this.category,
    required this.ticket,
    required this.direction,
    required this.entryPrice,
    this.exitPrice,
    this.volume,
    this.stopLoss,
    this.takeProfit,
    this.realizedProfit,
    required this.startTime,
    this.endTime,
    this.openSignalType,
    this.openSignalAt,
    this.updateSignalType,
    this.updateSignalAt,
    this.closeSignalType,
    this.closeSignalAt,
    this.stopReason,
    this.detail,
  });

  final String id;
  final DateTime ts;
  final String mt5Symbol;
  final String tradingViewSymbol;
  final AutoCategory category;
  final int ticket;
  final TradeDirection direction;
  final double entryPrice;
  final double? exitPrice;

  /// The actual lot size this trade was opened with (2026-10-06, per the
  /// user: "add volume to history. it should be recorded too"). Null for
  /// entries written before this field existed - never backfilled.
  final double? volume;

  /// The SL/TP levels this trade was actually opened with (2026-10-06, per
  /// the user: "also add tp/sl trigger entry price too" / "everything
  /// should be recorded") - the ORIGINAL levels set at open time, not
  /// whatever MT5 reports NOW (a closed position/history record no longer
  /// carries its own sl/tp once gone, so these are read at close time from
  /// whichever source still has them: the live position snapshot for an
  /// app-driven close, or MT5's own closed-order record for a
  /// reconciled SL/TP/manual close).
  final double? stopLoss;
  final double? takeProfit;
  final double? realizedProfit;
  final DateTime startTime;
  final DateTime? endTime;

  final String? openSignalType;
  final int? openSignalAt;

  /// The latest same-direction confirming tag seen while this position was
  /// open (2026-10-06, per the user: "i want history to include open
  /// signal, update signal, close A signal, close b signal") - mirrors
  /// [EntrySignalSnapshot.updateTag]/[updateTime], which already existed
  /// and was already being read at close time, just never carried through
  /// into the history record itself. Null if the direction was never
  /// re-confirmed before the position closed.
  final String? updateSignalType;
  final int? updateSignalAt;

  final String? closeSignalType;
  final int? closeSignalAt;

  final String? stopReason;
  final String? detail;

  Map<String, dynamic> toJson() => {
    'id': id,
    'ts': ts.toIso8601String(),
    'mt5_symbol': mt5Symbol,
    'tradingview_symbol': tradingViewSymbol,
    'category': category.wireValue,
    'ticket': ticket,
    'direction': direction == TradeDirection.long ? 'long' : 'short',
    'entry_price': entryPrice,
    if (exitPrice != null) 'exit_price': exitPrice,
    if (volume != null) 'volume': volume,
    if (stopLoss != null) 'stop_loss': stopLoss,
    if (takeProfit != null) 'take_profit': takeProfit,
    if (realizedProfit != null) 'realized_profit': realizedProfit,
    'start_time': startTime.toIso8601String(),
    if (endTime != null) 'end_time': endTime!.toIso8601String(),
    if (openSignalType != null) 'open_signal_type': openSignalType,
    if (openSignalAt != null) 'open_signal_at': openSignalAt,
    if (updateSignalType != null) 'update_signal_type': updateSignalType,
    if (updateSignalAt != null) 'update_signal_at': updateSignalAt,
    if (closeSignalType != null) 'close_signal_type': closeSignalType,
    if (closeSignalAt != null) 'close_signal_at': closeSignalAt,
    if (stopReason != null) 'stop_reason': stopReason,
    if (detail != null) 'detail': detail,
  };

  factory BotHistoryEntry.fromJson(Map<String, dynamic> json) => BotHistoryEntry(
    id: json['id'] as String,
    ts: DateTime.parse(json['ts'] as String),
    mt5Symbol: json['mt5_symbol'] as String,
    tradingViewSymbol: json['tradingview_symbol'] as String,
    category: autoCategoryFromWire(json['category'] as String?) ?? AutoCategory.oneHour,
    ticket: (json['ticket'] as num).toInt(),
    direction: (json['direction'] as String) == 'long' ? TradeDirection.long : TradeDirection.short,
    entryPrice: (json['entry_price'] as num).toDouble(),
    exitPrice: (json['exit_price'] as num?)?.toDouble(),
    volume: (json['volume'] as num?)?.toDouble(),
    stopLoss: (json['stop_loss'] as num?)?.toDouble(),
    takeProfit: (json['take_profit'] as num?)?.toDouble(),
    realizedProfit: (json['realized_profit'] as num?)?.toDouble(),
    startTime: DateTime.parse(json['start_time'] as String),
    endTime: json['end_time'] != null ? DateTime.parse(json['end_time'] as String) : null,
    openSignalType: json['open_signal_type'] as String?,
    openSignalAt: (json['open_signal_at'] as num?)?.toInt(),
    updateSignalType: json['update_signal_type'] as String?,
    updateSignalAt: (json['update_signal_at'] as num?)?.toInt(),
    closeSignalType: json['close_signal_type'] as String?,
    closeSignalAt: (json['close_signal_at'] as num?)?.toInt(),
    stopReason: json['stop_reason'] as String?,
    detail: json['detail'] as String?,
  );
}
