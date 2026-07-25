import 'package:lunasea/api/ntfy/ntfy.dart';
import 'package:lunasea/system/network/platform/network_io.dart'
    if (dart.library.html) 'package:lunasea/system/network/platform/network_html.dart';

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
