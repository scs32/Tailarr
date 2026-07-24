// Multiple Tailarr accounts: each server owns exactly one profile, matched
// by host, with a de-duplicated name — a second server never collides with
// or overwrites the first "Tailarr" profile.
//   flutter test integration_test/multi_server_profile_test.dart -d <sim-udid>
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/main.dart';
import 'package:lunasea/utils/profile_tools.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  var booted = false;
  Future<void> ensureBooted() async {
    if (!booted) {
      await bootstrap();
      booted = true;
    }
    await LunaBox.profiles.clear();
  }

  // Seed a server-owned profile as an invite join would.
  Future<void> seedServer(String name, String host) async {
    await LunaBox.profiles.update(
      name,
      LunaProfile(serverOwned: true, tailarrServerHost: host),
    );
  }

  testWidgets('a second distinct server gets a de-duplicated name', (t) async {
    await ensureBooted();
    const hostA = 'https://tailarr.tail95fc29.ts.net';
    const hostB = 'https://tailarr.taila06ea9.ts.net';

    // First server → clean "Tailarr".
    expect(LunaProfileTools.serverProfileName(hostA), 'Tailarr');
    await seedServer('Tailarr', hostA);

    // Second server (same controller hostname, different tailnet) → does NOT
    // reuse "Tailarr"; disambiguated by tailnet.
    final nameB = LunaProfileTools.serverProfileName(hostB);
    expect(nameB, 'Tailarr (taila06ea9)');
    expect(nameB, isNot('Tailarr'));
    await seedServer(nameB, hostB);

    // Both profiles coexist, each pointing at its own server.
    expect(LunaProfile.list, containsAll(['Tailarr', 'Tailarr (taila06ea9)']));
    expect(LunaBox.profiles.read('Tailarr')!.tailarrServerHost, hostA);
    expect(
      LunaBox.profiles.read('Tailarr (taila06ea9)')!.tailarrServerHost,
      hostB,
    );
  });

  testWidgets('a server reuses its own profile, matched by host', (t) async {
    await ensureBooted();
    const hostA = 'https://tailarr.tail95fc29.ts.net';
    const hostB = 'https://tailarr.taila06ea9.ts.net';
    await seedServer('Tailarr', hostA);
    await seedServer('Tailarr (taila06ea9)', hostB);

    // Re-joining server A finds its existing profile (trailing slash and
    // all) — no duplicate is minted.
    final reused =
        LunaProfileTools.serverOwnedProfileFor('$hostA/');
    expect(reused, isNotNull);
    expect(reused!.key, 'Tailarr');
    expect(reused.tailarrServerHost, hostA);

    // A server we haven't joined has no owned profile.
    expect(
      LunaProfileTools.serverOwnedProfileFor('https://tailarr.tailZZZZ.ts.net'),
      isNull,
    );
  });

  testWidgets('a third server on a taken base+tailnet falls back to a number',
      (t) async {
    await ensureBooted();
    await seedServer('Tailarr', 'https://tailarr.tail95fc29.ts.net');
    await seedServer('Tailarr (tail95fc29)', 'https://other.tail95fc29.ts.net');

    // Another "tailarr" host on the SAME tailnet can't take base or
    // base+tailnet — numeric fallback keeps it distinct.
    final name = LunaProfileTools.serverProfileName(
      'https://tailarr.tail95fc29.ts.net',
    );
    // (Same host would normally reuse; this exercises the pure namer's
    // numeric branch when both base and base+tailnet are occupied.)
    expect(name, 'Tailarr 2');
  });
}
