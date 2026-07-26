import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/tables/lunasea.dart';
import 'package:lunasea/modules.dart';
import 'package:lunasea/vendor.dart';

part 'profile.g.dart';

@JsonSerializable()
@HiveType(typeId: 0, adapterName: 'LunaProfileAdapter')
class LunaProfile extends HiveObject {
  static const String DEFAULT_PROFILE = 'default';

  static LunaProfile get current {
    final enabled = LunaSeaDatabase.ENABLED_PROFILE.read();
    return LunaBox.profiles.read(enabled) ?? LunaProfile();
  }

  static List<String> get list {
    final profiles = LunaBox.profiles.keys.cast<String>().toList();
    profiles.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return profiles;
  }

  @JsonKey()
  @HiveField(0, defaultValue: false)
  bool lidarrEnabled;

  @JsonKey()
  @HiveField(1, defaultValue: '')
  String lidarrHost;

  @JsonKey()
  @HiveField(2, defaultValue: '')
  String lidarrKey;

  @JsonKey()
  @HiveField(26, defaultValue: <String, String>{})
  Map<String, String> lidarrHeaders;

  @JsonKey()
  @HiveField(3, defaultValue: false)
  bool radarrEnabled;

  @JsonKey()
  @HiveField(4, defaultValue: '')
  String radarrHost;

  @JsonKey()
  @HiveField(5, defaultValue: '')
  String radarrKey;

  @JsonKey()
  @HiveField(27, defaultValue: <String, String>{})
  Map<String, String> radarrHeaders;

  @JsonKey()
  @HiveField(6, defaultValue: false)
  bool sonarrEnabled;

  @JsonKey()
  @HiveField(7, defaultValue: '')
  String sonarrHost;

  @JsonKey()
  @HiveField(8, defaultValue: '')
  String sonarrKey;

  @JsonKey()
  @HiveField(28, defaultValue: <String, String>{})
  Map<String, String> sonarrHeaders;

  @JsonKey()
  @HiveField(9, defaultValue: false)
  bool sabnzbdEnabled;

  @JsonKey()
  @HiveField(10, defaultValue: '')
  String sabnzbdHost;

  @JsonKey()
  @HiveField(11, defaultValue: '')
  String sabnzbdKey;

  @JsonKey()
  @HiveField(29, defaultValue: <String, String>{})
  Map<String, String> sabnzbdHeaders;

  @JsonKey()
  @HiveField(12, defaultValue: false)
  bool nzbgetEnabled;

  @JsonKey()
  @HiveField(13, defaultValue: '')
  String nzbgetHost;

  @JsonKey()
  @HiveField(14, defaultValue: '')
  String nzbgetUser;

  @JsonKey()
  @HiveField(15, defaultValue: '')
  String nzbgetPass;

  @JsonKey()
  @HiveField(30, defaultValue: <String, String>{})
  Map<String, String> nzbgetHeaders;

  @JsonKey()
  @HiveField(23, defaultValue: false)
  bool wakeOnLANEnabled;

  @JsonKey()
  @HiveField(24, defaultValue: '')
  String wakeOnLANBroadcastAddress;

  @JsonKey()
  @HiveField(25, defaultValue: '')
  String wakeOnLANMACAddress;

  @JsonKey()
  @HiveField(31, defaultValue: false)
  bool tautulliEnabled;

  @JsonKey()
  @HiveField(32, defaultValue: '')
  String tautulliHost;

  @JsonKey()
  @HiveField(33, defaultValue: '')
  String tautulliKey;

  @JsonKey()
  @HiveField(35, defaultValue: <String, String>{})
  Map<String, String> tautulliHeaders;

  /// The caller's person has a Jellyfin badge and a provisioned, per-person
  /// Jellyfin account (via the tailarr-gate /self/jellyfin endpoints). Set by
  /// [GatewayJellyfinSync] probing the gateway; when false the Jellyfin module
  /// is hidden. Never a manual toggle — Jellyfin is entirely server-driven.
  @JsonKey()
  @HiveField(36, defaultValue: false)
  bool jellyfinEnabled;

  /// Last known Jellyfin base URL for this person (https MagicDNS). Persisted
  /// so a stopped pod (`url:""` in the handout) keeps showing the prior value
  /// instead of blanking out.
  @JsonKey()
  @HiveField(37, defaultValue: '')
  String jellyfinUrl;

  @JsonKey()
  @HiveField(44, defaultValue: false)
  bool tailarrServerEnabled;

  @JsonKey()
  @HiveField(47, defaultValue: false)
  bool tailscaleEnabled;

  @JsonKey()
  @HiveField(48, defaultValue: '')
  String tailscaleAuthKey;

  /// Logical node-identity name passed to tailscale_embed — generated ONCE
  /// when the profile first enables Tailscale and stored, never derived
  /// from the (renamable, free-form) profile name. The profile migrated
  /// from the old global settings owns 'default' (the plugin migrates the
  /// legacy node state there).
  @JsonKey()
  @HiveField(49, defaultValue: '')
  String tailscaleIdentity;

