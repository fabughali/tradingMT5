import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thin client for the native MCP server MetaTrader 5 (build 6140+) exposes
/// on localhost when the terminal is running — confirmed live end-to-end on
/// this machine 2026-09-12, including a full `tools/list` (42 tools,
/// including `trade_send_market_order` and friends — this is a complete
/// first-party trading API, not just read-only data). See ARCHITECTURE.md
/// for the full story.
///
/// Auth: `Authorization: Bearer <key>`. The key comes from **Tools >
/// Options > MCP** in the terminal UI — NOT from `Config/assistant.ini`
/// (that file's keys are unrelated). Supplied via [apiKey], read from
/// `.env` (`MT5_MCP_API_KEY`) — never hardcoded, never committed.
///
/// **Gotcha, confirmed live**: the running MCP listener only reads its
/// expected key at terminal startup. Changing/saving a key in Options does
/// NOT hot-reload into an already-running server — it keeps returning 401
/// until MT5 is fully restarted. If a previously-working key suddenly stops
/// authenticating, suspect a stale in-memory key server-side before
/// assuming the key itself is wrong.
///
/// Session protocol: [connect] must be called once before any other method
/// — it runs `initialize`, captures the `Mcp-Session-Id` response header,
/// and sends the required `notifications/initialized` follow-up. Skipping
/// this gets `"MCP session is not initialized"` (JSON-RPC error -32600).
class Mt5Client {
  Mt5Client({
    required this.apiKey,
    required this.host,
    required this.port,
    void Function(String)? onLog,
  }) : _onLog = onLog;

  final String apiKey;
  final String host;
  final int port;
  final void Function(String)? _onLog;
  final http.Client _http = http.Client();

  /// Added 2026-10-05, per the user ("fix the bug so the engine will never
  /// stuck for 5 min") — none of this class's three HTTP calls had a
  /// timeout at all, so a connection MT5's MCP server accepted but then
  /// never answered (the local equivalent of the TradingView CDP stall
  /// that prompted this fix) could block the engine indefinitely with no
  /// bound whatsoever, worse than the 5-minute TradingView case. A local
  /// MCP round-trip normally completes in well under a second.
  static const _requestTimeout = Duration(seconds: 15);

  Uri get _endpoint => Uri.parse('http://$host:$port/mcp');

  int _nextId = 1;
  String? _sessionId;

