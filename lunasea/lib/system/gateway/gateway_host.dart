import 'package:flutter/foundation.dart';
import 'package:lunasea/api/ntfy/ntfy.dart';
import 'package:lunasea/system/network/platform/network_io.dart'
    if (dart.library.html) 'package:lunasea/system/network/platform/network_html.dart';

/// Test/demo-only seam: when set, [gatewayClient] returns this instead of
/// dialing the live `tailarr-gate`. Null in production — no runtime effect.
/// Used by the Jellyfin/services demo harnesses to render module screens
/// against canned data with no backend.
@visibleForTesting
Future<NtfyGatewayClient> Function()? debugGatewayClientBuilder;

/// Pure throttle decision shared by the services + Jellyfin opportunistic
/// re-sync paths. A fetch that REACHED the gate holds for [reached]; a dial
/// that THREW (the embedded node isn't up yet) only holds for [cooled], so a
/// cold-launch race retries on the next foreground/reconnect instead of being
/// locked out for the full interval. Arming the long throttle on a failed
/// attempt was the "it doesn't seem to be autoconfiguring" bug — the first
/// launch attempt (node not up) blocked re-sync for 15 minutes.
bool gatewaySyncThrottled({
  DateTime? lastReached,
  DateTime? lastFailure,
  required DateTime now,
  Duration reached = const Duration(minutes: 15),
  Duration cooled = const Duration(seconds: 30),
}) {
  if (lastReached != null && now.difference(lastReached) < reached) return true;
  if (lastFailure != null && now.difference(lastFailure) < cooled) return true;
  return false;
}

/// Builds a [NtfyGatewayClient] pointed at the hidden `tailarr-gate` node.
///
/// The gate is reached by its BARE MagicDNS short name (`tailarr-gate`),
/// which resolves unreliably through the embedded proxy — observed on device
/// as "Failed host lookup: tailarr-gate". That single failure silently breaks
/// BOTH services self-config AND notifications setup, even while the gate is a
/// healthy, visible peer on the Tailscale Status page (peer-visible is not the
/// same as short-name-resolvable). Full `*.ts.net` names route reliably — the
/// controller works precisely because it is dialed by its full name — so build
/// the FQDN from the live MagicDNS suffix whenever it is known, and fall back
/// to the bare name only when the node isn't up yet (or on web, which has no
/// tunnel and no status).
Future<NtfyGatewayClient> gatewayClient() async {
  final override = debugGatewayClientBuilder;
  if (override != null) return override();
  var host = NtfyGatewayClient.DEFAULT_HOST;
  try {
    final suffix = (await IO.tailscaleStatus())?.magicDnsSuffix;
    if (suffix != null && suffix.isNotEmpty) {
      host = '${NtfyGatewayClient.DEFAULT_HOST}.$suffix';
    }
  } catch (_) {
    // Status unavailable (node not up yet / web) — the bare name is the
    // fallback, matching the pre-FQDN behaviour.
  }
  return NtfyGatewayClient(host: host);
}
