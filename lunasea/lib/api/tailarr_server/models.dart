/// Models for the Tailarr Server JSON API.
///
/// Field names mirror the server's Flask handlers (`web/app.py`) exactly —
/// the API has no schema/codegen, so these are hand-written and tolerant of
/// missing keys.
library tailarr_server_models;

String _string(dynamic value) => value?.toString() ?? '';
bool _bool(dynamic value) => value == true;
int _int(dynamic value) => value is num ? value.toInt() : 0;

/// `GET /api/info`
class TailarrServerInfo {
  final int apiVersion;
  final String version;
  final String podsDir;
  final List<String> controllerPods;
  final bool upgradeAvailable;

  const TailarrServerInfo({
    required this.apiVersion,
    required this.version,
    required this.podsDir,
    required this.controllerPods,
    required this.upgradeAvailable,
  });

  factory TailarrServerInfo.fromJson(Map<String, dynamic> json) {
    return TailarrServerInfo(
      apiVersion: _int(json['api_version']),
      version: _string(json['version']),
      podsDir: _string(json['pods_dir']),
      controllerPods: (json['controller_pods'] as List? ?? [])
          .map((e) => e.toString())
          .toList(),
      upgradeAvailable: _bool(json['upgrade_available']),
    );
  }
}

/// One entry of `GET /api/pods`
class TailarrServerPod {
  final String name;
  final String state;
  final bool controller;
  final String image;
  final bool tailscale;
  final bool https;
  final List<String> shares;
  final bool updateAvailable;
  final String busy;
  final String identity;

  const TailarrServerPod({
    required this.name,
    required this.state,
    required this.controller,
    required this.image,
    required this.tailscale,
    required this.https,
    required this.shares,
    required this.updateAvailable,
    required this.busy,
    required this.identity,
  });

  bool get isRunning => state == 'running';
  bool get isBusy => busy.isNotEmpty;
  bool get identityMissing => tailscale && identity == 'missing';

  factory TailarrServerPod.fromJson(Map<String, dynamic> json) {
    final busy = json['busy'];
    return TailarrServerPod(
      name: _string(json['name']),
      state: _string(json['state']),
      controller: _bool(json['controller']),
      image: _string(json['image']),
      tailscale: _bool(json['tailscale']),
      https: _bool(json['https']),
      shares:
          (json['shares'] as List? ?? []).map((e) => e.toString()).toList(),
      updateAvailable: _bool(json['update']),
      busy: busy == null || busy == false ? '' : busy.toString(),
      identity: _string(json['identity']),
    );
  }
}

/// One entry of `GET /api/network`
class TailarrServerNetworkEntry {
  final String name;
  final String state;
  final bool controller;
  final bool tailscale;
  final bool https;
  final bool funnel;
  final String networkMode;
  final Map<String, String> ports;
  final String ip;
  final String dnsName;
  final String busy;

  const TailarrServerNetworkEntry({
    required this.name,
    required this.state,
    required this.controller,
    required this.tailscale,
    required this.https,
    required this.funnel,
    required this.networkMode,
    required this.ports,
    required this.ip,
    required this.dnsName,
    required this.busy,
  });

  /// Funnel can be toggled: the pod serves HTTPS and is not the controller.
  bool get canTogglePublic => https && !controller;
  bool get isBusy => busy.isNotEmpty;

  /// Best launch URL for the pod — mirrors the server's `service_url()`:
  /// HTTPS on the MagicDNS name when tailscale serve terminates TLS, else
  /// plain HTTP on the first published port.
  String get serviceUrl {
    final port = ports.values.isEmpty ? '' : ports.values.first;
    final host = dnsName.isNotEmpty ? dnsName : ip;
    if (host.isEmpty) return '';
    if (https && dnsName.isNotEmpty) return 'https://$dnsName';
    return port.isEmpty ? 'http://$host' : 'http://$host:$port';
  }

  factory TailarrServerNetworkEntry.fromJson(Map<String, dynamic> json) {
    final busy = json['busy'];
    return TailarrServerNetworkEntry(
      name: _string(json['name']),
      state: _string(json['state']),
      controller: _bool(json['controller']),
      tailscale: _bool(json['tailscale']),
      https: _bool(json['https']),
      funnel: _bool(json['funnel']),
      networkMode: _string(json['network_mode']),
      ports: (json['ports'] as Map? ?? {})
          .map((k, v) => MapEntry(k.toString(), v.toString())),
      ip: _string(json['ip']),
      dnsName: _string(json['dns_name']),
      busy: busy == null || busy == false ? '' : busy.toString(),
    );
  }
}

/// One device of `GET /api/users`
class TailarrServerUserDevice {
  final String id;
  final String hostname;
  final String nickname;
  final String os;
  final DateTime? lastSeen;
  final String ip;
  final List<String> can;

  const TailarrServerUserDevice({
    required this.id,
    required this.hostname,
    required this.nickname,
    required this.os,
    required this.lastSeen,
    required this.ip,
    required this.can,
  });

  String get displayName => nickname.isNotEmpty ? nickname : hostname;

  /// Tailscale reports a recent last-seen for connected devices.
  bool get isOnline =>
      lastSeen != null &&
      DateTime.now().toUtc().difference(lastSeen!.toUtc()).inMinutes < 2;

