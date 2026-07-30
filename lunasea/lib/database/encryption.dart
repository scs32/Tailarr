import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// At-rest encryption for the Hive database (security audit M2).
///
/// A 256-bit AES key is generated once and stored in the platform secure
/// enclave (iOS Keychain / Android Keystore / libsecret / DPAPI) via
/// flutter_secure_storage — NEVER in Hive itself, and never derived from
/// anything guessable. All boxes are then opened with a [HiveAesCipher], so
/// service API keys, the NZBGet password, and the ntfy + Tailscale keys are
/// ciphertext on disk instead of plaintext.
class LunaEncryption {
  LunaEncryption._();

  static const _keyName = 'tailarr_hive_key_v1';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    // Accessible after the first unlock so a foregrounded app (and any future
    // Hive access from a background task) can read it; not synced off-device
    // by default.
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// Whether a key already exists. False on the very first launch after
  /// encryption ships — the signal that an existing PLAINTEXT database must be
  /// migrated before the boxes are opened with the cipher.
  static Future<bool> hasKey() => _storage.containsKey(key: _keyName);

  /// The persisted key, creating and storing a fresh 256-bit key on first use.
  static Future<Uint8List> getOrCreateKey() async {
    final existing = await _storage.read(key: _keyName);
    if (existing != null) return Uint8List.fromList(base64Decode(existing));
    final key = Hive.generateSecureKey();
    await _storage.write(key: _keyName, value: base64Encode(key));
    return Uint8List.fromList(key);
  }

  static HiveCipher cipher(Uint8List key) => HiveAesCipher(key);
}

/// One-time migration of an existing PLAINTEXT Hive database to encryption.
///
/// Runs only on the first launch after encryption is introduced (gated by the
/// absence of the secure-storage key). Per box: open plaintext → snapshot →
/// delete the plaintext file → reopen with the cipher → restore. A fresh
/// install has no box files, so nothing runs; an already-encrypted install
/// never reaches here (the key exists).
///
/// Pure of secure-storage so it is unit-testable with an injected cipher.
class LunaHiveMigration {
  LunaHiveMigration._();

  static Future<void> encryptExistingBoxes({
    required List<String> boxNames,
    required HiveCipher cipher,
    String? path,
  }) async {
    for (final name in boxNames) {
      await _encryptBox(name, cipher, path);
    }
  }

  static Future<void> _encryptBox(
    String name,
    HiveCipher cipher,
    String? path,
  ) async {
    if (!await Hive.boxExists(name, path: path)) return;

    // Read the plaintext box (dynamic — adapters deserialize each value by its
    // typeId regardless of the box's generic type).
    final plain = await Hive.openBox<dynamic>(name, path: path);
    final snapshot = Map<dynamic, dynamic>.from(plain.toMap());

    // A HiveObject can't be stored in two boxes, and values loaded here still
    // carry their (soon-deleted) box association — putAll would throw. Detach
    // each by deleting it from the plaintext box; the in-memory object keeps
    // its fields for re-serialization into the encrypted box.
    for (final value in snapshot.values) {
      if (value is HiveObject && value.isInBox) {
        await value.delete();
      }
    }
    await plain.close();

    // Drop the plaintext file, then re-create the box encrypted and restore.
    await Hive.deleteBoxFromDisk(name, path: path);
    final encrypted = await Hive.openBox<dynamic>(
      name,
      encryptionCipher: cipher,
      path: path,
    );
    await encrypted.putAll(snapshot);
    await encrypted.close();
  }
}
