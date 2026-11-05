import '../../core/core_storage.dart';

/// User TP/SL triggers (2026-11-05, v1.6.67, per the user: "set take profit
/// and stop loss triggers in three ways - P&L percentage, dollars, price ...
/// for any auto trade even if this trade not filled or filled").
///
/// Keys: `ticket:<n>` for a running trade (a copy has its own ticket - copies
/// get NO trigger unless the user sets one on the copy's card), or
/// `pair:<tvSymbol>` for a pair still waiting/resting - the engine moves it
/// onto the main (non-copy) ticket the moment that pair fills. A `ticket:`
/// entry is cleared when its trade closes, whatever closed it.
///
/// Each side holds `{kind: pct|usd|price, value}`; the engine compares the
/// live value IN THAT UNIT (card P&L %, card $, live price) - never a
/// converted equivalent (per the user).
enum TriggerKind { pct, usd, price }

class UserTrigger {
  const UserTrigger(this.kind, this.value);
  final TriggerKind kind;
  final double value;

  Map<String, dynamic> toJson() => {'kind': kind.name, 'value': value};

  static UserTrigger? fromJson(Object? j) {
    if (j is! Map) return null;
    final k = TriggerKind.values.where((e) => e.name == j['kind']).firstOrNull;
    final v = (j['value'] as num?)?.toDouble();
    return k == null || v == null ? null : UserTrigger(k, v);
  }

  String describe() => switch (kind) {
        TriggerKind.pct => '${value >= 0 ? '+' : ''}${value.toStringAsFixed(2)}%',
        TriggerKind.usd => '${value >= 0 ? '+' : '-'}\$${value.abs().toStringAsFixed(2)}',
        TriggerKind.price => '@ $value',
      };
}

class UserTriggers {
  const UserTriggers({this.tp, this.sl});
  final UserTrigger? tp;
  final UserTrigger? sl;
  bool get isEmpty => tp == null && sl == null;
}

String ticketTriggerKey(int ticket) => 'ticket:$ticket';
String pairTriggerKey(String tvSymbol) => 'pair:${tvSymbol.toUpperCase()}';

class UserTriggerStore {
  UserTriggerStore(this._storage);
  final CoreStorage _storage;

  Map<String, dynamic> _read() => Map<String, dynamic>.from(_storage.readJsonObject(_storage.userTriggersFile) ?? const {});
  void _write(Map<String, dynamic> m) => _storage.writeJson(_storage.userTriggersFile, m);

  Map<String, UserTriggers> all() {
    final out = <String, UserTriggers>{};
    _read().forEach((k, v) {
      if (v is! Map) return;
      final t = UserTriggers(tp: UserTrigger.fromJson(v['tp']), sl: UserTrigger.fromJson(v['sl']));
      if (!t.isEmpty) out[k] = t;
    });
    return out;
  }

  UserTriggers get(String key) => all()[key] ?? const UserTriggers();

  /// Sets ([trigger] non-null) or clears one side ('tp' or 'sl') of [key].
  void setSide(String key, String side, UserTrigger? trigger) {
    final m = _read();
    final e = Map<String, dynamic>.from(m[key] as Map? ?? const {});
    if (trigger == null) {
      e.remove(side);
    } else {
      e[side] = trigger.toJson();
    }
    if (e.isEmpty) {
      m.remove(key);
    } else {
      m[key] = e;
    }
    _write(m);
  }

  void remove(String key) {
    final m = _read();
    if (m.remove(key) != null) _write(m);
  }

  /// Moves a waiting pair's triggers onto its freshly-filled ticket.
  void bind(String pairKey, String ticketKey) {
    final m = _read();
    final e = m.remove(pairKey);
    if (e == null) return;
    m[ticketKey] = e;
    _write(m);
  }
}
