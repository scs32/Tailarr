// End-to-end test against a LIVE tailarr-server on the tailnet: enroll the
// embedded Tailscale node, verify the module's Test Connection path, and
// walk the Tailarr Server screens against real data.
//
// Config is written through the same storage the settings dialogs use
// (Hive); the network stack, node enrollment, API calls, and module UI are
// all exercised for real.
//
// Run (simulator):
//   flutter test integration_test/e2e_test.dart -d <sim-udid> \
//     --dart-define=TS_AUTHKEY=tskey-auth-... \
//     --dart-define=SERVER_HOST=https://tailarr-server.<tailnet>.ts.net
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/modules/tailarr_server.dart';
import 'package:lunasea/main.dart';
import 'package:lunasea/router/router.dart';
import 'package:lunasea/system/network/platform/network_io.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

const _authKey = String.fromEnvironment('TS_AUTHKEY');
const _serverHost = String.fromEnvironment('SERVER_HOST');

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('Timed out waiting for $finder');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('embedded tailscale + tailarr server module e2e',
      (tester) async {
    expect(_authKey, isNotEmpty, reason: 'pass --dart-define=TS_AUTHKEY=…');
    expect(_serverHost, isNotEmpty, reason: 'pass --dart-define=SERVER_HOST=…');

    await bootstrap();

    // ── Configure via the same storage the settings dialogs write ──
    // Tailscale is per-profile now; a non-default identity also exercises
    // the plugin's multi-identity path against a real tailnet.
    final profile = LunaProfile.current;
    profile.tailscaleEnabled = true;
    profile.tailscaleAuthKey = _authKey;
    profile.tailscaleIdentity = 'e2e-test';
    profile.tailarrServerEnabled = true;
    profile.tailarrServerHost = _serverHost;
    await LunaBox.profiles.update(LunaProfile.DEFAULT_PROFILE, profile);

    await tester.pumpWidget(const LunaBIOS());
    await tester.pump(const Duration(seconds: 2));

    // ── Enroll the embedded node (blocks on tsnet Up, up to ~45s) ──
    debugPrint('[e2e] starting embedded tailscale node…');
    final port = await IO.startTailscale(_authKey);
    debugPrint('[e2e] node up, proxy on 127.0.0.1:$port');
    expect(port, greaterThan(0));
    expect(await TailscaleEmbed.instance.isRunning(), isTrue);

    // ── The module's own connection path: /api/info over the proxy ──
    debugPrint('[e2e] querying $_serverHost/api/info over the tunnel…');
    final api = TailarrServerAPI(host: _serverHost);
    final info = await api.getInfo();
    debugPrint('[e2e] server v${info.version} api_version=${info.apiVersion}');
    expect(info.apiVersion, greaterThanOrEqualTo(1));

    // ── Walk the module screens against live data ──
    context.read<TailarrServerState>().reset();
    LunaRouter.router.go('/tailarr_server');
    await _pumpUntilFound(
      tester,
      find.text('uptime-kuma'),
      timeout: const Duration(seconds: 60),
    );
    debugPrint('[e2e] pods list shows uptime-kuma');

    await tester.tap(find.text('uptime-kuma'));
    await _pumpUntilFound(tester, find.text('Logs'));
    expect(find.text('Backups'), findsOneWidget);
    expect(find.text('Open Service'), findsOneWidget);
    debugPrint('[e2e] pod detail rendered (with tailnet service URL)');

    await tester.tap(find.text('Logs'));
    await _pumpUntilFound(
      tester,
      find.textContaining('uptime-kuma: Logs'),
    );
    // Real log lines or the empty state — either proves the round-trip.
    final end = DateTime.now().add(const Duration(seconds: 45));
    var logsRendered = false;
    while (DateTime.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.text('No Logs Found').evaluate().isNotEmpty ||
          find.byType(ListView).evaluate().isNotEmpty) {
        logsRendered = true;
        break;
      }
    }
    expect(logsRendered, isTrue, reason: 'logs page never rendered');
    debugPrint('[e2e] logs page rendered');

    LunaRouter.router.go('/tailarr_server/pod/uptime-kuma/backups');
    await _pumpUntilFound(tester, find.text('Back Up Now'));
    debugPrint('[e2e] backups page rendered');

    LunaRouter.router.go('/tailarr_server/updates');
    await _pumpUntilFound(
      tester,
      find.textContaining('uptime-kuma'),
      timeout: const Duration(seconds: 45),
    );
    debugPrint('[e2e] updates page rendered');

    // ── v2: Users screen (gate or live list depending on tsapi) ──
    LunaRouter.router.go('/tailarr_server/users');
    final users = await api.getUsers();
    if (users.configured) {
      await _pumpUntilFound(
        tester,
        find.text('Add User'),
        timeout: const Duration(seconds: 30),
      );
      debugPrint('[e2e] users list rendered '
          '(${users.users.length} devices, ${users.services.length} services)');
    } else {
      await _pumpUntilFound(
        tester,
        find.text('Tailscale API Credentials Required'),
        timeout: const Duration(seconds: 30),
      );
      debugPrint('[e2e] users gate screen rendered (tsapi not configured)');
    }

    // ── v2: Funnel round-trip via the API the toggle uses ──
    final onResult = await api.setFunnel('uptime-kuma', true);
    debugPrint('[e2e] funnel on → status=${onResult.status}');
    expect(
      ['public', 'funnel refused'].contains(onResult.status),
      isTrue,
      reason: 'unexpected funnel status: '
          '${onResult.status} / ${onResult.error}',
    );
    if (onResult.ok) {
      final entries = await api.getNetwork();
      final kuma = entries.firstWhere((e) => e.name == 'uptime-kuma');
      expect(kuma.funnel, isTrue);
      final offResult = await api.setFunnel('uptime-kuma', false);
      debugPrint('[e2e] funnel off → status=${offResult.status}');
      expect(offResult.ok, isTrue);
    } else {
      debugPrint('[e2e] funnel refused (missing nodeAttr in tailnet '
          'policy) — error surfaced correctly');
    }

    debugPrint('[e2e] SUCCESS — full flow completed against live server');
  });
}

/// Shorthand: the router's current context for Provider reads.
BuildContext get context => LunaRouter.navigator.currentContext!;
