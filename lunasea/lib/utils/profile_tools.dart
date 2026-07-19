import 'dart:math';

import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/tables/lunasea.dart';
import 'package:lunasea/system/state.dart';
// ignore: always_use_package_imports
import 'package:lunasea/system/network/platform/network_stub.dart'
    if (dart.library.io) 'package:lunasea/system/network/platform/network_io.dart'
    if (dart.library.html) 'package:lunasea/system/network/platform/network_html.dart';
import 'package:lunasea/router/router.dart';
import 'package:lunasea/system/logger.dart';
import 'package:lunasea/types/exception.dart';
import 'package:lunasea/vendor.dart';
import 'package:lunasea/widgets/ui.dart';

class LunaProfileTools {
  /// A tailscale_embed identity name for a profile: generated ONCE when the
  /// profile first enables Tailscale, then stored on the profile. Never
  /// derive it on the fly — profile names are free-form and renamable, and
  /// naive slugs collide ("Test!" and "Test?" are both "test"). The random
  /// suffix keeps generated names unique; identity names must match
  /// [A-Za-z0-9][A-Za-z0-9._-]{0,63}.
  static String generateTailscaleIdentity(String profileName) {
    var slug = profileName
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-')
        .replaceAll(RegExp(r'^[^A-Za-z0-9]+'), '');
    if (slug.length > 24) slug = slug.substring(0, 24);

    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random();
    final suffix =
        List.generate(6, (_) => chars[random.nextInt(chars.length)]).join();

    return slug.isEmpty ? 'profile-$suffix' : '$slug-$suffix';
  }
  bool changeTo(
    String profile, {
    bool showSnackbar = true,
    bool popToRootRoute = false,
  }) {
    try {
      if (LunaSeaDatabase.ENABLED_PROFILE.read() == profile) return true;
      _changeTo(profile);

      if (showSnackbar) {
        showLunaSuccessSnackBar(
          title: 'settings.ChangedProfile'.tr(),
          message: profile,
        );
      }

      if (popToRootRoute) {
        LunaRouter().popToRootRoute();
      }

      return true;
    } on ProfileNotFoundException catch (error, trace) {
      LunaLogger().exception(error, trace);
    }
    return false;
  }

  Future<bool> create(
    String profile, {
    bool showSnackbar = true,
  }) async {
    try {
      await _create(profile);
      _changeTo(profile);

      if (showSnackbar) {
        showLunaSuccessSnackBar(
          title: 'settings.AddedProfile'.tr(),
          message: profile,
        );
      }
    } on ProfileAlreadyExistsException catch (error, trace) {
      LunaLogger().exception(error, trace);
    } catch (error, trace) {
      LunaLogger().error('Failed to create profile', error, trace);
    }

    return false;
  }

  Future<bool> remove(
    String profile, {
    bool showSnackbar = true,
  }) async {
    try {
      await _remove(profile);

      if (showSnackbar) {
        showLunaSuccessSnackBar(
          title: 'settings.DeletedProfile'.tr(),
          message: profile,
        );
      }
    } on ProfileNotFoundException catch (error, trace) {
      LunaLogger().exception(error, trace);
    } on ActiveProfileRemovalException catch (error, trace) {
      LunaLogger().exception(error, trace);
    } catch (error, trace) {
      LunaLogger().error('Failed to delete profile', error, trace);
    }

    return false;
  }

  Future<bool> rename(
    String oldProfile,
    String newProfile, {
    bool showSnackbar = true,
  }) async {
    try {
      await _rename(oldProfile, newProfile);

      if (showSnackbar) {
        showLunaSuccessSnackBar(
          title: 'settings.RenamedProfile'.tr(),
          message: 'settings.ProfileToProfile'.tr(
            args: [oldProfile, newProfile],
          ),
        );
      }

      return true;
    } on ProfileNotFoundException catch (error, trace) {
      LunaLogger().exception(error, trace);
    } on ProfileAlreadyExistsException catch (error, trace) {
      LunaLogger().exception(error, trace);
    } catch (error, trace) {
      LunaLogger().error('Failed to rename profile', error, trace);
    }

    return false;
  }

  void _changeTo(String profile) {
    if (!LunaBox.profiles.contains(profile)) {
      throw ProfileNotFoundException(profile);
    }

    LunaSeaDatabase.ENABLED_PROFILE.update(profile);
    LunaState.reset();
    // Fire-and-forget: restarts the embedded node when the new profile
    // uses a different identity (or stops it when disabled); TailscaleGuard
    // covers the gap in the UI.
    IO.syncTailscaleToProfile();
  }

  Future<void> _create(String profile) async {
    if (LunaBox.profiles.contains(profile)) {
      throw ProfileAlreadyExistsException(profile);
    }

    await LunaBox.profiles.update(profile, LunaProfile());
  }

  Future<void> _remove(String profile) async {
    if (LunaSeaDatabase.ENABLED_PROFILE.read() == profile) {
      throw ActiveProfileRemovalException(profile);
    }

    if (!LunaBox.profiles.contains(profile)) {
      throw ProfileNotFoundException(profile);
    }

    final identity = LunaBox.profiles.read(profile)?.tailscaleIdentity ?? '';
    await LunaBox.profiles.delete(profile);

    // The deleted profile's node state is orphaned — remove it. Best
    // effort: only the active identity can refuse deletion, and the
    // active profile can't be removed.
    if (identity.isNotEmpty) {
      IO.forgetTailscaleNode(identity).catchError((error, stack) {
        LunaLogger().error('Orphaned identity cleanup failed', error, stack);
      });
    }
  }

  Future<void> _rename(String oldProfile, String newProfile) async {
    if (!LunaBox.profiles.contains(oldProfile)) {
      throw ProfileNotFoundException(oldProfile);
    }

    if (LunaBox.profiles.contains(newProfile)) {
      throw ProfileAlreadyExistsException(newProfile);
    }

    final oldDb = LunaBox.profiles.read(oldProfile)!;
    final newDb = LunaProfile.clone(oldDb);

    await LunaBox.profiles.update(newProfile, newDb);
    _changeTo(newProfile);

    oldDb.delete();
  }
}

class ProfileNotFoundException with ErrorExceptionMixin {
  final String profile;
  const ProfileNotFoundException(this.profile);

  @override
  String toString() {
    return 'ProfileNotFoundException: "$profile" was not found';
  }
}

class ProfileAlreadyExistsException with ErrorExceptionMixin {
  final String profile;
  const ProfileAlreadyExistsException(this.profile);

  @override
  String toString() {
    return 'ProfileAlreadyExistsException: "$profile" already exists';
  }
}

class ActiveProfileRemovalException with ErrorExceptionMixin {
  final String profile;
  const ActiveProfileRemovalException(this.profile);

  @override
  String toString() {
    return 'ActiveProfileRemovalException: "$profile" can\'t be removed as it is in use';
  }
}
