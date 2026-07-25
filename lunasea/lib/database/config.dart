import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/database/database.dart';
import 'package:lunasea/database/models/external_module.dart';
import 'package:lunasea/database/models/indexer.dart';
import 'package:lunasea/database/table.dart';

class LunaConfig {
  Future<void> import(BuildContext context, String data) async {
    await LunaDatabase().clear();

    try {
      Map<String, dynamic> config = json.decode(data);

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
      await LunaDatabase().bootstrap();
      LunaLogger().error(
        'Failed to import configuration, resetting to default',
        error,
        stack,
      );
    }

    LunaState.reset(context);
  }

  String export() {
    Map<String, dynamic> config = {};
    config[LunaBox.externalModules.key] = LunaBox.externalModules.export();
    config[LunaBox.indexers.key] = LunaBox.indexers.export();
    // Security: a backup is a plaintext, user-shareable file. Strip the
    // Tailscale auth/enroll key from every profile — it is a live tailnet
    // enrollment credential that must not travel in a shared/cloud backup.
    // Everything else is intended for restore; the auth key is re-entered on
    // re-enrollment. See docs/security-audit-2026-07-25.md (M3).
    final profiles = LunaBox.profiles.export();
    for (final profile in profiles) {
      profile['tailscaleAuthKey'] = '';
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
