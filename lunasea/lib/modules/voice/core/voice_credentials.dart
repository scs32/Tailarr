/// Server-mediated credential acquisition for the in-app voice assistant.
///
/// PHASE 2 (key-off-device): the app ships NO Gemini key and NO MCP token. On
/// each voice-session start it asks the Tailarr controller — through the
/// whois-authenticated `tailarr-gate` node, exactly like `/self/services` — for:
///
///   1. a SHORT-LIVED, model-scoped Gemini Live **ephemeral token** via
///      `POST /self/ai/session` (the broker mints it from the admin's key, which
///      never leaves the box), and
///   2. the caller's own 30-day Tailarr **MCP bearer** via
///      `POST /self/ai {do:"token"}`.
///
/// The MCP funnel URL comes back on the session descriptor (`mcp_url`); when the
/// pod isn't reporting it we derive `http://tailarr-mcp.<suffix>:8100/mcp` from
/// the live tailnet MagicDNS suffix (same anchor `gatewayClient()` uses).
///
/// Nothing secret is compiled into the binary — every credential is fetched at
/// runtime and gated on the person's AI badge. A person without the badge (or an
/// unconfigured/old server) gets a typed [VoiceUnavailableReason], not a crash.
library;

import 'package:lunasea/api/ntfy/models.dart';
import 'package:lunasea/api/ntfy/ntfy.dart';
import 'package:lunasea/system/gateway/gateway_host.dart';
import 'package:lunasea/system/network/platform/network_io.dart'
    if (dart.library.html) 'package:lunasea/system/network/platform/network_html.dart';

/// The raw MCP netns port the controller publishes the tailnet MCP plane on
/// (tailarr-server `MCP_PORT`). Only used to reconstruct the funnel URL if the
/// server didn't hand one back — the server-provided `mcp_url` is authoritative.
const int kMcpTailnetPort = 8100;
const String kMcpPodShortName = 'tailarr-mcp';

/// Runtime-fetched, non-secret-at-rest voice credentials.
class VoiceCredentials {
  const VoiceCredentials({
    required this.ephemeralToken,
    required this.model,
    required this.mcpUrl,
    required this.mcpToken,
    required this.expiresAt,
  });

  /// Short-lived Gemini Live token (single-use, ~30 min). Passed as
  /// `GeminiLiveClient.ephemeralToken`; the raw provider key is never present.
  final String ephemeralToken;

  /// The Live model the ephemeral token is bound to.
  final String model;

  /// Tailnet MCP endpoint (`http://tailarr-mcp.<suffix>:8100/mcp`).
  final String mcpUrl;

  /// The caller's own `tailarr-mcp-…` bearer.
  final String mcpToken;

  /// RFC3339 expiry of [ephemeralToken] — a new session past this re-fetches.
  final String expiresAt;
}

/// Why voice credentials could not be obtained — maps to a UX branch.
enum VoiceUnavailableReason {
  /// The person lacks the AI badge. "Ask your admin to enable AI access."
  noBadge,

  /// The admin hasn't added an AI provider key — AI is dormant server-side.
  notConfigured,

  /// Gateway unreachable / too old / MCP endpoint unknown — transient/degraded.
  unreachable,

  /// The provider rejected the mint (rate limit, bad key server-side, …).
  providerError,
}

/// Result of a credential fetch: either [credentials] or a typed failure.
class VoiceCredentialResult {
  const VoiceCredentialResult._({
    this.credentials,
    this.reason,
    this.message = '',
  });

  const VoiceCredentialResult.ok(VoiceCredentials creds)
      : this._(credentials: creds);

  const VoiceCredentialResult.fail(
    VoiceUnavailableReason reason,
    String message,
  ) : this._(reason: reason, message: message);

  final VoiceCredentials? credentials;
  final VoiceUnavailableReason? reason;

  /// A ready-to-show, user-facing explanation (prefers the server's own copy).
  final String message;

  bool get ok => credentials != null;
}

/// Fetches voice credentials from the controller via the gateway node. Pure
/// orchestration + classification over an injectable [NtfyGatewayClient], so it
/// is directly unit-testable with a fake Dio adapter (no gateway, no Tailscale).
class VoiceCredentialBroker {
  const VoiceCredentialBroker._();

