import 'dart:io';

import 'package:flutter/services.dart';
import 'package:lunasea/database/tables/lunasea.dart';
import 'package:lunasea/vendor.dart';

// ignore: always_use_package_imports
import '../network.dart';

bool isPlatformSupported() => true;
LunaNetwork getNetwork() => IO();

class IO extends HttpOverrides implements LunaNetwork {
  static const MethodChannel _tailscaleChannel =
      MethodChannel('com.lunasea.tailscale/method');

  static int? _tailscaleProxyPort;

  /// Start the Tailscale proxy with the given auth key.
  /// Returns the proxy port on success.
  static Future<int> startTailscale(String authKey) async {
    final port =
        await _tailscaleChannel.invokeMethod<int>('start', {'authKey': authKey});
    if (port == null) {
      throw Exception('Failed to start Tailscale proxy');
    }
    _tailscaleProxyPort = port;
    // Re-initialize HttpOverrides to pick up the new proxy
    HttpOverrides.global = IO();
    return port;
  }

  /// Ensure the Tailscale proxy is up and its listener is healthy, starting
  /// or rebinding it as needed. Returns the current proxy port.
  static Future<int> ensureTailscale(String authKey) async {
    if (await isTailscaleRunning()) {
      final port = await _tailscaleChannel.invokeMethod<int>('ensure');
      if (port != null) {
        _tailscaleProxyPort = port;
        return port;
      }
    }
    return startTailscale(authKey);
  }

  /// Stop the Tailscale proxy.
  static Future<void> stopTailscale() async {
    await _tailscaleChannel.invokeMethod('stop');
    _tailscaleProxyPort = null;
    // Re-initialize HttpOverrides to remove proxy
    HttpOverrides.global = IO();
  }

  /// Check if the Tailscale proxy is running.
  static Future<bool> isTailscaleRunning() async {
    final result = await _tailscaleChannel.invokeMethod<bool>('isRunning');
    return result ?? false;
  }

  /// Get the current Tailscale proxy port, or null if not running.
  static Future<int?> getTailscalePort() async {
    final result = await _tailscaleChannel.invokeMethod<int>('getPort');
    return result;
  }

  /// Returns true if Tailscale is available on this platform.
  static bool get isTailscaleSupported => Platform.isIOS;

  /// Returns true if [host] is a Tailscale destination: a MagicDNS FQDN
  /// (*.ts.net), a Tailscale IPv4 address (CGNAT range 100.64.0.0/10), or a
  /// Tailscale IPv6 address (fd7a:115c:a1e0::/48).
  static bool _isTailscaleHost(String host) {
    if (host.endsWith('.ts.net')) return true;

    final ip = InternetAddress.tryParse(host);
    if (ip == null) return false;

    if (ip.type == InternetAddressType.IPv4) {
      final octets = ip.rawAddress;
      // 100.64.0.0/10 -> first octet 100, second octet 64-127
      return octets[0] == 100 && (octets[1] & 0xC0) == 0x40;
    }

    // fd7a:115c:a1e0::/48
    final v6 = ip.rawAddress;
    return v6[0] == 0xfd &&
        v6[1] == 0x7a &&
        v6[2] == 0x11 &&
        v6[3] == 0x5c &&
        v6[4] == 0xa1 &&
        v6[5] == 0xe0;
  }

  @override
  void initialize() {
    HttpOverrides.global = IO();
  }

  String generateUserAgent(PackageInfo info) {
    return '${info.appName}/${info.version} ${info.buildNumber}';
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final HttpClient client = super.createHttpClient(context);

    // Configure proxy for Tailscale destinations. The port is read on every
    // request so clients created before the proxy started (or across a
    // rebind) always use the current port.
    client.findProxy = (uri) {
      final port = _tailscaleProxyPort;
      if (port != null && _isTailscaleHost(uri.host)) {
        return 'PROXY 127.0.0.1:$port';
      }
      return 'DIRECT';
    };

    // Disable TLS validation if configured
    if (!LunaSeaDatabase.NETWORKING_TLS_VALIDATION.read()) {
      client.badCertificateCallback = (cert, host, port) => true;
    }

    // Set User-Agent
    PackageInfo.fromPlatform()
        .then((info) => client.userAgent = generateUserAgent(info))
        .catchError((_) => client.userAgent = 'Tailarr/Unknown');

    return client;
  }
}
