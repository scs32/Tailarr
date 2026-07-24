// Server-owned profile naming: derivation from a Tailarr Server host and
// collision handling. Pure — no Hive (the naming helper reads LunaProfile.list
// only for dedupe, which is empty in a unit context).
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/utils/profile_tools.dart';

void main() {
  group('serverProfileName', () {
    test('derives a clean name from the server host', () {
      expect(
        LunaProfileTools.serverProfileBaseName(
            'https://tailarr.tail95fc29.ts.net'),
        'Tailarr',
      );
    });

    test('handles a bare host without a scheme', () {
      expect(
        LunaProfileTools.serverProfileBaseName('tailarr.taila06ea9.ts.net'),
        'Tailarr',
      );
    });

    test('falls back gracefully on an empty/odd host', () {
      expect(LunaProfileTools.serverProfileBaseName(''), 'Tailarr');
    });
  });
}