  static const String _noBadgeCopy =
      'AI access isn\'t enabled for you. Ask your admin to turn on AI access '
      '(the AI badge) for this device.';
  static const String _notConfiguredCopy =
      'Voice AI isn\'t set up on this server yet. Ask your admin to add an AI '
      'provider key.';
  static const String _unreachableCopy =
      'Couldn\'t reach your server to start voice. Check your connection and '
      'try again.';
  static const String _noMcpCopy =
      'The server\'s AI tools endpoint isn\'t available right now. Try again '
      'shortly.';

  /// Resolve credentials. [client] defaults to the live `tailarr-gate` client;
  /// pass a fake in tests. [cachedMcpToken] (non-empty) is reused instead of
  /// minting a fresh MCP bearer, so a reconnect within the app session doesn't
  /// churn the person's 30-day token cap. [suffixLookup] overrides the tailnet
  /// MagicDNS-suffix source (tests inject it; production reads the live status).
  static Future<VoiceCredentialResult> resolve({
    NtfyGatewayClient? client,
    String? cachedMcpToken,
    Future<String?> Function()? suffixLookup,
  }) async {
    final gw = client ?? await gatewayClient();

    // 1. Ephemeral Gemini Live token (badge-gated; raw key stays on the box).
    final GatewayAiSession session;
    try {
      session = await gw.selfAiSession();
    } catch (_) {
      return const VoiceCredentialResult.fail(
          VoiceUnavailableReason.unreachable, _unreachableCopy);
    }
    if (!session.isAvailable) {
      if (session.hasNoAccess) {
        return const VoiceCredentialResult.fail(
            VoiceUnavailableReason.noBadge, _noBadgeCopy);
      }
      if (session.isNotConfigured) {
        return const VoiceCredentialResult.fail(
            VoiceUnavailableReason.notConfigured, _notConfiguredCopy);
      }
      if (session.isUnavailable) {
        return const VoiceCredentialResult.fail(
            VoiceUnavailableReason.unreachable, _unreachableCopy);
      }
      // A clean {ok:false,error} the app doesn't specifically classify — surface
      // the server's own message (already user-facing), else a provider error.
      return VoiceCredentialResult.fail(
        VoiceUnavailableReason.providerError,
        (session.error?.isNotEmpty ?? false)
            ? session.error!
            : 'Couldn\'t start voice AI. Try again shortly.',
      );
    }

    // 2. MCP bearer — reuse the cached one, else mint a fresh person-bound token.
    String mcpToken = cachedMcpToken ?? '';
    if (mcpToken.isEmpty) {
      final GatewayAiToken tok;
      try {
        tok = await gw.selfAiToken();
      } catch (_) {
        return const VoiceCredentialResult.fail(
            VoiceUnavailableReason.unreachable, _unreachableCopy);
      }
      if (!tok.isAvailable) {
        if (tok.hasNoAccess) {
          return const VoiceCredentialResult.fail(
              VoiceUnavailableReason.noBadge, _noBadgeCopy);
        }
        return VoiceCredentialResult.fail(
          VoiceUnavailableReason.providerError,
          (tok.error?.isNotEmpty ?? false)
              ? tok.error!
              : 'Couldn\'t mint an AI tools token. Try again shortly.',
        );
      }
      mcpToken = tok.token;
    }

    // 3. MCP URL — prefer the server-provided value, else derive from the suffix.
    var mcpUrl = session.mcpUrl;
    if (mcpUrl.isEmpty) {
      final suffix = await (suffixLookup?.call() ?? _liveSuffix());
      if (suffix != null && suffix.isNotEmpty) {
        mcpUrl = 'http://$kMcpPodShortName.$suffix:$kMcpTailnetPort/mcp';
      }
    }
    if (mcpUrl.isEmpty) {
      return const VoiceCredentialResult.fail(
          VoiceUnavailableReason.unreachable, _noMcpCopy);
    }

    return VoiceCredentialResult.ok(VoiceCredentials(
      ephemeralToken: session.ephemeralToken,
      model: session.model,
      mcpUrl: mcpUrl,
      mcpToken: mcpToken,
      expiresAt: session.expiresAt,
    ));
  }

  /// The live tailnet MagicDNS suffix, or null when the embedded node isn't up.
  static Future<String?> _liveSuffix() async {
    try {
      final status = await IO.tailscaleStatus();
      final suffix = status?.magicDnsSuffix;
      return (suffix != null && suffix.isNotEmpty) ? suffix : null;
    } catch (_) {
      return null;
    }
  }
}
