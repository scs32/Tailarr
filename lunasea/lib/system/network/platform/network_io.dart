import 'dart:io';

import 'package:lunasea/database/tables/lunasea.dart';
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
class IO implements LunaNetwork {
  static TailscaleEmbed get _embed => TailscaleEmbed.instance;

  /// Start the Tailscale proxy. The auth key is read from the configured
  /// [TailscaleConfig] provider (Hive), which [authKey] has already been
  /// written to by the settings flow.
  static Future<int> startTailscale(String authKey) => _embed.start();

  /// Ensure the Tailscale proxy is up and its listener is healthy, starting
  /// or rebinding it as needed. Returns the current proxy port.
  static Future<int> ensureTailscale(String authKey) => _embed.ensure();

  static Future<void> stopTailscale() => _embed.stop();

  static Future<bool> isTailscaleRunning() => _embed.isRunning();

  static Future<int?> getTailscalePort() async => _embed.proxyPort;

  static bool get isTailscaleSupported => _embed.isSupported;

  @override
  void initialize() {
    _embed.configure(
      config: () => TailscaleConfig(
        enabled: LunaSeaDatabase.TAILSCALE_ENABLED.read(),
        authKey: LunaSeaDatabase.TAILSCALE_AUTH_KEY.read(),
        // Not 'tailarr' — that's the tailarr-server controller's hostname;
        // sharing it risks the app's resolver matching itself for the
        // server's MagicDNS name.
        hostname: 'tailarr-app',
      ),
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
