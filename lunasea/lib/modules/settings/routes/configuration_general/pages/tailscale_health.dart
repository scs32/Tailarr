import 'package:tailscale_embed/tailscale_embed.dart';

/// Gates the embedded node's health warnings on *observed* connectivity so a
/// stale magicsock "ReceiveIPv4 is not running" warning stops sticking in the
/// UI when the tunnel is actually fine.
///
/// Why this exists (P1 — the loudest TestFlight beta report): iOS parks the
/// magicsock UDP socket on suspend/roam, which trips the node's
/// `MagicSock function ReceiveIPv4 is not running` health warning. The
/// watchdog rebinds and connectivity recovers, but the warning **lingers in
/// the node's health snapshot** — the health tracker is slow to clear it, and
/// in the field only a full Tailscale stop/start (a state reset) reliably
/// clears it. Peers meanwhile read 8/8 online and traffic flows. So the app
/// was surfacing a persistent red "Health Warning" for a tunnel that works.
///
/// The fix is to treat this specific warning as a *false alarm* whenever
/// connectivity is demonstrably healthy — i.e. the node is Running and at
/// least one peer is reachable (online). A genuine dead receive path drops
/// peers offline, and in that case we keep showing the warning. All other
/// health warnings are always shown verbatim; only the magicsock
/// receive-function warning is gated.
class TailscaleHealthView {
  const TailscaleHealthView._();

  /// A magicsock receive-function "not running" health warning — the transient
  /// that lingers after the receive path has actually recovered. Matches the
  /// field wording ("MagicSock function ReceiveIPv4 is not running") plus
  /// lower-cased / reworded variants, but only when it says the function is
  /// *not running* (so an unrelated magicsock/receive message isn't gated).
  static bool isStaleMagicsockWarning(String warning) {
    final s = warning.toLowerCase();
    final namesReceiveFn = s.contains('receiveipv4') ||
        s.contains('receiveipv6') ||
        RegExp(r'magicsock.*receive').hasMatch(s);
    return namesReceiveFn && s.contains('not running');
  }

  /// Connectivity is *proven* when the node is up, its backend is Running, and
  /// at least one peer is online (reachable). This is the evidence that a
  /// magicsock receive warning is stale rather than a real outage.
  static bool connectivityProven(TailscaleStatus status) =>
      status.running &&
      status.backendState == 'Running' &&
      status.onlinePeerCount > 0;

  /// The health warnings that should actually be shown. Identical to
  /// `status.health` unless connectivity is proven, in which case the stale
  /// magicsock receive warning is suppressed. Never suppresses other warnings.
  static List<String> effectiveHealth(TailscaleStatus status) {
    if (!connectivityProven(status)) return status.health;
    return status.health.where((w) => !isStaleMagicsockWarning(w)).toList();
  }

  /// Whether the node should read as healthy for the Connection block. Mirrors
  /// `TailscaleStatus.isHealthy` but over the *effective* (gated) health list,
  /// so a lone stale magicsock warning no longer demotes a working tunnel.
  static bool isHealthy(TailscaleStatus status) =>
      status.running &&
      status.backendState == 'Running' &&
      effectiveHealth(status).isEmpty;
}
