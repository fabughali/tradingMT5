import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../../core/core_storage.dart';

/// Metadata embedded in every export (2026-10-10, per the user: "exported
/// file should have time stamp and app version"). Written once, at export
/// time, as a small plaintext-after-decryption `_meta.json` entry inside
/// the zip — survives the user renaming the outer file (the filename is
/// ALSO stamped with the same two values, by the Settings screen that
/// calls [BackupService.exportTo] — see [BackupRestoreCard] — but a
/// filename can be changed by hand; this can't). [importFrom] returns this
/// (or null, for a backup made before this field existed) so the caller can
/// show the user exactly what they're about to restore before confirming.
class BackupMetadata {
  const BackupMetadata({required this.exportedAt, required this.appVersion});
  final DateTime exportedAt;
  final String appVersion;
}

/// Settings screen "Backup & Restore" (2026-10-03, per the user: "export
/// setting and all data related to current user ... user does not need to
/// start from scratch. once data imported, everything is settled and user
/// can continue from the timestamp of file extraction date" + "the
/// exported file should be encrypted, with high security level") — zips
/// every file under [CoreStorage.rootDir] (everything in logs/ -
/// auto-managed state, trade history, pending signals, volume overrides,
/// the lot - plus a credential/connection-stripped copy of config.json)
/// except process-specific or purely diagnostic files that mean nothing on
/// a different machine, then encrypts the whole zip with a password the
/// user chooses at export time.
///
/// **No credentials, API keys, or connection settings are ever included**
/// (2026-10-10, per the user: "credentials are not included in exported
/// imported files. only user data ... api, ports, credentials are not
/// included") — `.env` (the MT5 MCP API key) is excluded entirely, and
/// `config.json`'s `mt5`/`cdp` blocks (host/port for both) are stripped out
/// of the copy that goes into the archive, keeping everything else in that
/// file (symbols, risk, technique, poll interval, remote-session flag).
/// [importFrom] mirrors this: it never overwrites THIS machine's own
/// `mt5`/`cdp` settings with anything from the backup (there's nothing
/// there to overwrite with anyway) or touches `.env` at all.
///
/// Format (all integers big-endian, written as raw bytes):
/// `MAGIC(4) | VERSION(1) | SALT(16) | NONCE(12) | CIPHERTEXT(N) | MAC(16)`
///
/// AES-256-GCM (authenticated - a wrong password or any tampering fails
/// decryption outright, not a silent garbage result) with a key derived
/// via PBKDF2-HMAC-SHA256 at 310,000 iterations (2023 OWASP-recommended
/// floor for PBKDF2-SHA256) from a random 16-byte salt, so the same
/// password never produces the same key twice across exports.
class BackupService {
  BackupService(this._storage);

  final CoreStorage _storage;

  static const _magic = [0x54, 0x4D, 0x54, 0x35]; // "TMT5"
  static const _formatVersion = 1;
  static const _pbkdf2Iterations = 310000;
  static const _metaEntryName = '_meta.json';

  /// Transient, process-specific, or purely diagnostic files that are
  /// meaningless (or actively wrong) to carry over to a different machine
  /// or a later run of this same one — plus `.env`, which is pure
  /// credential (the MT5 MCP API key) with nothing else worth carrying
  /// over, so it's excluded outright rather than partially redacted like
  /// config.json is (see [_sanitizeConfigForExport]).
  bool _shouldExclude(String relativePath) {
    final name = p.basename(relativePath);
    if (name == 'heartbeat' || name == 'engine.pid') return true;
    if (RegExp(r'^engine(\..*)?\.log$').hasMatch(name)) return true;
    if (relativePath == '.env') return true;
    // Never zip up the backups folder itself - [CoreStorage.backupsDir]
    // lives inside rootDir, so without this a later export would include
    // every earlier backup file too, growing unboundedly.
    final normalized = p.split(relativePath);
    if (normalized.isNotEmpty && normalized.first == 'backups') return true;
    return false;
  }

  /// Strips `mt5`/`cdp` (host/port for both - the only "ports"/connection
  /// settings this app has) out of config.json before it goes into the
  /// archive, keeping everything else (symbols, risk, technique,
  /// poll_interval_sec, remote_session, heartbeat) - those are genuine user
  /// data worth carrying to a new machine, unlike a host/port pair that's
  /// only ever meaningful on the machine that set it up.
  List<int> _sanitizeConfigForExport(List<int> rawBytes) {
    final json = jsonDecode(utf8.decode(rawBytes)) as Map<String, dynamic>;
    json.remove('mt5');
    json.remove('cdp');
    return utf8.encode('${const JsonEncoder.withIndent('  ').convert(json)}\n');
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Future<SecretKey> _deriveKey(String password, List<int> salt) {
    final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: _pbkdf2Iterations, bits: 256);
    return kdf.deriveKeyFromPassword(password: password, nonce: salt);
  }

