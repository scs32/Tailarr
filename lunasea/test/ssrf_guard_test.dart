// The SSRF address classifier for Test Connection. Locks the key decision:
// block only addresses a Tailarr service never lives at (loopback / link-local
// / metadata / multicast / unspecified) while ALLOWING LAN + tailnet + public —
// blocking private ranges would break the whole app.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/system/security/ssrf_guard.dart';

void main() {
  group('SsrfGuard.isBlockedAddress', () {
    void blocked(String ip) => test('blocks $ip', () {
          expect(SsrfGuard.isBlockedAddress(InternetAddress(ip)), isTrue);
        });
    void allowed(String ip) => test('allows $ip', () {
          expect(SsrfGuard.isBlockedAddress(InternetAddress(ip)), isFalse);
        });

    // Never a legitimate Tailarr service.
    blocked('127.0.0.1'); // loopback
    blocked('::1'); // loopback v6
    blocked('169.254.169.254'); // link-local — cloud-metadata crown jewel
    blocked('169.254.0.1'); // link-local
    blocked('0.0.0.0'); // unspecified
    blocked('::'); // unspecified v6
    blocked('224.0.0.1'); // multicast

    // Real Tailarr services live here — must stay allowed.
    allowed('10.0.0.5'); // RFC1918 LAN
    allowed('172.16.4.20'); // RFC1918 LAN
    allowed('192.168.1.50'); // RFC1918 LAN
    allowed('100.64.0.1'); // tailnet CGNAT
    allowed('100.110.34.30'); // tailnet CGNAT
    allowed('8.8.8.8'); // public
    allowed('1.1.1.1'); // public
  });
}
