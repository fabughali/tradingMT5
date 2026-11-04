import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/core_constants.dart';

/// Raw Chrome DevTools Protocol client over a plain WebSocket — ported 1:1
/// from lib/cdp.js. This is NOT a browser-automation framework: CDP is just
/// JSON-RPC over a WebSocket, and `evaluate()` runs a JavaScript expression
/// string inside the target page (TradingView Desktop's own renderer) and
/// returns its value. The JS strings themselves are ported verbatim in
/// signals_reader.dart / chart_state.dart / enforce.dart — this file only
/// owns the transport.
class CdpException implements Exception {
  CdpException(this.message);
  final String message;
  @override
  String toString() => 'CdpException: $message';
}

class _PendingRequest {
  _PendingRequest(this.completer, this.timer);
  final Completer<Map<String, dynamic>?> completer;
  final Timer timer;
}

class CdpClient {
  CdpClient(this._socket, {Duration timeout = CoreConstants.cdpRequestTimeout})
    : _timeout = timeout {
    _subscription = _socket.listen(
      _onMessage,
      onDone: () => _fail('websocket closed'),
      onError: (_) => _fail('websocket error'),
    );
  }

  final WebSocket _socket;
  final Duration _timeout;
  final Map<int, _PendingRequest> _pending = {};
  late final StreamSubscription _subscription;
  int _id = 0;

  /// Mirrors the original's `cdp.dead` flag — set once the socket is known
  /// unusable, so callers reconnect with a fresh client instead of reusing a
  /// broken one (the core self-recovery guard: a lost CDP target must reject
  /// in-flight awaits instead of hanging the engine's mainLoop forever).
  bool dead = false;

  void _onMessage(dynamic raw) {
    Map<String, dynamic> msg;
    try {
      msg = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final id = msg['id'] as int?;
    if (id == null) return;
    final pending = _pending.remove(id);
    if (pending == null) return;
    pending.timer.cancel();
    final error = msg['error'] as Map<String, dynamic>?;
    if (error != null) {
      pending.completer.completeError(
        CdpException(error['message']?.toString() ?? 'CDP error'),
      );
    } else {
      pending.completer.complete(msg['result'] as Map<String, dynamic>?);
    }
  }

  void _fail(String reason) {
    dead = true;
    final entries = _pending.entries.toList();
    _pending.clear();
    for (final entry in entries) {
      entry.value.timer.cancel();
      entry.value.completer.completeError(
        CdpException('CDP $reason: pending request #${entry.key} rejected'),
      );
    }
  }

  Future<Map<String, dynamic>?> send(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    if (dead || _socket.readyState != WebSocket.open) {
      return Future.error(
        CdpException('CDP send aborted (dead=$dead) for $method'),
      );
    }
    final id = ++_id;
    final completer = Completer<Map<String, dynamic>?>();
    final timer = Timer(_timeout, () {
      _pending.remove(id);
      dead = true;
      try {
        _socket.close();
      } catch (_) {}
      completer.completeError(
        CdpException(
          'CDP request timed out after ${_timeout.inMilliseconds}ms for $method (req #$id)',
        ),
      );
    });
    _pending[id] = _PendingRequest(completer, timer);
    try {
      _socket.add(jsonEncode({'id': id, 'method': method, 'params': params}));
    } catch (e) {
      timer.cancel();
      _pending.remove(id);
      completer.completeError(CdpException('CDP send failed for $method: $e'));
    }
    return completer.future;
  }

  /// Evaluates a JavaScript expression inside the page and returns its value
  /// (via `Runtime.evaluate` with `returnByValue`+`awaitPromise`).
  Future<dynamic> evaluate(String expression) async {
    final result = await send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    });
    final exceptionDetails =
        result?['exceptionDetails'] as Map<String, dynamic>?;
    if (exceptionDetails != null) {
      final exception = exceptionDetails['exception'] as Map<String, dynamic>?;
      throw CdpException(
        (exception?['description'] ??
                exceptionDetails['text'] ??
                'JS evaluation error')
            .toString(),
      );
    }
    return (result?['result'] as Map<String, dynamic>?)?['value'];
  }

  void close() {
    try {
      _socket.close();
    } catch (_) {}
    _subscription.cancel();
  }
}

class CdpTarget {
  const CdpTarget({
    required this.type,
    required this.url,
    required this.webSocketDebuggerUrl,
  });
  final String type;
  final String url;
  final String webSocketDebuggerUrl;
}

