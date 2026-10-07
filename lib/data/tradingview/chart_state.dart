import 'dart:convert';

import 'cdp_client.dart';

/// The user's two custom Pine scripts — the ONLY signal sources. Never read
/// data from anything else. Ported 1:1 from lib/chart-state.js.
class CustomScript {
  const CustomScript({
    required this.key,
    required this.scriptIdPart,
    required this.legendTitle,
    required this.dataTitle,
  });
  final String key;
  final String scriptIdPart;
  final String legendTitle;
  final String dataTitle;
}

const customScripts = [
  // Per the user (2026-09-13): "instead of using worm_8_26, i want you to
  // use worm_9_26, it is there in my script section" - a genuinely
  // different saved script (confirmed live via CDP inspection: a
  // different scriptIdPart hash, not a rename of the old one), carrying
  // every plot worm_8_26 had, including the dedicated "BUY"/"SELL"
  // plots signals_reader.dart's readBuySellSignals reads from - the only
  // thing this upgrade changed. (Same day, the signal itself briefly
  // detoured through this script's "New Higher High"/"New Lower High"/
  // "New Higher Low"/"New Lower Low" plots instead - fully reverted per
  // the user: "i want to go back to old theory ... buy/sell signals but
  // in worm 9 26 not in worm 8 26" / "no use for hh/hl/ll/lh".)
  CustomScript(
    key: 'MSB',
    scriptIdPart: 'USER;ac8febb9427a44578fd4052af6c17d65',
    legendTitle: 'MSB/OB',
    dataTitle: 'Footprint/VFAS/EMA/HLOTT/MSB/OB/AlphaTrend/ZigZag++',
  ),
  // Per the user (2026-09-16): "instead of using combined indicator, i
  // want you to use spy_9_26, it is there in my script" - same pattern as
  // the worm_8_26 -> worm_9_26 switch above: a different saved script,
  // not a rename. Real scriptIdPart confirmed live 2026-09-16 via the
  // "CUSTOM SCRIPT SOURCES" diagnostic dump (name "RSI & Vol & Stochastic
  // RSI & VAPI", the SAME dataTitle as before - only the underlying
  // script changed, not its display title). CRITICAL follow-up fix, same
  // day: the earlier interim fix (title-fallback in verifyCustomScripts,
  // 'spy_9_26' searchTitle in enforce.dart) only stopped the chart being
  // stripped - it did NOT fix `readSwingOscillatorSignals`, which matches
  // scripts ONLY by this exact scriptIdPart with no fallback. With the
  // stale hash still here, that function could never find the real RSI
  // source, so EVERY signal read failed regardless of wait budget -
  // confirmed live (all 5 tracked pairs stuck, some past 65 consecutive
  // failures, even a fresh 30s budget still failing post-restart). Fixed
  // now with the real hash.
  CustomScript(
    key: 'RSI',
    scriptIdPart: 'USER;f40c0a529f954b648be8f2b530d43d3f',
    legendTitle: 'spy_9_26',
    dataTitle: 'RSI & Vol & Stochastic RSI & VAPI',
  ),
];

/// The Supertrend Plus technique's entry/exit signal source (2026-10-06,
/// second decision technique). Kept OUT of [customScripts] since that list's
/// own doc comment says "the ONLY signal sources" for the original Signal
/// Flip technique — this is a parallel, separate source for the other
/// technique, not a third member of that set. Same scriptIdPart as
/// enforce.dart's private `_supertrendScript` (verified live via CDP against
/// the user's own "My Scripts" library, 2026-10-06) — that one drives the
/// "search and attach" UI automation, this one drives signal reading, same
/// parallel-lists pattern already used for worm_9_26/spy_9_26.
const supertrendPlusScript = CustomScript(
  key: 'SUPERTREND',
  scriptIdPart: 'USER;de83e70197704202ae530fd979d38aae',
  legendTitle: 'Supertrend Plus',
  dataTitle: 'Supertrend Plus',
);

class ChartState {
  const ChartState({this.symbol, this.resolution, this.error});
  final String? symbol;
  final String? resolution;
  final String? error;

  factory ChartState.fromJson(Map<String, dynamic>? json) => ChartState(
    symbol: json?['symbol'] as String?,
    resolution: json?['resolution'] as String?,
    error: json?['error'] as String?,
  );
}

const _chartStateExpr = '''(function() {
  try {
    var wv = window.TradingViewApi && window.TradingViewApi._activeChartWidgetWV;
    if (!wv) return { error: 'TradingViewApi not found' };
    var chart = wv.value();
    if (!chart) return { error: 'chart widget not found' };
    var symbol = chart.symbol ? chart.symbol() : '';
    var resolution = chart.resolution ? chart.resolution() : '';
    return { symbol: symbol, resolution: resolution, url: location.href };
  } catch (e) {
    return { error: String(e && e.message || e) };
  }
})()''';

