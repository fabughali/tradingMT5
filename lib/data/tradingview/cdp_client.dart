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
    _tvAnsweringSince ??= DateTime.now();
    return (jsonDecode(body) as List).cast<Map<String, dynamic>>();
  } catch (_) {
    _tvAnsweringSince = null;
    rethrow;
  } finally {
    client.close(force: true);
  }
}

/// Since when TradingView has answered `/json/list` without a break this
/// engine run (2026-11-14): after a restart it restores its tabs slowly, so
/// a tab is opened only once it has answered for [_tvSettleBeforeOpen].
DateTime? _tvAnsweringSince;
const _tvSettleBeforeOpen = Duration(seconds: 90);

CdpTarget _toTarget(Map<String, dynamic> t) => CdpTarget(
  type: t['type'] as String,
  url: t['url'] as String,
  webSocketDebuggerUrl: t['webSocketDebuggerUrl'] as String,
);

/// TradingMT5 has no chart tab it may use. Never a reason to restart
/// TradingView or to use another app's tab.
class OwnChartTabMissingException extends CdpException {
  OwnChartTabMissingException(super.message);
}

/// Whether [url] is a TradingView chart page
/// (`https://www.tradingview.com/chart/<layoutId>/...`), of layout
/// [layoutId] when one is set.
bool isOwnChartUrl(String url, String layoutId) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.host.toLowerCase().endsWith('tradingview.com')) return false;
  final segments = uri.pathSegments;
  if (segments.length < 2 || segments[0] != 'chart' || segments[1].isEmpty) return false;
  return layoutId.isEmpty || segments[1] == layoutId;
}

// Shared tab-owner rule (2026-11-04, v1.6.64, per the user): on the free plan
// both apps' tabs are the same saved layout, so the URL can't tell them apart.
// Each app tags its own tab in that tab's sessionStorage; TradingPionex uses
// the identical rule with "tradingpionex".
const tabOwnerKey = 'tvTabOwner';
const mt5TabOwner = 'tradingmt5';
const readTabOwnerScript = 'sessionStorage.getItem("$tabOwnerKey")';

/// Claims a tab for [owner] in ONE evaluate, so two apps can't take the same
/// tab: "mine", "taken:<other>" or "claimed".
String claimTabScript(String owner) =>
    '(function(){var k="$tabOwnerKey",v=sessionStorage.getItem(k);'
    'if(v==="$owner")return "mine";if(v)return "taken:"+v;'
    'sessionStorage.setItem(k,"$owner");return "claimed";})()';

/// Runs [expression] in one tab and returns its value; throws if the tab
/// can't be reached.
typedef TabEvaluator = Future<dynamic> Function(Map<String, dynamic> target, String expression);

/// Opens ONE new chart tab and returns its target once its chart is loaded,
/// or null.
typedef ChartTabOpener = Future<Map<String, dynamic>?> Function();

/// Free plan: at most this many chart tabs; a third closes the oldest.
const maxChartTabs = 2;

