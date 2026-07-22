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

  LunaNotification({
    required this.id,
    required this.time,
    required this.topic,
    this.title,
    this.body,
    this.priority = 3,
    this.tags = const [],
    this.read = false,
  });

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
    };
  }
}
