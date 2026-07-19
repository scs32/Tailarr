import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:share_plus/share_plus.dart';

/// One module's connection settings as carried by a share link.
///
/// The payload rides in the URL *fragment* of https://tailarr.com/import so
/// it never reaches the server: `{v: 1, module, host, key|user+pass, headers}`
/// base64url-encoded. The recipient's app decodes it on-device and nothing is
/// written to the profile until they explicitly save on the import screen.
class SharedModuleConfiguration {
  static const int VERSION = 1;
  static const String _BASE_URL = 'https://tailarr.com/import';

  /// Modules whose connection settings are shareable. The Tailscale auth key
  /// and any other identity material are deliberately not shareable.
  static const List<LunaModule> SUPPORTED = [
    LunaModule.SONARR,
    LunaModule.RADARR,
    LunaModule.LIDARR,
    LunaModule.SABNZBD,
    LunaModule.NZBGET,
    LunaModule.TAUTULLI,
    LunaModule.TAILARR_SERVER,
  ];

  final LunaModule module;
  final String host;
  final String key;
  final String user;
  final String pass;
  final Map<String, String> headers;

  const SharedModuleConfiguration({
    required this.module,
    required this.host,
    this.key = '',
    this.user = '',
    this.pass = '',
    this.headers = const {},
  });

  /// Snapshot the current profile's settings for [module], or null when the
  /// module is not supported.
  static SharedModuleConfiguration? fromProfile(LunaModule module) {
    final profile = LunaProfile.current;
    switch (module) {
      case LunaModule.SONARR:
        return SharedModuleConfiguration(
          module: module,
          host: profile.sonarrHost,
          key: profile.sonarrKey,
          headers: Map<String, String>.from(profile.sonarrHeaders),
        );
      case LunaModule.RADARR:
        return SharedModuleConfiguration(
          module: module,
          host: profile.radarrHost,
          key: profile.radarrKey,
          headers: Map<String, String>.from(profile.radarrHeaders),
        );
      case LunaModule.LIDARR:
        return SharedModuleConfiguration(
          module: module,
          host: profile.lidarrHost,
          key: profile.lidarrKey,
          headers: Map<String, String>.from(profile.lidarrHeaders),
        );
      case LunaModule.SABNZBD:
        return SharedModuleConfiguration(
          module: module,
          host: profile.sabnzbdHost,
          key: profile.sabnzbdKey,
          headers: Map<String, String>.from(profile.sabnzbdHeaders),
        );
      case LunaModule.NZBGET:
        return SharedModuleConfiguration(
          module: module,
          host: profile.nzbgetHost,
          user: profile.nzbgetUser,
          pass: profile.nzbgetPass,
          headers: Map<String, String>.from(profile.nzbgetHeaders),
        );
      case LunaModule.TAUTULLI:
        return SharedModuleConfiguration(
          module: module,
          host: profile.tautulliHost,
          key: profile.tautulliKey,
          headers: Map<String, String>.from(profile.tautulliHeaders),
        );
      case LunaModule.TAILARR_SERVER:
        return SharedModuleConfiguration(
          module: module,
          host: profile.tailarrServerHost,
          headers: Map<String, String>.from(profile.tailarrServerHeaders),
        );
      default:
        return null;
    }
  }