/// Picks TradingMT5's tab under the shared tab-owner rule:
/// 1. read every chart tab's tag (read-only) - exactly one "tradingmt5" wins;
/// 2. else claim one untagged tab;
/// 3. else, only with fewer than [maxChartTabs] chart tabs open, [openTab]
///    once and claim that.
/// A tab tagged by anyone else is never used. Returns null when nothing is
/// usable; [log] says why.
Future<Map<String, dynamic>?> selectOwnChartTab({
  required List<Map<String, dynamic>> targets,
  required String layoutId,
  required TabEvaluator evaluate,
  ChartTabOpener? openTab,
  String owner = mt5TabOwner,
  void Function(String message)? log,
}) async {
  bool usable(Object? claim) => claim == 'claimed' || claim == 'mine';
  final chartTabs = [
    for (final t in targets)
      if (t['type'] == 'page' && isOwnChartUrl((t['url'] ?? '').toString(), layoutId)) t,
  ];
  final mine = <Map<String, dynamic>>[];
  final untagged = <Map<String, dynamic>>[];
  final unreadable = <String>[];
  for (final t in chartTabs) {
    try {
      final tag = await evaluate(t, readTabOwnerScript);
      if (tag == owner) {
        mine.add(t);
      } else if (tag == null) {
        untagged.add(t);
      }
    } catch (e) {
      unreadable.add('${t['id']}: $e');
    }
  }
  if (mine.length > 1) {
    log?.call('${mine.length} chart tabs are tagged "$owner" - using none of them');
    return null;
  }
  if (mine.length == 1) return mine.single;
  // A tab that didn't answer may be our own, hung - never claim or open
  // another one on a guess. Thrown as a plain CdpException so the engine's
  // stuck ladder (own-tab reload first) counts it.
  if (unreadable.isNotEmpty) {
    throw CdpException('could not read the owner tag of ${unreadable.join('; ')}');
  }
  for (final t in untagged) {
    try {
      final claim = await evaluate(t, claimTabScript(owner));
      if (usable(claim)) {
        log?.call('claimed chart tab ${t['id']} as "$owner"');
        return t;
      }
      log?.call('tab ${t['id']} was $claim - skipping it');
    } catch (e) {
      log?.call('could not claim tab ${t['id']}: $e');
    }
  }
  if (openTab == null) {
    log?.call('no "$owner" chart tab and none free to claim');
    return null;
  }
  // Every TradingView page counts, tabs still loading included (2026-11-14,
  // TradingPionex's rule) - not only finished chart tabs.
  final tvPages = targets
      .where((t) => t['type'] == 'page' && (t['url'] ?? '').toString().contains('tradingview.com'))
      .length;
  if (tvPages >= maxChartTabs) {
    log?.call(
      'no "$owner" chart tab, none free to claim, and $tvPages TradingView tabs are '
      'already open - not opening another (the free plan allows $maxChartTabs)',
    );
    return null;
  }
  final opened = await openTab();
  if (opened == null) return null;
  try {
    final claim = await evaluate(opened, claimTabScript(owner));
    if (usable(claim)) {
      log?.call('opened and claimed chart tab ${opened['id']} as "$owner"');
      return opened;
    }
    log?.call('the tab this app opened was $claim - not using it');
  } catch (e) {
    log?.call('could not claim the tab this app opened: $e');
  }
  return null;
}

Future<dynamic> _evaluateOnTarget(Map<String, dynamic> target, String expression) async {
  final socket = await WebSocket.connect(target['webSocketDebuggerUrl'] as String)
      .timeout(CoreConstants.cdpRequestTimeout);
  final client = CdpClient(socket);
  try {
    return await client.evaluate(expression);
  } finally {
    client.close();
  }
}

/// Set once this engine process has really opened its one allowed chart
/// tab (TradingView created it). A FAILED attempt does not count (2026-11-08,
/// found live: one HTTP 500 "Could not create new page" at 09:11Z set this
/// for good and left the app with no tab for 5 hours) - it is retried, at
/// most once every [_chartTabRetryEvery].
bool _openedChartTabThisProcess = false;

/// Shared-TradingView lock hooks (tvsync, 2026-11-13), set by the engine:
/// [openTabGate] must return true before a tab is opened (false = TradingPionex
/// holds the lock - skip now, retry later); [openTabDone] runs after.
bool Function(String action)? openTabGate;
void Function()? openTabDone;
DateTime? _lastChartTabOpenFailAt;
const _chartTabRetryEvery = Duration(minutes: 2);

/// Real tab-open attempts TradingView refused in a row (2026-11-08, per the
/// user: "it is okay to restart trading view if it is not responding"). The
/// engine restarts TradingView once this reaches 2; reset by a created tab
/// or [resetChartTabStateAfterRestart].
int chartTabOpenFailuresInARow = 0;

/// Fresh start after the engine restarts TradingView: a new TradingView
/// process may have no tab at all, so this run may open one tab again, at
/// once.
void resetChartTabStateAfterRestart() {
  chartTabOpenFailuresInARow = 0;
  _lastChartTabOpenFailAt = null;
  _openedChartTabThisProcess = false;
}