  Map<String, String> _headers() => {
    'Authorization': 'Bearer $apiKey',
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    'MCP-Protocol-Version': '2025-06-18',
    if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
  };

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> params,
  ) async {
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': _nextId++,
      'method': method,
      'params': params,
    });
    final response = await _http
        .post(_endpoint, headers: _headers(), body: body)
        .timeout(_requestTimeout);
    _onLog?.call('MT5 MCP $method -> ${response.statusCode}');
    if (response.statusCode != 200) {
      throw Mt5ClientException(
        'MCP call "$method" failed with HTTP ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    if (decoded['error'] != null) {
      throw Mt5ClientException(
        'MCP call "$method" returned an error: ${decoded['error']}',
      );
    }
    return (decoded['result'] as Map<String, dynamic>?) ?? const {};
  }

  /// A notification carries no `id` and expects no JSON-RPC response body
  /// (the server answers 202 Accepted with an empty body).
  Future<void> _notify(String method, Map<String, dynamic> params) async {
    final body = jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params});
    final response = await _http
        .post(_endpoint, headers: _headers(), body: body)
        .timeout(_requestTimeout);
    _onLog?.call('MT5 MCP notify $method -> ${response.statusCode}');
    if (response.statusCode != 202 && response.statusCode != 200) {
      throw Mt5ClientException(
        'MCP notification "$method" failed with HTTP ${response.statusCode}',
      );
    }
  }

  /// Runs the MCP handshake: `initialize`, captures the session id, then
  /// sends `notifications/initialized`. Must be called once before
  /// [listTools] or [callTool].
  Future<void> connect() async {
    final initBody = jsonEncode({
      'jsonrpc': '2.0',
      'id': _nextId++,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2025-06-18',
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'trading_mt5', 'version': '0.1.0'},
      },
    });
    final response = await _http
        .post(_endpoint, headers: _headers(), body: initBody)
        .timeout(_requestTimeout);
    _onLog?.call('MT5 MCP initialize -> ${response.statusCode}');
    if (response.statusCode != 200) {
      throw Mt5ClientException(
        'MCP initialize failed with HTTP ${response.statusCode}',
      );
    }
    _sessionId = response.headers['mcp-session-id'];
    if (_sessionId == null) {
      throw Mt5ClientException('MCP initialize did not return a session id');
    }
    await _notify('notifications/initialized', const {});
  }

  Future<Map<String, dynamic>> listTools() => _call('tools/list', const {});

  /// Raw `tools/call`. Prefer the typed wrappers below — this is exposed
  /// for tools that don't have one yet.
  ///
  /// **Response shape, confirmed live 2026-09-17**: a tool result is NOT
  /// structured JSON directly — it's `{isError, content: [{type: "text",
  /// text: "a-json-string"}]}`, where `text` itself needs a SECOND
  /// `jsonDecode`. This method does that unwrapping and returns the decoded
  /// payload. Throws [Mt5ClientException] when `isError` is true.
  Future<Map<String, dynamic>> callTool(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    final result = await _call('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    final content = result['content'] as List<dynamic>?;
    final text = content != null && content.isNotEmpty
        ? (content.first as Map<String, dynamic>)['text'] as String?
        : null;
    if (text == null) {
      throw Mt5ClientException('Tool "$name" returned no text content');
    }
    // Confirmed live 2026-09-27: a permission failure (e.g. trading tools
    // disabled in Tools > Options > MCP) comes back as PLAIN TEXT, not the
    // usual JSON-wrapped payload ("Tool 'trade_send_market_order' trading
    // is not permitted") - jsonDecode on that crashes with a cryptic
    // FormatException instead of surfacing the real, human-readable reason.
    Object? payload;
    try {
      payload = jsonDecode(text);
    } catch (_) {
      throw Mt5ClientException('Tool "$name": $text');
    }
    if (result['isError'] == true) {
      throw Mt5ClientException('Tool "$name" reported an error: $payload');
    }
    return payload is Map<String, dynamic> ? payload : {'value': payload};
  }

  /// Currently open positions/orders. [symbol] filters to one exact symbol
  /// (case-insensitive, no wildcards). Read-only — never places, modifies,
  /// or cancels anything.
  Future<Map<String, dynamic>> getOpenPositions({String? symbol}) =>
      callTool('get_trading_open_positions', {
        if (symbol != null) 'symbol': symbol,
      });

  /// Closed position history — used by the reconciliation loop to find how
  /// a position that vanished from [getOpenPositions] actually ended (SL
  /// hit, TP hit, or closed manually) when the engine's own [closePosition]
  /// was never the one to close it. Read-only.
  Future<Map<String, dynamic>> getHistoryPositions({String? symbol}) =>
      callTool('get_trading_history_positions', {
        if (symbol != null) 'symbol': symbol,
      });

  /// Order (not position) history — used after a pending-order fallback
  /// doesn't trigger within the poll window, to find out whether the
  /// broker actually rejected/deleted it and why (2026-09-29, confirmed
  /// live: XRPUSD.lv's repeated "did not trigger" pending orders were all
  /// being silently auto-deleted with `comment: "deleted [no money]"` -
  /// insufficient free margin - something [getOpenPositions]'s orders list
  /// alone can't reveal once the order is gone). Read-only.
  Future<Map<String, dynamic>> getHistoryOrders({String? symbol}) =>
      callTool('get_trading_history_orders', {
        if (symbol != null) 'symbol': symbol,
      });

  /// Market Watch symbol info — used for `volume_min`, `trade_stops_level`,
  /// `digits`, and current `bid`/`ask` before placing an order. Read-only.
  Future<Map<String, dynamic>> getMarketWatchSymbol(String symbol) =>
      callTool('get_marketwatch_symbols', {'symbol': symbol, 'limit': 1});

  /// Exactly what's currently VISIBLE in MT5's own Market Watch panel right
  /// now — no filter, `include_hidden` left at its default (false). This is
  /// the live source of truth for "what symbols does the app show": add a
  /// symbol in MT5 (Market Watch right-click > Show, or the terminal's
  /// symbol search) and it appears here next poll; remove it and it drops
  /// out. Per the user (2026-09-17): the app's symbol list should always
  /// mirror this, not a separately-maintained list.
  Future<List<Map<String, dynamic>>> getWatchedSymbols() async {
    final result = await callTool('get_marketwatch_symbols', const {
      'limit': 5000,
    });
    return ((result['symbols'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
  }

  /// The broker's FULL tradable symbol universe (not just what's currently
  /// in Market Watch — `include_hidden: true` surfaces everything).
  /// Confirmed live 2026-09-17: this broker has 2247 symbols. Used by
  /// `SymbolResolver`/the symbol-availability checker rather than querying
  /// one candidate name at a time.
  Future<List<Map<String, dynamic>>> getAllSymbols() async {
    final result = await callTool('get_marketwatch_symbols', const {
      'include_hidden': true,
      'limit': 5000,
    });
    return ((result['symbols'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> getAccountInfo() =>
      callTool('get_trading_account_info', const {});

  /// Checks whether an EXACT symbol name exists anywhere in the broker's
  /// full catalog (2026-10-10, per the user's Add Pair flow: "confirmed
  /// from three apps (mt5: if this pair is listed...)") — `include_hidden:
  /// true` so this finds a symbol even if it isn't currently visible in
  /// Market Watch, unlike [getMarketWatchSymbol]. Read-only. Returns the
  /// raw symbol record (digits, volume bounds, etc.) if found, or null.
  Future<Map<String, dynamic>?> findSymbolInFullCatalog(String symbol) async {
    final result = await callTool('get_marketwatch_symbols', {
      'symbol': symbol,
      'include_hidden': true,
      'limit': 1,
    });
    final symbols = ((result['symbols'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    return symbols.isEmpty ? null : symbols.first;
  }

  /// Adds a symbol to MT5's Market Watch — visibility only, per the
  /// corresponding [removeMarketWatchSymbol]'s own contract ("never places,
  /// modifies, or cancels orders"); a symbol already present in the
  /// broker's full catalog (confirmed via [findSymbolInFullCatalog] first)
  /// but not currently shown in Market Watch needs this before it has a
  /// live bid/ask the rest of the app can read at all (2026-10-10, Add Pair
  /// flow). No-op (not an error) if the symbol is already visible.
  Future<Map<String, dynamic>> addMarketWatchSymbol(String symbol) =>
      callTool('add_marketwatch_symbol', {'symbol': symbol});

  /// Removes a symbol from MT5's Market Watch — visibility only, per the
  /// tool's own contract ("never places, modifies, or cancels orders").
  /// The GUI additionally refuses to call this for a symbol with an open
  /// position (see WatchedSymbolsList) before this method is ever reached.
  Future<Map<String, dynamic>> removeMarketWatchSymbol(String symbol) =>
      callTool('remove_marketwatch_symbol', {'symbol': symbol});

  /// Places a market BUY or SELL order. **This is a real trading action on
  /// a live account** — the caller (EngineService, gated by RiskGate) is
  /// responsible for every safety check before calling this; this method
  /// does none of its own. [side] must be exactly `'buy'` or `'sell'`.
  Future<Map<String, dynamic>> sendMarketOrder({
    required String symbol,
    required String side,
    required double volume,
    double? sl,
    double? tp,
    String? comment,
  }) => callTool('trade_send_market_order', {
    'symbol': symbol,
    'type': side,
    'volume': volume,
    if (sl != null) 'sl': sl,
    if (tp != null) 'tp': tp,
    if (comment != null) 'comment': comment,
  });

  /// Places a pending order (buy_stop/sell_stop/buy_limit/sell_limit/
  /// buy_stop_limit/sell_stop_limit). **Real trading action.** Unlike
  /// [sendMarketOrder], this tool exposes [fillingType] — confirmed live
  /// 2026-09-27: some symbols (e.g. a broker's BTC "Leverage" CFD, whose
  /// spec only allows IOC fills) reject `trade_send_market_order` outright
  /// with retcode 10030 "Invalid fill" because that tool has NO filling-mode
  /// parameter at all and the MCP server's own hidden default doesn't match
  /// the symbol's requirement. A stop order placed just past the current
  /// price with an explicit [fillingType] triggers essentially immediately
  /// and successfully opens a real position where the market-order tool
  /// cannot — see [EngineService._openPosition]'s fallback.
  Future<Map<String, dynamic>> sendPendingOrder({
    required String symbol,
    required String type,
    required double volume,
    required double price,
    double? stopLimit,
    double? sl,
    double? tp,
    String? fillingType,
    String? comment,
  }) => callTool('trade_send_pending_order', {
    'symbol': symbol,
    'type': type,
    'volume': volume,
    'price': price,
    if (stopLimit != null) 'stoplimit': stopLimit,
    if (sl != null) 'sl': sl,
    if (tp != null) 'tp': tp,
    if (fillingType != null) 'filling_type': fillingType,
    if (comment != null) 'comment': comment,
  });

  /// Cancels one existing pending order. **Real trading action.**
  Future<Map<String, dynamic>> deleteOrder({
    required String symbol,
    required int orderTicket,
  }) => callTool('trade_delete_order', {
    'symbol': symbol,
    'order_ticket': orderTicket,
  });

  /// Modifies SL/TP on an existing position. Per the tool's own contract:
  /// omit a field to leave it unchanged, pass 0 to remove it — never pass
  /// the current unchanged value.
  Future<Map<String, dynamic>> modifyStopLossTakeProfit({
    required String symbol,
    required int positionTicket,
    double? sl,
    double? tp,
  }) => callTool('trade_modify_sl_tp', {
    'symbol': symbol,
    'position_ticket': positionTicket,
    if (sl != null) 'sl': sl,
    if (tp != null) 'tp': tp,
  });

  /// Closes one open position by ticket. **Real trading action.**
  Future<Map<String, dynamic>> closePosition({
    required String symbol,
    required int positionTicket,
  }) => callTool('trade_close_single_position', {
    'symbol': symbol,
    'position_ticket': positionTicket,
  });

  void close() => _http.close();
}

class Mt5ClientException implements Exception {
  Mt5ClientException(this.message);
  final String message;

  @override
  String toString() => 'Mt5ClientException: $message';
}
