// Log redaction: credentials must never reach a stored/exported/screenshotted
// log line. The Arrs/Tautulli/SABnzbd carry apikey in the query string and
// NZBGet carries user:password in the path, so a failed-request DioException
// string is the main leak vector.
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/system/log_redactor.dart';

void main() {
  group('LogRedactor.scrub', () {
    test('redacts an apikey query parameter (Arr / Tautulli / SABnzbd)', () {
      const raw = 'DioException [connection error]: uri = '
          'https://radarr.tail600657.ts.net/api/v3/movie?apikey=abc123SECRET&pageSize=20';
      final out = LogRedactor.scrub(raw);
      expect(out.contains('abc123SECRET'), isFalse);
      expect(out.contains('apikey=<redacted>'), isTrue);
      // Non-secret query params are preserved.
      expect(out.contains('pageSize=20'), isTrue);
    });

    test('redacts api_key / token / password variants', () {
      expect(LogRedactor.scrub('x?api_key=SEKRIT'), contains('api_key=<redacted>'));
      expect(LogRedactor.scrub('x?token=tOkEnVal&a=1'),
          allOf(contains('token=<redacted>'), contains('a=1')));
      expect(LogRedactor.scrub('x?password=hunter2'),
          isNot(contains('hunter2')));
    });

    test("redacts NZBGet's user:password path credentials", () {
      const raw = 'HttpException connecting to '
          'http://box.tail600657.ts.net:6789/nzbadmin:s3cretPass/jsonrpc/';
      final out = LogRedactor.scrub(raw);
      expect(out.contains('s3cretPass'), isFalse);
      expect(out.contains('nzbadmin'), isFalse);
      expect(out.contains('/<redacted>/jsonrpc'), isTrue);
    });

    test('redacts standard URL userinfo', () {
      final out = LogRedactor.scrub('https://user:p4ssw0rd@host.example/path');
      expect(out.contains('p4ssw0rd'), isFalse);
      expect(out.contains(':<redacted>@'), isTrue);
    });

    test('redacts a Tailscale auth key', () {
      final out =
          LogRedactor.scrub('start failed key=tskey-auth-kAbC123-deadBeef99');
      expect(out.contains('kAbC123-deadBeef99'), isFalse);
      expect(out.contains('tskey-<redacted>'), isTrue);
    });

    test('redacts an ntfy token and Bearer header', () {
      expect(LogRedactor.scrub('token tk_jlwm13ca86zm18zq'),
          allOf(isNot(contains('jlwm13ca86zm18zq')), contains('tk_<redacted>')));
      expect(LogRedactor.scrub('Authorization: Bearer eyJhbGc.payload.sig'),
          allOf(isNot(contains('eyJhbGc.payload.sig')),
              contains('Bearer <redacted>')));
    });

    test('leaves clean strings — including the CONNECT-tunnel URI — untouched',
        () {
      // The proxy 502 line the user screenshotted carries no secret.
      const clean = 'HttpException: Proxy failed to establish tunnel '
          '(502 Bad Gateway), uri = //radarr.tail600657.ts.net:443';
      expect(LogRedactor.scrub(clean), clean);
      expect(LogRedactor.scrub('An Error Has Occurred'), 'An Error Has Occurred');
    });

    test('is idempotent — safe to re-scrub on export', () {
      const raw = 'uri=https://s/api?apikey=SECRET';
      final once = LogRedactor.scrub(raw);
      expect(LogRedactor.scrub(once), once);
    });
  });
}
