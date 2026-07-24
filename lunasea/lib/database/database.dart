import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/database/table.dart';
import 'package:lunasea/database/tables/lunasea.dart';
import 'package:lunasea/system/filesystem/filesystem.dart';
import 'package:lunasea/system/platform.dart';
import 'package:lunasea/utils/profile_tools.dart';
import 'package:lunasea/vendor.dart';

class LunaDatabase {
  static const String _DATABASE_LEGACY_PATH = 'database';
  static const String _DATABASE_PATH = 'LunaSea/database';

  String get path {
    if (LunaPlatform.isWindows || LunaPlatform.isLinux) return _DATABASE_PATH;
    return _DATABASE_LEGACY_PATH;
  }

  Future<void> initialize() async {
    await Hive.initFlutter(path);
    LunaTable.register();
    await open();
  }

  Future<void> open() async {
    await LunaBox.open();
    if (LunaBox.profiles.isEmpty) await bootstrap();
    migrateGlobalTailscaleToProfile();
    migrateLegacyServerProfiles();
  }

  /// Invites accepted before the server-owned-profile feature wrote their
  /// server-driven config onto whatever profile was active (usually
  /// 'default') without marking it owned or renaming it. Detect those —
  /// a profile with a Tailarr Server host whose `tailarr` module is
  /// gateway-managed — and convert them in place: mark serverOwned and
  /// rename to the server-derived name. Runs once (already-owned profiles
  /// are skipped) and preserves the stored Tailscale identity, so the node
  /// enrollment is untouched.
  void migrateLegacyServerProfiles() {
    for (final name in LunaProfile.list) {
      final profile = LunaBox.profiles.read(name);
      if (profile == null) continue;
      if (profile.serverOwned) continue;
      final isServerAttached = profile.tailarrServerHost.isNotEmpty &&
          profile.gatewayManagedModules.contains('tailarr');
      if (!isServerAttached) continue;

      // Already carrying its server's base name (or a deduped variant of
      // it) — just flip the ownership flag, don't rename it to yet another
      // variant.
      final base =
          LunaProfileTools.serverProfileBaseName(profile.tailarrServerHost);
      if (name == base || name.startsWith('$base (') || name == '$base') {
        profile.serverOwned = true;
        profile.save();
        continue;
      }

      final desired =
          LunaProfileTools.serverProfileName(profile.tailarrServerHost);
      if (desired == name || LunaBox.profiles.contains(desired)) {
        // Target is taken (a newer join already owns it) — flip in place.
        profile.serverOwned = true;
        profile.save();
        continue;
      }

      // Rename in place at the box level (no LunaState/router — the UI
      // isn't up yet): clone under the new key, repoint the active
      // pointer, drop the old key.
      final renamed = LunaProfile.clone(profile)..serverOwned = true;
      LunaBox.profiles.update(desired, renamed);
      if (LunaSeaDatabase.ENABLED_PROFILE.read() == name) {
        LunaSeaDatabase.ENABLED_PROFILE.update(desired);
      }
      profile.delete();
    }
  }

  /// Pre-per-profile installs kept the Tailscale settings in the global
  /// table. Move them onto the enabled profile with identity 'default' —
  /// the name tailscale_embed migrates the legacy node state to — so the
  /// existing enrollment survives the upgrade untouched.
  void migrateGlobalTailscaleToProfile() {
    final enabled = LunaSeaDatabase.TAILSCALE_ENABLED.read();
    final authKey = LunaSeaDatabase.TAILSCALE_AUTH_KEY.read();
    if (!enabled && authKey.isEmpty) return;

    final profile = LunaBox.profiles.read(
      LunaSeaDatabase.ENABLED_PROFILE.read(),
    );
    if (profile != null) {
      profile.tailscaleEnabled = enabled;
      profile.tailscaleAuthKey = authKey;
      profile.tailscaleIdentity = 'default';
      profile.save();
    }

    LunaSeaDatabase.TAILSCALE_ENABLED.update(false);
    LunaSeaDatabase.TAILSCALE_AUTH_KEY.update('');
  }

  Future<void> nuke() async {
    await Hive.close();

    for (final box in LunaBox.values) {
      await Hive.deleteBoxFromDisk(box.key, path: path);
    }

    if (LunaFileSystem.isSupported) {
      await LunaFileSystem().nuke();
    }
  }

  Future<void> bootstrap() async {
    const defaultProfile = LunaProfile.DEFAULT_PROFILE;
    await clear();

    LunaBox.profiles.update(defaultProfile, LunaProfile());
    LunaSeaDatabase.ENABLED_PROFILE.update(defaultProfile);
  }

  Future<void> clear() async {
    for (final box in LunaBox.values) await box.clear();
  }

  Future<void> deinitialize() async {
    await Hive.close();
  }
}
