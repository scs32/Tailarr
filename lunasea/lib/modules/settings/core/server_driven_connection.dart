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

  /// True when a Tailarr Server is configured and has reported its service
  /// list at least once. In that world every service the person is granted
  /// is already adopted+managed, so an UNmanaged service means "not granted
  /// to you" — the screen offers to request access instead of manual entry.
  static bool hasServerGrantList() {
    final profile = LunaProfile.current;
    return profile.tailarrServerEnabled &&
        profile.tailarrServerHost.isNotEmpty &&
        NotificationsDatabase.SERVICES_LAST_SYNC.read() > 0;
  }

  /// The connection screen for [type] should show "Request Access" (no
  /// manual editors) when a server owns configuration but hasn't granted
  /// this service.
  static bool shouldRequestAccess(String type) =>
      !isManaged(type) && hasServerGrantList();

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