Future<ChartState> getChartState(CdpClient cdp) async {
  final result = await cdp.evaluate(_chartStateExpr);
  return ChartState.fromJson(result as Map<String, dynamic>?);
}

class VerifyResult {
  const VerifyResult({
    required this.ok,
    this.error,
    this.msbPresent = false,
    this.rsiPresent = false,
    this.rawSources = const [],
  });
  final bool ok;
  final String? error;
  final bool msbPresent;
  final bool rsiPresent;
  // Temporary (2026-09-16, per the user - "instead of using combined
  // indicator, i want you to use spy_9_26"): every loaded script's real
  // scriptIdPart + name, so the caller can log it once to find spy_9_26's
  // actual hash - same live-discovery step the worm_8_26 -> worm_9_26
  // switch needed on 2026-09-13. Remove once that hash is confirmed and
  // hardcoded into `customScripts` below.
  final List<Map<String, dynamic>> rawSources;
}

const _verifyScriptsExpr = '''(function() {
  var wv = window.TradingViewApi && window.TradingViewApi._activeChartWidgetWV;
  if (!wv) return { error: 'TradingViewApi not found' };
  var chart = wv.value();
  if (!chart) return { error: 'chart widget not found' };
  var legend = [];
  var items = document.querySelectorAll('[data-qa-id=legend-source-item]');
  for (var i = 0; i < items.length; i++) {
    var el = items[i];
    var t = el.querySelector('.title-quatTGAC');
    legend.push({ entity: el.getAttribute('data-entity-id'), title: t ? t.textContent.trim() : '' });
  }
  var sources = [];
  try {
    var all = chart._chartWidget.model().model().dataSources();
    for (var j = 0; j < all.length; j++) {
      var s = all[j];
      var part = '';
      var name = '';
      try { var m = s.metaInfo(); part = m ? (m.scriptIdPart || '') : ''; name = m ? (m.description || m.shortDescription || '') : ''; } catch (e) {}
      sources.push({ scriptIdPart: part, name: name });
    }
  } catch (e) {}
  return { legend: legend, sources: sources };
})()''';

