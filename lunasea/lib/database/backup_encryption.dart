import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart';

/// Whole-backup encryption (M3). A device backup is a user-shareable file that
/// still carries live service API keys (Sonarr/Radarr/… keys are kept so a
/// restore actually works — see [LunaConfig.export]). Stripping them is not an
/// option, so instead the ENTIRE payload is encrypted with a user passphrase
/// before it ever leaves the app.
///
/// Format: AES-256-GCM (authenticated — a wrong passphrase or a tampered file
/// fails the tag check and throws, which the restore UI surfaces as "Incorrect
/// encryption key"). The key is derived from the passphrase with PBKDF2 over a
/// per-backup random salt, so two backups with the same passphrase are not
/// linkable and an offline guess costs the full KDF. The salt + nonce are
/// stored in the clear alongside the ciphertext (standard practice — they are
/// not secret) inside a small JSON envelope.
class LunaBackupEncryption {
  LunaBackupEncryption._();

  /// Envelope marker key — its presence is how [isEncrypted] tells an encrypted
  /// backup from a legacy plaintext one (a legacy backup is the bare config
  /// map, which never carries this key).
  static const String markerKey = 'tailarr_encrypted_backup';

  /// Envelope schema version, so a future format change can be detected.
  static const int version = 1;

  static const int _keyLength = 32; // AES-256
  static const int _iterations = 100000;
  static const int _saltLength = 16;
  static const int _ivLength = 12; // GCM nonce

  /// Encrypt [plaintext] (the JSON config) under [passphrase], returning the
  /// JSON envelope string to write to the `.lunasea` file.
  static String encrypt(String plaintext, String passphrase) {
    final salt = SecureRandom(_saltLength).bytes;
    final iv = IV.fromSecureRandom(_ivLength);
    final key = _deriveKey(passphrase, salt, _iterations, _keyLength);
    final encrypter = Encrypter(AES(key, mode: AESMode.gcm));
    final encrypted = encrypter.encrypt(plaintext, iv: iv);
    return json.encode({
      markerKey: version,
      'cipher': 'aes-256-gcm',
      'kdf': 'pbkdf2-hmac-sha1',
      'iterations': _iterations,
      'keyLength': _keyLength,
      'salt': base64.encode(salt),
      'iv': base64.encode(iv.bytes),
      'data': encrypted.base64,
    });
  }

  /// Whether [contents] is an encrypted Tailarr backup envelope (vs. a legacy
  /// plaintext config). Robust to non-JSON input — returns false.
  static bool isEncrypted(String contents) {
    try {
      final decoded = json.decode(contents);
      return decoded is Map && decoded.containsKey(markerKey);
    } catch (_) {
      return false;
    }
  }

  /// Decrypt an envelope produced by [encrypt]. Throws on a wrong passphrase or
  /// a corrupt/tampered file (GCM tag mismatch) — the caller shows the retry
  /// prompt. Throws [FormatException] on a structurally-invalid envelope.
  static String decrypt(String contents, String passphrase) {
    final Map<String, dynamic> env;
    try {
      final decoded = json.decode(contents);
      if (decoded is! Map<String, dynamic> || decoded[markerKey] == null) {
        throw const FormatException('Backup is not an encrypted Tailarr file.');
      }
      env = decoded;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Backup is not an encrypted Tailarr file.');
    }
    final salt = base64.decode(env['salt'] as String);
    final iv = IV(base64.decode(env['iv'] as String));
    final iterations = (env['iterations'] as num?)?.toInt() ?? _iterations;
    final keyLength = (env['keyLength'] as num?)?.toInt() ?? _keyLength;
    final key = _deriveKey(passphrase, salt, iterations, keyLength);
    final encrypter = Encrypter(AES(key, mode: AESMode.gcm));
    // A wrong passphrase makes the GCM tag check fail → pointycastle throws.
    return encrypter.decrypt(
      Encrypted.fromBase64(env['data'] as String),
      iv: iv,
    );
  }

  static Key _deriveKey(
    String passphrase,
    Uint8List salt,
    int iterations,
    int keyLength,
  ) {
    return Key.fromUtf8(passphrase)
        .stretch(keyLength, iterationCount: iterations, salt: salt);
  }
}
