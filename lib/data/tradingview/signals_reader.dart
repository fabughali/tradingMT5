import 'dart:convert';

import '../models/range_result.dart';
import '../models/signal.dart';
import 'cdp_client.dart';
import 'chart_state.dart' show customScripts;

/// Strict, scriptIdPart-filtered reads from only the two custom scripts —
/// ported 1:1 from lib/signals.js. Every reader here evaluates a JS
/// expression that walks TradingView's internal chart model
/// (`dataSources()` -> `_graphics._primitivesCollection`) directly, exactly
/// as the original did; only the transport (CdpClient.evaluate) changed.

double? _round(num? v) => v == null ? null : (v * 1e8).round() / 1e8;

String _buildSourceReaderExpr(String scriptPart, List<String> collections) {
  final keys = jsonEncode(collections);
  return '''(function() {
    var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
    var sources = chart.model().model().dataSources();
    var result = { found: false, meta: null, collections: {} };
    var wantKeys = $keys;
    for (var si = 0; si < sources.length; si++) {
      var s = sources[si];
      if (!s.metaInfo) continue;
      var part = '';
      var name = '';
      try {
        var m = s.metaInfo();
        part = m.scriptIdPart || '';
        name = m.description || m.shortDescription || '';
      } catch (e) {}
      if (part !== ${jsonEncode(scriptPart)}) continue;
      result.found = true;
      result.meta = { name: name, scriptIdPart: part };
      var g = s._graphics;
      if (!g || !g._primitivesCollection) continue;
      var pc = g._primitivesCollection;
      for (var ci = 0; ci < wantKeys.length; ci++) {
        var ck = wantKeys[ci];
        var items = [];
        try {
          var outer = pc[ck];
          if (outer && typeof outer.forEach === 'function') {
            outer.forEach(function(mapVal, mapKey) {
              if (!mapVal) return;
              if (mapVal._primitivesDataById && mapVal._primitivesDataById.size > 0) {
                mapVal._primitivesDataById.forEach(function(v, id) { items.push({ mapKey: mapKey, id: id, raw: v }); });
              } else if (typeof mapVal.get === 'function') {
                try {
                  var inner = mapVal.get(false);
                  if (inner && inner._primitivesDataById) {
                    inner._primitivesDataById.forEach(function(v, id) { items.push({ mapKey: mapKey, id: id, raw: v }); });
                  }
                } catch (e) {}
              }
            });
          }
        } catch (e) {}
        result.collections[ck] = items;
      }
    }
    return result;
  })()''';
}

class LabelReading {
  const LabelReading({required this.text, required this.price});
  final String text;
  final double? price;
}