  @JsonKey()
  @HiveField(45, defaultValue: '')
  String tailarrServerHost;

  /// Native module types ('sonarr', 'radarr', …, 'tailarr') whose connection
  /// details came from the tailarr-gate /self/services endpoint and are
  /// reconciled on re-sync. A manual edit to a module's host/key removes it
  /// from this list so hand-entered configs are never clobbered.
  @JsonKey(defaultValue: <String>[])
  @HiveField(50, defaultValue: <String>[])
  List<String> gatewayManagedModules;

  /// This profile was created by joining a Tailarr Server via invite and is
  /// OWNED by that server: its name is locked (server-driven), and all of
  /// its configuration is managed by the server. Isolating server config in
  /// its own profile is what guarantees a user's hand-built profiles are
  /// never overwritten. The owning server is [tailarrServerHost].
  @JsonKey(defaultValue: false)
  @HiveField(51, defaultValue: false)
  bool serverOwned;

  /// The server tagged this profile's person "Basic" (`ui.basic` in
  /// /self/services). The app resolves it to a simplified shell — Settings
  /// hidden, no drawer, launched straight into the granted module. UX only:
  /// access is still governed by badges. Persisted so it applies before the
  /// first gateway call each session.
  @JsonKey(defaultValue: false)
  @HiveField(52, defaultValue: false)
  bool uiBasic;

  /// Whether the Settings surface is hidden for this profile (resolved from
  /// [uiBasic] today; an explicit server override later).
  bool get uiHidesSettings => uiBasic;

  /// Whether the navigation drawer is shown (Basic users get a drawerless,
  /// single-purpose shell).
  bool get uiShowsDrawer => !uiBasic;

  @JsonKey()
  @HiveField(46, defaultValue: <String, String>{})
  Map<String, String> tailarrServerHeaders;

  /// Admin bearer token for this server's controller `/api/*` calls, minted via
  /// Quick Connect self-config (server v0.78.0+). Empty until the device
  /// "Connect this device" self-configures. Sent as `Authorization: Bearer`;
  /// dropped on a stale 401 and re-minted. Per-server, profile-lifetime.
  @JsonKey()
  @HiveField(53, defaultValue: '')
  String serverAdminToken;

  @JsonKey()
  @HiveField(40, defaultValue: false)
  bool overseerrEnabled;

  @JsonKey()
  @HiveField(41, defaultValue: '')
  String overseerrHost;

  @JsonKey()
  @HiveField(42, defaultValue: '')
  String overseerrKey;

  @JsonKey()
  @HiveField(43, defaultValue: <String, String>{})
  Map<String, String> overseerrHeaders;

  LunaProfile._internal({
    //Lidarr
    required this.lidarrEnabled,
    required this.lidarrHost,
    required this.lidarrKey,
    required this.lidarrHeaders,
    //Radarr
    required this.radarrEnabled,
    required this.radarrHost,
    required this.radarrKey,
    required this.radarrHeaders,
    //Sonarr
    required this.sonarrEnabled,
    required this.sonarrHost,
    required this.sonarrKey,
    required this.sonarrHeaders,
    //SABnzbd
    required this.sabnzbdEnabled,
    required this.sabnzbdHost,
    required this.sabnzbdKey,
    required this.sabnzbdHeaders,
    //NZBGet
    required this.nzbgetEnabled,
    required this.nzbgetHost,
    required this.nzbgetUser,
    required this.nzbgetPass,
    required this.nzbgetHeaders,
    //Wake On LAN
    required this.wakeOnLANEnabled,
    required this.wakeOnLANBroadcastAddress,
    required this.wakeOnLANMACAddress,
    //Tailscale
    required this.tailscaleEnabled,
    required this.tailscaleAuthKey,
    required this.tailscaleIdentity,
    //Jellyfin
    required this.jellyfinEnabled,
    required this.jellyfinUrl,
    //Tailarr Server
    required this.tailarrServerEnabled,
    required this.tailarrServerHost,
    required this.tailarrServerHeaders,
    required this.serverAdminToken,
    //Gateway self-config
    required this.gatewayManagedModules,
    required this.serverOwned,
    required this.uiBasic,
    //Tautulli
    required this.tautulliEnabled,
    required this.tautulliHost,
    required this.tautulliKey,
    required this.tautulliHeaders,
    //Overseerr
    required this.overseerrEnabled,
    required this.overseerrHost,
    required this.overseerrKey,
    required this.overseerrHeaders,
  });

