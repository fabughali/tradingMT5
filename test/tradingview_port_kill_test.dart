import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/data/tradingview/launch.dart';

void main() {
  // Real shape from this PC (2026-10-30): no LISTENING row for 9222/22346,
  // only connected sockets, plus TIME_WAIT rows with PID 0.
  const netstat = '''

Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1188
  TCP    127.0.0.1:9222         127.0.0.1:59103        ESTABLISHED     9548
  TCP    127.0.0.1:22346        127.0.0.1:59920        ESTABLISHED     3700
  TCP    127.0.0.1:51783        127.0.0.1:22346        TIME_WAIT       0
  TCP    127.0.0.1:59103        127.0.0.1:9222         ESTABLISHED     15348
  TCP    127.0.0.1:19222        0.0.0.0:0              LISTENING       4321
  TCP    127.0.0.1:9222         127.0.0.1:59200        TIME_WAIT       0
''';

  test('finds the server-side owner of the port, not the client connecting to it', () {
    expect(parseNetstatPortOwnerPids(netstat, 9222), [9548]);
    expect(parseNetstatPortOwnerPids(netstat, 22346), [3700]);
  });

  test('a LISTENING row counts too', () {
    expect(parseNetstatPortOwnerPids(netstat, 135), [1188]);
  });

  test('TIME_WAIT rows (PID 0) and unused ports give nothing', () {
    expect(parseNetstatPortOwnerPids(netstat, 9333), isEmpty);
  });

  test('does not match a longer port that merely ends in the same digits', () {
    expect(parseNetstatPortOwnerPids(netstat, 222), isEmpty);
  });

  test('CRLF output parses the same', () {
    expect(parseNetstatPortOwnerPids(netstat.replaceAll('\n', '\r\n'), 9222), [9548]);
  });

  group('ownTradingViewPidsToKill', () {
    const exe = r'"C:\Program Files\WindowsApps\TradingView.Desktop_3.4.1.8194_x64__n534cwy3pjxzj\TradingView.exe"';
    const defaultDir = r'--user-data-dir="C:\Users\DELL\AppData\Roaming\TradingView"';

    TradingViewProcess proc(int pid, int parent, String? args) =>
        TradingViewProcess(pid: pid, parentPid: parent, commandLine: args == null ? null : '$exe $args');

    // Real command lines from this PC (2026-11-01).
    final ours = [
      proc(19976, 3960, '--remote-debugging-port=9222'),
      proc(4876, 19976, '--type=renderer $defaultDir --no-zygote --remote-debugging-port=9222 --lang=en-US'),
      proc(5000, 19976, '--type=gpu-process $defaultDir --no-sandbox'),
    ];
    final pionex = [
      proc(7000, 900, r'--remote-debugging-port=9333 --user-data-dir="C:\tv-pionex"'),
      proc(7001, 7000, r'--type=renderer --user-data-dir="C:\tv-pionex" --remote-debugging-port=9333'),
      proc(7002, 7000, r'--type=gpu-process --user-data-dir="C:\tv-pionex"'),
    ];

    test('kills our main process only, its children go with it', () {
      expect(ownTradingViewPidsToKill(ours, 9222), [19976]);
    });

    test('never touches an instance on another port', () {
      expect(ownTradingViewPidsToKill(pionex, 9222), isEmpty);
      expect(ownTradingViewPidsToKill([...pionex, ...ours], 9222), [19976]);
    });

    test('a longer port with the same digits is not ours', () {
      expect(ownTradingViewPidsToKill([proc(1, 2, '--remote-debugging-port=92220')], 9222), isEmpty);
    });

    test('a child left behind on our port is still killed', () {
      expect(ownTradingViewPidsToKill([ours[1]], 9222), [4876]);
    });

    test('a plain TradingView holding the default folder is killed', () {
      expect(ownTradingViewPidsToKill([proc(1, 2, '')], 9222), [1]);
    });

    test('no port but its own data folder is left alone', () {
      expect(ownTradingViewPidsToKill([proc(1, 2, r'--user-data-dir="C:\other"')], 9222), isEmpty);
    });

    test('an unreadable command line is left alone', () {
      expect(ownTradingViewPidsToKill([proc(1, 2, null)], 9222), isEmpty);
    });
  });
}
