/// Models for the ntfy (ntfy.sh) publish-subscribe protocol, as served by
/// the Tailarr Server ntfy system pod.
library ntfy_models;

import 'dart:convert';

/// A subscription handed out by the server: where the ntfy pod lives, the
/// access token to read with, and which topics to follow. This is the exact
/// shape the server's future QR / deep-link handout delivers:
/// `{"url": "https://…", "token": "tk_…", "topics": ["tlr-ops", …]}`.
class NtfySubscription {
  final String url;
  final String token;
  final List<String> topics;

  const NtfySubscription({
    required this.url,
    required this.token,
    required this.topics,
  });

  bool get isValid => url.isNotEmpty && topics.isNotEmpty;

  factory NtfySubscription.fromJson(Map<String, dynamic> json) {
    return NtfySubscription(
      url: (json['url'] as String? ?? '').trim().replaceAll(RegExp(r'/+$'), ''),
      token: (json['token'] as String? ?? '').trim(),
      topics: (json['topics'] as List? ?? [])
          .map((t) => t.toString().trim())
          .where((t) => t.isNotEmpty)
          .toList(),
    );
  }

  /// Parses a `tailarr://ntfy?url=…&token=…&topics=a,b` deep link, or the
  /// same parameters carried by any URI (the future QR payload).
  factory NtfySubscription.fromUri(Uri uri) {
    return NtfySubscription.fromJson({
      'url': uri.queryParameters['url'] ?? '',
      'token': uri.queryParameters['token'] ?? '',
      'topics': (uri.queryParameters['topics'] ?? '').split(','),
    });
  }

  /// Accepts either the JSON handout or a deep-link/QR URI as pasted text.
  /// Returns null if the input parses but contains no usable subscription.
  static NtfySubscription? parse(String input) {
    final text = input.trim();
    NtfySubscription? result;
    if (text.startsWith('{')) {
      try {
        result = NtfySubscription.fromJson(json.decode(text));
      } catch (_) {
        return null;
      }
    } else {
      final uri = Uri.tryParse(text);
      if (uri == null) return null;
      result = NtfySubscription.fromUri(uri);
    }
    return result.isValid ? result : null;
  }

  Map<String, dynamic> toJson() => {
        'url': url,
        'token': token,
        'topics': topics,
      };
}

/// `GET http://tailarr-gate/self/notifications` (tailarr-server v0.21.0+).
/// The gateway whois-authenticates the caller by tailnet source address and
/// returns THAT person's ntfy credentials — no auth material in the request.
class NtfyGatewayCredentials {
  final bool ok;
  final String? error;
  final String url;
  final String user;
  final String password;
  final String token;
  final List<String> topics;

  /// HTTP status of the gateway response — surfaced in the FAILED state so
  /// debugging is never blind to what actually came back.
  final int? statusCode;

  const NtfyGatewayCredentials({
    required this.ok,
    required this.error,
    required this.url,
    required this.user,
    required this.password,
    required this.token,
    required this.topics,
    this.statusCode,
  });

  /// The gateway's "this machine isn't attached to any person" refusal —
  /// the fix is an admin action (assign the device), not a retry.
  bool get isUnassigned =>
      !ok && (error ?? '').toLowerCase().contains('not assigned');

  NtfySubscription get subscription =>
      NtfySubscription(url: url, token: token, topics: topics);

  factory NtfyGatewayCredentials.fromJson(
    Map<String, dynamic> json, {
    int? statusCode,
  }) {
    final error = json['error'];
    return NtfyGatewayCredentials(
      ok: json['ok'] == true,
      statusCode: statusCode,
      error: error == null ? null : error.toString(),
      url: (json['url'] as String? ?? '')
          .trim()
          .replaceAll(RegExp(r'/+$'), ''),
      user: json['user'] as String? ?? '',
      password: json['password'] as String? ?? '',
      token: json['token'] as String? ?? '',
      topics:
          (json['topics'] as List? ?? []).map((t) => t.toString()).toList(),
    );
  }
}

/// Maps a Tailarr topic name to its display label: `tlr-ops` is the server
/// itself, `tlr-media-<service>` is the service's name.
String ntfyTopicLabel(String topic) {
  if (topic == 'tlr-ops') return 'Server';
  if (topic.startsWith('tlr-media-')) {
    final service = topic.substring('tlr-media-'.length);
    if (service.isNotEmpty) {
      return service[0].toUpperCase() + service.substring(1);
    }
  }
  return topic;
}

/// A single message from an ntfy JSON/ndjson feed. Non-"message" events
/// (open, keepalive) are still parsed — callers filter on [isMessage].
class NtfyMessage {
  final String id;
  final int time;
  final String event;
  final String topic;
  final String? title;
  final String? message;
  final int priority;
  final List<String> tags;
  final String? attachmentName;
  final String? attachmentUrl;

  const NtfyMessage({
    required this.id,
    required this.time,
    required this.event,
    required this.topic,
    this.title,
    this.message,
    this.priority = 3,
    this.tags = const [],
    this.attachmentName,
    this.attachmentUrl,
  });

  bool get isMessage => event == 'message';

  factory NtfyMessage.fromJson(Map<String, dynamic> json) {
    final attachment = json['attachment'] as Map<String, dynamic>?;
    return NtfyMessage(
      id: json['id'] as String? ?? '',
      time: json['time'] as int? ?? 0,
      event: json['event'] as String? ?? '',
      topic: json['topic'] as String? ?? '',
      title: json['title'] as String?,
      message: json['message'] as String?,
      priority: json['priority'] as int? ?? 3,
      tags: (json['tags'] as List? ?? []).map((t) => t.toString()).toList(),
      attachmentName: attachment?['name'] as String?,
      attachmentUrl: attachment?['url'] as String?,
    );
  }

  /// Parses one line of an ndjson feed; returns null for blank/broken lines.
  static NtfyMessage? fromLine(String line) {
    final text = line.trim();
    if (text.isEmpty) return null;
    try {
      final decoded = json.decode(text);
      if (decoded is! Map<String, dynamic>) return null;
      return NtfyMessage.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }
}
