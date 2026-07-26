import 'package:lunasea/api/pairing/pairing.dart';
import 'package:lunasea/database/models/profile.dart';

/// Resolves the Quick Connect pairing transport + the approver capability gate
/// for a profile. The app is an APPROVER: it may only approve/self-config when
/// its person holds the `server` badge — which manifests in the handout as a
/// `{type:"tailarr"}` service, materialized on the profile as a controller host
/// (`tailarrServerHost`) + gateway-managed `tailarr`. The server's netns whois
/// (against `people.json[uid].badges`) is the real gate; this is the UX
/// pre-filter that decides whether to show the pairing UI at all.
class QuickConnect {
  QuickConnect._();

  /// The pairing PORT (raw netns) the approve leg lands on — frozen §7-Q1.
  static const pairPort = 8089;

  /// Whether this profile may approve sign-ins: it must have a controller to
  /// talk to (the `{type:"tailarr"}` grant → `tailarrServerHost`).
  static bool canApprove(LunaProfile profile) =>
      profile.tailarrServerHost.trim().isNotEmpty;

  /// `<controller-dns>` over serve/HTTPS — the base for /api/pair/start +
  /// /api/pair/status. Null when the profile can't approve.
  static String? serveBase(LunaProfile profile) {
    final host = profile.tailarrServerHost.trim();
    return host.isEmpty ? null : host;
  }

  /// The identity-proven pairing base — `http://<controller-dns>:8089` — for
  /// /pair/approve. Derived from the same controller host. Null when the
  /// profile can't approve or the host is unparseable.
  static String? pairBase(LunaProfile profile) {
    final base = serveBase(profile);
    if (base == null) return null;
    final host = Uri.tryParse(base)?.host;
    if (host == null || host.isEmpty) return null;
    return 'http://$host:$pairPort';
  }

  /// A [PairingClient] wired to this profile's controller, or null when the
  /// profile lacks the server grant (caller shows the refuse-to-approve copy).
  static PairingClient? clientFor(LunaProfile profile) {
    if (!canApprove(profile)) return null;
    final serve = serveBase(profile);
    final pair = pairBase(profile);
    if (serve == null || pair == null) return null;
    return PairingClient(serveBaseUrl: serve, pairBaseUrl: pair);
  }

  /// Self-config ("Connect this device"): mint an admin token for THIS device
  /// and store it on the profile as [LunaProfile.serverAdminToken]. The two
  /// legs run against the same identity-proven device — start → approve → poll
  /// status for the once-token (§5 A: the token lives on status, not approve).
  /// [client] is injectable for tests. Never throws — returns a typed result.
  static Future<QuickConnectResult> selfConfigure(
    LunaProfile profile, {
    required String deviceLabel,
    PairingClient? client,
    int pollAttempts = 15,
    Duration pollDelay = const Duration(seconds: 1),
  }) async {
    final c = client ?? clientFor(profile);
    if (c == null) return const QuickConnectResult(QuickConnectStatus.noBadge);
    try {
      final started = await c.pairStart(device: deviceLabel);
      if (!started.isValid) {
        return const QuickConnectResult(QuickConnectStatus.failed, 'start');
      }
      final approve = await c.pairApprove(started.code);
      if (!approve.ok) {
        return QuickConnectResult(QuickConnectStatus.refused, approve.error);
      }
      for (var i = 0; i < pollAttempts; i++) {
        final status = await c.pairStatus(started.pollId);
        final token = status.token;
        if (token != null && token.isNotEmpty) {
          profile.serverAdminToken = token;
          if (profile.isInBox) profile.save();
          return const QuickConnectResult(QuickConnectStatus.ok);
        }
        if (status.isSettled && !status.isApproved) {
          return QuickConnectResult(QuickConnectStatus.failed, status.status);
        }
        await Future.delayed(pollDelay);
      }
      return const QuickConnectResult(QuickConnectStatus.failed, 'no token');
    } catch (_) {
      return const QuickConnectResult(QuickConnectStatus.transportError);
    }
  }
}

enum QuickConnectStatus { ok, noBadge, refused, transportError, failed }

/// Typed outcome of [QuickConnect.selfConfigure].
class QuickConnectResult {
  final QuickConnectStatus status;
  final String? error;

  const QuickConnectResult(this.status, [this.error]);

  bool get ok => status == QuickConnectStatus.ok;
}
