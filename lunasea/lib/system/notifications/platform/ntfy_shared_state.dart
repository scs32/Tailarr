import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:lunasea/api/ntfy/models.dart';
import 'package:path_provider/path_provider.dart';

/// Subscription config + since-markers shared between the main app and the
/// background-refresh isolate through a plain JSON file. The background
/// isolate must never open the Hive boxes (Hive is not multi-isolate safe),
/// so this file is its only source of truth; the main isolate mirrors the
/// Hive-backed settings into it on every change.
///
/// Two markers on purpose:
/// - [since]: how far the INBOX has caught up. Advanced only by the main
///   isolate, after messages are safely stored in Hive.
/// - [bgSince]: how far background LOCAL NOTIFICATIONS have caught up.
///   Advanced by the background isolate after notifying, and by the main
///   isolate after storing (messages seen live in-app must not re-notify).
class NtfySharedState {
  String url;
  String token;
  List<String> topics;
  int since;
  int bgSince;
  List<String> notifiedIds;
  bool backgroundEnabled;

  NtfySharedState({
    this.url = '',
    this.token = '',
    this.topics = const [],
    this.since = 0,
    this.bgSince = 0,
    this.notifiedIds = const [],
    this.backgroundEnabled = false,
  });

  NtfySubscription? get subscription {
    final sub = NtfySubscription(url: url, token: token, topics: topics);
    return sub.isValid ? sub : null;
  }

  /// The `since` parameter for an inbox poll: everything on first sync.
  String get sinceParameter => since == 0 ? 'all' : since.toString();

  /// The file lives in the App Group container so the Notification Service
  /// Extension (a separate process) can read the config and advance the
  /// same markers. Falls back to Application Support when the container is
  /// unavailable (no entitlement yet, non-iOS, channel missing).
  static const _channel = MethodChannel('com.stephenspeicher.tailarr/push');
  static String? _appGroupPath;
  static bool _appGroupResolved = false;

  static Future<File> _file() async {
    if (!_appGroupResolved) {
      _appGroupResolved = true;
      try {
        _appGroupPath =
            await _channel.invokeMethod<String>('getAppGroupPath');
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
    // One-time migration: carry the pre-App-Group state (config + markers)
    // over so nothing re-notifies after the upgrade.
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
      return NtfySharedState(
        url: data['url'] as String? ?? '',
        token: data['token'] as String? ?? '',
        topics: (data['topics'] as List? ?? [])
            .map((t) => t.toString())
            .toList(),
        since: data['since'] as int? ?? 0,
        bgSince: data['bg_since'] as int? ?? 0,
        notifiedIds: (data['notified_ids'] as List? ?? [])
            .map((i) => i.toString())
            .toList(),
        backgroundEnabled: data['background_enabled'] as bool? ?? false,
      );
    } catch (_) {
      return NtfySharedState();
    }
  }

  Future<void> save() async {
    final file = await _file();
    await file.writeAsString(json.encode({
      'url': url,
      'token': token,
      'topics': topics,
      'since': since,
      'bg_since': bgSince,
      // Guards against double-notifying messages published in the same
      // second the marker points at (ntfy `since` is inclusive-ish).
      'notified_ids': notifiedIds.take(25).toList(),
      'background_enabled': backgroundEnabled,
    }));
  }
}
