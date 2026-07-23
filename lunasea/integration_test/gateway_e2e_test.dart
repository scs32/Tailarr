// LIVE end-to-end of the notifications self-config path (server v0.21.0+):
// enroll the embedded node with a person-bound key, fetch credentials from
// the tailarr-gate gateway, auto-configure the notifications module, have
// the server publish a test message, and poll it back through ntfy.
//
// Run (simulator):
//   flutter test integration_test/gateway_e2e_test.dart -d <sim-udid> \
//     --dart-define=TS_AUTHKEY=tskey-auth-... \
//     --dart-define=SERVER_HOST=https://tailarr.<tailnet>.ts.net
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/api/ntfy/ntfy.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/database/tables/notifications.dart';
import 'package:lunasea/main.dart';
import 'package:lunasea/system/gateway/gateway_services.dart';
import 'package:lunasea/system/network/platform/network_io.dart';
import 'package:lunasea/system/notifications/notifications.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

const _authKey = String.fromEnvironment('TS_AUTHKEY');
const _serverHost = String.fromEnvironment('SERVER_HOST');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('gateway self-config + ntfy round-trip', (tester) async {
    expect(_authKey, isNotEmpty, reason: 'pass --dart-define=TS_AUTHKEY=…');
    expect(_serverHost, isNotEmpty, reason: 'pass --dart-define=SERVER_HOST=…');

    await bootstrap();

    final profile = LunaProfile.current;
    profile.tailscaleEnabled = true;
    profile.tailscaleAuthKey = _authKey;
    profile.tailscaleIdentity = 'gate-e2e';
    await LunaBox.profiles.update(LunaProfile.DEFAULT_PROFILE, profile);

    await tester.pumpWidget(const LunaBIOS());
    await tester.pump(const Duration(seconds: 2));

    debugPrint('[gate-e2e] enrolling embedded node…');
    final port = await IO.startTailscale(_authKey);
    debugPrint('[gate-e2e] node up, proxy on 127.0.0.1:$port');
    expect(await TailscaleEmbed.instance.isRunning(), isTrue);

    // ── 1. Gateway self-config: whois-authenticated, zero configuration ──
    debugPrint('[gate-e2e] querying http://tailarr-gate/self/notifications…');
    final creds = await NtfyGatewayClient().selfNotifications();
    debugPrint('[gate-e2e] gateway: ok=${creds.ok} topics=${creds.topics}');
    expect(creds.ok, isTrue, reason: creds.error ?? '');
    expect(creds.url, startsWith('https://'));
    expect(creds.token, isNotEmpty);
    // Badges: heresphere + server → media topic + ops topic.
    expect(creds.topics, contains('tlr-media-heresphere'));
    expect(creds.topics, contains('tlr-ops'));

    // ── 2. The module's auto-configure stores + marks gateway-managed ──
    final stored = await LunaNtfy().autoConfigure();
    expect(stored?.ok, isTrue);
    expect(NotificationsDatabase.ENABLED.read(), isTrue);
    expect(NotificationsDatabase.GATEWAY_MANAGED.read(), isTrue);
    expect(NotificationsDatabase.URL.read(), creds.url);
    debugPrint('[gate-e2e] module auto-configured from gateway');

    // ── 3. The stage-1 poller reads tlr-ops with the gateway credentials.
    // The server publishes to tlr-ops during setup ("Notifications are set
    // up.") and on every /api/ntfy/test — the operator triggers one before
    // this run; since=all picks up the cached copy either way. ──
    final messages = await NtfyClient(creds.subscription).poll();
    debugPrint('[gate-e2e] polled ${messages.length} message(s)');
    expect(messages, isNotEmpty, reason: 'no messages on subscribed topics');
    expect(
      messages.any((m) => m.topic == 'tlr-ops' && m.message != null),
      isTrue,
      reason: 'test notification not found on tlr-ops',
    );
    debugPrint('[gate-e2e] ntfy round-trip complete');

    // ── 4. Services self-config (server v0.23.0+): the same gateway lists
    // every service the person is badged for. Gate E2E holds heresphere +
    // server, so the app's own server module materializes natively and
    // heresphere falls through to an external bookmark. ──
    debugPrint('[gate-e2e] querying http://tailarr-gate/self/services…');
    final services = await NtfyGatewayClient().selfServices();
    debugPrint(
      '[gate-e2e] services: ok=${services.ok} kind=${services.kind} '
      '${services.services?.map((s) => '${s.type}:${s.name}:${s.url}').toList()}',
    );
    expect(services.ok, isTrue, reason: services.error ?? '');
    expect(services.isSupported, isTrue,
        reason: 'server answered a non-services payload — v0.23.0+ required');

    final outcome = await GatewayServicesSync.sync();
    final result = outcome.result;
    expect(result, isNotNull);
    debugPrint(
      '[gate-e2e] reconciled: configured=${result!.configured} '
      'bookmarked=${result.bookmarked} missingAuth=${result.missingAuth}',
    );

    final synced = LunaProfile.current;
    final tailarrEntry = services.services!
        .where((s) => s.type == 'tailarr')
        .toList();
    expect(tailarrEntry, hasLength(1),
        reason: 'server badge should hand out the tailarr module');
    if (tailarrEntry.single.url.isNotEmpty) {
      expect(synced.tailarrServerEnabled, isTrue);
      expect(synced.tailarrServerHost, tailarrEntry.single.url);
      expect(synced.gatewayManagedModules, contains('tailarr'));
    }

    final heresphere = services.services!
        .where((s) => s.name == 'heresphere')
        .toList();
    expect(heresphere, hasLength(1),
        reason: 'heresphere badge should appear in the listing');
    if (heresphere.single.url.isNotEmpty) {
      expect(
        LunaBox.externalModules.data
            .any((m) => m.gatewayName == 'heresphere' && m.host.isNotEmpty),
        isTrue,
        reason: 'heresphere should reconcile into an external bookmark',
      );
    }
    debugPrint('[gate-e2e] services self-config complete');
  });
}