Future<List<Map<String, dynamic>>> _fetchJsonList(String host, int port) async {
  final client = HttpClient();
  try {
    final request = await client
        .getUrl(Uri.parse('http://$host:$port/json/list'))
        .timeout(CoreConstants.cdpJsonListTimeout);
    final response = await request.close().timeout(
      CoreConstants.cdpJsonListTimeout,
    );
    if (response.statusCode != 200) {
      throw CdpException('CDP /json/list returned HTTP ${response.statusCode}');
    }
    final body = await response.transform(utf8.decoder).join();
    return (jsonDecode(body) as List).cast<Map<String, dynamic>>();
  } finally {
    client.close(force: true);
  }
}

CdpTarget _toTarget(Map<String, dynamic> t) => CdpTarget(
  type: t['type'] as String,
  url: t['url'] as String,
  webSocketDebuggerUrl: t['webSocketDebuggerUrl'] as String,
);

/// TradingMT5's own chart tab is not open in TradingView (or no layout ID is
/// configured). Never a reason to restart TradingView or use another tab.
class OwnChartTabMissingException extends CdpException {
  OwnChartTabMissingException(String layoutId)
    : super(
        layoutId.isEmpty
            ? 'no TradingView layout ID configured (config.json cdp.layout_id) - doing nothing'
            : 'own chart tab /chart/$layoutId/ not found - doing nothing',
      );
}

/// Whether [url] is the chart page of layout [layoutId]
/// (`https://www.tradingview.com/chart/<layoutId>/...`).
bool isOwnChartUrl(String url, String layoutId) {
  if (layoutId.isEmpty) return false;
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.host.toLowerCase().endsWith('tradingview.com')) return false;
  final segments = uri.pathSegments;
  return segments.length >= 2 && segments[0] == 'chart' && segments[1] == layoutId;
}

/// The one page target that is TradingMT5's own chart tab, or null
/// (2026-11-04, v1.6.63, per the user: TradingMT5 and TradingPionex share one
/// TradingView, each on its own tab; "it never reads, switches or changes any
/// other tab ... It never falls back to another tab").
Map<String, dynamic>? pickOwnChartTarget(List<Map<String, dynamic>> targets, String layoutId) {
  for (final t in targets) {
    if (t['type'] == 'page' && isOwnChartUrl((t['url'] ?? '').toString(), layoutId)) return t;
  }
  return null;
}

/// Fetches `/json/list` and returns TradingMT5's own chart tab - the page
/// whose URL is `/chart/<layoutId>/`. Throws [OwnChartTabMissingException]
/// when it isn't there; there is no fallback to any other tab.
Future<CdpTarget> getChartTarget(String host, int port, {required String layoutId}) async {
  final targets = await _fetchJsonList(host, port);
  final own = pickOwnChartTarget(targets, layoutId);
  if (own == null) throw OwnChartTabMissingException(layoutId);
  return _toTarget(own);
}

/// Lists every visible TradingView page target (not just the first match).
/// Read-only listing from `/json/list` - never connects to any of them.
Future<List<CdpTarget>> listTradingViewTargets(String host, int port) async {
  final targets = await _fetchJsonList(host, port);
  return targets
      .where(
        (t) =>
            t['type'] == 'page' &&
            RegExp(
              'tradingview',
              caseSensitive: false,
            ).hasMatch((t['url'] ?? '').toString()),
      )
      .map(_toTarget)
      .toList();
}

/// Connects to the TradingView chart page's CDP WebSocket, retrying with
/// exponential backoff — ported 1:1 from lib/cdp.js `connectToChart`.
Future<CdpClient> connectToChart(
  String host,
  int port, {
  required String layoutId,
  // Lowered from 5, 2026-10-05, per the user ("fix the bug so the engine
  // will never stuck for 5 min") — paired with CoreConstants.cdpRequestTimeout
  // dropping from 60s to 8s, this caps the worst case here at roughly
  // 3 x 8s plus backoff (~27.5s) instead of the old 5 x 60s (~5 minutes).
  int maxRetries = 3,
}) async {
  const baseDelay = Duration(milliseconds: 500);
  Object? lastError;
  for (var attempt = 0; attempt < maxRetries; attempt++) {
    try {
      final target = await getChartTarget(host, port, layoutId: layoutId);
      final socket = await WebSocket.connect(target.webSocketDebuggerUrl);
      final client = CdpClient(socket);
      await client.send('Runtime.enable');
      return client;
    } on OwnChartTabMissingException {
      rethrow;
    } catch (e) {
      lastError = e;
      final delayMs = (baseDelay.inMilliseconds * (1 << attempt)).clamp(
        0,
        30000,
      );
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
  }
  throw CdpException(
    'CDP connection failed after $maxRetries attempts: $lastError',
  );
}
