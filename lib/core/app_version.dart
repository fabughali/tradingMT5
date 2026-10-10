import 'package:flutter/services.dart' show rootBundle;

/// Reads the real version straight out of pubspec.yaml itself, bundled as a
/// plain asset (2026-10-08) — see `AboutCard`'s own doc comment history for
/// why this avoids `package_info_plus` (this project's working directory is
/// on a FAT32 drive, which breaks Flutter's native-plugin build step for
/// any plugin with real platform code). Used by both `AboutCard` and
/// `BackupRestoreCard` (2026-10-10) so neither screen duplicates the read.
///
/// **GUI-only — never import this from anything the engine's own
/// `bin/engine.dart` dependency graph can reach.** This needs
/// `package:flutter/services.dart`, which plain `dart compile exe` (how the
/// engine is built) cannot compile — confirmed live 2026-10-10 when this
/// function briefly lived in `core/core_constants.dart` instead, a file
/// `data/tradingview/cdp_client.dart` (engine-reachable) already imports,
/// and broke the engine's AOT build outright. Kept as its own small file,
/// separate from `CoreConstants`, specifically so that mistake can't repeat
/// by accident - this file has exactly one Flutter-only job and nothing
/// engine code has any reason to import it for.
Future<String> readAppVersion() async {
  final text = await rootBundle.loadString('pubspec.yaml');
  final match = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(text);
  return match?.group(1) ?? 'unknown';
}
