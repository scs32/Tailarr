// Post-migration Hive adapter verification (hive_ce migration, PR #5).
//
// The hive_ce migration + generator bumps regenerated every Hive TypeAdapter.
// A regen that silently renumbered a typeId or reordered an enum's field bytes
// would corrupt every user's on-disk profile/notification/module state on the
// next launch — with no compile error to catch it. These tests pin the two
// things a regen must never change:
//
//   1. the stable typeIds (LunaProfile=0, LunaModule=25, LunaNotification=30)
//   2. a full write→close→reopen→read round-trip through the REAL adapters on
//      a REAL temp Hive box, so the on-disk byte mapping is exercised end to end.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
// Implementation imports (test-only): let us serialize/deserialize a value
// through an adapter to its RAW on-disk bytes, so the persisted byte mapping
// can be pinned against a frozen fixture — a same-adapter box round-trip alone
// would not catch a regen that renumbered write AND read in lockstep.
import 'package:hive_ce/src/binary/binary_reader_impl.dart';
import 'package:hive_ce/src/binary/binary_writer_impl.dart';

import 'package:lunasea/database/models/notification.dart';
import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/modules.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tailarr_hive_roundtrip');
    Hive.init(dir.path);
    if (!Hive.isAdapterRegistered(0)) Hive.registerAdapter(LunaProfileAdapter());
    if (!Hive.isAdapterRegistered(25)) {
      Hive.registerAdapter(LunaModuleAdapter());
    }
    if (!Hive.isAdapterRegistered(30)) {
      Hive.registerAdapter(LunaNotificationAdapter());
    }
  });

  tearDown(() async {
    await Hive.close();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  group('stable typeIds (a regen must never renumber these)', () {
    test('adapters carry their frozen typeIds', () {
      expect(LunaProfileAdapter().typeId, 0);
      expect(LunaModuleAdapter().typeId, 25);
      expect(LunaNotificationAdapter().typeId, 30);
    });
  });

  group('LunaProfile write→reopen→read round-trip', () {
    test('every field — including the newest HiveFields — survives disk',
        () async {
      final profile = LunaProfile(
        // Arrs + headers (low field numbers)
        sonarrEnabled: true,
        sonarrHost: 'https://sonarr.ts.net',
        sonarrKey: 'SONARR_KEY',
        sonarrHeaders: {'X-Api': 'a', 'Cookie': 'b'},
        radarrEnabled: true,
        radarrHost: 'https://radarr.ts.net',
        radarrKey: 'RADARR_KEY',
        lidarrHeaders: {'H': '1'},
        nzbgetEnabled: true,
        nzbgetUser: 'nzb',
        nzbgetPass: 'NZB_PW',
        // Tautulli / Overseerr (mid field numbers)
        tautulliEnabled: true,
        tautulliHost: 'https://tautulli.ts.net',
        tautulliKey: 'TAUT_KEY',
        overseerrEnabled: true,
        overseerrHost: 'https://requests.ts.net',
        overseerrKey: 'OVER_KEY',
        // Jellyfin (36/37)
        jellyfinEnabled: true,
        jellyfinUrl: 'https://jellyfin.ts.net',
        // Tailscale (47/48/49)
        tailscaleEnabled: true,
        tailscaleAuthKey: 'tskey-auth-SECRET',
        tailscaleIdentity: 'node-abc123',
        // Tailarr server + gateway self-config (44-54: the newest fields)
        tailarrServerEnabled: true,
        tailarrServerHost: 'https://tailarr.ts.net',
        tailarrServerHeaders: {'Authorization': 'Bearer x'},
        serverAdminToken: 'ADMIN_BEARER',
        gatewayManagedModules: ['sonarr', 'radarr', 'tailarr'],
        serverOwned: true,
        uiBasic: true,
        demo: true,
      );

      var box = await Hive.openBox<LunaProfile>('profiles');
      await box.put('p1', profile);
      await box.close();

      box = await Hive.openBox<LunaProfile>('profiles');
      final read = box.get('p1')!;

      // Low-numbered fields
      expect(read.sonarrEnabled, isTrue);
      expect(read.sonarrHost, 'https://sonarr.ts.net');
      expect(read.sonarrKey, 'SONARR_KEY');
      expect(read.sonarrHeaders, {'X-Api': 'a', 'Cookie': 'b'});
      expect(read.radarrKey, 'RADARR_KEY');
      expect(read.lidarrHeaders, {'H': '1'});
      expect(read.nzbgetPass, 'NZB_PW');
      // Mid-numbered fields
      expect(read.tautulliKey, 'TAUT_KEY');
      expect(read.overseerrHost, 'https://requests.ts.net');
      expect(read.jellyfinEnabled, isTrue);
      expect(read.jellyfinUrl, 'https://jellyfin.ts.net');
      // Tailscale
      expect(read.tailscaleAuthKey, 'tskey-auth-SECRET');
      expect(read.tailscaleIdentity, 'node-abc123');
      // Newest fields (44-54) — the ones a regen is most likely to disturb
      expect(read.tailarrServerHost, 'https://tailarr.ts.net');
      expect(read.tailarrServerHeaders, {'Authorization': 'Bearer x'});
      expect(read.serverAdminToken, 'ADMIN_BEARER');
      expect(read.gatewayManagedModules, ['sonarr', 'radarr', 'tailarr']);
      expect(read.serverOwned, isTrue);
      expect(read.uiBasic, isTrue);
      expect(read.demo, isTrue);

      // The whole structural payload is identical across the disk round-trip.
      expect(read.toJson()..remove('key'), profile.toJson()..remove('key'));
    });

    test('a default profile round-trips to its documented defaults', () async {
      var box = await Hive.openBox<LunaProfile>('profiles');
      await box.put('d', LunaProfile());
      await box.close();

      box = await Hive.openBox<LunaProfile>('profiles');
      final read = box.get('d')!;
      expect(read.sonarrEnabled, isFalse);
      expect(read.serverOwned, isFalse);
      expect(read.demo, isFalse);
      expect(read.gatewayManagedModules, isEmpty);
      expect(read.tailarrServerHeaders, isEmpty);
      expect(read.serverAdminToken, '');
    });
  });

  group('LunaModule enum adapter byte-stability', () {
    // The enum's HiveField bytes are the module identity persisted in the
    // dashboard order and quick actions. Removing REQUESTS from the enum must
    // not shift any surviving module's byte.
    test('every module value round-trips through the on-disk adapter',
        () async {
      var box = await Hive.openBox<LunaModule>('modules');
      for (final module in LunaModule.values) {
        await box.put(module.key, module);
      }
      await box.close();

      box = await Hive.openBox<LunaModule>('modules');
      for (final module in LunaModule.values) {
        expect(box.get(module.key), module,
            reason: 'module ${module.key} did not survive the disk round-trip');
      }
      // Every enum member persisted and read back to itself, 1:1.
      expect(box.length, LunaModule.values.length);
    });

    // Frozen-byte fixture. Pins the EXACT on-disk byte each module serializes
    // to, so a regen that renumbered the write and read paths in lockstep —
    // which a same-adapter box round-trip would silently pass — is caught here.
    // These bytes are the persisted module identity; changing one corrupts
    // every existing user's dashboard order / quick actions.
    const frozenBytes = <LunaModule, int>{
      LunaModule.DASHBOARD: 0,
      LunaModule.LIDARR: 1,
      LunaModule.NZBGET: 2,
      LunaModule.OVERSEERR: 3,
      LunaModule.RADARR: 4,
      LunaModule.SABNZBD: 5,
      LunaModule.SEARCH: 6,
      LunaModule.SETTINGS: 7,
      LunaModule.SONARR: 8,
      LunaModule.TAUTULLI: 9,
      LunaModule.WAKE_ON_LAN: 10,
      LunaModule.EXTERNAL_MODULES: 11,
      LunaModule.TAILARR_SERVER: 12,
      LunaModule.NOTIFICATIONS: 13,
      LunaModule.JELLYFIN: 14,
    };

    test('the fixture covers every module (no value left unpinned)', () {
      expect(frozenBytes.keys.toSet(), LunaModule.values.toSet());
    });

    test('each module serializes to its frozen byte and reads back', () {
      final adapter = LunaModuleAdapter();
      frozenBytes.forEach((module, expectedByte) {
        final writer = BinaryWriterImpl(Hive);
        adapter.write(writer, module);
        final bytes = writer.toBytes();
        expect(bytes, [expectedByte],
            reason: '${module.key} must serialize to byte $expectedByte');

        final read = adapter.read(BinaryReaderImpl(bytes, Hive));
        expect(read, module);
      });
    });
  });

  group('LunaNotification write→reopen→read round-trip', () {
    test('all fields incl. the per-profile tag survive disk', () async {
      final n = LunaNotification(
        id: 'msg-1',
        time: 1234567890,
        topic: 'tlr-media-sonarr',
        title: 'Grabbed',
        body: 'Some Show S01E01',
        priority: 5,
        tags: const ['tv', 'grab'],
        read: true,
        profile: 'server-owned-profile',
      );

      var box = await Hive.openBox<LunaNotification>('notifications');
      await box.put(LunaNotification.boxKey(n.profile, n.id), n);
      await box.close();

      box = await Hive.openBox<LunaNotification>('notifications');
      final read = box.get(LunaNotification.boxKey(n.profile, n.id))!;
      expect(read.id, 'msg-1');
      expect(read.time, 1234567890);
      expect(read.topic, 'tlr-media-sonarr');
      expect(read.title, 'Grabbed');
      expect(read.body, 'Some Show S01E01');
      expect(read.priority, 5);
      expect(read.tags, ['tv', 'grab']);
      expect(read.read, isTrue);
      expect(read.profile, 'server-owned-profile');
    });

    test('nullable title/body and defaults round-trip', () async {
      final n = LunaNotification(id: 'x', time: 1, topic: 'tlr-ops');
      var box = await Hive.openBox<LunaNotification>('notifications');
      await box.put('k', n);
      await box.close();

      box = await Hive.openBox<LunaNotification>('notifications');
      final read = box.get('k')!;
      expect(read.title, isNull);
      expect(read.body, isNull);
      expect(read.priority, 3);
      expect(read.tags, isEmpty);
      expect(read.read, isFalse);
      expect(read.profile, '');
    });
  });
}
