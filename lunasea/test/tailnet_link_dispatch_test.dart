import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/models/log.dart';
import 'package:lunasea/extensions/string/links.dart';
import 'package:lunasea/types/log_type.dart';
import 'package:lunasea/utils/link_dispatch.dart';
import 'package:lunasea/utils/tailnet.dart';

/// "Open web GUI" was broken because `url_launcher` hands the URL to Safari —
/// a different process, with no view of this isolate's `HttpOverrides` and no
/// system-wide MagicDNS. These tests lock the routing decision that fixes it,
/// and — just as importantly — lock that NOTHING ELSE gets diverted.
void main() {
  group('isTailnetUrl', () {
    test('MagicDNS hosts are tailnet', () {
      expect(isTailnetUrl('https://sonarr.tail95fc29.ts.net'), isTrue);
      expect(isTailnetUrl('https://sonarr.tail95fc29.ts.net/activity/queue'),
          isTrue);
      // Case and a trailing root dot must not defeat it.
      expect(isTailnetUrl('HTTPS://Sonarr.Tail95FC29.TS.NET'), isTrue);
      expect(isTailnetUrl('https://sonarr.tail95fc29.ts.net./'), isTrue);
      // Explicit port is still a tailnet host.
      expect(isTailnetUrl('http://radarr.tail95fc29.ts.net:7878'), isTrue);
    });

    test('tailnet IP literals are tailnet', () {
      expect(isTailnetUrl('http://100.64.0.1:8989'), isTrue);
      expect(isTailnetUrl('http://100.110.34.30'), isTrue);
      expect(isTailnetUrl('http://100.127.255.254'), isTrue);
      expect(isTailnetUrl('http://[fd7a:115c:a1e0::1]'), isTrue);
    });

    test('CONTROL: public and LAN destinations are NOT tailnet', () {
      // ⚠️ Without this, "route everything through the proxy" would pass the
      // suite trivially while dragging every docs link into a webview.
      expect(isTailnetUrl('https://github.com/scs32/Tailarr'), isFalse);
      expect(isTailnetUrl('https://www.tailarr.com/docs'), isFalse);
      expect(isTailnetUrl('https://tailscale.com/kb'), isFalse);
      expect(isTailnetUrl('https://www.themoviedb.org/movie/1'), isFalse);
      expect(isTailnetUrl('http://192.168.1.50:8989'), isFalse);
      expect(isTailnetUrl('http://10.0.0.5'), isFalse);
      // Just outside 100.64.0.0/10 on either side.
      expect(isTailnetUrl('http://100.63.255.255'), isFalse);
      expect(isTailnetUrl('http://100.128.0.1'), isFalse);
      // Not a *.ts.net label boundary, and not the public apex.
      expect(isTailnetUrl('https://notts.net'), isFalse);
      expect(isTailnetUrl('https://ts.net'), isFalse);
      // A ts.net string that is not the HOST must not match.
      expect(isTailnetUrl('https://evil.example.com/?x=a.ts.net'), isFalse);
      // Non-http schemes never route anywhere.
      expect(isTailnetUrl('ftp://sonarr.tail95fc29.ts.net'), isFalse);
      expect(isTailnetUrl('not a url'), isFalse);
    });
  });

  group('linkDestinationFor', () {
    test('tailnet → in-app browser, everything else → system browser', () {
      expect(
        linkDestinationFor('https://sonarr.tail95fc29.ts.net'),
        LinkDestination.tailnetBrowser,
      );
      expect(
        linkDestinationFor('https://github.com/scs32/Tailarr'),
        LinkDestination.systemBrowser,
      );
    });
  });

  group('openLink dispatch', () {
    late List<String> tailnet;
    late List<String> system;
    late Directory dir;

    // `openLink` logs through LunaLogger, which writes to the `logs` Hive box.
    // The box must be REAL here, for two reasons:
    //
    //  1. Without it every fallback/failure path throws
    //     `HiveError: Box not found` — asynchronously, out of
    //     `LunaBox.create`'s `async` body — which no try/catch at the call
    //     site can absorb, so it surfaces as an unhandled error and fails the
    //     test. That is a harness gap, not a product defect.
    //  2. With it, the logging becomes ASSERTABLE. These tests exist because
    //     the bug failed as an *apparent success* — nothing logged, nothing
    //     shown — so "a failure is actually reported" is the property under
    //     test, and it is now checked against the real log records.
    //
    // Same shape as test/hive_adapter_roundtrip_test.dart: real temp dir,
    // real adapters, closed and deleted in tearDown.
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tailarr_link_dispatch');
      Hive.init(dir.path);
      if (!Hive.isAdapterRegistered(23)) Hive.registerAdapter(LunaLogAdapter());
      if (!Hive.isAdapterRegistered(24)) {
        Hive.registerAdapter(LunaLogTypeAdapter());
      }
      await Hive.openBox<LunaLog>(LunaBox.logs.key);

      tailnet = [];
      system = [];
      tailnetLinkOpener = (url) async {
        tailnet.add(url);
        return true;
      };
      debugSystemLinkOpener = (url) async {
        system.add(url);
        return true;
      };
    });

    tearDown(() async {
      resetLinkDispatchForTesting();
      await Hive.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    /// The logger fires `LunaBox.logs.create` without awaiting it (that is
    /// exactly why the un-opened box failed asynchronously), so let the write
    /// settle before reading. Polls only while EMPTY — a path that logs
    /// nothing waits the full budget and then fails its expectation, so this
    /// cannot manufacture a pass in either direction.
    Future<List<LunaLog>> settledLogs() async {
      for (var i = 0; i < 50 && LunaBox.logs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      return LunaBox.logs.data.toList();
    }

    test('a tailnet URL goes to the in-app browser, not the system one',
        () async {
      await 'https://sonarr.tail95fc29.ts.net'.openLink();
      expect(tailnet, ['https://sonarr.tail95fc29.ts.net']);
      expect(system, isEmpty);
      // A success is silent — the warnings below must mean something.
      expect(await settledLogs(), isEmpty);
    });

    test('CONTROL: a public URL still goes to the system browser', () async {
      await 'https://github.com/scs32/Tailarr'.openLink();
      expect(system, ['https://github.com/scs32/Tailarr']);
      expect(tailnet, isEmpty);
      expect(await settledLogs(), isEmpty);
    });

    test('a blocked scheme reaches neither opener, and IS logged', () async {
      await 'tailarr:///import#payload'.openLink();
      expect(tailnet, isEmpty);
      expect(system, isEmpty);

      final logs = await settledLogs();
      expect(logs, hasLength(1));
      expect(logs.single.type, LunaLogType.WARNING);
      expect(logs.single.message, contains('Refused to open'));
    });

    test(
        'when the in-app browser cannot be presented, the system opener is '
        'still tried AND the fallback is reported', () async {
      tailnetLinkOpener = (url) async {
        tailnet.add(url);
        return false;
      };
      await 'https://sonarr.tail95fc29.ts.net'.openLink();
      expect(tailnet, ['https://sonarr.tail95fc29.ts.net']);
      expect(system, ['https://sonarr.tail95fc29.ts.net']);

      // The original bug was an APPARENT SUCCESS: Safari opened, nothing was
      // logged, the user got a bare DNS error. A silent fallback here would
      // reproduce exactly that, so the warning is the assertion.
      final logs = await settledLogs();
      expect(logs, hasLength(1));
      expect(logs.single.type, LunaLogType.WARNING);
      expect(logs.single.message, contains('could not be presented'));
      expect(logs.single.message, contains('MagicDNS'));
    });

    test('with no in-app browser registered, the fallback is reported',
        () async {
      tailnetLinkOpener = null;
      await 'https://sonarr.tail95fc29.ts.net'.openLink();
      expect(system, ['https://sonarr.tail95fc29.ts.net']);

      final logs = await settledLogs();
      expect(logs, hasLength(1));
      expect(logs.single.type, LunaLogType.WARNING);
      expect(logs.single.message, contains('No in-app tailnet browser'));
    });

    test('a platform refusal is reported, not swallowed', () async {
      // url_launcher returning false used to return silently: no throw, no
      // log, no message.
      debugSystemLinkOpener = (url) async => false;
      await 'https://github.com/scs32/Tailarr'.openLink();

      final logs = await settledLogs();
      expect(logs, hasLength(1));
      expect(logs.single.type, LunaLogType.WARNING);
      expect(logs.single.message, contains('declined'));
    });

    test('a thrown launch failure is caught AND recorded as an error',
        () async {
      debugSystemLinkOpener = (url) async => throw StateError('no handler');
      await expectLater(
        'https://github.com/scs32/Tailarr'.openLink(),
        completes,
      );

      final logs = await settledLogs();
      expect(logs, hasLength(1));
      expect(logs.single.type, LunaLogType.ERROR);
      expect(logs.single.message, contains('Unable to open URL'));
      expect(logs.single.error, contains('no handler'));
    });
  });
}
