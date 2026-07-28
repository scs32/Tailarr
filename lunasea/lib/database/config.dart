import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/database/database.dart';
import 'package:lunasea/database/models/external_module.dart';
import 'package:lunasea/database/models/indexer.dart';
import 'package:lunasea/database/table.dart';

class LunaConfig {
  Future<void> import(BuildContext context, String data) async {
    // Security/robustness: NEVER let a bad restore destroy the user's data. The
    // old code cleared the database first, so a truncated/malformed/empty/
    // "valid-enough" file (`{}`, `{"profiles":[1]}`, …) wiped every profile,
    // credential, indexer, module, and setting irrecoverably. Now:
    //   1. cheaply reject structurally-invalid input before touching anything;
    //   2. snapshot the live config;
    //   3. apply; and on ANY failure (incl. "no usable profile") roll the
    //      snapshot BACK instead of resetting to defaults.
    // See docs/security-audit-2026-07-28.md (H1).
    final Map<String, dynamic> config = _parseAndValidate(data);
    final _ConfigSnapshot snapshot = _snapshot();

    await LunaDatabase().clear();
    try {
      _setProfiles(config[LunaBox.profiles.key]);
      _setIndexers(config[LunaBox.indexers.key]);
      _setExternalModules(config[LunaBox.externalModules.key]);
      for (final table in LunaTable.values) table.import(config[table.key]);

      // A backup with no usable profile would leave the app unusable — treat it
      // as a failed restore and roll back rather than seat the user on defaults.
      if (LunaProfile.list.isEmpty) {
        throw const FormatException('Backup contained no profiles.');
      }
      if (!LunaProfile.list.contains(LunaSeaDatabase.ENABLED_PROFILE.read())) {
        LunaSeaDatabase.ENABLED_PROFILE.update(LunaProfile.list.first);
      }

      // A restored backup can carry server-attached profiles from a build
      // that predates serverOwned — the launch migration already ran before
      // this manual restore, so convert them now too.
      LunaDatabase().migrateLegacyServerProfiles();

      // Device-local secrets (the ntfy bearer + APNs push token) are
      // deliberately absent from the export (H2). Carry THIS device's current
      // values forward for any profile that still exists so restoring your own
      // device's backup doesn't drop live notifications until the gateway
      // re-mints them. See docs/security-audit-2026-07-28.md (H2).
      await _restoreLocalTokens(snapshot);
    } catch (error, stack) {
      await _restoreSnapshot(snapshot);
      LunaLogger().error(
        'Invalid backup — restored previous configuration',
        error,
        stack,
      );
      LunaState.reset(context);
      rethrow;
    }

    LunaState.reset(context);
  }

  /// An in-memory copy of everything [import] can overwrite, used to roll back a
  /// failed restore. Profiles/indexers/modules are captured as their serialized
  /// maps (re-applied via `fromJson`, so no stale HiveObject is reused); the
  /// `lunasea` box (all table state, incl. the device-local tokens that are
  /// blocked from export) is captured raw.
  _ConfigSnapshot _snapshot() {
    final lunasea = <dynamic, dynamic>{};
    for (final key in LunaBox.lunasea.keys) {
      lunasea[key] = LunaBox.lunasea.read(key);
    }
    return _ConfigSnapshot(
      profiles: LunaBox.profiles.export(),
      indexers: LunaBox.indexers.export(),
      externalModules: LunaBox.externalModules.export(),
      lunasea: lunasea,
    );
  }

  Future<void> _restoreSnapshot(_ConfigSnapshot snapshot) async {
    await LunaDatabase().clear();
    _setProfiles(snapshot.profiles);
    _setIndexers(snapshot.indexers);
    _setExternalModules(snapshot.externalModules);
    for (final entry in snapshot.lunasea.entries) {
      await LunaBox.lunasea.update(entry.key, entry.value);
    }
  }

