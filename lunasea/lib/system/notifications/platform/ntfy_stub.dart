import 'package:lunasea/system/notifications/ntfy_hive_migration.dart';

/// Web stub — the notification inbox renders from Hive everywhere, but
/// syncing, streaming, and background refresh are dart:io only.
class LunaNtfy {
  static bool get isSupported => false;
  static bool get isBackgroundRefreshSupported => false;

  Future<void> initialize() async {}
  Future<int> syncInbox() async => 0;
  void restartStream() {}
  Future<void> onConfigChanged() async {}
  // Inbox + config keys live in Hive on web too, so migrate/purge them here
  // (the file-backed shared-state slice is dart:io-only, hence absent).
  Future<void> migrateProfileName(String oldName, String newName) =>
      NtfyHiveMigration.migrate(oldName, newName);
  Future<void> purgeProfileName(String name) => NtfyHiveMigration.purge(name);
  Future<void> recordDismissed(Iterable<String> ids, {String? profile}) async {}
  Future<bool> enableBackgroundRefresh() async => false;
  Future<void> disableBackgroundRefresh() async {}
  Future<dynamic> autoConfigure() async => null;
}
