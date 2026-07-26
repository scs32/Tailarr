import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/api/pairing/quick_connect.dart';
import 'package:lunasea/database/models/profile.dart';

void main() {
  LunaProfile profile({String host = ''}) =>
      LunaProfile()..tailarrServerHost = host;

  group('QuickConnect gate + base resolution', () {
    test('no controller grant → cannot approve, no client', () {
      final p = profile();
      expect(QuickConnect.canApprove(p), isFalse);
      expect(QuickConnect.serveBase(p), isNull);
      expect(QuickConnect.pairBase(p), isNull);
      expect(QuickConnect.clientFor(p), isNull);
    });

    test('a whitespace-only host is not a grant', () {
      expect(QuickConnect.canApprove(profile(host: '   ')), isFalse);
    });

    test('a server-badged profile approves and resolves both bases', () {
      final p = profile(host: 'https://ts.tail600657.ts.net');
      expect(QuickConnect.canApprove(p), isTrue);
      expect(QuickConnect.serveBase(p), 'https://ts.tail600657.ts.net');
      // approve leg = raw netns pairing port on the same controller host.
      expect(QuickConnect.pairBase(p), 'http://ts.tail600657.ts.net:8089');
      expect(QuickConnect.clientFor(p), isNotNull);
    });

    test('pairBase strips scheme/path and pins :8089', () {
      final p = profile(host: 'https://ts.example.ts.net/');
      expect(QuickConnect.pairBase(p), 'http://ts.example.ts.net:8089');
    });
  });
}
