import 'package:lunasea/core.dart';

part 'notification.g.dart';

/// One entry in the local notification inbox. Stored in
/// [LunaBox.notifications] keyed by the ntfy message id, so repeated polls
/// naturally dedupe.
@HiveType(typeId: 30, adapterName: 'LunaNotificationAdapter')
class LunaNotification extends HiveObject {
  @HiveField(0)
  final String id;
  @HiveField(1)
  final int time;
  @HiveField(2)
  final String topic;
  @HiveField(3)
  final String? title;
  @HiveField(4)
  final String? body;
  @HiveField(5, defaultValue: 3)
  final int priority;
  @HiveField(6, defaultValue: [])
  final List<String> tags;
  @HiveField(7, defaultValue: false)
  bool read;

  /// The profile (Tailarr Server) this alert belongs to. The inbox filters
  /// on it so each server-owned profile sees only its own notifications.
  /// Empty on legacy pre-per-profile entries (shown under any profile).
  @HiveField(8, defaultValue: '')
  final String profile;

  LunaNotification({
    required this.id,
    required this.time,
    required this.topic,
    this.title,
    this.body,
    this.priority = 3,
    this.tags = const [],
    this.read = false,
    this.profile = '',
  });

  /// The box key: profile-namespaced so the same ntfy message id on two
  /// different servers can't collide, and per-profile dedupe still works.
  static String boxKey(String profile, String id) => '$profile $id';

  /// Whether this entry belongs to [activeProfile]. Legacy untagged entries
  /// (empty profile) show under any profile.
  bool matchesProfile(String activeProfile) =>
      profile.isEmpty || profile == activeProfile;

  DateTime get timestamp =>
      DateTime.fromMillisecondsSinceEpoch(time * 1000);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'time': time,
      'topic': topic,
      if (title != null) 'title': title,
      if (body != null) 'body': body,
      'priority': priority,
      if (tags.isNotEmpty) 'tags': tags,
      'read': read,
      if (profile.isNotEmpty) 'profile': profile,
    };
  }
}
