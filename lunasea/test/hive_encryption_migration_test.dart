// M2 (security audit): the one-time plaintext→encrypted Hive migration. Runs on
// a real temp Hive with the real adapters and an injected cipher — proves user
// data survives AND that secrets go from plaintext to ciphertext on disk. The
// only part NOT covered here is the Keychain key storage (LunaEncryption), which
// needs on-device verification.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:lunasea/database/encryption.dart';
import 'package:lunasea/database/models/notification.dart';
import 'package:lunasea/database/models/profile.dart';

void main() {
  late Directory dir;
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 7));
  final cipher = HiveAesCipher(key);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tailarr_enc');
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(LunaProfileAdapter());
    if (!Hive.isAdapterRegistered(30)) {
      Hive.registerAdapter(LunaNotificationAdapter());
    }
  });

  tearDown(() async {
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('migrates plaintext boxes to encrypted, preserving all data', () async {
    // Seed PLAINTEXT boxes carrying secrets (typed HiveObject boxes + the
    // dynamic lunasea box).
    final profiles = await Hive.openBox<LunaProfile>('profiles');
    await profiles.put(
      'default',
      LunaProfile(
        sonarrHost: 'https://sonarr.ts.net',
        sonarrKey: 'SECRET_APIKEY',
        nzbgetUser: 'nzb',
        nzbgetPass: 'PLAINTEXT_PW',
        tailscaleAuthKey: 'tskey-auth-SECRET',
      ),
    );
    await profiles.close();

    final lunasea = await Hive.openBox<dynamic>('lunasea');
    await lunasea.put('NOTIFICATIONS_TOKEN@default', 'tk_SECRETTOKEN');
    await lunasea.put('SOME_INT', 42);
    await lunasea.close();

    final notifications = await Hive.openBox<LunaNotification>('notifications');
    await notifications.put(
      'default abc',
      LunaNotification(id: 'abc', time: 1, topic: 'tlr-ops', profile: 'default'),
    );
    await notifications.close();

    // Precondition: the secret is plaintext on disk.
    final rawBefore = await File('${dir.path}/profiles.hive').readAsBytes();
    expect(String.fromCharCodes(rawBefore).contains('SECRET_APIKEY'), isTrue);

    // MIGRATE.
    await LunaHiveMigration.encryptExistingBoxes(
      boxNames: ['profiles', 'lunasea', 'notifications'],
      cipher: cipher,
      path: dir.path,
    );

    // The secret is no longer plaintext on disk.
    final rawAfter = await File('${dir.path}/profiles.hive').readAsBytes();
    expect(String.fromCharCodes(rawAfter).contains('SECRET_APIKEY'), isFalse,
        reason: 'profile box must be ciphertext after migration');
    final rawLuna = await File('${dir.path}/lunasea.hive').readAsBytes();
    expect(String.fromCharCodes(rawLuna).contains('tk_SECRETTOKEN'), isFalse,
        reason: 'lunasea box must be ciphertext after migration');

    // Data round-trips when opened WITH the cipher.
    final p =
        await Hive.openBox<LunaProfile>('profiles', encryptionCipher: cipher);
    final prof = p.get('default')!;
    expect(prof.sonarrKey, 'SECRET_APIKEY');
    expect(prof.nzbgetPass, 'PLAINTEXT_PW');
    expect(prof.tailscaleAuthKey, 'tskey-auth-SECRET');
    await p.close();

    final l = await Hive.openBox<dynamic>('lunasea', encryptionCipher: cipher);
    expect(l.get('NOTIFICATIONS_TOKEN@default'), 'tk_SECRETTOKEN');
    expect(l.get('SOME_INT'), 42);
    await l.close();

    final n = await Hive.openBox<LunaNotification>('notifications',
        encryptionCipher: cipher);
    expect(n.get('default abc')!.profile, 'default');
    await n.close();
  });

  test('is a no-op on a fresh install (no box files)', () async {
    await LunaHiveMigration.encryptExistingBoxes(
      boxNames: ['profiles'],
      cipher: cipher,
      path: dir.path,
    );
    expect(await Hive.boxExists('profiles', path: dir.path), isFalse);
  });
}