Future<List<LabelReading>> readLabels(CdpClient cdp, String scriptPart) async {
  final raw =
      await cdp.evaluate(_buildSourceReaderExpr(scriptPart, ['dwglabels']))
          as Map<String, dynamic>?;
  if (raw?['found'] != true) return const [];
  final items = ((raw?['collections']?['dwglabels'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  return items
      .map((it) {
        final v = (it['raw'] as Map?)?.cast<String, dynamic>() ?? const {};
        return LabelReading(
          text: (v['t'] ?? '').toString(),
          price: _round(v['y'] as num?),
        );
      })
      .where((l) => l.text.isNotEmpty || l.price != null)
      .toList();
}

class BoxReading {
  const BoxReading({required this.high, required this.low});
  final double high;
  final double low;
}

Future<List<BoxReading>> readBoxes(CdpClient cdp, String scriptPart) async {
  final raw =
      await cdp.evaluate(_buildSourceReaderExpr(scriptPart, ['dwgboxes']))
          as Map<String, dynamic>?;
  if (raw?['found'] != true) return const [];
  final items = ((raw?['collections']?['dwgboxes'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final out = <BoxReading>[];
  for (final it in items) {
    final v = (it['raw'] as Map?)?.cast<String, dynamic>() ?? const {};
    final y1 = v['y1'] as num?, y2 = v['y2'] as num?;
    if (y1 == null || y2 == null) continue;
    out.add(
      BoxReading(
        high: _round(y1 > y2 ? y1 : y2)!,
        low: _round(y1 < y2 ? y1 : y2)!,
      ),
    );
  }
  return out;
}

Future<List<ZigzagSegment>> readLines(CdpClient cdp, String scriptPart) async {
  final raw =
      await cdp.evaluate(_buildSourceReaderExpr(scriptPart, ['dwglines']))
          as Map<String, dynamic>?;
  if (raw?['found'] != true) return const [];
  final items = ((raw?['collections']?['dwglines'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final out = <ZigzagSegment>[];
  for (final it in items) {
    final v = (it['raw'] as Map?)?.cast<String, dynamic>() ?? const {};
    final y1 = v['y1'] as num?;
    if (y1 == null) continue;
    final y2 = (v['y2'] as num?) ?? y1;
    out.add(
      ZigzagSegment(
        x1: (v['x1'] as num?)?.toDouble() ?? 0,
        y1: y1.toDouble(),
        x2: (v['x2'] as num?)?.toDouble() ?? 0,
        y2: y2.toDouble(),
        horizontal: y1 == y2,
      ),
    );
  }
  return out;
}

class ParsedTable {
  const ParsedTable({required this.tableId, required this.rows});
  final int tableId;
  final List<String> rows;
}

Future<List<ParsedTable>> readTables(CdpClient cdp, String scriptPart) async {
  final raw =
      await cdp.evaluate(_buildSourceReaderExpr(scriptPart, ['dwgtablecells']))
          as Map<String, dynamic>?;
  if (raw?['found'] != true) return const [];
  final cells = ((raw?['collections']?['dwgtablecells'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final tables = <int, Map<int, Map<int, String>>>{};
  for (final it in cells) {
    final v = (it['raw'] as Map?)?.cast<String, dynamic>() ?? const {};
    final tid = (v['tid'] as num?)?.toInt() ?? 0;
    final row = (v['row'] as num?)?.toInt() ?? 0;
    final col = (v['col'] as num?)?.toInt() ?? 0;
    (tables[tid] ??= {})[row] ??= {};
    tables[tid]![row]![col] = (v['t'] ?? '').toString();
  }
  final out = <ParsedTable>[];
  for (final entry in tables.entries) {
    final rowNums = entry.value.keys.toList()..sort();
    final lines = <String>[];
    for (final rn in rowNums) {
      final cols = entry.value[rn]!;
      final colNums = cols.keys.toList()..sort();
      final line = colNums
          .map((cn) => cols[cn]!)
          .where((s) => s.isNotEmpty)
          .join(' | ');
      if (line.isNotEmpty) lines.add(line);
    }
    out.add(ParsedTable(tableId: entry.key, rows: lines));
  }
  return out;
}

Future<Map<String, String>> readStudyValues(
  CdpClient cdp,
  String scriptPart,
) async {
  final expr =
      '''(function() {
    var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
    var sources = chart.model().model().dataSources();
    for (var si = 0; si < sources.length; si++) {
      var s = sources[si];
      if (!s.metaInfo) continue;
      var part = '';
      try { var m = s.metaInfo(); part = m.scriptIdPart || ''; } catch (e) {}
      if (part !== ${jsonEncode(scriptPart)}) continue;
      var values = {};
      try {
        var dwv = s.dataWindowView();
        if (dwv) {
          var items = dwv.items();
          if (items) {
            for (var i = 0; i < items.length; i++) {
              var item = items[i];
              if (item._value && item._value !== '∅' && item._title) values[item._title] = item._value;
            }
          }
        }
      } catch (e) {}
      return { found: true, values: values };
    }
    return { found: false, values: {} };
  })()''';
  final raw = await cdp.evaluate(expr) as Map<String, dynamic>?;
  return ((raw?['values'] as Map?) ?? const {}).map(
    (k, v) => MapEntry(k.toString(), v.toString()),
  );
}

/// Reads the worm/MSB script's own dedicated "BUY"/"SELL" plotshape()
/// history - per the user (2026-09-13, reverting the same-day HH/LH/HL/LL
/// swing-structure detour): "i want to go back to old theory ... buy/sell
/// signals but in worm 9 26 not in worm 8 26" / "no use for hh/hl/ll/lh".
/// This one signal now drives both opening AND closing a grid again
/// (opposite-signal close, same as originally) - only the underlying
/// script stays upgraded to worm_9_26. Resolves both columns ("BUY"/
/// "SELL") by PLOT TITLE (never by position — Pine's internal plot
/// numbering doesn't match source-code order) - confirmed live via CDP
/// that worm_9_26's metaInfo().styles genuinely still carries these two
/// plots (plot_14/plot_15) alongside the swing-structure ones the
/// now-reverted detour used, so no separate script/indicator was ever
/// needed. Returns `latestBarTime` — the newest bar's open time, the
/// anchor the engine's candle gate compares against.
Future<BuySellCheck> readBuySellSignals(
  CdpClient cdp,
  String symbol,
  String scriptPart,
) async {
  final expr =
      '''(function() {
    try {
      var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
      var sources = chart.model().model().dataSources();
      for (var si = 0; si < sources.length; si++) {
        var s = sources[si];
        if (!s.metaInfo) continue;
        var part = '';
        try { var m0 = s.metaInfo(); part = m0.scriptIdPart || ''; } catch (e) {}
        if (part !== ${jsonEncode(scriptPart)}) continue;

        var meta = s.metaInfo();
        var styles = meta.styles || {};
        var buyPlotId = null, sellPlotId = null;
        for (var sk in styles) {
          var se = styles[sk];
          if (!se) continue;
          if (se.title === 'BUY') buyPlotId = sk;
          else if (se.title === 'SELL') sellPlotId = sk;
        }
        if (!buyPlotId || !sellPlotId) {
          return { found: true, error: 'BUY/SELL plot titles not found in metaInfo().styles' };
        }

        function colOf(plotId) {
          var num = parseInt((String(plotId).match(/(\\d+)\$/) || [])[1], 10);
          return String(num + 1);
        }
        var buyCol = colOf(buyPlotId), sellCol = colOf(sellPlotId);

        var items = (s._data && s._data._items) ? s._data._items : null;
        if (!items) return { found: true, error: 'no _data._items on source' };

        var signals = [];
        var latestBarTime = 0;
        var isNum = function (v) { return typeof v === 'number' && !isNaN(v) && v !== 0; };
        var total = items.length !== undefined ? items.length : Object.keys(items).length;
        for (var r = 0; r < total; r++) {
          var item = items[r];
          if (!item) continue;
          var row = (item.value || item);
          var time = row['0'] !== undefined ? row['0'] : (Array.isArray(row) ? row[0] : null);
          if (typeof time === 'number' && time > latestBarTime) latestBarTime = time;
          if (isNum(row[buyCol])) signals.push({ time: time, type: 'BUY', value: row[buyCol] });
          if (isNum(row[sellCol])) signals.push({ time: time, type: 'SELL', value: row[sellCol] });
        }
        signals.sort(function (a, b) { return (a.time || 0) - (b.time || 0); });
        return { found: true, signals: signals, latestBarTime: latestBarTime || null };
      }
      return { found: false };
    } catch (e) {
      return { found: false, error: String(e && e.message || e) };
    }
  })()''';
  final raw = await cdp.evaluate(expr) as Map<String, dynamic>?;
  final signals = ((raw?['signals'] as List?) ?? const [])
      .cast<Map<String, dynamic>>()
      .map(Signal.fromJson)
      .toList();
  return BuySellCheck(
    symbol: symbol,
    signals: signals,
    latestBarTime: (raw?['latestBarTime'] as num?)?.toInt(),
  );
}

/// Technique (rewritten 2026-09-29, per the user: "change app decision...
/// remove old decision detection. dont keep in code neither in PRD" —
/// replaces the old two-indicator HH/LL + spy_9_26 RSI-zone confirmation
/// entirely). worm_9_26 alone now supplies every decision, off its own four
/// tag plots on a single bar: "New Higher High" (HH), "New Lower Low" (LL),
/// and its own separate "BUY"/"SELL" plotshape pair — no zone/RSI reading
/// at all any more. spy_9_26 still has to be attached (checked by
/// [areIndicatorsPresent]/[enforceCustomScripts] before any pair is ever
/// scanned, per the user: "app need to check it two indicators are open
/// before doing any pair checkup") but its data is no longer read here.
///
/// A tag's own implied direction: HH and SELL both mean short/sell; LL and
/// BUY both mean long/buy. What the engine DOES with a newly confirmed tag
/// depends only on whether it agrees or disagrees with any position already
/// running — every tag type is treated identically (simplified 2026-09-29,
/// per the user: "no delete this .... i want to do action immediatly
/// according to signal ... signal appears > 1 million reading > action" /
/// "no waitng for new signal" — removes an earlier HH/LL "close only, wait
/// for a new tag" exception entirely). See the state machine in
/// `EngineService._checkOneSymbol`:
/// - No position running: open in the tag's own direction.
/// - Position running, tag agrees with its direction: ignore.
/// - Position running, tag disagrees: close AND immediately reopen in the
///   tag's (opposite) direction, regardless of tag type — the "1 million
///   reading" is the triple-read confirmation itself, not a cooldown after
///   it; once confirmed, the action is immediate.
///
/// Returns the exact same [BuySellCheck] shape used before so every
/// downstream consumer (`_checkOneSymbol`, the candle-gate `latestBarTime`)
/// keeps working unchanged; only the signal SOURCE and shape of [Signal]
/// itself differ (see lib/data/models/signal.dart).
///
/// [relaxed] is kept as an unused parameter only so existing call sites
/// don't need to change — see its history in prior revisions of this file.
Future<BuySellCheck> readSwingOscillatorSignals(
  CdpClient cdp,
  String symbol,
  String msbScriptPart, {
  bool relaxed = false,
  void Function(String message)? onDebugError,
}) async {
  final expr =
      '''(function() {
    try {
      var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
      var sources = chart.model().model().dataSources();
      var msbSrc = null;
      for (var si = 0; si < sources.length; si++) {
        var s = sources[si];
        if (!s.metaInfo) continue;
        var part = '';
        try { part = s.metaInfo().scriptIdPart || ''; } catch (e) {}
        if (part === ${jsonEncode(msbScriptPart)}) { msbSrc = s; break; }
      }
      if (!msbSrc) return { found: false, error: 'worm_9_26 not found' };

      function colOf(plotId) {
        var num = parseInt((String(plotId).match(/(\\d+)\$/) || [])[1], 10);
        return num + 1;
      }
      function findCol(src, title) {
        var meta = src.metaInfo();
        var styles = meta.styles || {};
        for (var sk in styles) {
          var se = styles[sk];
          if (se && se.title === title) return colOf(sk);
        }
        return null;
      }

      var hhCol = findCol(msbSrc, 'New Higher High');
      var llCol = findCol(msbSrc, 'New Lower Low');
      var buyCol = findCol(msbSrc, 'BUY');
      var sellCol = findCol(msbSrc, 'SELL');
      if (hhCol == null || llCol == null || buyCol == null || sellCol == null) {
        var msbTitles = [];
        try {
          var msbStyles = msbSrc.metaInfo().styles || {};
          for (var msk in msbStyles) { msbTitles.push(msbStyles[msk] && msbStyles[msk].title); }
        } catch (e) {}
        return { found: true, error: 'plot columns not found (hhCol=' + hhCol + ' llCol=' + llCol + ' buyCol=' + buyCol + ' sellCol=' + sellCol + ') - worm_9_26 plot titles available: ' + JSON.stringify(msbTitles) };
      }

      function rowsOf(s) {
        var items = (s._data && s._data._items) ? s._data._items : null;
        var out = [];
        if (!items) return out;
        var total = items.length !== undefined ? items.length : Object.keys(items).length;
        for (var r = 0; r < total; r++) {
          var item = items[r];
          if (!item) continue;
          out.push(item.value || item);
        }
        return out;
      }

      var isNum = function (v) { return typeof v === 'number' && !isNaN(v) && v !== 0; };
      var latestBarTime = 0;
      var bars = [];
      var msbRows = rowsOf(msbSrc);
      for (var r = 0; r < msbRows.length; r++) {
        var row = msbRows[r];
        var t = row[0];
        if (typeof t !== 'number') continue;
        if (t > latestBarTime) latestBarTime = t;
        bars.push({
          time: t,
          hh: isNum(row[hhCol]),
          ll: isNum(row[llCol]),
          buy: isNum(row[buyCol]),
          sell: isNum(row[sellCol])
        });
      }
      bars.sort(function (a, b) { return a.time - b.time; });

      // One [Signal] per raw tag present on a bar - pushed in a fixed
      // HH/LL/BUY/SELL order so two tags sharing the exact same bar time
      // resolve deterministically (see [BuySellCheck.latest]'s doc).
      var signals = [];
      for (var i = 0; i < bars.length; i++) {
        var bar = bars[i];
        if (bar.hh) signals.push({ time: bar.time, tag: 'HH' });
        if (bar.ll) signals.push({ time: bar.time, tag: 'LL' });
        if (bar.buy) signals.push({ time: bar.time, tag: 'BUY' });
        if (bar.sell) signals.push({ time: bar.time, tag: 'SELL' });
      }
      signals.sort(function (a, b) { return (a.time || 0) - (b.time || 0); });
      return { found: true, signals: signals, latestBarTime: latestBarTime || null };
    } catch (e) {
      return { found: false, error: String(e && e.message || e) };
    }
  })()''';
  final raw = await cdp.evaluate(expr) as Map<String, dynamic>?;
  if (raw?['error'] != null) {
    onDebugError?.call(raw!['error'].toString());
  }
  final signals = ((raw?['signals'] as List?) ?? const [])
      .cast<Map<String, dynamic>>()
      .map(Signal.fromJson)
      .toList();
  return BuySellCheck(
    symbol: symbol,
    signals: signals,
    latestBarTime: (raw?['latestBarTime'] as num?)?.toInt(),
  );
}

/// Reads Supertrend Plus's own "Buy"/"Sell" plots (2026-10-06, per the
/// user's second decision technique) - confirmed live against real history
/// that these two specific plots (title-matched exactly, mixed case -
/// NOT the all-caps 'BUY'/'SELL' worm_9_26 uses) fire as sparse, strictly
/// alternating events (never two of the same side in a row), unlike the
/// indicator's OTHER "SuperTrend Buy"/"SuperTrend Sell" plots, which are
/// continuous true-every-bar trend flags, not discrete entry signals -
/// deliberately NOT read here. Reuses [Signal]/[SignalTag] unchanged - this
/// technique only ever produces buy/sell, never hh/ll, same tag space, no
/// new model needed.
Future<BuySellCheck> readSupertrendSignals(
  CdpClient cdp,
  String symbol,
  String scriptIdPart, {
  void Function(String message)? onDebugError,
}) async {
  final expr =
      '''(function() {
    try {
      var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
      var sources = chart.model().model().dataSources();
      var src = null;
      for (var si = 0; si < sources.length; si++) {
        var s = sources[si];
        var part = '';
        try { part = s.metaInfo().scriptIdPart || ''; } catch (e) {}
        if (part === ${jsonEncode(scriptIdPart)}) { src = s; break; }
      }
      if (!src) return { found: false, error: 'Supertrend Plus not found' };

      function colOf(plotId) {
        var num = parseInt((String(plotId).match(/(\\d+)\$/) || [])[1], 10);
        return num + 1;
      }
      function findCol(title) {
        var meta = src.metaInfo();
        var styles = meta.styles || {};
        for (var sk in styles) {
          var se = styles[sk];
          if (se && se.title === title) return colOf(sk);
        }
        return null;
      }

      var buyCol = findCol('Buy');
      var sellCol = findCol('Sell');
      if (buyCol == null || sellCol == null) {
        return { found: true, error: 'Buy/Sell plot columns not found (buyCol=' + buyCol + ' sellCol=' + sellCol + ')' };
      }

      var items = (src._data && src._data._items) ? src._data._items : null;
      if (!items) return { found: true, error: 'no _data._items on source' };

      var isNum = function (v) { return typeof v === 'number' && !isNaN(v) && v !== 0; };
      var total = items.length !== undefined ? items.length : Object.keys(items).length;
      var signals = [];
      var latestBarTime = 0;
      for (var r = 0; r < total; r++) {
        var item = items[r];
        if (!item) continue;
        var row = item.value || item;
        var t = row[0];
        if (typeof t !== 'number') continue;
        if (t > latestBarTime) latestBarTime = t;
        if (isNum(row[buyCol])) signals.push({ time: t, tag: 'BUY' });
        if (isNum(row[sellCol])) signals.push({ time: t, tag: 'SELL' });
      }
      signals.sort(function (a, b) { return (a.time || 0) - (b.time || 0); });
      return { found: true, signals: signals, latestBarTime: latestBarTime || null };
    } catch (e) {
      return { found: false, error: String(e && e.message || e) };
    }
  })()''';
  final raw = await cdp.evaluate(expr) as Map<String, dynamic>?;
  if (raw?['error'] != null) {
    onDebugError?.call(raw!['error'].toString());
  }
  final signals = ((raw?['signals'] as List?) ?? const [])
      .cast<Map<String, dynamic>>()
      .map(Signal.fromJson)
      .toList();
  return BuySellCheck(
    symbol: symbol,
    signals: signals,
    latestBarTime: (raw?['latestBarTime'] as num?)?.toInt(),
  );
}

class MsbReading {
  const MsbReading({
    required this.labels,
    required this.boxes,
    required this.lines,
    required this.tables,
  });
  final List<LabelReading> labels;
  final List<BoxReading> boxes;
  final List<ZigzagSegment> lines;
  final List<ParsedTable> tables;
}

class RsiReading {
  const RsiReading({required this.values});
  final Map<String, String> values;
}

class CustomSignalsReading {
  const CustomSignalsReading({required this.msb, required this.rsi});
  final MsbReading msb;
  final RsiReading rsi;
}

/// Reads ALL signal data from ONLY the two custom scripts.
Future<CustomSignalsReading> readCustomSignals(CdpClient cdp) async {
  final msbPart = customScripts[0].scriptIdPart;
  final rsiPart = customScripts[1].scriptIdPart;
  final msb = MsbReading(
    labels: await readLabels(cdp, msbPart),
    boxes: await readBoxes(cdp, msbPart),
    lines: await readLines(cdp, msbPart),
    tables: await readTables(cdp, msbPart),
  );
  final rsi = RsiReading(values: await readStudyValues(cdp, rsiPart));
  return CustomSignalsReading(msb: msb, rsi: rsi);
}
