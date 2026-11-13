import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// TradingView sync with TradingPionex (2026-11-13, per the user: both apps
/// share one TradingView Desktop and must coordinate through
/// `%USERPROFILE%\.tvsync\`). Plain files, written atomically (temp file,
/// then rename). All times are epoch milliseconds.
///
/// - `<app>.heartbeat.json` - each app's state every 5s; older than
///   [heartbeatStaleAfter] = that app is offline.
/// - `tv.lock` - who may restart TradingView / reload its own tab / open a
///   tab right now. Created exclusively; expires [lockTtl] after it was
///   taken; only an expired lock or your own may be replaced.
/// - `requests\<epochms>_<from>_<type>.json` - asks for the other app; the
///   addressee handles each one once and deletes it.
const tvSyncSelf = 'tradingmt5';
const tvSyncPeer = 'tradingpionex';

const heartbeatStaleAfter = Duration(seconds: 20);
const lockTtl = Duration(minutes: 2);

/// Lock actions (the three TradingView actions that need the lock).
const lockRestartTradingView = 'restart_tradingview';
const lockReloadOwnTab = 'reload_own_tab';
const lockOpenTab = 'open_tab';

typedef NowMs = int Function();

int _systemNowMs() => DateTime.now().millisecondsSinceEpoch;

class TvHeartbeat {
  const TvHeartbeat({
    required this.app,
    required this.pid,
    required this.version,
    required this.at,
    required this.power,
    required this.tab,
    required this.busy,
    required this.tvHealthy,
  });

  final String app;
  final int pid;
  final String version;
  final int at;
  final bool power;

  /// "claimed", "missing" or "unknown".
  final String tab;

  /// Reading its chart right now.
  final bool busy;
  final bool tvHealthy;

  Map<String, dynamic> toJson() => {
        'app': app,
        'pid': pid,
        'version': version,
        'at': at,
        'power': power,
        'tab': tab,
        'busy': busy,
        'tvHealthy': tvHealthy,
      };

  static TvHeartbeat? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = j['at'];
    if (at is! num) return null;
    return TvHeartbeat(
      app: '${j['app'] ?? ''}',
      pid: (j['pid'] as num?)?.toInt() ?? 0,
      version: '${j['version'] ?? ''}',
      at: at.toInt(),
      power: j['power'] == true,
      tab: '${j['tab'] ?? 'unknown'}',
      busy: j['busy'] == true,
      tvHealthy: j['tvHealthy'] == true,
    );
  }

  /// Offline = no heartbeat, or one older than [heartbeatStaleAfter].
  static bool isOnline(TvHeartbeat? hb, int nowMs) =>
      hb != null && nowMs - hb.at <= heartbeatStaleAfter.inMilliseconds;
}

class TvLock {
  const TvLock({required this.app, required this.action, required this.at, required this.expiresAt});

  final String app;
  final String action;
  final int at;
  final int expiresAt;

  bool expired(int nowMs) => nowMs >= expiresAt;

  Map<String, dynamic> toJson() => {'app': app, 'action': action, 'at': at, 'expiresAt': expiresAt};

  static TvLock? fromJson(Object? j) {
    if (j is! Map || j['expiresAt'] is! num) return null;
    return TvLock(
      app: '${j['app'] ?? ''}',
      action: '${j['action'] ?? ''}',
      at: (j['at'] as num?)?.toInt() ?? 0,
      expiresAt: (j['expiresAt'] as num).toInt(),
    );
  }
}

class TvRequest {
  const TvRequest({
    required this.id,
    required this.from,
    required this.to,
    required this.type,
    required this.reason,
    required this.at,
    required this.file,
  });

  final String id;
  final String from;
  final String to;
  final String type;
  final String reason;
  final int at;

  /// The request file itself - deleted once handled.
  final File file;
}

class TvSync {
  TvSync({String? dir, NowMs? now, this.self = tvSyncSelf, this.peer = tvSyncPeer})
      : dir = dir ?? p.join(Platform.environment['USERPROFILE'] ?? '.', '.tvsync'),
        _now = now ?? _systemNowMs;

  final String dir;
  final String self;
  final String peer;
  final NowMs _now;

  int nowMs() => _now();

  String get lockPath => p.join(dir, 'tv.lock');
  String get requestsDir => p.join(dir, 'requests');
  String heartbeatPath(String app) => p.join(dir, '$app.heartbeat.json');

  void _ensureDirs() => Directory(requestsDir).createSync(recursive: true);

