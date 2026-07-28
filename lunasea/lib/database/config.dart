import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/database/database.dart';
import 'package:lunasea/database/models/external_module.dart';
import 'package:lunasea/database/models/indexer.dart';
import 'package:lunasea/database/table.dart';

class LunaConfig {
  Future<void> import(BuildContext context, String data) async {
    // Security/robustness: validate the ENTIRE backup BEFORE touching the live
    // database. The old code cleared first, so a truncated/malformed/wrong-shape
    // file wiped every profile, credential, indexer, module, and setting
    // irrecoverably (the catch only bootstrapped a fresh default). Parse + shape-
    // check up front and throw on anything invalid — the caller surfaces the
    // error and the user's existing config is left untouched. See
    // docs/security-audit-2026-07-28.md (H1).
    final Map<String, dynamic> config = _parseAndValidate(data);

    await LunaDatabase().clear();
    try {
      _setProfiles(config[LunaBox.profiles.key]);
      _setIndexers(config[LunaBox.indexers.key]);
      _setExternalModules(config[LunaBox.externalModules.key]);
      for (final table in LunaTable.values) table.import(config[table.key]);

      if (!LunaProfile.list.contains(LunaSeaDatabase.ENABLED_PROFILE.read())) {
        LunaSeaDatabase.ENABLED_PROFILE.update(LunaProfile.list[0]);
      }

      // A restored backup can carry server-attached profiles from a build
      // that predates serverOwned — the launch migration already ran before
      // this manual restore, so convert them now too.
      LunaDatabase().migrateLegacyServerProfiles();
    } catch (error, stack) {
      // The backup validated but a value failed to apply (rare — well-formed
      // JSON, our own fromJson). Reset to a clean default rather than leave a
      // half-imported database, then let the caller report the failure.
      await LunaDatabase().bootstrap();
      LunaLogger().error(
        'Failed to apply validated backup, resetting to default',
        error,
        stack,
      );
      LunaState.reset(context);
      rethrow;
    }

    LunaState.reset(context);
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
