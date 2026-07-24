import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/database/tables/notifications.dart';
import 'package:lunasea/extensions/datetime.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/system/gateway/gateway_services.dart';

/// Connection screens for server-driven modules: when the gateway manages a
/// module, its configuration is what the server says it is — the screen
/// shows that state and offers a re-sync, never editors. Manual entry
/// exists only for standalone setups (no Tailarr Server), with a one-tap
/// path to hand configuration over once a server is present.
class ServerDrivenConnection {
  ServerDrivenConnection._();

  static bool isManaged(String type) =>
      LunaProfile.current.gatewayManagedModules.contains(type);

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

  /// Shown above the manual editors when a Tailarr Server is configured
  /// but this module is still hand-entered: one tap hands ownership over.
  static List<Widget> adoptBlocks({
    required BuildContext context,
    required String type,
  }) {
    if (!LunaProfile.current.tailarrServerEnabled) return [];
    return [
      LunaBlock(
        title: 'Use Server Configuration',
        body: const [
          TextSpan(
            text: 'Let your Tailarr Server manage this connection — '
                'address and credentials stay in sync automatically',
          ),
        ],
        trailing: const LunaIconButton(
          icon: Icons.cloud_sync_rounded,
          color: LunaColours.accent,
        ),
        onTap: () async {
          final error = await GatewayServicesSync.adopt(type);
          if (error != null) {
            showLunaErrorSnackBar(title: 'Not Available', message: error);
            return;
          }
          showLunaSuccessSnackBar(
            title: 'Server Managed',
            message: '${type.toTitleCase()} now follows your Tailarr Server',
          );
        },
      ),
    ];
  }
}
