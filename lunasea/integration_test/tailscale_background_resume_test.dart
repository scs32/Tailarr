// Robustness test for the embedded Tailscale node's magicsock recovery across
// app background -> resume cycles (the "ReceiveIPv4 is not running" bug class).
//
// What it does, against a LIVE tailarr box on the tailnet:
//   1. Enrolls the embedded node with a person-bound auth key and confirms it
//      can reach the box (GET /api/info returns 200 over the tunnel).
//   2. Drives real app-lifecycle transitions (inactive -> paused -> resumed)
//      exactly as iOS delivers them, for several hold durations (seconds,
//      tens of seconds, ~90s past the node's 60s health self-check timer), plus
//      a rapid double-background. The mounted TailscaleGuard re-ensures on
//      resume; the test also awaits ensure() directly so it can read the result.
//   3. After every resume it re-probes connectivity and reads the node's
//      health warnings + self-heal telemetry (rebinds/restarts/needsRebind),
//      asserting the tunnel recovers and that any surfaced "ReceiveIPv4 not
//      running" magicsock warning clears within the window.
//
// IMPORTANT — simulator caveat: the receiveipv4-goroutine death this guards
// against is triggered by iOS *tearing down UDP sockets* on real hardware
// suspension / network-path changes. The iOS Simulator does NOT reclaim the
// app's sockets when it is backgrounded, so this test exercises the full
// resume -> ensure -> rebind recovery path and the telemetry/health surface,
// but a green run on the simulator is NOT proof the bug is absent on device.
// It WILL fail loudly if the warning ever surfaces and does not clear, and it
// records the exact telemetry for any live capture. Run it on a physical
// device (same invocation, -d <device-udid>) for the authoritative signal.
//
// Run (simulator):
//   flutter test integration_test/tailscale_background_resume_test.dart \
//     -d <sim-udid> \
//     --dart-define=TS_AUTHKEY=tskey-auth-... \
//     --dart-define=SERVER_HOST=https://tailarr.<tailnet>.ts.net
//
// The tool/ts_background_resume.sh wrapper runs this while streaming the
// embedded tailscaled logs off the simulator and grepping for the symptom.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/main.dart';
import 'package:lunasea/system/network/platform/network_io.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

const _authKey = String.fromEnvironment('TS_AUTHKEY');
const _serverHost = String.fromEnvironment('SERVER_HOST');

/// Drive a real app-lifecycle transition the way the engine delivers it, so the
/// mounted TailscaleGuard's `didChangeAppLifecycleState` fires for real.
///
/// NOTE: we deliberately do NOT call `tester.pump()` here. Under the live
/// integration-test binding, pumping awaits a rendered frame, and while the app
/// is in the `paused` state the engine throttles frames — a pump-while-paused
/// hangs the whole test. Lifecycle messages dispatch to observers synchronously
/// via the binary messenger, so no pump is needed to deliver them.
Future<void> _setLifecycle(WidgetTester tester, AppLifecycleState state) async {
  final ByteData? msg = const StringCodec().encodeMessage(state.toString());
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/lifecycle',
    msg,
    (_) {},
  );
}

/// Send the app to the background (foreground -> inactive -> paused), hold for
/// [hold] of real wall-clock time, then bring it back (paused -> inactive ->
/// resumed). Mirrors the exact iOS transition sequence. No frame pumps while
/// paused (see [_setLifecycle]); a single settle pump happens after resume.
Future<void> _backgroundThenResume(
  WidgetTester tester,
  Duration hold,
) async {
  await _setLifecycle(tester, AppLifecycleState.inactive);
  await _setLifecycle(tester, AppLifecycleState.paused);
  // Real wall-clock time must pass while suspended (on device this is when iOS
  // reclaims the UDP sockets). A real Future.delayed advances the clock so the
  // node's own timers run; no pump (engine is throttled while paused).
  await Future<void>.delayed(hold);
  await _setLifecycle(tester, AppLifecycleState.inactive);
  await _setLifecycle(tester, AppLifecycleState.resumed);
  // One bounded settle pump now that the engine is servicing frames again; the
  // resumed lifecycle also kicked the mounted guard's _ensure().
  await tester.pump(const Duration(milliseconds: 500)).timeout(
        const Duration(seconds: 20),
        onTimeout: () => debugPrint('[bg-resume] post-resume pump timed out'),
      );
}

