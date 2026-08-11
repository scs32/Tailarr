import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/extensions/string/links.dart';
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

    setUp(() {
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

    tearDown(resetLinkDispatchForTesting);

    test('a tailnet URL goes to the in-app browser, not the system one',
        () async {
      await 'https://sonarr.tail95fc29.ts.net'.openLink();
      expect(tailnet, ['https://sonarr.tail95fc29.ts.net']);
      expect(system, isEmpty);
    });

    test('CONTROL: a public URL still goes to the system browser', () async {
      await 'https://github.com/scs32/Tailarr'.openLink();
      expect(system, ['https://github.com/scs32/Tailarr']);
      expect(tailnet, isEmpty);
    });

    test('a blocked scheme reaches neither opener', () async {
      await 'tailarr:///import#payload'.openLink();
      expect(tailnet, isEmpty);
      expect(system, isEmpty);
    });

    test(
        'when the in-app browser cannot be presented, the system opener is '
        'still tried rather than failing silently', () async {
      tailnetLinkOpener = (url) async {
        tailnet.add(url);
        return false;
      };
      await 'https://sonarr.tail95fc29.ts.net'.openLink();
      expect(tailnet, ['https://sonarr.tail95fc29.ts.net']);
      expect(system, ['https://sonarr.tail95fc29.ts.net']);
    });

    test('with no in-app browser registered, a tailnet URL falls back',
        () async {
      tailnetLinkOpener = null;
      await 'https://sonarr.tail95fc29.ts.net'.openLink();
      expect(system, ['https://sonarr.tail95fc29.ts.net']);
    });

    test('a thrown launch failure is caught, not propagated', () async {
      debugSystemLinkOpener = (url) async => throw StateError('no handler');
      await expectLater(
        'https://github.com/scs32/Tailarr'.openLink(),
        completes,
      );
    });
  });
}
