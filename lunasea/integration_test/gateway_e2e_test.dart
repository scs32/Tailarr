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
  });
}
