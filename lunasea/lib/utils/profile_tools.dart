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
import 'package:lunasea/system/demo/demo.dart';
import 'package:lunasea/system/logger.dart';
import 'package:lunasea/system/notifications/notifications.dart';
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

  /// The profile that a Tailarr Server at [host] owns, or null. A server
  /// owns at most one profile (matched by host), keeping its config isolated
  /// from the user's own profiles.
  static LunaProfile? serverOwnedProfileFor(String host) {
    final normalized = host.trim().replaceAll(RegExp(r'/+$'), '');
    for (final name in LunaProfile.list) {
      final profile = LunaBox.profiles.read(name);
      if (profile != null &&
          profile.serverOwned &&
          profile.tailarrServerHost
                  .trim()
                  .replaceAll(RegExp(r'/+$'), '') ==
              normalized) {
        return profile;
      }
    }
    return null;
  }

  /// A locked, human-readable profile name derived from a Tailarr Server
  /// host (`https://tailarr.tailXXXX.ts.net` → `Tailarr`), disambiguated by
  /// the tailnet label only when a DIFFERENT profile already holds the base
  /// name. Server-owned profiles reuse their existing name (matched on
  /// host), so this only runs when minting a new one.
  /// The base (pre-dedup) profile name for a server host — pure, no box
  /// access. `https://tailarr.tailXXXX.ts.net` → `Tailarr`.
  static String serverProfileBaseName(String host) {
    final authority = Uri.tryParse(host)?.host ?? host;
    final labels = authority.split('.').where((l) => l.isNotEmpty).toList();
    return labels.isEmpty
        ? 'Tailarr'
        : labels.first[0].toUpperCase() + labels.first.substring(1);
  }

  /// The profile name for a server, de-duplicated against existing profiles.
  /// Prefers the server's admin-chosen [preferredName] (from the invite);
  /// falls back to the host-derived name. On a collision it appends the
  /// tailnet label, then a number — so two servers sharing a display name
  /// (e.g. both "Home") still get distinct profiles ("Home", "Home
  /// (tail95fc29)", "Home 2").
  static String serverProfileName(String host, {String? preferredName}) {
    final trimmed = preferredName?.trim() ?? '';
    final base = trimmed.isNotEmpty ? trimmed : serverProfileBaseName(host);
    return _dedupedProfileName(base, host);
  }

  /// De-duplicate [base] against the existing profiles, escalating on a
  /// collision: tailnet label, then a number. [exclude] is the profile being
  /// renamed (so it never collides with its own current name). Shared by
  /// minting ([serverProfileName]) and server-driven renaming
  /// ([renameServerOwnedProfile]).
  static String _dedupedProfileName(String base, String host,
      {String? exclude}) {
    final existing = LunaProfile.list.toSet()..remove(exclude);
    if (!existing.contains(base)) return base;
    final labels = (Uri.tryParse(host)?.host ?? host)
        .split('.')
        .where((l) => l.isNotEmpty)
        .toList();
    if (labels.length >= 2) {
      final tailnet = '$base (${labels[1]})';
      if (!existing.contains(tailnet)) return tailnet;
    }
    var n = 2;
    while (existing.contains('$base $n')) {
      n++;
    }
    return '$base $n';
  }

  /// The de-duplicated name a server-owned profile at [host] would take for
  /// the admin-chosen [desiredName], excluding [current] from the collision
  /// check. Pure — no box mutation; [renameServerOwnedProfile] applies it.
  static String serverRenameTarget(
    String host,
    String desiredName, {
    required String current,
  }) {
    return _dedupedProfileName(desiredName.trim(), host, exclude: current);
  }

  /// Create (or reuse) the server-owned profile for [host] and switch to it.
  /// Returns the profile name. All subsequent server-driven configuration
  /// lands here, never on the user's own profiles.
  Future<String> enterServerOwnedProfile(
    String host, {
    String? preferredName,
  }) async {
    final existing = serverOwnedProfileFor(host);
    if (existing != null) {
      _changeTo(existing.key as String);
      await _removePristineDefaultProfile();
      return existing.key as String;
    }
    final name = serverProfileName(host, preferredName: preferredName);
    await LunaBox.profiles.update(
      name,
      LunaProfile(serverOwned: true, tailarrServerHost: host),
    );
    _changeTo(name);
    await _removePristineDefaultProfile();
    return name;
  }

  /// Follow a server-driven rename: point the server-owned profile for
  /// [profile] at the admin-chosen [desiredName] (delivered live on the
  /// `/self/services` handout as `server.name`). The name-lock only blocks
  /// USER renames — the server owns the name, so it may change it. Because a
  /// profile's name IS its Hive key AND the key namespaces its per-profile
  /// notification state, this migrates all of it in place:
  ///   * the profiles-box entry (key = name),
  ///   * the `NOTIFICATIONS_*@<name>` config + inbox + shared-state slice
  ///     (via [LunaNtfy.migrateProfileName]).
  /// No node churn — the tailscale identity lives on the profile, not the
  /// name, so the embedded node is untouched. Returns the final name, or null
  /// when nothing changed (not server-owned, empty/identical name, or the
  /// de-duplicated target equals the current name).
  Future<String?> renameServerOwnedProfile(
    LunaProfile profile,
    String desiredName,
  ) async {
    if (!profile.serverOwned) return null;
    final current = profile.key as String?;
    if (current == null || !LunaBox.profiles.contains(current)) return null;
    final base = desiredName.trim();
    if (base.isEmpty || base == current) return null;

    final target = LunaProfileTools.serverRenameTarget(
      profile.tailarrServerHost,
      base,
      current: current,
    );
    if (target == current) return null;

    // Move the box entry to the new key. Preserve the active selection
    // WITHOUT a real profile switch's node/stream churn — it is the same
    // profile (same identity), only its key changed.
    await LunaBox.profiles.update(target, LunaProfile.clone(profile));
    final wasActive = LunaSeaDatabase.ENABLED_PROFILE.read() == current;
    if (wasActive) LunaSeaDatabase.ENABLED_PROFILE.update(target);
    await LunaBox.profiles.delete(current);

    // Per-profile notification state is keyed by name — migrate it so the
    // rename doesn't orphan the subscription, inbox, or push registration.
    await LunaNtfy().migrateProfileName(current, target);
    // Re-mirror the (now newly-named) active slice + restart the stream.
    if (wasActive) await LunaNtfy().onConfigChanged();

    LunaLogger().debug('Server renamed profile "$current" → "$target"');
    return target;
  }

  /// Remove the empty bootstrap 'default' profile left behind once the user
  /// has joined a server. A fresh install seeds 'default'; the invite then
  /// creates a separate server-owned profile and switches to it, stranding
  /// an untouched 'default'. Manual profiles are Pro-gated, so a leftover
  /// 'default' is always pristine — safe to drop. Never removes the active
  /// profile, a configured one, or the last remaining profile.
  Future<void> _removePristineDefaultProfile() async {
    const name = LunaProfile.DEFAULT_PROFILE;
    if (LunaSeaDatabase.ENABLED_PROFILE.read() == name) return;
    if (LunaProfile.list.length <= 1) return;
    final profile = LunaBox.profiles.read(name);
    if (profile == null || !_isPristine(profile)) return;
    try {
      await _remove(name);
    } catch (error, stack) {
      LunaLogger().error('Leftover default cleanup failed', error, stack);
    }
  }

  /// A never-configured profile: no server, no Tailscale, no module enabled,
  /// no gateway provenance. (Not [LunaProfile.isAnythingEnabled], which reads
  /// the ACTIVE profile, not this one.)
  static bool _isPristine(LunaProfile p) {
    return !p.serverOwned &&
        !p.demo &&
        p.tailarrServerHost.isEmpty &&
        !p.tailscaleEnabled &&
        p.tailscaleAuthKey.isEmpty &&
        p.gatewayManagedModules.isEmpty &&
        !p.sonarrEnabled &&
        !p.radarrEnabled &&
        !p.lidarrEnabled &&
        !p.sabnzbdEnabled &&
        !p.nzbgetEnabled &&
        !p.tautulliEnabled &&
        !p.overseerrEnabled &&
        !p.tailarrServerEnabled;
  }

  /// This profile has real configuration (server, demo, Tailscale, or an
  /// enabled module) — the inverse of the pristine first-run state.
  static bool isConfigured(LunaProfile p) => !_isPristine(p);

  /// First run: NO profile anywhere is configured (no server joined, no demo,
  /// no manual/gateway module). Drives the first-run landing screen. When a
  /// user leaves a server or exits demo and only a pristine `default` remains,
  /// this returns true again → they land back on the first screen.
  static bool isFirstRun() {
    for (final name in LunaProfile.list) {
      final p = LunaBox.profiles.read(name);
      if (p != null && isConfigured(p)) return false;
    }
    return true;
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

  /// Leave the active server-owned profile entirely (the Basic-mode escape
  /// hatch, but usable by anyone). Switches to another profile — creating a
  /// pristine `default` if none exists — so the server profile is no longer
  /// active, then removes it and forgets its tailnet node. Reversible: a new
  /// invite re-creates a server-owned profile. Returns the profile switched to,
  /// or null if there was nothing to leave.
  Future<String?> leaveServer({bool showSnackbar = true}) async {
    final current = LunaSeaDatabase.ENABLED_PROFILE.read();
    final leaving = LunaBox.profiles.read(current);
    if (leaving == null || !leaving.serverOwned) return null;

    try {
      // Pick a destination that is NOT the profile we're leaving; prefer a
      // non-server profile, else create the pristine bootstrap default.
      final others = LunaProfile.list.where((p) => p != current).toList();
      String destination;
      if (others.isNotEmpty) {
        destination = others.firstWhere(
          (p) => !(LunaBox.profiles.read(p)?.serverOwned ?? false),
          orElse: () => others.first,
        );
      } else {
        destination = LunaProfile.DEFAULT_PROFILE;
        if (!LunaBox.profiles.contains(destination)) await _create(destination);
      }

      // Switch away first (server profile is active and can't be removed while
      // active). _changeTo debounces the node reconfigure + re-mirrors ntfy.
      _changeTo(destination);
      // Now inactive → remove it; _remove forgets the orphaned tailnet node.
      await _remove(current);

      if (showSnackbar) {
        showLunaSuccessSnackBar(
          title: 'Left Server',
          message: current,
        );
      }
      return destination;
    } catch (error, trace) {
      LunaLogger().error('Failed to leave server', error, trace);
      return null;
    }
  }

  /// Enter the bundled read-only demo (see [DemoMode]). Creates/refreshes the
  /// name-locked `Demo` profile with the showcase modules server-managed
  /// against the demo sentinel host, then switches to it.
  Future<void> enterDemo() async {
    await LunaBox.profiles.update(DemoMode.profileName, DemoMode.build());
    changeTo(DemoMode.profileName, showSnackbar: false);
  }

  /// Exit demo: switch to a real/pristine profile (creating a `default` if none
  /// exists), then delete the `Demo` profile — so an untouched install returns
  /// to the first-run landing. Returns the profile switched to, or null if not
  /// currently in demo.
  Future<String?> leaveDemo() async {
    final current = LunaSeaDatabase.ENABLED_PROFILE.read();
    final leaving = LunaBox.profiles.read(current);
    if (leaving == null || !leaving.demo) return null;

    // Destination: a real/pristine profile, creating a default if none.
    final others = LunaProfile.list.where((p) => p != current).toList();
    String destination;
    if (others.isNotEmpty) {
      destination = others.firstWhere(
        (p) => !(LunaBox.profiles.read(p)?.demo ?? false),
        orElse: () => others.first,
      );
    } else {
      destination = LunaProfile.DEFAULT_PROFILE;
    }

    // Box mutations FIRST and unconditionally — these decide isFirstRun (and
    // thus whether the app returns to the landing). They must NOT be stranded
    // by a flaky node/ntfy side-effect: previously `_changeTo`'s channel calls
    // could throw AFTER switching but BEFORE the demo profile was removed,
    // leaving it behind so the landing never showed.
    if (!LunaBox.profiles.contains(destination)) {
      await LunaBox.profiles.update(destination, LunaProfile());
    }
    LunaSeaDatabase.ENABLED_PROFILE.update(destination);
    await LunaBox.profiles.delete(current);

    // Best-effort session refresh — never blocks or reverts the exit.
    try {
      LunaState.reset();
      IO.syncTailscaleToProfile();
      LunaNtfy().onConfigChanged();
    } catch (error, trace) {
      LunaLogger().error('Demo exit side-effects failed', error, trace);
    }
    return destination;
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
    } on ServerOwnedProfileException catch (error, trace) {
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
    // Notifications are per-profile: re-mirror the new profile's
    // subscription and restart the ntfy stream so the inbox, badge and
    // push follow the profile switch.
    LunaNtfy().onConfigChanged();
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

    // A server-owned profile's name is dictated by its Tailarr Server.
    if (LunaBox.profiles.read(oldProfile)?.serverOwned ?? false) {
      throw ServerOwnedProfileException(oldProfile);
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

class ServerOwnedProfileException with ErrorExceptionMixin {
  final String profile;
  const ServerOwnedProfileException(this.profile);

  @override
  String toString() {
    return 'ServerOwnedProfileException: "$profile" is owned by a Tailarr Server; its name is locked';
  }
}
