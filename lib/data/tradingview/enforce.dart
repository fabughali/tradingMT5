import 'dart:convert';

import 'cdp_client.dart';

/// Keeps exactly the two custom scripts attached and dialogs dismissed —
/// ported 1:1 from lib/enforce.js. This automation is the hard-won result of
/// real live debugging (see PRD §4.4 "Critical gotchas"): the legend row's
/// bounding box spans almost the full chart pane (mostly blank canvas), so a
/// naive hover-and-click on it never arms anything; the trash button is
/// ALWAYS present in the DOM (TradingView fades it via opacity/pointer-events,
/// not display:none) so `offsetParent` alone is a false positive. The fix:
/// dispatch a REAL mouse event onto the indicator NAME text specifically,
/// wait for React to arm the trash button, re-query it, gate on computed
/// opacity>0 and pointer-events!=='none', confirm via elementFromPoint that
/// nothing covers it, then click for real. NEVER call `s.destroy()` on a
/// study dataSource — it corrupts metaInfo until a full TradingView restart.

class EnforceScript {
  const EnforceScript({
    required this.key,
    required this.searchTitle,
    required this.scriptIdPart,
  });
  final String key;
  final String searchTitle;
  final String scriptIdPart;
}

const _enforceScripts = [
  // URGENT fix 2026-09-16, per the user ("instead of using combined
  // indicator, i want you to use spy_9_26" then, live: "hangup and not
  // doing anything in trading view"): searching "My Scripts" by the OLD
  // long title found nothing (the script saved under that name is gone),
  // so every enforcement pass stripped the chart bare and then failed to
  // re-add anything, forever. Switched to searching by the short name
  // directly, same as worm_9_26 below already does.
  EnforceScript(
    key: 'RSI',
    searchTitle: 'spy_9_26',
    scriptIdPart: 'USER;f40c0a529f954b648be8f2b530d43d3f',
  ),
  // 2026-09-13, per the user: switched from worm_8_26 to worm_9_26 (a
  // genuinely different saved script - confirmed live via CDP, different
  // scriptIdPart). Also corrects a stale comment: confirmed live that the
  // "My scripts" dialog list actually matches by the script's SHORT title
  // ('worm_9_26') directly, not its long descriptive title - the opposite
  // of what this comment used to claim for worm_8_26.
  EnforceScript(
    key: 'MSB',
    searchTitle: 'worm_9_26',
    scriptIdPart: 'USER;ac8febb9427a44578fd4052af6c17d65',
  ),
];

Future<bool> waitForChartApiReady(
  CdpClient cdp, {
  // Lowered from 60s, 2026-10-05, per the user ("fix the bug so the engine
  // will never stuck for 5 min") — this single poll-wait, called twice in a
  // row in the worst case (once directly from _ensureCdpUp, once again
  // inside enforceCustomScripts), was a big share of that stall. The chart
  // widget normally initializes in a few seconds; 20s is still generous.
  Duration timeout = const Duration(seconds: 20),
}) async {
  const probeExpr = '''(function() {
    try {
      var wv = window.TradingViewApi && window.TradingViewApi._activeChartWidgetWV;
      var widget = wv && wv.value && wv.value();
      return !!(widget && widget._chartWidget && widget._chartWidget.model && widget._chartWidget.model());
    } catch (e) { return false; }
  })()''';
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    bool ready = false;
    try {
      ready =
          await cdp
                  .evaluate(probeExpr)
                  .timeout(const Duration(seconds: 3), onTimeout: () => false)
              as bool? ??
          false;
    } catch (_) {}
    if (ready) return true;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return false;
}

class _EnforceChartState {
  const _EnforceChartState({
    required this.sourceScriptIdParts,
    required this.legendTitles,
  });
  final List<String> sourceScriptIdParts;
  final List<String> legendTitles;
}

const _getEnforceStateExpr = '''(function() {
  var wv = window.TradingViewApi._activeChartWidgetWV;
  var widget = wv.value();
  var out = { sources: [], legend: [] };
  var sources = widget._chartWidget.model().model().dataSources();
  for (var i = 0; i < sources.length; i++) {
    var s = sources[i];
    var info = { scriptIdPart: '' };
    try { var m = s.metaInfo(); info.scriptIdPart = m ? (m.scriptIdPart || '') : ''; } catch(e) {}
    out.sources.push(info);
  }
  var items = document.querySelectorAll('[data-qa-id=legend-source-item]');
  for (var j = 0; j < items.length; j++) {
    var el = items[j];
    var t = el.querySelector('.title-quatTGAC');
    out.legend.push({ entity: el.getAttribute('data-entity-id'), title: t ? t.textContent.trim() : '' });
  }
  return out;
})()''';

