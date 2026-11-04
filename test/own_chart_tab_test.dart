import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/tradingview/cdp_client.dart';

Map<String, dynamic> page(String url) => {'type': 'page', 'url': url, 'webSocketDebuggerUrl': 'ws://x/$url'};

void main() {
  const mt5 = 'sdsxZ9HR';
  const pionexUrl = 'https://www.tradingview.com/chart/PionexAB/';
  const mt5Url = 'https://www.tradingview.com/chart/sdsxZ9HR/';

  group('isOwnChartUrl', () {
    test('matches our layout, with or without query', () {
      expect(isOwnChartUrl(mt5Url, mt5), isTrue);
      expect(isOwnChartUrl('https://www.tradingview.com/chart/sdsxZ9HR/?symbol=BTCUSDT', mt5), isTrue);
      expect(isOwnChartUrl('https://www.tradingview.com/chart/sdsxZ9HR', mt5), isTrue);
    });

    test('rejects other layouts, other sites, blank layout ID', () {
      expect(isOwnChartUrl(pionexUrl, mt5), isFalse);
      expect(isOwnChartUrl('https://www.tradingview.com/chart/', mt5), isFalse);
      expect(isOwnChartUrl('https://www.tradingview.com/chart/sdsxZ9HRx/', mt5), isFalse);
      expect(
        isOwnChartUrl('https://cm.g.doubleclick.net/partnerpixels?url=https%3A%2F%2Fwww.tradingview.com%2Fchart%2FsdsxZ9HR%2F', mt5),
        isFalse,
      );
      expect(isOwnChartUrl(mt5Url, ''), isFalse);
    });
  });

  group('pickOwnChartTarget', () {
    test('picks our tab when both apps\' tabs are open, in either order', () {
      expect(pickOwnChartTarget([page(pionexUrl), page(mt5Url)], mt5)?['url'], mt5Url);
      expect(pickOwnChartTarget([page(mt5Url), page(pionexUrl)], mt5)?['url'], mt5Url);
    });

    test('never falls back to another tab when ours is missing', () {
      expect(pickOwnChartTarget([page(pionexUrl)], mt5), isNull);
      expect(pickOwnChartTarget([page('https://www.tradingview.com/')], mt5), isNull);
      expect(pickOwnChartTarget([], mt5), isNull);
    });

    test('ignores iframes and workers carrying our URL', () {
      expect(pickOwnChartTarget([{'type': 'iframe', 'url': mt5Url}], mt5), isNull);
    });

    test('no layout ID configured picks nothing', () {
      expect(pickOwnChartTarget([page(mt5Url)], ''), isNull);
    });
  });

  test('the app never opens tabs or windows or navigates a tab', () {
    final banned = RegExp(r'Target\.createTarget|window\.open\(|Page\.navigate|Target\.activateTarget');
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (banned.hasMatch(lines[i])) hits.add('${f.path}:${i + 1}: ${lines[i].trim()}');
      }
    }
    expect(hits, isEmpty);
  });
}
