import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/models/notification.dart';
import 'package:lunasea/database/tables/notifications.dart';

/// Platform-neutral (Hive-only) parts of per-profile notification state
/// migration and purge, shared by the dart:io plugin AND the web stub so both
/// platforms clean up the config keys + inbox rows on a profile rename/delete.
/// The file-backed shared-state slice is dart:io-only and handled separately by
/// the io implementation. See docs/security-audit-2026-07-28.md (H4/L1).
class NtfyHiveMigration {
  NtfyHiveMigration._();

  static const _prefix = 'NOTIFICATIONS_'; // LunaTable.notifications.key.upper

  /// Move the `NOTIFICATIONS_<FIELD>@<profile>` config keys and every inbox
  /// entry tagged [oldName] over to [newName].
  static Future<void> migrate(String oldName, String newName) async {
    if (oldName == newName || newName.isEmpty) return;

    for (final field in NotificationsDatabase.values) {
      final oldKey = '$_prefix${field.name}@$oldName';
      if (!LunaBox.lunasea.contains(oldKey)) continue;
      await LunaBox.lunasea.update(
        '$_prefix${field.name}@$newName',
        LunaBox.lunasea.read(oldKey),
      );
      await LunaBox.lunasea.delete(oldKey);
    }

    for (final key in LunaBox.notifications.keys.toList()) {
      final n = LunaBox.notifications.read(key);
      if (n == null || n.profile != oldName) continue;
      await LunaBox.notifications.update(
        LunaNotification.boxKey(newName, n.id),
        LunaNotification(
          id: n.id,
          time: n.time,
          topic: n.topic,
          title: n.title,
          body: n.body,
          priority: n.priority,
          tags: n.tags,
          read: n.read,
          profile: newName,
        ),
      );
      await LunaBox.notifications.delete(key);
    }
  }

  /// Delete the config keys and inbox entries for a removed profile [name].
  static Future<void> purge(String name) async {
    if (name.isEmpty) return;

    for (final field in NotificationsDatabase.values) {
      final key = '$_prefix${field.name}@$name';
      if (LunaBox.lunasea.contains(key)) await LunaBox.lunasea.delete(key);
    }

    for (final key in LunaBox.notifications.keys.toList()) {
      final n = LunaBox.notifications.read(key);
      if (n == null || n.profile != name) continue;
      await LunaBox.notifications.delete(key);
    }
  }
}