Future<_EnforceChartState> _getEnforceState(CdpClient cdp) async {
  final raw = await cdp.evaluate(_getEnforceStateExpr) as Map<String, dynamic>?;
  final sources = ((raw?['sources'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final legend = ((raw?['legend'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  return _EnforceChartState(
    sourceScriptIdParts: sources
        .map((s) => (s['scriptIdPart'] ?? '').toString())
        .toList(),
    legendTitles: legend.map((l) => (l['title'] ?? '').toString()).toList(),
  );
}

class _BothOpen {
  const _BothOpen(this.msb, this.rsi);
  final bool msb;
  final bool rsi;
}

_BothOpen _bothOpen(_EnforceChartState state) {
  final all =
      '${state.sourceScriptIdParts.join(' ')} ${state.legendTitles.join(' ')}';
  // Tightened 2026-09-28, per the user: after a 15-hour outage forced a cold
  // TradingView relaunch, it restored a DIFFERENT, unrelated indicator pair
  // ("EMA & HLOTT & MSB/OB" and "Combined_Indicators") whose display names
  // happened to contain the old generic keyword fallbacks (MSB, HLOTT, RSI,
  // Stochastic, VAPI, Combined_Indicators) - a false positive that declared
  // "Ready" and let the engine cycle for 5+ minutes reading data from the
  // wrong scripts (always "no range yet", since they don't output the
  // expected format - no trade was placed, but the status was a lie). Only
  // the exact scriptIdPart and the exact short save-name each script is
  // actually confirmed to carry (see _enforceScripts above) are specific
  // enough to trust; a still-loading stub with an empty scriptIdPart is
  // exactly why the exact-name checks stay as a fallback at all.
  final msb =
      all.contains('USER;ac8febb9427a44578fd4052af6c17d65') ||
      RegExp(r'\bworm_9_26\b', caseSensitive: false).hasMatch(all);
  final rsi =
      all.contains('USER;f40c0a529f954b648be8f2b530d43d3f') ||
      RegExp(r'\bspy_9_26\b', caseSensitive: false).hasMatch(all);
  return _BothOpen(msb, rsi);
}

/// Read-only check: are both required indicators (worm_9_26 + spy_9_26)
/// currently attached to the chart, with no DOM automation and nothing
/// removed or re-added — just the one chart-state read `_getEnforceState`
/// already does internally. Added 2026-09-20 for the Power health check, so
/// a chart that's already fine doesn't pay for the full close-and-re-add
/// cycle [enforceCustomScripts] runs, on every single check.
Future<bool> areIndicatorsPresent(CdpClient cdp) async {
  final check = _bothOpen(await _getEnforceState(cdp));
  return check.msb && check.rsi;
}

Future<void> _dispatchMouseMove(CdpClient cdp, double x, double y) => cdp.send(
  'Input.dispatchMouseEvent',
  {'type': 'mouseMoved', 'x': x, 'y': y, 'button': 'none'},
);

Future<void> _dispatchMouseClick(CdpClient cdp, double x, double y) async {
  await cdp.send('Input.dispatchMouseEvent', {
    'type': 'mouseMoved',
    'x': x,
    'y': y,
    'button': 'none',
  });
  await Future<void>.delayed(const Duration(milliseconds: 60));
  await cdp.send('Input.dispatchMouseEvent', {
    'type': 'mousePressed',
    'x': x,
    'y': y,
    'button': 'left',
    'clickCount': 1,
  });
  await Future<void>.delayed(const Duration(milliseconds: 60));
  await cdp.send('Input.dispatchMouseEvent', {
    'type': 'mouseReleased',
    'x': x,
    'y': y,
    'button': 'left',
    'clickCount': 1,
  });
}

class _Point {
  const _Point(this.x, this.y);
  final double x;
  final double y;
}

class _LegendItemInfo {
  const _LegendItemInfo({
    required this.entity,
    required this.title,
    this.titlePos,
    this.trash,
  });
  final String? entity;
  final String title;
  final _Point? titlePos;
  final _Point? trash;
}

const _legendItemsExpr = '''(function() {
  function rectOf(el) {
    if (!el || el.offsetParent === null) return null;
    var r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return null;
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }
  function interactableRectOf(el) {
    if (!el || el.offsetParent === null) return null;
    var cs = getComputedStyle(el);
    if (parseFloat(cs.opacity) === 0) return null;
    if (cs.pointerEvents === 'none') return null;
    var r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return null;
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }
  var out = [];
  var items = document.querySelectorAll('[data-qa-id=legend-source-item]');
  for (var i = 0; i < items.length; i++) {
    var el = items[i];
    var t = el.querySelector('.title-quatTGAC');
    var title = t ? t.textContent.trim() : '';
    var trash = el.querySelector('[data-qa-id=legend-delete-action]');
    out.push({
      entity: el.getAttribute('data-entity-id'),
      title: title,
      titlePos: rectOf(t),
      trash: interactableRectOf(trash),
    });
  }
  return out;
})()''';

Future<List<_LegendItemInfo>> _getLegendItemsInfo(CdpClient cdp) async {
  final raw = (await cdp.evaluate(_legendItemsExpr) as List?) ?? const [];
  return raw.cast<Map<String, dynamic>>().map((item) {
    Map<String, dynamic>? p(String key) =>
        (item[key] as Map?)?.cast<String, dynamic>();
    final titlePos = p('titlePos');
    final trash = p('trash');
    return _LegendItemInfo(
      entity: item['entity'] as String?,
      title: (item['title'] ?? '').toString(),
      titlePos: titlePos == null
          ? null
          : _Point(
              (titlePos['x'] as num).toDouble(),
              (titlePos['y'] as num).toDouble(),
            ),
      trash: trash == null
          ? null
          : _Point(
              (trash['x'] as num).toDouble(),
              (trash['y'] as num).toDouble(),
            ),
    );
  }).toList();
}

Future<bool> _elementAtPointMatches(
  CdpClient cdp,
  double x,
  double y,
  String qaId,
) async {
  final expr =
      '''(function() {
    var el = document.elementFromPoint($x, $y);
    while (el) {
      if (el.getAttribute && el.getAttribute('data-qa-id') === ${jsonEncode(qaId)}) return true;
      el = el.parentElement;
    }
    return false;
  })()''';
  return await cdp.evaluate(expr) as bool? ?? false;
}

class RemovedSourceResult {
  const RemovedSourceResult({
    required this.entity,
    required this.title,
    required this.ok,
    this.reason,
  });
  final String? entity;
  final String title;
  final bool ok;
  final String? reason;
}

/// Replicates the user's manual action: hover the indicator NAME, then click
/// the trash icon — using real CDP mouse events. Runs up to 3 rounds to mop
/// up anything a promo dialog blocked mid-way.
Future<List<RemovedSourceResult>> removeAllSources(CdpClient cdp) async {
  final removed = <RemovedSourceResult>[];
  for (var round = 0; round < 3; round++) {
    final items = await _getLegendItemsInfo(cdp);
    if (items.isEmpty) break;

    for (final item in items) {
      final blocking = await findDismissTarget(cdp);
      if (blocking != null) await dismissUpgradeDialog(cdp);

      if (item.titlePos == null) {
        removed.add(
          RemovedSourceResult(
            entity: item.entity,
            title: item.title,
            ok: false,
            reason: 'title not visible',
          ),
        );
        continue;
      }

      await _dispatchMouseMove(cdp, item.titlePos!.x, item.titlePos!.y);
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final refreshed = await _getLegendItemsInfo(cdp);
      final match = refreshed.cast<_LegendItemInfo?>().firstWhere(
        (r) => r?.entity == item.entity,
        orElse: () => null,
      );
      if (match?.trash == null) {
        removed.add(
          RemovedSourceResult(
            entity: item.entity,
            title: item.title,
            ok: false,
            reason: 'trash not interactable after hover',
          ),
        );
        continue;
      }

      await _dispatchMouseMove(cdp, match!.trash!.x, match.trash!.y);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final onTarget = await _elementAtPointMatches(
        cdp,
        match.trash!.x,
        match.trash!.y,
        'legend-delete-action',
      );
      if (!onTarget) {
        removed.add(
          RemovedSourceResult(
            entity: item.entity,
            title: item.title,
            ok: false,
            reason: 'covered at click point',
          ),
        );
        continue;
      }

      await _dispatchMouseClick(cdp, match.trash!.x, match.trash!.y);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      removed.add(
        RemovedSourceResult(entity: item.entity, title: item.title, ok: true),
      );
    }

    final after = await _getLegendItemsInfo(cdp);
    if (after.isEmpty) break;
  }
  return removed;
}

Future<void> _closeAllDialogs(CdpClient cdp) async {
  await cdp.evaluate('''(function() {
    var btns = document.querySelectorAll('[role=dialog] button');
    for (var i = 0; i < btns.length; i++) {
      if (btns[i].offsetParent !== null && (btns[i].getAttribute('data-qa-id') === 'close' || (btns[i].textContent||'').indexOf('Close') !== -1)) btns[i].click();
    }
  })()''');
  await Future<void>.delayed(const Duration(seconds: 1));
}

class DismissTarget {
  const DismissTarget({required this.via, required this.x, required this.y});
  final String via;
  final double x;
  final double y;
}

const _findDismissTargetExpr = '''(function() {
  function visible(el) { return !!el && el.offsetParent !== null; }
  function rectOf(el) {
    var r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return null;
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }

  var known = document.querySelector('[data-qa-id=promo-dialog-close-button]');
  if (visible(known)) {
    var r0 = rectOf(known);
    if (r0) return { via: 'promo-dialog-close-button', rect: r0 };
  }

  var dialogs = document.querySelectorAll('[role=dialog]');
  for (var i = 0; i < dialogs.length; i++) {
    var d = dialogs[i];
    if (!visible(d)) continue;
    var text = (d.textContent || '').replace(/\\s+/g, ' ').toLowerCase();
    if (text.indexOf('indicators, metrics, and strategies') !== -1) continue;
    var btns = d.querySelectorAll('button, [class*=close], [aria-label]');
    for (var j = 0; j < btns.length; j++) {
      var b = btns[j];
      if (!visible(b)) continue;
      var label = (b.getAttribute('aria-label') || b.getAttribute('title') || b.textContent || '').trim().toLowerCase();
      if (b.getAttribute('data-qa-id') === 'promo-dialog-close-button' || b.getAttribute('data-qa-id') === 'close' || label === 'close' || /^x\$/.test(label)) {
        var r1 = rectOf(b);
        if (r1) return { via: 'dialog close btn', rect: r1 };
      }
    }
    var dismissBtns = d.querySelectorAll('button');
    for (var k = 0; k < dismissBtns.length; k++) {
      var db = dismissBtns[k];
      if (!visible(db)) continue;
      var dt = (db.textContent || '').trim().toLowerCase();
      if (/not now|maybe later|later|no thanks|keep using the free|continue free|dismiss|got it/i.test(dt)) {
        var r2 = rectOf(db);
        if (r2) return { via: dt.slice(0, 40), rect: r2 };
      }
    }
  }

  var all = document.querySelectorAll('body *');
  for (var m = 0; m < all.length; m++) {
    var el = all[m];
    if (!visible(el) || el.children.length === 0) continue;
    var rr = el.getBoundingClientRect();
    if (rr.width < window.innerWidth * 0.5 || rr.height < window.innerHeight * 0.5) continue;
    var t = (el.textContent || '').replace(/\\s+/g, ' ').toLowerCase();
    if (!/upgrade|go pro|free plan|start trial|subscribe|unlock|offer|maximum available on your plan/i.test(t)) continue;
    var cbs = el.querySelectorAll('button, [aria-label], [class*=close]');
    for (var n = 0; n < cbs.length; n++) {
      var cb = cbs[n];
      if (!visible(cb)) continue;
      var label2 = (cb.getAttribute('aria-label') || cb.getAttribute('title') || cb.textContent || '').trim().toLowerCase();
      if (cb.getAttribute('data-qa-id') === 'promo-dialog-close-button' || label2 === 'close' || /^x\$/.test(label2) || /not now|maybe later|later|no thanks|keep using the free|continue free|dismiss|got it/i.test(label2)) {
        var r3 = rectOf(cb);
        if (r3) return { via: 'overlay ' + label2.slice(0, 30), rect: r3 };
      }
    }
  }
  return null;
})()''';

Future<DismissTarget?> findDismissTarget(CdpClient cdp) async {
  final raw =
      await cdp.evaluate(_findDismissTargetExpr) as Map<String, dynamic>?;
  if (raw == null) return null;
  final rect = (raw['rect'] as Map).cast<String, dynamic>();
  return DismissTarget(
    via: raw['via'] as String,
    x: (rect['x'] as num).toDouble(),
    y: (rect['y'] as num).toDouble(),
  );
}

class DismissResult {
  const DismissResult({required this.closed, this.via});
  final bool closed;
  final String? via;
}

/// Free TradingView accounts sometimes show an upgrade/offer dialog
/// (typically triggered by opening ~3 indicators at once). Must be dismissed
/// BEFORE opening any script — it blocks the Indicators dialog from
/// rendering, and can reappear mid-removal too.
Future<DismissResult> dismissUpgradeDialog(CdpClient cdp) async {
  for (var attempt = 0; attempt < 3; attempt++) {
    final target = await findDismissTarget(cdp);
    if (target == null) return const DismissResult(closed: false);

    await _dispatchMouseMove(cdp, target.x, target.y);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _dispatchMouseClick(cdp, target.x, target.y);
    await Future<void>.delayed(const Duration(milliseconds: 700));

    final stillThere = await findDismissTarget(cdp);
    if (stillThere == null) return DismissResult(closed: true, via: target.via);
  }
  return const DismissResult(closed: false, via: 'gave up after 3 attempts');
}

Future<bool> _waitForRow(CdpClient cdp, String needle) async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final expr =
        '''(function() {
      var needle = ${jsonEncode(needle)};
      var all = document.querySelectorAll('.contentWrapper-uumrt5rh *');
      for (var j = 0; j < all.length; j++) {
        var el = all[j];
        if (el.children.length > 0 || el.offsetParent === null) continue;
        var t = (el.textContent || '').trim();
        if (t.indexOf(needle) !== -1) return true;
      }
      return false;
    })()''';
    final found = await cdp.evaluate(expr) as bool? ?? false;
    if (found) return true;
  }
  return false;
}

/// Real dispatched mouse click on the first element matching [selector] -
/// gets its bounding-rect center via JS, then clicks through CDP's
/// `Input.dispatchMouseEvent` (see [_dispatchMouseClick]). Returns false if
/// nothing matched. Added 2026-09-29, per the user ("learn from
/// tradingpionex... make a self healing for this problem"): confirmed live
/// that TradingView's `button[data-name=open-indicators-dialog]` (and, by
/// the same logic, its sidebar tab and search-result rows) silently stopped
/// responding to a synthetic `el.click()` call entirely - it never opened
/// the dialog, no error, no exception, just nothing happening - while an
/// identical REAL dispatched mouse event on the exact same element worked
/// immediately. This had every symptom of a stuck/broken TradingView (the
/// watchdog above fired three times force-relaunching it, with the SAME
/// failure recurring on every fresh launch) when the actual cause was this
/// one automation primitive no longer working against TradingView's current
/// build - not TradingView being stuck at all.
Future<bool> _realClick(CdpClient cdp, String selector) async {
  final rect = await cdp.evaluate('''(function() {
    var el = document.querySelector(${jsonEncode(selector)});
    if (!el) return null;
    var r = el.getBoundingClientRect();
    return JSON.stringify({x: r.x + r.width / 2, y: r.y + r.height / 2});
  })()''');
  if (rect == null) return false;
  final point = jsonDecode(rect as String) as Map<String, dynamic>;
  final x = (point['x'] as num).toDouble();
  final y = (point['y'] as num).toDouble();
  await _dispatchMouseMove(cdp, x, y);
  await Future<void>.delayed(const Duration(milliseconds: 150));
  await _dispatchMouseClick(cdp, x, y);
  return true;
}

Future<bool> _addOneViaMyScripts(CdpClient cdp, EnforceScript script) async {
  await _closeAllDialogs(cdp);
  await dismissUpgradeDialog(cdp);

  await Future<void>.delayed(const Duration(seconds: 3));
  final openedDialog = await _realClick(cdp, 'button[data-name=open-indicators-dialog]');
  if (!openedDialog) return false;
  await Future<void>.delayed(const Duration(seconds: 3));

  await _realClick(cdp, '[data-qa-id="indicator-sidebar-item-my-scripts"]');
  await Future<void>.delayed(const Duration(milliseconds: 1500));

  final rowFound = await _waitForRow(cdp, script.searchTitle);
  if (!rowFound) {
    await _closeAllDialogs(cdp);
    return false;
  }

  // The matching row's own clickable ancestor isn't a fixed selector (its
  // class names are TradingView's own hashed/obfuscated build output), so
  // find it by text content in JS and report its rect back, then click for
  // real from here rather than clicking it inside the JS itself.
  final rowRect = await cdp.evaluate('''(function() {
    var needle = ${jsonEncode(script.searchTitle)};
    var all = document.querySelectorAll('.contentWrapper-uumrt5rh *');
    for (var j = 0; j < all.length; j++) {
      var el = all[j];
      if (el.children.length > 0 || el.offsetParent === null) continue;
      var t = (el.textContent || '').trim();
      if (t.indexOf(needle) !== -1) {
        var rowEl = el.closest('[role=button], [class*=item], .main-cDWXFIqV, [class*=main-]') || el.parentElement;
        if (rowEl) {
          var r = rowEl.getBoundingClientRect();
          return JSON.stringify({x: r.x + r.width / 2, y: r.y + r.height / 2});
        }
      }
    }
    return null;
  })()''');
  var clicked = false;
  if (rowRect != null) {
    final point = jsonDecode(rowRect as String) as Map<String, dynamic>;
    final x = (point['x'] as num).toDouble();
    final y = (point['y'] as num).toDouble();
    await _dispatchMouseMove(cdp, x, y);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _dispatchMouseClick(cdp, x, y);
    clicked = true;
  }
  await Future<void>.delayed(const Duration(milliseconds: 1500));

  await _closeAllDialogs(cdp);
  await Future<void>.delayed(const Duration(seconds: 2));
  return clicked;
}

class EnforceResult {
  const EnforceResult({
    required this.status,
    this.error,
    this.removed = const [],
    this.addedOk = const {},
    this.finalMsb = false,
    this.finalRsi = false,
  });
  final String status;
  final String? error;
  final List<RemovedSourceResult> removed;
  final Map<String, bool> addedOk;
  final bool finalMsb;
  final bool finalRsi;
}

/// End-to-end: close all indicators, then open the two custom scripts, then
/// verify — ported 1:1 from lib/enforce.js `enforceCustomScripts`. Idempotent
/// across repeated runs without a TradingView restart.
Future<EnforceResult> enforceCustomScripts(String host, int port) async {
  final cdp = await connectToChart(host, port);
  try {
    final apiReady = await waitForChartApiReady(cdp);
    if (!apiReady) {
      return const EnforceResult(
        status: 'blocked',
        error: 'TradingView chart API did not become ready in time',
      );
    }

    // Step 1: close ALL currently open indicators (free-account 2-indicator
    // limit; TradingView restores last-open indicators on every launch) and
    // any dialog sitting on top - a subscription/upgrade prompt or any
    // other open dialog would otherwise block removeAllSources' clicks.
    await _closeAllDialogs(cdp);
    await dismissUpgradeDialog(cdp);
    final removed = await removeAllSources(cdp);
    await Future<void>.delayed(const Duration(seconds: 2));

    final afterRemoval = await _getEnforceState(cdp);
    if (afterRemoval.legendTitles.isNotEmpty) {
      return EnforceResult(
        status: 'blocked',
        removed: removed,
        finalMsb: false,
        finalRsi: false,
      );
    }

    final addedOk = <String, bool>{};
    for (final script in _enforceScripts) {
      addedOk[script.key] = await _addOneViaMyScripts(cdp, script);
    }

    // Wait for loading stubs to resolve. Per the user (2026-09-05): a
    // subscription/limit dialog can pop up right as the second custom
    // indicator is added (a common free-tier prompt) and silently block it
    // from ever finishing loading - previously nothing here dismissed it,
    // so the indicator sat stuck on its generic stub title for the full
    // wait and enforcement gave up, leaving a broken/duplicate chart state
    // on the next attempt. Dismiss on every iteration, not just at the
    // start of Step 1.
    var check = const _BothOpen(false, false);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      await dismissUpgradeDialog(cdp);
      check = _bothOpen(await _getEnforceState(cdp));
      if (check.msb && check.rsi) break;
    }

    // Cleanup: remove any leftover legend stubs so exactly the two custom
    // scripts remain (free account limit is 2). Protects both by
    // scriptIdPart AND by title, since a still-loading stub carries an empty
    // scriptIdPart.
    await cdp.evaluate('''(function() {
      var wv = window.TradingViewApi._activeChartWidgetWV;
      var widget = wv.value();
      var appModel = widget._chartWidget.model().model();
      var keptParts = ['USER;ac8febb9427a44578fd4052af6c17d65', 'USER;f40c0a529f954b648be8f2b530d43d3f'];
      var scriptTitles = ['Footprint/VFAS/EMA/HLOTT/MSB/OB/AlphaTrend/ZigZag++', 'Footprint/VFAS/EMA/HLOTT/MSB/OB/AlphaTrend', 'Footprint/VFAS/EMA/HLOTT/MSB/OB', 'EMA & HLOTT & MSB/OB', 'RSI & Vol & Stochastic RSI & VAPI', 'Combined_Indicators', 'worm_9_26', 'spy_9_26'];
      var items = document.querySelectorAll('[data-qa-id=legend-source-item]');
      var legend = [];
      for (var j = 0; j < items.length; j++) {
        var el = items[j];
        var t = el.querySelector('.title-quatTGAC');
        legend.push({ entity: el.getAttribute('data-entity-id'), title: t ? t.textContent.trim() : '' });
      }
      var sources = appModel.dataSources();
      var byEntity = {};
      for (var i = 0; i < sources.length; i++) {
        var s = sources[i];
        var part = '';
        var eid = null;
        try { var m = s.metaInfo(); part = m ? (m.scriptIdPart || '') : ''; } catch(e) {}
        try { eid = s.entityId ? s.entityId() : null; } catch(e) {}
        if (eid) byEntity[eid] = part;
      }
      for (var k = 0; k < legend.length; k++) {
        var item = legend[k];
        var part = byEntity[item.entity] || '';
        var titleIsScript = scriptTitles.some(function (st) { return item.title.indexOf(st) !== -1; });
        if (keptParts.indexOf(part) !== -1 || titleIsScript) continue;
        try { widget.removeEntity(item.entity); } catch(e) {}
      }
    })()''');

    final finalState = await _getEnforceState(cdp);
    final finalCheck = _bothOpen(finalState);
    return EnforceResult(
      status: addedOk.values.every((v) => v) ? 'ok' : 'partial',
      removed: removed,
      addedOk: addedOk,
      finalMsb: finalCheck.msb,
      finalRsi: finalCheck.rsi,
    );
  } finally {
    cdp.close();
  }
}

// ============================================================================
// Supertrend Plus + Heikin Ashi (2026-10-06, per the user's second decision
// technique) - a parallel set of functions, deliberately NOT merged into the
// worm_9_26/spy_9_26 functions above. Those are hard-won, carefully-tuned
// automation (see this file's own top-of-file doc comment on real live
// debugging) - reusing their shared low-level primitives
// (_closeAllDialogs, dismissUpgradeDialog, removeAllSources,
// _addOneViaMyScripts, _getEnforceState) is safe, but reshaping their own
// exact-two-scripts logic to be generic would risk regressing behavior
// that's already proven correct for Signal Flip.
//
// Requires TWO scripts, same free-account 2-indicator limit as Signal Flip:
// Supertrend Plus (entry/exit Buy/Sell signals) AND worm_9_26 (2026-10-06,
// per the user: "keep using old method" for TP/SL - the 60/40 zigzag range
// model still reads worm_9_26's own range data; only its HH/LL/BUY/SELL
// SIGNALS go unused under this technique, not the script itself). spy_9_26
// is NOT required here - its presence was always specific to validating
// Signal Flip's own setup, and nothing in this technique reads anything
// from it.
// ============================================================================

const _supertrendScript = EnforceScript(
  key: 'SUPERTREND',
  searchTitle: 'Supertrend Plus',
  scriptIdPart: 'USER;de83e70197704202ae530fd979d38aae',
);

/// worm_9_26, same scriptIdPart Signal Flip's own [_enforceScripts] entry
/// uses - needed here ONLY for its zigzag range data (see the section's own
/// doc comment above), never for its HH/LL/BUY/SELL signals.
const _supertrendRangeScript = EnforceScript(
  key: 'MSB',
  searchTitle: 'worm_9_26',
  scriptIdPart: 'USER;ac8febb9427a44578fd4052af6c17d65',
);

const _supertrendScripts = [_supertrendScript, _supertrendRangeScript];

class _SupertrendBothOpen {
  const _SupertrendBothOpen(this.supertrend, this.worm);
  final bool supertrend;
  final bool worm;
}

_SupertrendBothOpen _supertrendBothOpen(_EnforceChartState state) {
  final all =
      '${state.sourceScriptIdParts.join(' ')} ${state.legendTitles.join(' ')}';
  final supertrend =
      all.contains(_supertrendScript.scriptIdPart) ||
      RegExp(r'\bSupertrend Plus\b', caseSensitive: false).hasMatch(all);
  final worm =
      all.contains(_supertrendRangeScript.scriptIdPart) ||
      RegExp(r'\bworm_9_26\b', caseSensitive: false).hasMatch(all);
  return _SupertrendBothOpen(supertrend, worm);
}

/// Read-only check, same shape as [areIndicatorsPresent] but for the
/// Supertrend Plus + worm_9_26 combo.
Future<bool> isSupertrendPresent(CdpClient cdp) async {
  final check = _supertrendBothOpen(await _getEnforceState(cdp));
  return check.supertrend && check.worm;
}

/// Same end-to-end shape as [enforceCustomScripts] (close everything, add
/// the required scripts, verify) but for the Supertrend Plus + worm_9_26
/// combo.
Future<EnforceResult> enforceSupertrendPlus(String host, int port) async {
  final cdp = await connectToChart(host, port);
  try {
    final apiReady = await waitForChartApiReady(cdp);
    if (!apiReady) {
      return const EnforceResult(
        status: 'blocked',
        error: 'TradingView chart API did not become ready in time',
      );
    }

    await _closeAllDialogs(cdp);
    await dismissUpgradeDialog(cdp);
    final removed = await removeAllSources(cdp);
    await Future<void>.delayed(const Duration(seconds: 2));

    final afterRemoval = await _getEnforceState(cdp);
    if (afterRemoval.legendTitles.isNotEmpty) {
      return EnforceResult(status: 'blocked', removed: removed);
    }

    final addedOk = <String, bool>{};
    for (final script in _supertrendScripts) {
      addedOk[script.key] = await _addOneViaMyScripts(cdp, script);
    }

    var check = const _SupertrendBothOpen(false, false);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(seconds: 3));
      await dismissUpgradeDialog(cdp);
      check = _supertrendBothOpen(await _getEnforceState(cdp));
      if (check.supertrend && check.worm) break;
    }

    // Cleanup: remove any leftover legend stub that isn't one of the two
    // required scripts (same free-account-limit reasoning as
    // enforceCustomScripts).
    await cdp.evaluate('''(function() {
      var wv = window.TradingViewApi._activeChartWidgetWV;
      var widget = wv.value();
      var appModel = widget._chartWidget.model().model();
      var keptParts = [${jsonEncode(_supertrendScript.scriptIdPart)}, ${jsonEncode(_supertrendRangeScript.scriptIdPart)}];
      var scriptTitles = ['Supertrend Plus', 'worm_9_26', 'Footprint/VFAS/EMA/HLOTT/MSB/OB/AlphaTrend/ZigZag++', 'EMA & HLOTT & MSB/OB'];
      var items = document.querySelectorAll('[data-qa-id=legend-source-item]');
      var legend = [];
      for (var j = 0; j < items.length; j++) {
        var el = items[j];
        var t = el.querySelector('.title-quatTGAC');
        legend.push({ entity: el.getAttribute('data-entity-id'), title: t ? t.textContent.trim() : '' });
      }
      var sources = appModel.dataSources();
      var byEntity = {};
      for (var i = 0; i < sources.length; i++) {
        var s = sources[i];
        var part = '';
        var eid = null;
        try { var m = s.metaInfo(); part = m ? (m.scriptIdPart || '') : ''; } catch(e) {}
        try { eid = s.entityId ? s.entityId() : null; } catch(e) {}
        if (eid) byEntity[eid] = part;
      }
      for (var k = 0; k < legend.length; k++) {
        var item = legend[k];
        var part = byEntity[item.entity] || '';
        var titleIsScript = scriptTitles.some(function (st) { return item.title.indexOf(st) !== -1; });
        if (keptParts.indexOf(part) !== -1 || titleIsScript) continue;
        try { widget.removeEntity(item.entity); } catch(e) {}
      }
    })()''');

    final finalCheck = _supertrendBothOpen(await _getEnforceState(cdp));
    return EnforceResult(
      status: addedOk.values.every((v) => v) ? 'ok' : 'partial',
      removed: removed,
      addedOk: addedOk,
      // Reusing EnforceResult.finalMsb/finalRsi to mean "Supertrend Plus
      // is open" / "worm_9_26 is open" - avoids adding one-off fields to a
      // shared class for this one caller. Read them as that here, not
      // literally "MSB"/"RSI".
      finalMsb: finalCheck.supertrend,
      finalRsi: finalCheck.worm,
    );
  } finally {
    cdp.close();
  }
}

/// Candle style codes, confirmed live 2026-10-06 against a real chart:
/// clicking TradingView's toolbar "Candles"/"Heikin Ashi" buttons set
/// `mainSeries.properties().childs().style.value()` to 1/8 respectively,
/// and calling `.setValue()` directly on that same property works exactly
/// the same way without any UI automation at all - far more reliable than
/// clicking (this codebase has already been bitten once by a TradingView
/// update silently breaking synthetic clicks on a toolbar button - see
/// [_realClick]'s own doc comment).
class ChartStyle {
  ChartStyle._();
  static const candles = 1;
  static const heikinAshi = 8;
}

/// Reads the main series' current chart style (candle type) - see
/// [ChartStyle].
Future<int?> getChartStyle(CdpClient cdp) async {
  final result = await cdp.evaluate('''(function() {
    try {
      var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
      return chart.model().mainSeries().properties().childs().style.value();
    } catch (e) {
      return null;
    }
  })()''');
  return (result as num?)?.toInt();
}

/// Sets the main series' chart style directly (no UI clicking) - see
/// [ChartStyle]. Returns false if the chart API isn't ready yet.
Future<bool> setChartStyle(CdpClient cdp, int style) async {
  final result = await cdp.evaluate('''(function() {
    try {
      var chart = window.TradingViewApi._activeChartWidgetWV.value()._chartWidget;
      chart.model().mainSeries().properties().childs().style.setValue($style);
      return true;
    } catch (e) {
      return false;
    }
  })()''');
  return result == true;
}

/// Ensures the chart is on [style], only touching it if it isn't already -
/// called every cycle alongside the indicator-presence check, same spirit
/// as [areIndicatorsPresent]/[isSupertrendPresent] not re-running the full
/// enforce pass when nothing actually needs to change.
Future<bool> ensureChartStyle(CdpClient cdp, int style) async {
  final current = await getChartStyle(cdp);
  if (current == style) return true;
  return setChartStyle(cdp, style);
}