/// One connectivity probe over the tunnel: GET $host/api/info. Returns the
/// status code, or -1 on a thrown failure (no route / dead proxy / timeout).
Future<int> _probe(String host) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 12);
  try {
    final req = await client.getUrl(Uri.parse('$host/api/info'));
    final resp = await req.close().timeout(const Duration(seconds: 15));
    await resp.drain<void>();
    return resp.statusCode;
  } catch (e) {
    debugPrint('[bg-resume] probe threw: $e');
    return -1;
  } finally {
    client.close(force: true);
  }
}

/// Probe with retries so a just-resumed node gets a moment to rebind.
Future<int> _probeWithRetry(String host, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  int code = -1;
  while (DateTime.now().isBefore(end)) {
    code = await _probe(host);
    if (code == 200) return code;
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  return code;
}

bool _hasReceiveWarning(List<String> health) => health.any((h) {
      final l = h.toLowerCase();
      return l.contains('receiveipv4') ||
          l.contains('receiveipv6') ||
          (l.contains('magicsock') && l.contains('not running'));
    });

String _tel(TailscaleRecovery? r) => r == null
    ? 'recovery=null'
    : 'needsRebind=${r.needsRebind} healAttempts=${r.healAttempts} '
        'rebinds=${r.rebinds} restarts=${r.restarts} '
        'lastRebind=${r.lastRebindReason}@${r.lastRebindAt} '
        'lastRestart=${r.lastRestartReason}@${r.lastRestartAt}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('magicsock survives background/resume cycles', (tester) async {
    expect(_authKey, isNotEmpty, reason: 'pass --dart-define=TS_AUTHKEY=…');
    expect(_serverHost, isNotEmpty, reason: 'pass --dart-define=SERVER_HOST=…');

    await bootstrap();

    final profile = LunaProfile.current;
    profile.tailscaleEnabled = true;
    profile.tailscaleAuthKey = _authKey;
    profile.tailscaleIdentity = 'bg-resume-test';
    await LunaBox.profiles.update(LunaProfile.DEFAULT_PROFILE, profile);

    // Build the full app so the real TailscaleGuard is mounted and observing
    // lifecycle (its resume handler is part of what we're testing).
    await tester.pumpWidget(const LunaBIOS());
    await tester.pump(const Duration(seconds: 2));

    // ── Enroll ─────────────────────────────────────────────────────────────
    debugPrint('[bg-resume] enrolling embedded node…');
    final port = await IO.startTailscale(_authKey);
    debugPrint('[bg-resume] node up, proxy on 127.0.0.1:$port');
    expect(port, greaterThan(0));
    expect(await TailscaleEmbed.instance.isRunning(), isTrue);

    // ── Baseline connectivity + telemetry ───────────────────────────────────
    final baseCode = await _probeWithRetry(_serverHost);
    debugPrint('[bg-resume] baseline GET $_serverHost/api/info -> $baseCode');
    expect(baseCode, 200, reason: 'node never reached the box before backgrounding');

    final baseStatus = await TailscaleEmbed.instance.status();
    debugPrint('[bg-resume] baseline health=${baseStatus?.health} '
        'peers=${baseStatus?.onlinePeerCount} ${_tel(baseStatus?.recovery)}');
    final baseRebinds = baseStatus?.recovery?.rebinds ?? 0;
    final baseRestarts = baseStatus?.recovery?.restarts ?? 0;

    // ── Background/resume cycles ─────────────────────────────────────────────
    // (label, hold). The ~90s cycle outlasts the node's 60s health self-check
    // timer so a latched warning would have recomputed at least once.
    final cycles = <MapEntry<String, Duration>>[
      const MapEntry('short-3s', Duration(seconds: 3)),
      const MapEntry('medium-15s', Duration(seconds: 15)),
      const MapEntry('rapid-double-a', Duration(seconds: 2)),
      const MapEntry('rapid-double-b', Duration(seconds: 2)),
      const MapEntry('long-75s', Duration(seconds: 75)),
    ];

    var reproduced = false;
    for (final c in cycles) {
      debugPrint('[bg-resume] ── cycle ${c.key}: backgrounding for ${c.value.inSeconds}s ──');
      await _backgroundThenResume(tester, c.value);
      debugPrint('[bg-resume] ${c.key}: resumed, calling ensure()…');

      // Guard re-ensures on resume; await one directly so we can read the result
      // and so the probe doesn't race a still-rebinding node. Bounded so a
      // wedged native ensure() surfaces as a failed cycle, not a global hang.
      final ensured = await IO.ensureTailscale(_authKey).timeout(
            const Duration(seconds: 70),
            onTimeout: () {
              debugPrint('[bg-resume] ${c.key}: ensure() TIMED OUT (>70s) — '
                  'native node likely wedged');
              return -1;
            },
          );
      debugPrint('[bg-resume] ${c.key}: ensure() -> port $ensured');
      expect(ensured, isNot(-1), reason: '${c.key}: ensure() wedged after resume');
      expect(await TailscaleEmbed.instance.isRunning(), isTrue,
          reason: '${c.key}: node not running after resume');

      final code = await _probeWithRetry(_serverHost);
      final status = await TailscaleEmbed.instance.status();
      final warn = _hasReceiveWarning(status?.health ?? const []);
      debugPrint('[bg-resume] ${c.key}: probe=$code '
          'receiveWarning=$warn health=${status?.health} '
          'peers=${status?.onlinePeerCount} ${_tel(status?.recovery)}');

      if (warn) {
        reproduced = true;
        debugPrint('[bg-resume] ${c.key}: *** ReceiveIPv4/magicsock warning '
            'SURFACED after resume ***');
      }

      // Core assertion: the tunnel recovers. If this fails, background/resume
      // reproduced a real magicsock connectivity loss that rebind didn't fix.
      expect(code, 200,
          reason: '${c.key}: tunnel did NOT recover after resume '
              '(receiveWarning=$warn, ${_tel(status?.recovery)})');

      // If the warning surfaced, it must have cleared by now (rebind recovered
      // it). A warning still latched here == the deferred root-cause bug.
      expect(warn, isFalse,
          reason: '${c.key}: ReceiveIPv4 warning still latched after resume+'
              'ensure+recovery window — the deferred magicsock root cause. '
              '${_tel(status?.recovery)}');
    }

    // ── Final telemetry summary ──────────────────────────────────────────────
    final finalStatus = await TailscaleEmbed.instance.status();
    final rebindDelta = (finalStatus?.recovery?.rebinds ?? 0) - baseRebinds;
    final restartDelta = (finalStatus?.recovery?.restarts ?? 0) - baseRestarts;
    debugPrint('[bg-resume] ════════ SUMMARY ════════');
    debugPrint('[bg-resume] cycles run: ${cycles.length}');
    debugPrint('[bg-resume] receiveipv4 warning ever surfaced: $reproduced');
    debugPrint('[bg-resume] rebinds during test: $rebindDelta '
        '(base=$baseRebinds now=${finalStatus?.recovery?.rebinds})');
    debugPrint('[bg-resume] restarts during test: $restartDelta '
        '(base=$baseRestarts now=${finalStatus?.recovery?.restarts})');
    debugPrint('[bg-resume] final health=${finalStatus?.health}');
    debugPrint('[bg-resume] restarts MUST stay 0 (watchdog is rebind-only): '
        '${(finalStatus?.recovery?.restarts ?? 0) == 0 ? "OK" : "RESTART FIRED"}');
    debugPrint('[bg-resume] SUCCESS — tunnel recovered after every cycle');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
