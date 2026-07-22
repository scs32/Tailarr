// The Tailscale Status settings page, rendered against the plugin's fake
// backend — connected node, peers (online/offline, subnet routes), health
// warnings, and the stopped state. No network needed:
//   flutter test integration_test/tailscale_status_page_test.dart -d <sim-udid>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

import 'package:lunasea/main.dart';
import 'package:lunasea/modules/settings/routes/configuration_general/pages/tailscale_status.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpStatusPage(
    WidgetTester tester,
    TailscaleStatus status,
  ) async {
    final fake = FakeTailscaleBackend()..statusOverride = status;
    TailscaleEmbed.instance.configure(
      config: () => const TailscaleConfig(
        enabled: true,
        authKey: '',
        hostname: 'tailarr-app',
      ),
      backend: fake,
    );
    await tester.pumpWidget(
      const MaterialApp(home: ConfigurationGeneralTailscaleStatusRoute()),
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  // The page owns a periodic refresh timer — dispose it before the test
  // ends or flutter_test flags the pending timer.
  Future<void> disposePage(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets('renders a connected node with peers', (tester) async {
    await bootstrap();
    await pumpStatusPage(
      tester,
      const TailscaleStatus(
        running: true,
        identity: 'default',
        proxyPort: 41641,
        backendState: 'Running',
        tailnetName: 'stephen@example.com',
        magicDnsSuffix: 'taila06ea9.ts.net',
        self: TailscaleNode(
          hostName: 'tailarr-app',
          dnsName: 'tailarr-app.taila06ea9.ts.net',
          ips: ['100.64.0.1', 'fd7a:115c:a1e0::1'],
          online: true,
        ),
        peers: [
          TailscaleNode(
            hostName: 'tailarr',
            dnsName: 'tailarr.taila06ea9.ts.net',
            ips: ['100.64.0.2'],
            online: true,
          ),
          TailscaleNode(
            hostName: 'truenas-ts',
            dnsName: 'truenas-ts.taila06ea9.ts.net',
            ips: ['100.108.88.87'],
            online: false,
            routes: ['192.168.64.0/24'],
          ),
        ],
      ),
    );

    expect(find.text('Connected', findRichText: true), findsOneWidget);
    expect(find.text('tailarr-app', findRichText: true), findsOneWidget);
    expect(find.text('tailarr-app.taila06ea9.ts.net', findRichText: true), findsOneWidget);
    expect(find.text('100.64.0.1\nfd7a:115c:a1e0::1', findRichText: true), findsOneWidget);
    expect(find.text('127.0.0.1:41641', findRichText: true), findsOneWidget);
    expect(find.text('1 of 2 online', findRichText: true), findsOneWidget);
    expect(find.text('tailarr', findRichText: true), findsOneWidget);
    expect(find.text('Online', findRichText: true), findsOneWidget);
    expect(find.text('truenas-ts', findRichText: true), findsOneWidget);
    expect(find.text('Offline', findRichText: true), findsOneWidget);
    expect(find.text('Routes: 192.168.64.0/24', findRichText: true), findsOneWidget);

    await disposePage(tester);
  });

  testWidgets('renders health warnings', (tester) async {
    await pumpStatusPage(
      tester,
      const TailscaleStatus(
        running: true,
        identity: 'default',
        proxyPort: 41641,
        backendState: 'Running',
        health: ['not connected to home DERP region'],
      ),
    );

    expect(find.text('Health Warnings', findRichText: true), findsOneWidget);
    expect(find.text('not connected to home DERP region', findRichText: true), findsOneWidget);
    // Warnings demote the connection state.
    expect(find.text('Connected', findRichText: true), findsNothing);

    await disposePage(tester);
  });

  testWidgets('renders the stopped state', (tester) async {
    await pumpStatusPage(
      tester,
      const TailscaleStatus(running: false, backendState: 'Stopped'),
    );

    expect(find.text('Stopped', findRichText: true), findsOneWidget);
    expect(find.text('Enable Tailscale to connect', findRichText: true), findsOneWidget);
    // No peers section when the node is down.
    expect(find.text('Peers', findRichText: true), findsNothing);

    await disposePage(tester);
  });
}