  /// Refill the device-local notification tokens (`NOTIFICATIONS_TOKEN@…`,
  /// `NOTIFICATIONS_PUSH_TOKEN@…`) from [snapshot] for any profile that survived
  /// the restore and whose imported value is empty (the backup never carries
  /// them). Never overwrites a value the backup did set.
  Future<void> _restoreLocalTokens(_ConfigSnapshot snapshot) async {
    const prefixes = ['NOTIFICATIONS_TOKEN@', 'NOTIFICATIONS_PUSH_TOKEN@'];
    for (final entry in snapshot.lunasea.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value == null || value == '') continue;
      final prefix = prefixes.firstWhere(
        (p) => key.startsWith(p),
        orElse: () => '',
      );
      if (prefix.isEmpty) continue;
      final profile = key.substring(prefix.length);
      if (!LunaProfile.list.contains(profile)) continue;
      final current = LunaBox.lunasea.read(key);
      if (current == null || current == '') {
        await LunaBox.lunasea.update(key, value);
      }
    }
  }

  /// Decode [data] and confirm it is a configuration object with correctly-
  /// typed sections, WITHOUT mutating the database. Throws [FormatException]
  /// on anything malformed so [import] can bail before it clears anything.
  Map<String, dynamic> _parseAndValidate(String data) {
    final dynamic decoded;
    try {
      decoded = json.decode(data);
    } catch (_) {
      throw const FormatException('Backup is not valid JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Backup is not a configuration object.');
    }
    // Section shapes: profiles/indexers/externalModules are lists; every
    // LunaTable section is a map. Absent sections are fine (skipped on import);
    // a present section of the wrong type would half-apply then throw AFTER the
    // clear, so reject it here instead.
    for (final key in [
      LunaBox.profiles.key,
      LunaBox.indexers.key,
      LunaBox.externalModules.key,
    ]) {
      final section = decoded[key];
      if (section != null && section is! List) {
        throw FormatException('Backup section "$key" is malformed.');
      }
    }
    for (final table in LunaTable.values) {
      final section = decoded[table.key];
      if (section != null && section is! Map) {
        throw FormatException('Backup section "${table.key}" is malformed.');
      }
    }
    return decoded;
  }

  String export() {
    Map<String, dynamic> config = {};
    config[LunaBox.externalModules.key] = LunaBox.externalModules.export();
    config[LunaBox.indexers.key] = LunaBox.indexers.export();
    // Security: a backup is a plaintext, user-shareable file. Strip every live
    // credential from each profile — they must not travel in a shared/cloud
    // backup and all re-mint on restore:
    //   - tailscaleAuthKey: live tailnet enrollment key (M3, 2026-07-25).
    //   - serverAdminToken: Quick Connect bearer authorizing every mutating
    //     controller /api/* call — re-minted via Quick Connect on restore
    //     (H2, 2026-07-28).
    // The ntfy bearer + APNs push token are stripped at the notifications-table
    // layer (blockedFromImportExport). See docs/security-audit-2026-07-28.md.
    final profiles = LunaBox.profiles.export();
    for (final profile in profiles) {
      profile['tailscaleAuthKey'] = '';
      profile['serverAdminToken'] = '';
    }
    config[LunaBox.profiles.key] = profiles;
    for (final table in LunaTable.values) config[table.key] = table.export();

    return json.encode(config);
  }

  void _setProfiles(List? data) {
    if (data == null) return;

    for (final item in data) {
      final content = (item as Map).cast<String, dynamic>();
      final key = content['key'] ?? 'default';
      final obj = LunaProfile.fromJson(content);
      LunaBox.profiles.update(key, obj);
    }
  }

  void _setIndexers(List? data) {
    if (data == null) return;

    for (final indexer in data) {
      final obj = LunaIndexer.fromJson(indexer);
      LunaBox.indexers.create(obj);
    }
  }

  void _setExternalModules(List? data) {
    if (data == null) return;

    for (final module in data) {
      final obj = LunaExternalModule.fromJson(module);
      LunaBox.externalModules.create(obj);
    }
  }
}

/// In-memory rollback copy of everything [LunaConfig.import] can overwrite.
class _ConfigSnapshot {
  final List<Map<String, dynamic>> profiles;
  final List<Map<String, dynamic>> indexers;
  final List<Map<String, dynamic>> externalModules;
  final Map<dynamic, dynamic> lunasea;

  const _ConfigSnapshot({
    required this.profiles,
    required this.indexers,
    required this.externalModules,
    required this.lunasea,
  });
}
