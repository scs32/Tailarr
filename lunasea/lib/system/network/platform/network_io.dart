import 'dart:io';

import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/database/tables/lunasea.dart';
import 'package:lunasea/system/logger.dart';
import 'package:lunasea/vendor.dart';
import 'package:tailscale_embed/tailscale_embed.dart';
import 'package:tailscale_embed/tailscale_embed_io.dart';

// ignore: always_use_package_imports
import '../network.dart';

bool isPlatformSupported() => true;
LunaNetwork getNetwork() => IO();

/// Thin facade over package:tailscale_embed, which owns the embedded node,
/// the local proxy, and the findProxy routing. This class adds Tailarr's own
/// client configuration (TLS validation toggle, user agent) on top.
///
/// Tailscale settings are PER PROFILE (enabled/auth key/identity live on
/// [LunaProfile]); the plugin keeps one node state per identity and the
/// active profile decides which identity runs.
class IO implements LunaNetwork {
  static TailscaleEmbed get _embed => TailscaleEmbed.instance;

  /// Start the Tailscale proxy. Config (including the auth key) is read
  /// from the configured provider — the current profile's fields.
  static Future<int> startTailscale(String authKey) => _embed.start();

  /// Ensure the Tailscale proxy is up and its listener is healthy, starting
  /// or rebinding it as needed. Returns the current proxy port.
  static Future<int> ensureTailscale(String authKey) => _embed.ensure();

  static Future<void> stopTailscale() => _embed.stop();

  static Future<bool> isTailscaleRunning() => _embed.isRunning();

  static Future<int?> getTailscalePort() async => _embed.proxyPort;

  static bool get isTailscaleSupported => _embed.isSupported;

  /// Re-evaluate the provider config after a profile switch: `ensure()`
  /// restarts the node when the new profile's identity differs, and the
  /// node stops when the new profile has Tailscale off.
  static Future<void> syncTailscaleToProfile() async {
    try {
      if (LunaProfile.current.tailscaleEnabled) {
        await _embed.ensure();
      } else if (await _embed.isRunning()) {
        await _embed.stop();
      }
    } catch (error, stack) {
      LunaLogger().error('Tailscale profile sync failed', error, stack);
    }
  }

  /// Stop the node (when this identity is the active one) and delete its
  /// on-disk state, allowing a fresh enrollment with a new auth key.
  static Future<void> forgetTailscaleNode(String identity) async {
    if (identity.isEmpty) return;
    try {
      final active = await _embed.activeIdentity();
      if (active == identity) await _embed.stop();
    } catch (_) {}
    await _embed.deleteIdentity(identity);
  }

  @override
  void initialize() {
    _embed.configure(
      config: () {
        final profile = LunaProfile.current;
        final identity = profile.tailscaleIdentity.isEmpty
            ? 'default'
            : profile.tailscaleIdentity;
        return TailscaleConfig(
          enabled: profile.tailscaleEnabled,
          authKey: profile.tailscaleAuthKey,
          identity: identity,
          // Not 'tailarr' — that's the tailarr-server controller's
          // hostname; sharing it risks the app's resolver matching itself
          // for the server's MagicDNS name. Non-default identities get a
          // suffix so two profiles on the SAME tailnet don't collide.
          hostname:
              identity == 'default' ? 'tailarr-app' : 'tailarr-app-$identity',
        );
      },
      // The node's identity is persisted — the plaintext key has no
      // further use, so drop it from whichever profile owns the identity.
      onKeyConsumed: (identity) {
        for (final name in LunaProfile.list) {
          final profile = LunaBox.profiles.read(name);
          if (profile == null || profile.tailscaleAuthKey.isEmpty) continue;
          final owned = profile.tailscaleIdentity.isEmpty
              ? 'default'
              : profile.tailscaleIdentity;
          if (owned == identity) {
            profile.tailscaleAuthKey = '';
            profile.save();
          }
        }
      },
    );
    TailscaleHttpOverrides.install(configureClient: _configureClient);
  }

  String generateUserAgent(PackageInfo info) {
    return '${info.appName}/${info.version} ${info.buildNumber}';
  }

  void _configureClient(HttpClient client) {
    // Disable TLS validation if configured
    if (!LunaSeaDatabase.NETWORKING_TLS_VALIDATION.read()) {
      client.badCertificateCallback = (cert, host, port) => true;
    }

    // Set User-Agent
    PackageInfo.fromPlatform()
        .then((info) => client.userAgent = generateUserAgent(info))
        .catchError((_) => client.userAgent = 'Tailarr/Unknown');
  }
}
