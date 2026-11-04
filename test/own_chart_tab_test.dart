import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/tradingview/cdp_client.dart';

Map<String, dynamic> tab(String id) => {
  'id': id,
  'type': 'page',
  'url': 'https://www.tradingview.com/chart/sdsxZ9HR/',
  'webSocketDebuggerUrl': 'ws://x/$id',
};

/// A fake TradingView: each tab's sessionStorage tag, with the shared claim
/// script applied atomically like the real one.
class FakeTabs {
  FakeTabs(this.tags);
  final Map<String, String?> tags;
  final Set<String> unreachable = {};
  final List<String> calls = [];
  int opened = 0;

  Future<dynamic> evaluate(Map<String, dynamic> t, String expression) async {
    final id = t['id'] as String;
    calls.add('$id:${expression == readTabOwnerScript ? 'read' : 'claim'}');
    if (unreachable.contains(id)) throw Exception('timed out');
    if (expression == readTabOwnerScript) return tags[id];
    final v = tags[id];
    if (v == mt5TabOwner) return 'mine';
    if (v != null) return 'taken:$v';
    tags[id] = mt5TabOwner;
    return 'claimed';
  }

  Future<Map<String, dynamic>?> open() async {
    opened++;
    final id = 'new$opened';
    tags[id] = null;
    return tab(id);
  }
}

Future<String?> pick(FakeTabs fake, List<String> ids, {bool allowOpen = true}) async {
  final t = await selectOwnChartTab(
    targets: [for (final id in ids) tab(id)],
    layoutId: 'sdsxZ9HR',
    evaluate: fake.evaluate,
    openTab: allowOpen ? fake.open : null,
  );
  return t?['id'] as String?;
}

void main() {
  group('isOwnChartUrl', () {
    test('matches chart pages, of the layout when one is set', () {
      expect(isOwnChartUrl('https://www.tradingview.com/chart/sdsxZ9HR/', 'sdsxZ9HR'), isTrue);
      expect(isOwnChartUrl('https://www.tradingview.com/chart/sdsxZ9HR/?symbol=X', ''), isTrue);
      expect(isOwnChartUrl('https://www.tradingview.com/chart/other/', 'sdsxZ9HR'), isFalse);
      expect(isOwnChartUrl('https://www.tradingview.com/', ''), isFalse);
      expect(
        isOwnChartUrl('https://cm.g.doubleclick.net/p?url=https%3A%2F%2Fwww.tradingview.com%2Fchart%2FsdsxZ9HR%2F', ''),
        isFalse,
      );
    });
  });

  group('selectOwnChartTab (shared tab-owner rule)', () {
    test('uses the tab already tagged tradingmt5, claims nothing', () async {
      final fake = FakeTabs({'p': 'tradingpionex', 'm': 'tradingmt5'});
      expect(await pick(fake, ['p', 'm']), 'm');
      expect(fake.calls.where((c) => c.endsWith('claim')), isEmpty);
      expect(fake.tags['p'], 'tradingpionex');
    });

    test('never uses a tradingpionex tab - claims the untagged one', () async {
      final fake = FakeTabs({'p': 'tradingpionex', 'u': null});
      expect(await pick(fake, ['p', 'u']), 'u');
      expect(fake.tags, {'p': 'tradingpionex', 'u': 'tradingmt5'});
      expect(fake.calls, isNot(contains('p:claim')));
    });

    test('claims exactly one of two untagged tabs', () async {
      final fake = FakeTabs({'a': null, 'b': null});
      expect(await pick(fake, ['a', 'b']), 'a');
      expect(fake.tags, {'a': 'tradingmt5', 'b': null});
    });

    test('a claim race lost to Pionex is skipped', () async {
      final fake = FakeTabs({'a': null, 'b': null});
      final t = await selectOwnChartTab(
        targets: [tab('a'), tab('b')],
        layoutId: 'sdsxZ9HR',
        evaluate: (t, e) async {
          // Pionex claims "a" between our read and our claim.
          if (t['id'] == 'a' && e != readTabOwnerScript) fake.tags['a'] = 'tradingpionex';
          return fake.evaluate(t, e);
        },
      );
      expect(t?['id'], 'b');
      expect(fake.tags, {'a': 'tradingpionex', 'b': 'tradingmt5'});
    });

    test('two tradingmt5 tags: uses neither', () async {
      final fake = FakeTabs({'a': 'tradingmt5', 'b': 'tradingmt5'});
      expect(await pick(fake, ['a', 'b']), isNull);
      expect(fake.opened, 0);
    });

    test('opens one tab when only Pionex\'s tab is open', () async {
      final fake = FakeTabs({'p': 'tradingpionex'});
      expect(await pick(fake, ['p']), 'new1');
      expect(fake.opened, 1);
      expect(fake.tags['p'], 'tradingpionex');
    });

    test('opens one tab when no chart tab is open', () async {
      final fake = FakeTabs({});
      expect(await pick(fake, []), 'new1');
      expect(fake.opened, 1);
    });

    test('never opens a third chart tab', () async {
      final fake = FakeTabs({'p': 'tradingpionex', 'q': 'someoneelse'});
      expect(await pick(fake, ['p', 'q']), isNull);
      expect(fake.opened, 0);
    });

    test('without an opener, nothing is opened', () async {
      final fake = FakeTabs({'p': 'tradingpionex'});
      expect(await pick(fake, ['p'], allowOpen: false), isNull);
    });

    test('an unreadable tab blocks claiming and opening (it may be ours, hung)', () async {
      final fake = FakeTabs({'m': 'tradingmt5', 'u': null})..unreachable.add('m');
      await expectLater(pick(fake, ['m', 'u']), throwsA(isA<CdpException>()));
      expect(fake.tags['u'], isNull);
      expect(fake.opened, 0);
    });

    test('our tab is used even if Pionex\'s tab does not answer', () async {
      final fake = FakeTabs({'p': 'tradingpionex', 'm': 'tradingmt5'})..unreachable.add('p');
      expect(await pick(fake, ['p', 'm']), 'm');
    });
  });

  test('claim script is the shared one', () {
    expect(
      claimTabScript('tradingmt5'),
      '(function(){var k="tvTabOwner",v=sessionStorage.getItem(k);if(v==="tradingmt5")return "mine";'
      'if(v)return "taken:"+v;sessionStorage.setItem(k,"tradingmt5");return "claimed";})()',
    );
  });

  test('only cdp_client.dart may open a tab, and nothing closes, navigates or switches tabs', () {
    final banned = RegExp(
      r'Target\.createTarget|Target\.closeTarget|Target\.activateTarget|window\.open\(|window\.close\(|'
      r'Page\.navigate|json/close|json/activate|location\.(assign|replace)\(|location\.href\s*=',
    );
    final opener = RegExp(r'json/new');
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final isClient = f.path.replaceAll(r'\', '/').endsWith('tradingview/cdp_client.dart');
        if (banned.hasMatch(lines[i]) || (!isClient && opener.hasMatch(lines[i]))) {
          hits.add('${f.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(hits, isEmpty);
    final client = File('lib/data/tradingview/cdp_client.dart').readAsStringSync();
    expect(opener.allMatches(client).length, 1, reason: 'exactly one place opens a tab');
  });
}
