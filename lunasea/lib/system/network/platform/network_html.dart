import 'package:tailscale_embed/tailscale_embed.dart' show TailscaleStatus;

// ignore: always_use_package_imports
import '../network.dart';

bool isPlatformSupported() => false;
LunaNetwork getNetwork() => throw UnsupportedError('LunaNetwork unsupported');

/// No-op Tailscale facade for platforms without the embedded client.
class IO {
  static bool get isTailscaleSupported => false;

  static Future<int> startTailscale(String authKey) async =>
      throw UnsupportedError('Tailscale is not supported on this platform');

  static Future<int> ensureTailscale(String authKey) async =>
      throw UnsupportedError('Tailscale is not supported on this platform');

  static Future<void> stopTailscale() async {}

  static Future<bool> isTailscaleRunning() async => false;

  static Future<TailscaleStatus?> tailscaleStatus() async => null;

  static Future<int?> getTailscalePort() async => null;

  static Future<void> syncTailscaleToProfile() async {}

  static Future<void> forgetTailscaleNode(String identity) async {}
}
