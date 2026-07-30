import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/database/backup_encryption.dart';

void main() {
  const passphrase = 'correct horse battery';
  const plaintext =
      '{"profiles":[{"sonarrKey":"abc123","radarrKey":"def456"}],"indexers":[]}';

  group('LunaBackupEncryption (M3)', () {
    test('encrypt → decrypt round-trips the payload', () {
      final envelope = LunaBackupEncryption.encrypt(plaintext, passphrase);
      final restored = LunaBackupEncryption.decrypt(envelope, passphrase);
      expect(restored, plaintext);
    });

    test('the envelope is not plaintext and hides the service keys', () {
      final envelope = LunaBackupEncryption.encrypt(plaintext, passphrase);
      // The whole point of M3: no service secret survives in the clear.
      expect(envelope.contains('abc123'), isFalse);
      expect(envelope.contains('def456'), isFalse);
      expect(envelope.contains('sonarrKey'), isFalse);
    });

    test('a wrong passphrase fails the GCM tag check and throws', () {
      final envelope = LunaBackupEncryption.encrypt(plaintext, passphrase);
      expect(
        () => LunaBackupEncryption.decrypt(envelope, 'wrong passphrase'),
        throwsA(anything),
      );
    });

    test('a tampered ciphertext throws (authenticated encryption)', () {
      final env =
          json.decode(LunaBackupEncryption.encrypt(plaintext, passphrase))
              as Map<String, dynamic>;
      // Flip the last base64 char of the ciphertext.
      final data = env['data'] as String;
      env['data'] = data.substring(0, data.length - 2) +
          (data.endsWith('A=') ? 'B=' : 'A=');
      expect(
        () => LunaBackupEncryption.decrypt(json.encode(env), passphrase),
        throwsA(anything),
      );
    });

    test('two backups of the same data use a fresh salt + IV', () {
      final a = LunaBackupEncryption.encrypt(plaintext, passphrase);
      final b = LunaBackupEncryption.encrypt(plaintext, passphrase);
      final ea = json.decode(a) as Map<String, dynamic>;
      final eb = json.decode(b) as Map<String, dynamic>;
      expect(ea['salt'], isNot(eb['salt']));
      expect(ea['iv'], isNot(eb['iv']));
      expect(ea['data'], isNot(eb['data']));
    });

    group('isEncrypted', () {
      test('detects an encrypted envelope', () {
        final envelope = LunaBackupEncryption.encrypt(plaintext, passphrase);
        expect(LunaBackupEncryption.isEncrypted(envelope), isTrue);
      });

      test('treats a legacy plaintext backup as not encrypted', () {
        // Backward-compat: build-39-and-earlier backups import directly.
        expect(LunaBackupEncryption.isEncrypted(plaintext), isFalse);
      });

      test('is robust to non-JSON input', () {
        expect(LunaBackupEncryption.isEncrypted('not json at all'), isFalse);
        expect(LunaBackupEncryption.isEncrypted(''), isFalse);
      });
    });

    test('decrypting a non-envelope throws FormatException', () {
      expect(
        () => LunaBackupEncryption.decrypt(plaintext, passphrase),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
