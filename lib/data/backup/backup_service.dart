import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import '../../core/core_storage.dart';

/// Settings screen "Backup & Restore" (2026-10-03, per the user: "export
/// setting and all data related to current user ... user does not need to
/// start from scratch. once data imported, everything is settled and user
/// can continue from the timestamp of file extraction date" + "the
/// exported file should be encrypted, with high security level") — zips
/// every file under [CoreStorage.rootDir] (config.json, .env, and
/// everything in logs/ - auto-managed state, trade history, pending
/// signals, volume overrides, the lot) except process-specific or purely
/// diagnostic files that mean nothing on a different machine, then
/// encrypts the whole zip with a password the user chooses at export time.
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

  /// Transient, process-specific, or purely diagnostic files that are
  /// meaningless (or actively wrong) to carry over to a different machine
  /// or a later run of this same one.
  bool _shouldExclude(String relativePath) {
    final name = p.basename(relativePath);
    if (name == 'heartbeat' || name == 'engine.pid') return true;
    if (RegExp(r'^engine(\..*)?\.log$').hasMatch(name)) return true;
    // Never zip up the backups folder itself - [CoreStorage.backupsDir]
    // lives inside rootDir, so without this a later export would include
    // every earlier backup file too, growing unboundedly.
    final normalized = p.split(relativePath);
    if (normalized.isNotEmpty && normalized.first == 'backups') return true;
    return false;
  }

  List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  Future<SecretKey> _deriveKey(String password, List<int> salt) {
    final kdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: _pbkdf2Iterations, bits: 256);
    return kdf.deriveKeyFromPassword(password: password, nonce: salt);
  }

  /// Builds the encrypted backup and writes it to [outputPath]. Throws on
  /// any I/O failure - the caller shows the real error, never swallows it.
  Future<void> exportTo(String outputPath, String password) async {
    final rootDir = Directory(_storage.rootDir);
    final archive = Archive();
    if (await rootDir.exists()) {
      await for (final entity in rootDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final relative = p.relative(entity.path, from: _storage.rootDir);
        if (_shouldExclude(relative)) continue;
        final bytes = await entity.readAsBytes();
        archive.addFile(ArchiveFile(relative, bytes.length, bytes));
      }
    }
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
  /// contains into [CoreStorage.rootDir]. Throws [FormatException] for a
  /// malformed/foreign file, or the underlying `cryptography` package's own
  /// authentication exception for a wrong password or tampered file -
  /// GCM's authentication tag makes "wrong password" and "corrupted file"
  /// indistinguishable from each other, which is the correct, safe
  /// behavior (never partially decrypt un-authenticated data).
  Future<void> importFrom(String inputPath, String password) async {
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
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final outPath = p.join(_storage.rootDir, entry.name);
      final outFile = File(outPath);
      await outFile.create(recursive: true);
      await outFile.writeAsBytes(entry.content as List<int>);
    }
  }

  bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