  /// Temp file in the same folder, then rename into place, so a reader never
  /// sees a half-written file.
  void _writeAtomic(String path, Map<String, dynamic> json) {
    _ensureDirs();
    final tmp = File('$path.${_now()}.$pid.tmp');
    tmp.writeAsStringSync(jsonEncode(json), flush: true);
    tmp.renameSync(path);
  }

  Object? _readJson(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return null;
      return jsonDecode(f.readAsStringSync());
    } catch (_) {
      return null;
    }
  }

  // --- heartbeat ---------------------------------------------------------

  void writeHeartbeat({
    required String version,
    required bool power,
    required String tab,
    required bool busy,
    required bool tvHealthy,
  }) =>
      _writeAtomic(
        heartbeatPath(self),
        TvHeartbeat(
          app: self,
          pid: pid,
          version: version,
          at: _now(),
          power: power,
          tab: tab,
          busy: busy,
          tvHealthy: tvHealthy,
        ).toJson(),
      );

  TvHeartbeat? readHeartbeat(String app) => TvHeartbeat.fromJson(_readJson(heartbeatPath(app)));

  bool peerOnline() => TvHeartbeat.isOnline(readHeartbeat(peer), _now());

  // --- lock --------------------------------------------------------------

  /// The current lock, or null when there is none. A lock file that exists
  /// but can't be read yet (being written) counts as held until [lockTtl]
  /// after its file time.
  TvLock? readLock() {
    final f = File(lockPath);
    if (!f.existsSync()) return null;
    final lock = TvLock.fromJson(_readJson(lockPath));
    if (lock != null) return lock;
    try {
      final at = f.lastModifiedSync().millisecondsSinceEpoch;
      return TvLock(app: '?', action: '?', at: at, expiresAt: at + lockTtl.inMilliseconds);
    } catch (_) {
      return null;
    }
  }

  /// Held by the other app and not expired.
  bool peerHoldsLock() {
    final lock = readLock();
    return lock != null && lock.app != self && !lock.expired(_now());
  }

  /// Takes the lock for [action]. True when it is now ours. An existing lock
  /// is replaced only when it is expired or already ours.
  bool tryAcquire(String action) {
    _ensureDirs();
    final now = _now();
    final mine = TvLock(app: self, action: action, at: now, expiresAt: now + lockTtl.inMilliseconds);
    final existing = readLock();
    if (existing != null) {
      if (existing.app != self && !existing.expired(now)) return false;
      try {
        File(lockPath).deleteSync();
      } catch (_) {}
    }
    final RandomAccessFile raf;
    try {
      // Exclusive create: fails if the other app created it in between.
      File(lockPath).createSync(exclusive: true);
      raf = File(lockPath).openSync(mode: FileMode.writeOnly);
    } catch (_) {
      return false;
    }
    try {
      raf.writeStringSync(jsonEncode(mine.toJson()));
      raf.flushSync();
    } finally {
      raf.closeSync();
    }
    final check = readLock();
    return check != null && check.app == self && check.at == now;
  }

  /// Deletes the lock if it is ours.
  void release() {
    final lock = readLock();
    if (lock != null && lock.app == self) {
      try {
        File(lockPath).deleteSync();
      } catch (_) {}
    }
  }

  // --- requests ----------------------------------------------------------

  /// Requests addressed to this app, oldest first. Others' requests are left
  /// alone.
  List<TvRequest> pendingRequests() {
    final d = Directory(requestsDir);
    if (!d.existsSync()) return const [];
    final out = <TvRequest>[];
    for (final e in d.listSync().whereType<File>()) {
      if (!e.path.endsWith('.json')) continue;
      final j = _readJson(e.path);
      if (j is! Map || j['to'] != self) continue;
      out.add(TvRequest(
        id: '${j['id'] ?? p.basenameWithoutExtension(e.path)}',
        from: '${j['from'] ?? ''}',
        to: '${j['to']}',
        type: '${j['type'] ?? ''}',
        reason: '${j['reason'] ?? ''}',
        at: (j['at'] as num?)?.toInt() ?? 0,
        file: e,
      ));
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }

  /// Marks [r] handled (deletes its file).
  void done(TvRequest r) {
    try {
      r.file.deleteSync();
    } catch (_) {}
  }

  /// Sends a request to [to] (used by tests and for symmetry).
  void sendRequest({required String to, required String type, required String reason}) {
    final at = _now();
    final id = '${at}_${self}_$type';
    _writeAtomic(p.join(requestsDir, '$id.json'), {
      'id': id,
      'from': self,
      'to': to,
      'type': type,
      'reason': reason,
      'at': at,
    });
  }
}
