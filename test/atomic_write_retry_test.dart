import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:trading_mt5/core/core_storage.dart';

/// Holds [path] open (like the GUI reading status.json) for [holdMs], from a
/// separate isolate so the main isolate's synchronous retry loop can run
/// while the handle is held.
Future<void> _holdOpen(List<Object> args) async {
  final path = args[0] as String;
  final holdMs = args[1] as int;
  final ready = args[2] as SendPort;
  final raf = File(path).openSync();
  ready.send('locked');
  sleep(Duration(milliseconds: holdMs));
  raf.closeSync();
}

Future<void> _lockFor(String path, int holdMs) async {
  final ready = ReceivePort();
  await Isolate.spawn(_holdOpen, [path, holdMs, ready.sendPort]);
  await ready.first;
}

List<String> _tmpFiles(Directory dir) => dir
    .listSync()
    .map((e) => e.path)
    .where((p) => p.contains('.tmp-'))
    .toList();

void main() {
  late Directory dir;
  late CoreStorage storage;
  late String target;
  final defaultWindow = CoreStorage.renameRetryWindow;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tmt5_atomic_write');
    storage = CoreStorage.forRoot(dir.path);
    target = '${dir.path}${Platform.pathSeparator}status.json';
    File(target).writeAsStringSync('old');
  });
  tearDown(() {
    CoreStorage.renameRetryWindow = defaultWindow;
    sleep(const Duration(milliseconds: 600));
    dir.deleteSync(recursive: true);
  });

  test('plain write replaces the file and leaves no temp file', () {
    storage.writeString(target, 'new');
    expect(File(target).readAsStringSync(), 'new');
    expect(_tmpFiles(dir), isEmpty);
  });

  test('a reader holding the file briefly no longer breaks the write', () async {
    await _lockFor(target, 300);
    storage.writeString(target, 'new');
    expect(File(target).readAsStringSync(), 'new');
    expect(_tmpFiles(dir), isEmpty);
  }, skip: !Platform.isWindows ? 'Windows-only file locking' : false);

  test('a lock outlasting the retry window throws and cleans up the temp file', () async {
    CoreStorage.renameRetryWindow = const Duration(milliseconds: 100);
    await _lockFor(target, 500);
    expect(() => storage.writeString(target, 'new'), throwsA(isA<FileSystemException>()));
    expect(_tmpFiles(dir), isEmpty);
  }, skip: !Platform.isWindows ? 'Windows-only file locking' : false);
}
