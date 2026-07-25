import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/database/tables/notifications.dart';
import 'package:lunasea/extensions/datetime.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/settings/core/share_configuration.dart';
import 'package:lunasea/system/gateway/gateway_services.dart';
import 'package:share_plus/share_plus.dart';

/// Connection screens for server-driven modules: when the gateway manages a
/// module, its configuration is what the server says it is — the screen
/// shows that state and offers a re-sync, never editors. Manual entry
/// exists only for standalone setups (no Tailarr Server), with a one-tap
/// path to hand configuration over once a server is present.
class ServerDrivenConnection {
  ServerDrivenConnection._();

  static bool isManaged(String type) =>
      LunaProfile.current.gatewayManagedModules.contains(type);

  /// True when a Tailarr Server owns this profile's configuration and its
  /// grant set is known — every granted service is already adopted+managed,
  /// so an UNmanaged service means "not granted to you" and the screen
  /// offers Request Access instead of manual entry.
  ///
  /// The grant set is known via ANY of: the profile is server-owned (born
  /// from an invite), it already has gateway-managed modules (a sync or a
  /// restore populated them), or a services sync has completed. Relying on
  /// SERVICES_LAST_SYNC alone was too fragile — a server-owned profile whose
  /// timestamp wasn't set (restored/migrated) wrongly fell back to a manual
  /// toggle for services the person doesn't have.
  static bool hasServerGrantList() => hasServerGrantListFor(
        LunaProfile.current,
        servicesSynced: NotificationsDatabase.SERVICES_LAST_SYNC.read() > 0,
      );

  /// Pure form of [hasServerGrantList] — the Hive reads are hoisted to the
  /// caller so this predicate is directly unit-testable.
  ///
  /// Note the absence of a `tailarrServerEnabled && tailarrServerHost`
  /// precondition: an invite-joined profile reaches its server through the
  /// hidden `tailarr-gate` node, NOT a user-entered Tailarr Server host, so it
  /// is legitimately serverOwned with the module disabled. Requiring the
  /// module to be enabled here dropped exactly those profiles back to manual
  /// editors for services the person doesn't have.
  static bool hasServerGrantListFor(
    LunaProfile profile, {
    required bool servicesSynced,
  }) {
    return profile.serverOwned ||
        profile.gatewayManagedModules.isNotEmpty ||
        servicesSynced ||
        (profile.tailarrServerEnabled && profile.tailarrServerHost.isNotEmpty);
  }

  /// The connection screen for [type] should show "Request Access" (no
  /// manual editors) when a server owns configuration but hasn't granted
  /// this service.
  static bool shouldRequestAccess(String type) =>
      !isManaged(type) && hasServerGrantList();

  /// The module's Enable toggle, gated for server-owned config. On a server
  /// profile the enable state is the server's to decide, so:
  /// - granted (managed) → a read-only "Enabled by your Tailarr Server" row;
  /// - server present, not granted → the Request Access card (no toggle);
  /// - standalone (no server) → the normal manual toggle via [manualToggle].
  static Widget enableBlock({
    required BuildContext context,
    required String type,
    required Widget manualToggle,
  }) {
    if (isManaged(type)) {
      return const LunaBlock(
        title: 'Enabled',
        body: [
          TextSpan(
            text: 'Managed by your Tailarr Server',
            style: TextStyle(color: LunaColours.accent),
          ),
        ],
        trailing: LunaIconButton(
          icon: Icons.cloud_done_rounded,
          color: LunaColours.accent,
        ),
      );
    }
    if (shouldRequestAccess(type)) {
      return requestAccessBlocks(context: context, type: type).first;
    }
    return manualToggle;
  }

  /// Replaces the manual editors when a server is present but this service
  /// isn't granted: one tap sends the admin a request (there is no
  /// self-service grant — access is an admin action on the Users screen).
  static List<Widget> requestAccessBlocks({
    required BuildContext context,
    required String type,
  }) {
    final name = type.toTitleCase();
    return [
      LunaBlock(
        title: 'Request Access to $name',
        body: [
          TextSpan(
            text: 'Your Tailarr Server hasn\'t granted this device access '
                'to $name',
          ),
          const TextSpan(text: 'Tap to ask your server admin'),
        ],
        trailing: const LunaIconButton(
          icon: Icons.lock_person_rounded,
          color: LunaColours.accent,
        ),
        onTap: () async {
          final device = LunaProfile.current.tailscaleIdentity.isEmpty
              ? 'my Tailarr device'
              : 'my Tailarr device "${LunaProfile.current.tailscaleIdentity}"';
          await Share.share(
            'Hi — could you grant $device access to $name on the Tailarr '
            'Server? (Users → my name → toggle $name.)',
            sharePositionOrigin:
                SharedModuleConfiguration.shareOriginOf(context),
          );
        },
      ),
    ];
  }

  /// Replaces the host/credential editors when the server owns the config.
  static List<Widget> managedBlocks({
    required BuildContext context,
    required String type,
    required String host,
    bool hasCredential = false,
  }) {
    final synced = NotificationsDatabase.SERVICES_LAST_SYNC.read();
    return [
      LunaBlock(
        title: 'Server Managed',
        body: [
          const TextSpan(
            text: 'Configured by your Tailarr Server',
            style: TextStyle(
              color: LunaColours.accent,
              fontWeight: LunaUI.FONT_WEIGHT_BOLD,
            ),
          ),
          TextSpan(text: host.isEmpty ? 'Waiting for the service…' : host),
          if (hasCredential)
            const TextSpan(text: 'Credential: ${LunaUI.TEXT_OBFUSCATED_PASSWORD}'),
          TextSpan(
            text: (synced > 0
                    ? 'Synced ${DateTime.fromMillisecondsSinceEpoch(synced).asAge()}'
                    : '') +
                '${LunaUI.TEXT_BULLET.pad()}Tap to re-sync',
          ),
        ],
        trailing: const LunaIconButton(
          icon: Icons.cloud_done_rounded,
          color: LunaColours.accent,
        ),
        onTap: () async {
          try {
            await GatewayServicesSync.sync();
            showLunaSuccessSnackBar(
              title: 'Synced',
              message: 'Configuration refreshed from your Tailarr Server',
            );
          } catch (error) {
            showLunaErrorSnackBar(
              title: 'Sync Failed',
              message: 'Your Tailarr Server is not reachable',
            );
          }
        },
      ),
    ];
  }

}