  /// Builds the encrypted backup and writes it to [outputPath]. [appVersion]
  /// (2026-10-10, per the user: "exported file should have time stamp and
  /// app version") is embedded in a small internal manifest entry alongside
  /// the export timestamp — see [BackupMetadata]'s own doc comment for why
  /// this exists in addition to the filename the Settings screen itself
  /// stamps with the same two values. Throws on any I/O failure - the
  /// caller shows the real error, never swallows it.
  Future<void> exportTo(String outputPath, String password, {required String appVersion}) async {
    final rootDir = Directory(_storage.rootDir);
    final archive = Archive();
    if (await rootDir.exists()) {
      await for (final entity in rootDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relative = p.relative(entity.path, from: _storage.rootDir);
        if (_shouldExclude(relative)) continue;
        final bytes = relative == 'config.json'
            ? _sanitizeConfigForExport(await entity.readAsBytes())
            : await entity.readAsBytes();
        archive.addFile(ArchiveFile(relative, bytes.length, bytes));
      }
    }
    final meta = utf8.encode(
      jsonEncode({
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'app_version': appVersion,
      }),
    );
    archive.addFile(ArchiveFile(_metaEntryName, meta.length, meta));
    final zipBytes = ZipEncoder().encode(archive);

    final algorithm = AesGcm.with256bits();
    final salt = _randomBytes(16);
    final nonce = algorithm.newNonce();
    final secretKey = await _deriveKey(password, salt);
    final secretBox = await algorithm.encrypt(zipBytes, secretKey: secretKey, nonce: nonce);

    final out = BytesBuilder();
    out.add(_magic);
    out.add([_formatVersion]);
    out.add(salt);
    out.add(secretBox.nonce);
    out.add(secretBox.cipherText);
    out.add(secretBox.mac.bytes);

    final file = File(outputPath);
    await file.create(recursive: true);
    await file.writeAsBytes(out.toBytes());
  }

  /// Decrypts [inputPath] with [password] and overwrites every file it
  /// contains into [CoreStorage.rootDir] - except config.json, which is
  /// MERGED rather than overwritten wholesale (2026-10-10): the backup's
  /// own copy never has `mt5`/`cdp` (stripped at export time, see
  /// [_sanitizeConfigForExport]), so this machine's own existing connection
  /// settings are preserved untouched rather than being deleted outright.
  /// `.env` is never present in a backup at all, so it's never touched
  /// either. Returns the embedded [BackupMetadata] (null for a backup made
  /// before that field existed) so the caller can show what's actually
  /// being restored. Throws [FormatException] for a malformed/foreign
  /// file, or the underlying `cryptography` package's own authentication
  /// exception for a wrong password or tampered file - GCM's authentication
  /// tag makes "wrong password" and "corrupted file" indistinguishable from
  /// each other, which is the correct, safe behavior (never partially
  /// decrypt un-authenticated data).
  Future<BackupMetadata?> importFrom(String inputPath, String password) async {
    final bytes = await File(inputPath).readAsBytes();
    const headerLen = 4 + 1 + 16 + 12;
    const macLen = 16;
    if (bytes.length < headerLen + macLen) {
      throw const FormatException('File is too small to be a valid backup.');
    }
    if (!_bytesEqual(bytes.sublist(0, 4), _magic)) {
      throw const FormatException('Not a TradingMT5 backup file.');
    }
    final version = bytes[4];
    if (version != _formatVersion) {
      throw FormatException('Unsupported backup version: $version.');
    }
    final salt = bytes.sublist(5, 21);
    final nonce = bytes.sublist(21, headerLen);
    final cipherText = bytes.sublist(headerLen, bytes.length - macLen);
    final mac = bytes.sublist(bytes.length - macLen);

    final algorithm = AesGcm.with256bits();
    final secretKey = await _deriveKey(password, salt);
    final secretBox = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
    final zipBytes = await algorithm.decrypt(secretBox, secretKey: secretKey);

    final archive = ZipDecoder().decodeBytes(zipBytes);
    BackupMetadata? metadata;
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      if (entry.name == _metaEntryName) {
        try {
          final json = jsonDecode(utf8.decode(entry.content as List<int>)) as Map<String, dynamic>;
          metadata = BackupMetadata(
            exportedAt: DateTime.parse(json['exported_at'] as String),
            appVersion: json['app_version'] as String,
          );
        } catch (_) {
          // A manifest that fails to parse just means "unknown" to the
          // caller - never fails the whole import over a cosmetic field.
        }
        continue;
      }
      if (entry.name == 'config.json') {
        _mergeImportedConfig(entry.content as List<int>);
        continue;
      }
      final outPath = p.join(_storage.rootDir, entry.name);
      final outFile = File(outPath);
      await outFile.create(recursive: true);
      await outFile.writeAsBytes(entry.content as List<int>);
    }
    return metadata;
  }

  /// Writes the backup's config.json with THIS machine's own `mt5`/`cdp`
  /// blocks preserved (see [importFrom]'s own doc comment for why) rather
  /// than overwriting the file wholesale like every other archive entry.
  void _mergeImportedConfig(List<int> importedBytes) {
    final imported = jsonDecode(utf8.decode(importedBytes)) as Map<String, dynamic>;
    final localPath = _storage.configFile;
    final local = File(localPath).existsSync()
        ? jsonDecode(File(localPath).readAsStringSync()) as Map<String, dynamic>
        : const <String, dynamic>{};
    final merged = Map<String, dynamic>.from(imported);
    if (local['mt5'] != null) merged['mt5'] = local['mt5'];
    if (local['cdp'] != null) merged['cdp'] = local['cdp'];
    File(localPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(merged)}\n');
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