const _chartReadyProbe = '''(function() {
  try {
    var wv = window.TradingViewApi && window.TradingViewApi._activeChartWidgetWV;
    var widget = wv && wv.value && wv.value();
    return !!(widget && widget._chartWidget && widget._chartWidget.model && widget._chartWidget.model());
  } catch (e) { return false; }
})()''';

/// The ONLY place this app opens anything in TradingView: one new tab on
/// the saved "Unnamed" layout, at most once per engine process (a failed
/// attempt is retried after 2 min), only after TradingView has answered for
/// 90 s, and only with the shared lock (open_tab). Never closes a tab.
Future<Map<String, dynamic>?> _openOneChartTab(
  String host,
  int port,
  String layoutId,
  void Function(String message)? log,
) async {
  if (_openedChartTabThisProcess) {
    log?.call('already opened one chart tab this run - not opening another');
    return null;
  }
  if (layoutId.isEmpty) {
    log?.call('no layout ID configured (config.json cdp.layout_id) - not opening a tab');
    return null;
  }
  final answering = _tvAnsweringSince;
  if (answering == null || DateTime.now().difference(answering) < _tvSettleBeforeOpen) {
    log?.call('TradingView answering for under ${_tvSettleBeforeOpen.inSeconds}s - letting it restore its tabs before opening one');
    return null;
  }
  final lastFail = _lastChartTabOpenFailAt;
  if (lastFail != null && DateTime.now().difference(lastFail) < _chartTabRetryEvery) {
    log?.call('opening a chart tab failed ${DateTime.now().difference(lastFail).inSeconds}s ago - retrying after ${_chartTabRetryEvery.inMinutes} min');
    return null;
  }
  if (openTabGate != null && !openTabGate!('open_tab')) {
    log?.call('TradingPionex holds the TradingView lock - not opening a tab now, retrying later');
    return null;
  }
  try {
    return await _openOneChartTabLocked(host, port, layoutId, log);
  } finally {
    openTabDone?.call();
  }
}