  factory LunaProfile({
    //Lidarr
    bool? lidarrEnabled,
    String? lidarrHost,
    String? lidarrKey,
    Map<String, String>? lidarrHeaders,
    //Radarr
    bool? radarrEnabled,
    String? radarrHost,
    String? radarrKey,
    Map<String, String>? radarrHeaders,
    //Sonarr
    bool? sonarrEnabled,
    String? sonarrHost,
    String? sonarrKey,
    Map<String, String>? sonarrHeaders,
    //SABnzbd
    bool? sabnzbdEnabled,
    String? sabnzbdHost,
    String? sabnzbdKey,
    Map<String, String>? sabnzbdHeaders,
    //NZBGet
    bool? nzbgetEnabled,
    String? nzbgetHost,
    String? nzbgetUser,
    String? nzbgetPass,
    Map<String, String>? nzbgetHeaders,
    //Wake On LAN
    bool? wakeOnLANEnabled,
    String? wakeOnLANBroadcastAddress,
    String? wakeOnLANMACAddress,
    //Tailscale
    bool? tailscaleEnabled,
    String? tailscaleAuthKey,
    String? tailscaleIdentity,
    //Jellyfin
    bool? jellyfinEnabled,
    String? jellyfinUrl,
    //Tailarr Server
    bool? tailarrServerEnabled,
    String? tailarrServerHost,
    Map<String, String>? tailarrServerHeaders,
    String? serverAdminToken,
    //Gateway self-config
    List<String>? gatewayManagedModules,
    bool? serverOwned,
    bool? uiBasic,
    //Tautulli
    bool? tautulliEnabled,
    String? tautulliHost,
    String? tautulliKey,
    Map<String, String>? tautulliHeaders,
    //Overseerr
    bool? overseerrEnabled,
    String? overseerrHost,
    String? overseerrKey,
    Map<String, String>? overseerrHeaders,
  }) {
    return LunaProfile._internal(
      // Lidarr
      lidarrEnabled: lidarrEnabled ?? false,
      lidarrHost: lidarrHost ?? '',
      lidarrKey: lidarrKey ?? '',
      lidarrHeaders: lidarrHeaders ?? {},
      // Radarr
      radarrEnabled: radarrEnabled ?? false,
      radarrHost: radarrHost ?? '',
      radarrKey: radarrKey ?? '',
      radarrHeaders: radarrHeaders ?? {},
      // Sonarr
      sonarrEnabled: sonarrEnabled ?? false,
      sonarrHost: sonarrHost ?? '',
      sonarrKey: sonarrKey ?? '',
      sonarrHeaders: sonarrHeaders ?? {},
      // SABnzbd
      sabnzbdEnabled: sabnzbdEnabled ?? false,
      sabnzbdHost: sabnzbdHost ?? '',
      sabnzbdKey: sabnzbdKey ?? '',
      sabnzbdHeaders: sabnzbdHeaders ?? {},
      // NZBGet
      nzbgetEnabled: nzbgetEnabled ?? false,
      nzbgetHost: nzbgetHost ?? '',
      nzbgetUser: nzbgetUser ?? '',
      nzbgetPass: nzbgetPass ?? '',
      nzbgetHeaders: nzbgetHeaders ?? {},
      // Wake On LAN
      wakeOnLANEnabled: wakeOnLANEnabled ?? false,
      wakeOnLANBroadcastAddress: wakeOnLANBroadcastAddress ?? '',
      wakeOnLANMACAddress: wakeOnLANMACAddress ?? '',
      // Tailscale
      tailscaleEnabled: tailscaleEnabled ?? false,
      tailscaleAuthKey: tailscaleAuthKey ?? '',
      tailscaleIdentity: tailscaleIdentity ?? '',
      // Jellyfin
      jellyfinEnabled: jellyfinEnabled ?? false,
      jellyfinUrl: jellyfinUrl ?? '',
      // Tailarr Server
      tailarrServerEnabled: tailarrServerEnabled ?? false,
      tailarrServerHost: tailarrServerHost ?? '',
      tailarrServerHeaders: tailarrServerHeaders ?? {},
      serverAdminToken: serverAdminToken ?? '',
      // Gateway self-config
      gatewayManagedModules: gatewayManagedModules ?? [],
      serverOwned: serverOwned ?? false,
      uiBasic: uiBasic ?? false,
      // Tautulli
      tautulliEnabled: tautulliEnabled ?? false,
      tautulliHost: tautulliHost ?? '',
      tautulliKey: tautulliKey ?? '',
      tautulliHeaders: tautulliHeaders ?? {},
      // Overseerr
      overseerrEnabled: overseerrEnabled ?? false,
      overseerrHost: overseerrHost ?? '',
      overseerrKey: overseerrKey ?? '',
      overseerrHeaders: overseerrHeaders ?? {},
    );
  }

  @override
  String toString() => json.encode(this.toJson());

  Map<String, dynamic> toJson() {
    final json = _$LunaProfileToJson(this);
    json['key'] = key.toString();
    return json;
  }

  factory LunaProfile.fromJson(Map<String, dynamic> json) {
    return _$LunaProfileFromJson(json);
  }

  factory LunaProfile.clone(LunaProfile profile) {
    return LunaProfile.fromJson(profile.toJson().cast<String, dynamic>());
  }

  factory LunaProfile.get(String key) {
    return LunaBox.profiles.read(key)!;
  }

  bool isAnythingEnabled() {
    for (final module in LunaModule.active) {
      if (module.isEnabled) return true;
    }
    return false;
  }
}