  factory TailarrServerUserDevice.fromJson(Map<String, dynamic> json) {
    return TailarrServerUserDevice(
      id: _string(json['id']),
      hostname: _string(json['hostname']),
      nickname: _string(json['nickname']),
      os: _string(json['os']),
      lastSeen: DateTime.tryParse(_string(json['last_seen'])),
      ip: _string(json['ip']),
      can: (json['can'] as List? ?? []).map((e) => e.toString()).toList(),
    );
  }
}

/// `GET /api/users`
class TailarrServerUsers {
  /// Whether the server has Tailscale API credentials — the users features
  /// are gated on this.
  final bool configured;
  final String? error;
  final List<TailarrServerUserDevice> users;
  final List<String> services;

  const TailarrServerUsers({
    required this.configured,
    required this.error,
    required this.users,
    required this.services,
  });

  factory TailarrServerUsers.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    return TailarrServerUsers(
      configured: _bool(json['configured']),
      error: error == null ? null : error.toString(),
      users: (json['users'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(TailarrServerUserDevice.fromJson)
          .toList(),
      services:
          (json['services'] as List? ?? []).map((e) => e.toString()).toList(),
    );
  }
}

/// `POST /api/users/keys` — a single-use, preauthorized, 24h enrollment key.
class TailarrServerUserKey {
  final bool ok;
  final String? error;
  final String key;

  const TailarrServerUserKey({
    required this.ok,
    required this.error,
    required this.key,
  });

  factory TailarrServerUserKey.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    return TailarrServerUserKey(
      ok: _bool(json['ok']),
      error: error == null ? null : error.toString(),
      key: _string(json['key']),
    );
  }
}

/// `POST /api/users/adopt`
class TailarrServerAdoptResult {
  final bool ok;
  final String id;
  final String hostname;
  final String? error;

  const TailarrServerAdoptResult({
    required this.ok,
    required this.id,
    required this.hostname,
    required this.error,
  });

  factory TailarrServerAdoptResult.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    return TailarrServerAdoptResult(
      ok: _bool(json['ok']),
      id: _string(json['id']),
      hostname: _string(json['hostname']),
      error: error == null ? null : error.toString(),
    );
  }
}

/// Result dict shared by pod actions, logs, backup create/restore/delete.
class TailarrServerActionResult {
  final bool ok;
  final String name;
  final String action;
  final String status;
  final String? error;
  final String output;

  const TailarrServerActionResult({
    required this.ok,
    required this.name,
    required this.action,
    required this.status,
    required this.error,
    required this.output,
  });

  factory TailarrServerActionResult.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    return TailarrServerActionResult(
      ok: _bool(json['ok']),
      name: _string(json['name']),
      action: _string(json['action']),
      status: _string(json['status']),
      error: error == null ? null : error.toString(),
      output: _string(json['output']),
    );
  }
}

/// One entry of `GET /api/pods/<name>/backups`
class TailarrServerBackup {
  final String ts;
  final String image;
  final int size;
  final String reason;

  const TailarrServerBackup({
    required this.ts,
    required this.image,
    required this.size,
    required this.reason,
  });

  /// `ts` is `YYYYMMDD-HHMMSS` — parse for display.
  DateTime? get timestamp {
    if (ts.length != 15) return null;
    return DateTime.tryParse(
      '${ts.substring(0, 8)}T${ts.substring(9)}',
    );
  }

  factory TailarrServerBackup.fromJson(Map<String, dynamic> json) {
    return TailarrServerBackup(
      ts: _string(json['ts']),
      image: _string(json['image']),
      size: _int(json['size']),
      reason: _string(json['reason']),
    );
  }
}

/// Per-image entry of `GET /api/updates`
class TailarrServerImageUpdate {
  final String image;
  final bool updateAvailable;

  const TailarrServerImageUpdate({
    required this.image,
    required this.updateAvailable,
  });
}

/// `GET /api/updates`
class TailarrServerUpdates {
  final bool checking;
  final int checked;
  final List<TailarrServerImageUpdate> images;

  const TailarrServerUpdates({
    required this.checking,
    required this.checked,
    required this.images,
  });

  factory TailarrServerUpdates.fromJson(Map<String, dynamic> json) {
    final images = (json['images'] as Map? ?? {});
    return TailarrServerUpdates(
      checking: _bool(json['checking']),
      checked: _int(json['checked']),
      images: images.entries
          .map((e) => TailarrServerImageUpdate(
                image: e.key.toString(),
                updateAvailable:
                    e.value is Map && _bool((e.value as Map)['update']),
              ))
          .toList(),
    );
  }
}

/// `POST /api/fleet`
class TailarrServerFleetResult {
  final bool ok;
  final String action;
  final String status;
  final String? error;
  final List<TailarrServerActionResult> results;

  const TailarrServerFleetResult({
    required this.ok,
    required this.action,
    required this.status,
    required this.error,
    required this.results,
  });

  factory TailarrServerFleetResult.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    return TailarrServerFleetResult(
      ok: _bool(json['ok']),
      action: _string(json['action']),
      status: _string(json['status']),
      error: error == null ? null : error.toString(),
      results: (json['results'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(TailarrServerActionResult.fromJson)
          .toList(),
    );
  }
}