Future<Map<String, dynamic>?> _openOneChartTabLocked(
  String host,
  int port,
  String layoutId,
  void Function(String message)? log,
) async {
  // 2026-11-14, per the user ("do the same method" as TradingPionex):
  // `PUT /json/new` always answers HTTP 500 "Could not create new page" in
  // TradingView Desktop and a scripted element.click() is ignored, so the
  // tab is opened like a user would: a real click on the window's "New tab"
  // button, then on the "Unnamed" layout on the start page. No tab is ever
  // closed, navigated or brought to the front.
  Map<String, dynamic>? fail(String why) {
    _lastChartTabOpenFailAt = DateTime.now();
    chartTabOpenFailuresInARow++;
    log?.call('TV TAB: opening a chart tab failed: $why - will retry in ${_chartTabRetryEvery.inMinutes} min');
    return null;
  }

  try {
    final before = await _fetchJsonList(host, port);
    final beforeIds = {for (final t in before) t['id']};
    final frames = before
        .where((t) => t['type'] == 'page' && (t['url'] ?? '').toString().contains('/app/window/index.html'))
        .toList();
    var clicked = false;
    for (final frame in frames) {
      final point = await _evaluateOnTarget(frame, _newTabButtonExpr);
      if (point is! String) continue;
      await _realClickOn(frame, point);
      clicked = true;
      log?.call('TV TAB: clicked "New tab" in the TradingView window');
      break;
    }
    if (!clicked) return fail('no single "New tab" button found in a TradingView window');

    Map<String, dynamic>? startPage;
    for (var i = 0; i < 15 && startPage == null; i++) {
      await Future<void>.delayed(const Duration(seconds: 1));
      final now = await _fetchJsonList(host, port);
      startPage = now
          .where((t) => t['type'] == 'page' && (t['url'] ?? '').toString().contains('/app/new-tab/index.html'))
          .firstOrNull;
    }
    if (startPage == null) return fail('the new-tab start page did not appear within 15s');

    String? unnamed;
    for (var i = 0; i < 10 && unnamed == null; i++) {
      final point = await _evaluateOnTarget(startPage, _unnamedLayoutExpr);
      if (point is String) {
        unnamed = point;
      } else {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    if (unnamed == null) return fail('no single "Unnamed" layout on the start page');
    await _realClickOn(startPage, unnamed);
    log?.call('TV TAB: clicked the "Unnamed" layout');

    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final now = await _fetchJsonList(host, port);
      for (final t in now) {
        if (beforeIds.contains(t['id']) || t['type'] != 'page') continue;
        if (!isOwnChartUrl((t['url'] ?? '').toString(), layoutId)) continue;
        try {
          if (await _evaluateOnTarget(t, _chartReadyProbe) == true) {
            // TradingView really created it: this run never opens another.
            _openedChartTabThisProcess = true;
            _lastChartTabOpenFailAt = null;
            chartTabOpenFailuresInARow = 0;
            log?.call('TV TAB: opened chart tab ${t['id']} and its chart is ready');
            return t;
          }
        } catch (_) {}
      }
    }
    // A tab may exist but still be loading: it is claimed later, untagged.
    _openedChartTabThisProcess = true;
    log?.call('TV TAB: the new chart tab was not ready within 60s - not using it now');
    return null;
  } catch (e) {
    return fail('$e');
  }
}

const _newTabButtonExpr = '''(function(){var b=[...document.querySelectorAll('button')].filter(function(x){
return (x.getAttribute('aria-label')||x.getAttribute('title')||x.textContent||'').trim()==='New tab';});
if(b.length!==1)return null;var r=b[0].getBoundingClientRect();
return JSON.stringify({x:r.left+r.width/2,y:r.top+r.height/2});})()''';

const _unnamedLayoutExpr = '''(function(){var n="Unnamed";var hits=[];document.querySelectorAll('*').forEach(function(el){
if(el.children.length===0&&(el.textContent||'').trim()===n){var r=el.getBoundingClientRect();
if(r.width>0&&r.height>0)hits.push({x:r.left+r.width/2,y:r.top+r.height/2});}});
return hits.length===1?JSON.stringify(hits[0]):null;})()''';

/// A real mouse click (move, press, release) at [pointJson] {x,y} on [target].
Future<void> _realClickOn(Map<String, dynamic> target, String pointJson) async {
  final p = jsonDecode(pointJson) as Map<String, dynamic>;
  final x = (p['x'] as num).toDouble();
  final y = (p['y'] as num).toDouble();
  final socket = await WebSocket.connect(target['webSocketDebuggerUrl'] as String)
      .timeout(CoreConstants.cdpRequestTimeout);
  final client = CdpClient(socket);
  try {
    await client.send('Input.dispatchMouseEvent', {'type': 'mouseMoved', 'x': x, 'y': y, 'button': 'none'});
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await client.send('Input.dispatchMouseEvent',
        {'type': 'mousePressed', 'x': x, 'y': y, 'button': 'left', 'clickCount': 1});
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await client.send('Input.dispatchMouseEvent',
        {'type': 'mouseReleased', 'x': x, 'y': y, 'button': 'left', 'clickCount': 1});
  } finally {
    client.close();
  }
}

/// Fetches `/json/list` and returns TradingMT5's own chart tab per
/// [selectOwnChartTab]. Throws [OwnChartTabMissingException] when there is
/// none; there is no fallback to any other tab.
Future<CdpTarget> getChartTarget(
  String host,
  int port, {
  required String layoutId,
  void Function(String message)? log,
}) async {
  final targets = await _fetchJsonList(host, port);
  final reasons = <String>[];
  final own = await selectOwnChartTab(
    targets: targets,
    layoutId: layoutId,
    evaluate: _evaluateOnTarget,
    openTab: () => _openOneChartTab(host, port, layoutId, (m) {
      reasons.add(m);
      log?.call(m);
    }),
    log: (m) {
      reasons.add(m);
      log?.call(m);
    },
  );
  if (own == null) {
    throw OwnChartTabMissingException(
      'no usable "$mt5TabOwner" chart tab (${reasons.isEmpty ? 'none found' : reasons.last}) - doing nothing',
    );
  }
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
  void Function(String message)? log,
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
      final target = await getChartTarget(host, port, layoutId: layoutId, log: log);
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
