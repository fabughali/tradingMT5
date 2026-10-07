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

/// Fetches `/json/list` and returns the first TradingView chart page target
/// (preferring `tradingview.com/chart`, falling back to any tradingview page).
Future<CdpTarget?> getChartTarget(String host, int port) async {
  final targets = await _fetchJsonList(host, port);
  Map<String, dynamic>? pick(bool Function(String url) matches) {
    for (final t in targets) {
      if (t['type'] == 'page' && matches((t['url'] ?? '').toString())) return t;
    }
    return null;
  }

  final chartTarget =
      pick(
        (url) => RegExp(
          'tradingview\\.com/chart',
          caseSensitive: false,
        ).hasMatch(url),
      ) ??
      pick((url) => RegExp('tradingview', caseSensitive: false).hasMatch(url));
  return chartTarget == null ? null : _toTarget(chartTarget);
}

/// Lists every visible TradingView page target (not just the first match).
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
      final target = await getChartTarget(host, port);
      if (target == null)
        throw CdpException('No TradingView chart target found');
      final socket = await WebSocket.connect(target.webSocketDebuggerUrl);
      final client = CdpClient(socket);
      await client.send('Runtime.enable');
      return client;
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
