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
}
