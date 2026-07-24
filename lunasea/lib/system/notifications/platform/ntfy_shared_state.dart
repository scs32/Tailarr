import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:lunasea/api/ntfy/models.dart';
import 'package:path_provider/path_provider.dart';

/// One profile's ntfy subscription + since-markers. Each server-owned
/// profile joins a different Tailarr Server, so each has its own slice:
/// its own subscription, its own inbox catch-up marker ([since]) and its
/// own background-notify marker ([bgSince]).
class NtfyProfileState {
  final String profile;
  String url;
  String token;
  List<String> topics;
  int since;
  int bgSince;
  List<String> notifiedIds;

  NtfyProfileState({
    required this.profile,
    this.url = '',
    this.token = '',
    this.topics = const [],
    this.since = 0,
    this.bgSince = 0,
    this.notifiedIds = const [],
  });

  NtfySubscription? get subscription {
    final sub = NtfySubscription(url: url, token: token, topics: topics);
    return sub.isValid ? sub : null;
  }

  String get sinceParameter => since == 0 ? 'all' : since.toString();

  Map<String, dynamic> toJson() => {
        'url': url,
        'token': token,
        'topics': topics,
        'since': since,
        'bg_since': bgSince,
        // Guards against double-notifying messages published in the same
        // second the marker points at (ntfy `since` is inclusive-ish).
        'notified_ids': notifiedIds.take(25).toList(),
      };

  factory NtfyProfileState.fromJson(String profile, Map data) {
    return NtfyProfileState(
      profile: profile,
      url: data['url'] as String? ?? '',
      token: data['token'] as String? ?? '',
      topics:
          (data['topics'] as List? ?? []).map((t) => t.toString()).toList(),
      since: data['since'] as int? ?? 0,
      bgSince: data['bg_since'] as int? ?? 0,
      notifiedIds:
          (data['notified_ids'] as List? ?? []).map((i) => i.toString()).toList(),
    );
  }
}

/// The subscription state shared between the main app, the background-refresh
/// isolate, and the Notification Service Extension — a plain JSON file in the
/// App Group container. The background isolate and NSE must NEVER open Hive,
/// so this file is their only source of truth; the main isolate mirrors the
/// Hive-backed per-profile settings into it on every change.
///
/// It holds EVERY profile's slice (keyed by profile name) plus which profile
/// is active, so the background refresh and the push extension fetch each
/// server independently and attribute correctly, while the foreground uses
/// the active slice.
class NtfySharedState {
  Map<String, NtfyProfileState> profiles;
  String activeProfile;
  bool backgroundEnabled;

  NtfySharedState({
    Map<String, NtfyProfileState>? profiles,
    this.activeProfile = '',
    this.backgroundEnabled = false,
  }) : profiles = profiles ?? {};

  /// The active profile's slice (foreground stream + inbox catch-up).
  NtfyProfileState? get active => profiles[activeProfile];

  /// Every profile with a usable subscription (background refresh + NSE).
  List<NtfyProfileState> get subscribed =>
      profiles.values.where((p) => p.subscription != null).toList();

  /// Ensures a slice for [profile] exists and returns it.
  NtfyProfileState slice(String profile) =>
      profiles.putIfAbsent(profile, () => NtfyProfileState(profile: profile));

  static const _channel = MethodChannel('com.stephenspeicher.tailarr/push');
  static String? _appGroupPath;
  static bool _appGroupResolved = false;

  static Future<File> _file() async {
    if (!_appGroupResolved) {
      _appGroupResolved = true;
      try {
        _appGroupPath = await _channel.invokeMethod<String>('getAppGroupPath');
      } catch (_) {
        _appGroupPath = null;
      }
    }
    final legacy = File(
      '${(await getApplicationSupportDirectory()).path}/tailarr_ntfy.json',
    );
    final group = _appGroupPath;
    if (group == null || group.isEmpty) return legacy;
    final file = File('$group/tailarr_ntfy.json');
    if (!await file.exists() && await legacy.exists()) {
      try {
        await legacy.copy(file.path);
      } catch (_) {}
    }
    return file;
  }

  static Future<NtfySharedState> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return NtfySharedState();
      final data = json.decode(await file.readAsString());
      if (data is! Map) return NtfySharedState();

      final profiles = <String, NtfyProfileState>{};
      final rawProfiles = data['profiles'];
      if (rawProfiles is Map) {
        rawProfiles.forEach((key, value) {
          if (value is Map) {
            profiles[key.toString()] =
                NtfyProfileState.fromJson(key.toString(), value);
          }
        });
      } else if (data['url'] != null) {
        // Legacy single-profile file — fold it into a 'default' slice so
        // markers survive the upgrade.
        profiles['default'] = NtfyProfileState.fromJson('default', data);
      }
      return NtfySharedState(
        profiles: profiles,
        activeProfile: data['active'] as String? ?? 'default',
        backgroundEnabled: data['background_enabled'] as bool? ?? false,
      );
    } catch (_) {
      return NtfySharedState();
    }
  }

  Future<void> save() async {
    final file = await _file();
    await file.writeAsString(json.encode({
      'active': activeProfile,
      'background_enabled': backgroundEnabled,
      'profiles': {
        for (final entry in profiles.entries) entry.key: entry.value.toJson(),
      },
    }));
  }
}