/// Checks both custom scripts are present via legend + dataSources. MSB
/// counts present only via its real loaded title/scriptIdPart, NEVER the
/// stuck-stub title ("EMA & HLOTT & MSB/OB").
Future<VerifyResult> verifyCustomScripts(CdpClient cdp) async {
  final state = await cdp.evaluate(_verifyScriptsExpr) as Map<String, dynamic>?;
  if (state?['error'] != null)
    return VerifyResult(ok: false, error: state!['error'] as String);

  final legend = ((state?['legend'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final sources = ((state?['sources'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final titles = legend.map((l) => (l['title'] ?? '').toString()).toList();
  final sourceIds = sources
      .map((s) => (s['scriptIdPart'] ?? '').toString())
      .toList();
  final sourceNames = sources.map((s) => (s['name'] ?? '').toString()).toList();

  final msb =
      sourceIds.contains(customScripts[0].scriptIdPart) ||
      sourceNames.any((n) => n.contains('Footprint')) ||
      titles.any((t) => t.contains('Footprint'));
  // URGENT fix 2026-09-16 - see the doc comment on customScripts[1]:
  // added 'spy_9_26' (the real, currently-in-use script) as a title
  // fallback since the hardcoded scriptIdPart above still holds the OLD
  // Combined_Indicators hash. 'Combined_Indicators' kept too, harmless -
  // matches nothing now but costs nothing to leave.
  final rsi =
      sourceIds.contains(customScripts[1].scriptIdPart) ||
      titles.any(
        (t) => t.contains('Combined_Indicators') || t.contains('spy_9_26'),
      ) ||
      sourceNames.any((n) => n.contains('spy_9_26'));

  return VerifyResult(
    ok: msb && rsi,
    msbPresent: msb,
    rsiPresent: rsi,
    rawSources: sources,
  );
}

class SetChartViewResult {
  const SetChartViewResult({required this.ok, this.error, this.state});
  final bool ok;
  final String? error;
  final ChartState? state;
}

/// Letter resolutions ('D','W','M') land internally as '1D'/'1W'/'1M' —
/// normalize both sides before comparing, or a same-value switch is falsely
/// treated as "changed" (or vice versa) and either spuriously reloads or
/// never confirms.
String _normalizeResolution(String r) {
  final upper = r.toUpperCase();
  final match = RegExp(r'^1?([DWM])$').firstMatch(upper);
  return match != null ? match.group(1)! : upper;
}

/// Strips exchange prefix ("BINANCE:"), quote suffix ("USDT"), and any
/// ".PERP"/"_" segment - same convention as engine_service.dart's
/// `_baseOf` - so a bare request ("ETHUSDT") correctly matches the chart's
/// own fully-resolved report ("BINANCE:ETHUSDT") instead of only ever
/// matching an exact string that was never going to come back that way.
String _tickerBase(String s) {
  var v = s.trim().toUpperCase();
  if (v.contains(':')) v = v.split(':').last;
  if (v.contains('/')) v = v.split('/').first;
  if (v.contains('_')) v = v.split('_').first;
  return v.replaceAll('USDT', '').replaceAll('.PERP', '');
}

bool _sameBase(String a, String b) => _tickerBase(a) == _tickerBase(b);

/// Switches the chart to [symbol]/[resolution] via the widget API, then waits
/// until the chart actually reports the requested values. Only calls
/// setSymbol/setResolution for values that actually changed — a redundant
/// setResolution call triggers a spurious reload that never reports back.
/// Ported 1:1 from lib/chart-state.js `setChartView`.
Future<SetChartViewResult> setChartView(
  CdpClient cdp,
  String? symbol,
  String? resolution, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  ChartState? current;
  try {
    current = await getChartState(cdp);
  } catch (_) {}

  final expr =
      '''(function() {
    var wv = window.TradingViewApi && window.TradingViewApi._activeChartWidgetWV;
    if (!wv) return { error: 'TradingViewApi not found' };
    var chart = wv.value();
    if (!chart) return { error: 'chart widget not found' };
    var out = {};
    var curSym = ${jsonEncode(current?.symbol)};
    var curRes = ${jsonEncode(current?.resolution)};
    var wantSym = ${jsonEncode(symbol)};
    var wantRes = ${jsonEncode(resolution)};
    var symSame = curSym && wantSym && String(curSym) === String(wantSym);
    var resSame = curRes && wantRes && String(curRes).toUpperCase() === String(wantRes).toUpperCase();
    if (!wantSym) symSame = true;
    if (!wantRes) resSame = true;
    if (!symSame && typeof chart.setSymbol === 'function') {
      try { chart.setSymbol(wantSym); out.symbolSet = true; } catch (e) { out.symbolErr = String(e && e.message || e); }
    }
    if (!resSame && typeof chart.setResolution === 'function') {
      try { chart.setResolution(wantRes); out.resolutionSet = true; } catch (e) { out.resolutionErr = String(e && e.message || e); }
    }
    return out;
  })()''';
  final res = await cdp.evaluate(expr) as Map<String, dynamic>?;
  if (res?['error'] != null)
    return SetChartViewResult(ok: false, error: res!['error'] as String);
  final changedAnything =
      res?['symbolSet'] == true ||
      res?['resolutionSet'] == true ||
      res?['symbolErr'] != null ||
      res?['resolutionErr'] != null;
  if (!changedAnything) {
    return SetChartViewResult(ok: true, state: current);
  }

  final deadline = DateTime.now().add(timeout);
  ChartState? state;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    try {
      state = await getChartState(cdp);
    } catch (_) {
      state = null;
    }
    if (state?.symbol == null) continue;
    // Per the user (2026-09-06): a request sent without an exchange
    // prefix (e.g. "ETHUSDT") is deliberately left that way so
    // TradingView's own chart.setSymbol() resolves the exchange itself,
    // exactly like typing it into TradingView's search box - confirmed
    // live via CDP that this genuinely works. But the CHART then reports
    // back the fully-resolved symbol (e.g. "BINANCE:ETHUSDT"), which
    // never equals the bare string that was requested - comparing base
    // tickers instead of exact strings is what lets that resolution
    // still count as success instead of timing out for 45s and failing.
    final symOk = symbol == null || _sameBase(state!.symbol!, symbol);
    final resOk =
        resolution == null ||
        _normalizeResolution(state!.resolution ?? '') ==
            _normalizeResolution(resolution);
    if (symOk && resOk) return SetChartViewResult(ok: true, state: state);
  }
  return SetChartViewResult(
    ok: false,
    error: 'timeout waiting for $symbol $resolution',
    state: state,
  );
}

/// Lists every TradingView page target currently visible to CDP (not just
/// the first match) — a diagnostic helper, distinct from getChartTarget()
/// which is used on the hot path and only needs the one chart page.
Future<List<CdpTarget>> getActiveCharts(String host, int port) =>
    listTradingViewTargets(host, port);