  /// Decode a URL fragment produced by [encode]. Returns null for anything
  /// that is not a valid, supported v1 payload.
  static SharedModuleConfiguration? decode(String fragment) {
    if (fragment.isEmpty) return null;
    try {
      final normalized = base64Url.normalize(fragment);
      final json = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      if (json is! Map || json['v'] != VERSION) return null;
      final module = LunaModule.fromKey(json['module']?.toString());
      if (module == null || !SUPPORTED.contains(module)) return null;
      final host = json['host']?.toString() ?? '';
      if (host.isEmpty) return null;
      return SharedModuleConfiguration(
        module: module,
        host: host,
        key: json['key']?.toString() ?? '',
        user: json['user']?.toString() ?? '',
        pass: json['pass']?.toString() ?? '',
        headers: (json['headers'] as Map? ?? {}).map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  String encode() {
    final payload = <String, dynamic>{
      'v': VERSION,
      'module': module.key,
      'host': host,
      if (key.isNotEmpty) 'key': key,
      if (user.isNotEmpty) 'user': user,
      if (pass.isNotEmpty) 'pass': pass,
      if (headers.isNotEmpty) 'headers': headers,
    };
    return base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
  }

  String get link => '$_BASE_URL#${encode()}';

  /// True when saving would replace connection settings the recipient
  /// already has for this module.
  bool get conflictsWithProfile {
    final existing = fromProfile(module);
    if (existing == null) return false;
    return existing.host.isNotEmpty ||
        existing.key.isNotEmpty ||
        existing.user.isNotEmpty;
  }

  /// Write this configuration to the current profile and enable the module.
  /// Callers are responsible for the overwrite warning and state reset.
  void applyToProfile() {
    final profile = LunaProfile.current;
    switch (module) {
      case LunaModule.SONARR:
        profile.sonarrEnabled = true;
        profile.sonarrHost = host;
        profile.sonarrKey = key;
        profile.sonarrHeaders = Map<String, String>.from(headers);
        break;
      case LunaModule.RADARR:
        profile.radarrEnabled = true;
        profile.radarrHost = host;
        profile.radarrKey = key;
        profile.radarrHeaders = Map<String, String>.from(headers);
        break;
      case LunaModule.LIDARR:
        profile.lidarrEnabled = true;
        profile.lidarrHost = host;
        profile.lidarrKey = key;
        profile.lidarrHeaders = Map<String, String>.from(headers);
        break;
      case LunaModule.SABNZBD:
        profile.sabnzbdEnabled = true;
        profile.sabnzbdHost = host;
        profile.sabnzbdKey = key;
        profile.sabnzbdHeaders = Map<String, String>.from(headers);
        break;
      case LunaModule.NZBGET:
        profile.nzbgetEnabled = true;
        profile.nzbgetHost = host;
        profile.nzbgetUser = user;
        profile.nzbgetPass = pass;
        profile.nzbgetHeaders = Map<String, String>.from(headers);
        break;
      case LunaModule.TAUTULLI:
        profile.tautulliEnabled = true;
        profile.tautulliHost = host;
        profile.tautulliKey = key;
        profile.tautulliHeaders = Map<String, String>.from(headers);
        break;
      case LunaModule.TAILARR_SERVER:
        profile.tailarrServerEnabled = true;
        profile.tailarrServerHost = host;
        profile.tailarrServerHeaders = Map<String, String>.from(headers);
        break;
      default:
        break;
    }
    profile.save();
  }

  /// A scratch, never-saved profile holding ONLY this payload's values — for
  /// `XAPI.from(profile)`-style clients so Test Connection runs against the
  /// shared data, not whatever the recipient currently has saved.
  LunaProfile toScratchProfile() {
    final profile = LunaProfile();
    switch (module) {
      case LunaModule.LIDARR:
        profile.lidarrHost = host;
        profile.lidarrKey = key;
        profile.lidarrHeaders = Map<String, String>.from(headers);
        break;
      case LunaModule.SABNZBD:
        profile.sabnzbdHost = host;
        profile.sabnzbdKey = key;
        profile.sabnzbdHeaders = Map<String, String>.from(headers);
        break;
      case LunaModule.NZBGET:
        profile.nzbgetHost = host;
        profile.nzbgetUser = user;
        profile.nzbgetPass = pass;
        profile.nzbgetHeaders = Map<String, String>.from(headers);
        break;
      default:
        break;
    }
    return profile;
  }

  /// iOS requires a non-zero [sharePositionOrigin] to anchor the share
  /// sheet (it throws without one); [shareOriginOf] derives it from the
  /// calling widget's context.
  Future<void> share(BuildContext context) {
    return Share.share(
      'Tap to add my ${module.title} to Tailarr — the app opens with '
      'everything filled in:\n\n$link',
      sharePositionOrigin: shareOriginOf(context),
    );
  }

  static Rect shareOriginOf(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
    final size = MediaQuery.of(context).size;
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: 1,
      height: 1,
    );
  }
}
