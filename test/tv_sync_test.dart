import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:trading_mt5/data/tvsync/tv_sync.dart';

void main() {
  late Directory dir;
  var now = 1_000_000;

  TvSync mt5() => TvSync(dir: dir.path, now: () => now);
  TvSync pionex() => TvSync(dir: dir.path, now: () => now, self: tvSyncPeer, peer: tvSyncSelf);

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tvsync_test');
    now = 1_000_000;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  group('heartbeat staleness', () {
    test('online up to 20 s old, offline after; missing = offline', () {
      final a = mt5();
      expect(a.peerOnline(), isFalse); // no file yet
      pionex().writeHeartbeat(version: '1', power: true, tab: 'claimed', busy: false, tvHealthy: true);
      expect(a.peerOnline(), isTrue);
      now += 20000;
      expect(a.peerOnline(), isTrue);
      now += 1;
      expect(a.peerOnline(), isFalse);
    });

    test('written atomically with every field', () {
      mt5().writeHeartbeat(version: '1.6.78', power: false, tab: 'missing', busy: true, tvHealthy: false);
      final j = jsonDecode(File(p.join(dir.path, 'tradingmt5.heartbeat.json')).readAsStringSync()) as Map;
      expect(j.keys.toSet(), {'app', 'pid', 'version', 'at', 'power', 'tab', 'busy', 'tvHealthy'});
      expect(j['app'], 'tradingmt5');
      expect(j['power'], false);
      expect(j['at'], now);
      expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });
  });

  group('lock', () {
    test('exclusive: the other app cannot take a live lock', () {
      final a = mt5();
      final b = pionex();
      expect(a.tryAcquire(lockRestartTradingView), isTrue);
      expect(b.tryAcquire(lockOpenTab), isFalse);
      expect(b.peerHoldsLock(), isTrue);
      expect(a.peerHoldsLock(), isFalse);
      final lock = a.readLock()!;
      expect(lock.app, 'tradingmt5');
      expect(lock.action, lockRestartTradingView);
      expect(lock.expiresAt, now + 120000);
    });

    test('expires 2 min after it was taken, then may be replaced', () {
      expect(pionex().tryAcquire(lockReloadOwnTab), isTrue);
      now += 119999;
      expect(mt5().tryAcquire(lockOpenTab), isFalse);
      now += 1;
      expect(mt5().tryAcquire(lockOpenTab), isTrue);
      expect(mt5().readLock()!.app, 'tradingmt5');
    });

    test('own lock may be replaced; release deletes only our own', () {
      final a = mt5();
      expect(a.tryAcquire(lockReloadOwnTab), isTrue);
      now += 1000;
      expect(a.tryAcquire(lockOpenTab), isTrue);
      expect(a.readLock()!.action, lockOpenTab);
      pionex().release(); // not theirs - stays
      expect(a.readLock(), isNotNull);
      a.release();
      expect(a.readLock(), isNull);
    });

    test('a lock file being written (unreadable) counts as held', () {
      Directory(p.join(dir.path, 'requests')).createSync(recursive: true);
      File(p.join(dir.path, 'tv.lock')).writeAsStringSync('');
      now = DateTime.now().millisecondsSinceEpoch;
      expect(mt5().tryAcquire(lockOpenTab), isFalse);
    });
  });

  group('requests', () {
    test('only the addressee sees them, and each is handled once', () {
      final a = mt5();
      final b = pionex();
      b.sendRequest(to: 'tradingmt5', type: 'restart_tradingview', reason: 'tab stuck');
      now += 1;
      a.sendRequest(to: 'tradingpionex', type: 'restart_tradingview', reason: 'not for us');
      final mine = a.pendingRequests();
      expect(mine.length, 1);
      expect(mine.single.from, 'tradingpionex');
      expect(mine.single.type, 'restart_tradingview');
      expect(mine.single.reason, 'tab stuck');
      a.done(mine.single);
      expect(a.pendingRequests(), isEmpty);
      expect(b.pendingRequests().length, 1); // theirs untouched
    });

    test('file name is <epochms>_<from>_<type>.json', () {
      pionex().sendRequest(to: 'tradingmt5', type: 'restart_tradingview', reason: 'x');
      final names = Directory(p.join(dir.path, 'requests')).listSync().map((e) => p.basename(e.path)).toList();
      expect(names, ['${now}_tradingpionex_restart_tradingview.json']);
    });
  });
}
