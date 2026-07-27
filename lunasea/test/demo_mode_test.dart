// Demo mode: the fixture-routing table (which endpoint → which bundled asset)
// and the demo profile shape. The adapter's fetch() itself is exercised
// visually on the sim; here we lock the pure routing + profile invariants.
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/system/demo/demo.dart';
import 'package:lunasea/system/demo/demo_adapter.dart';

void main() {
  group('DemoAdapter.assetFor', () {
    test('Radarr movies grid → the movies fixture', () {
      expect(DemoAdapter.assetFor('/api/v3/movie', null),
          'assets/demo/radarr/movies.json');
    });

    test('Sonarr series grid → the series fixture', () {
      expect(DemoAdapter.assetFor('/api/v3/series', null),
          'assets/demo/sonarr/series.json');
    });

    test('shared /api/v3/qualityprofile → one fixture for both *arr', () {
      expect(DemoAdapter.assetFor('/api/v3/qualityprofile', null),
          'assets/demo/arr/qualityprofile.json');
    });

    test('object endpoints (queue / wanted-missing) → a paged-empty object', () {
      expect(DemoAdapter.assetFor('/api/v3/queue', null),
          'assets/demo/arr/page_empty.json');
      expect(DemoAdapter.assetFor('/api/v3/wanted/missing', null),
          'assets/demo/arr/page_empty.json');
    });

    test('Tautulli is matched on ?cmd=, not path', () {
      expect(DemoAdapter.assetFor('/api/v2/', 'get_activity'),
          'assets/demo/tautulli/activity.json');
      expect(DemoAdapter.assetFor('/api/v2/', 'get_history'),
          'assets/demo/tautulli/history.json');
    });

    test('unknown Tautulli cmd and unknown path → unmapped (null)', () {
      expect(DemoAdapter.assetFor('/api/v2/', 'get_something_else'), isNull);
      expect(DemoAdapter.assetFor('/api/v3/movie/1/delete', null), isNull);
    });
  });

  group('DemoMode.build', () {
    test('is a read-only, name-locked demo profile', () {
      final p = DemoMode.build();
      expect(p.demo, isTrue);
      expect(p.sonarrEnabled, isTrue);
      expect(p.radarrEnabled, isTrue);
      expect(p.tautulliEnabled, isTrue);
      expect(p.sonarrHost, DemoMode.host);
      // Server-driven-shaped so screens render managed (no manual editors).
      expect(p.gatewayManagedModules, containsAll(['sonarr', 'radarr', 'tautulli']));
    });
  });
}
