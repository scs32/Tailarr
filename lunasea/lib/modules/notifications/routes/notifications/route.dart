import 'package:flutter/material.dart';
import 'package:lunasea/api/ntfy/models.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/database/models/notification.dart';
import 'package:lunasea/database/tables/notifications.dart';
import 'package:lunasea/extensions/datetime.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/router/routes/settings.dart';
import 'package:lunasea/system/notifications/notifications.dart';

class NotificationsRoute extends StatefulWidget {
  const NotificationsRoute({
    Key? key,
  }) : super(key: key);

  @override
  State<NotificationsRoute> createState() => _State();
}

class _State extends State<NotificationsRoute> with LunaScrollControllerMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();

  @override
  void initState() {
    super.initState();
    // Everything in the inbox counts as seen once the page is on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _markAllRead();
      _maybeAutoSetup();
    });
  }

  /// Opportunistic self-provisioning on module open: unconfigured devices
  /// on a v0.21+ server come up with zero typing. Throttled, and every
  /// attempt is recorded on the settings status card — never silent.
  Future<void> _maybeAutoSetup() async {
    if (!LunaNtfy.isSupported) return;
    if (NotificationsDatabase.URL.read().isNotEmpty) return;
    final last = NotificationsDatabase.LAST_ATTEMPT.read();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < Duration.millisecondsPerHour) return;
    try {
      final creds = await LunaNtfy().autoConfigure();
      if (creds?.ok == true && mounted) {
        showLunaSuccessSnackBar(
          title: 'Notifications Configured',
          message: 'Set up automatically from your Tailarr Server',
        );
      }
    } catch (_) {
      // Recorded on the setup status card; the empty state links there.
    }
  }

  void _markAllRead() {
    for (final notification in LunaBox.notifications.data) {
      if (!notification.read) {
        notification.read = true;
        notification.save();
      }
    }
  }

  Future<void> _refresh() async {
    try {
      await LunaNtfy().syncInbox();
      _markAllRead();
    } catch (error, stack) {
      LunaLogger().error('Failed to poll ntfy', error, stack);
      showLunaErrorSnackBar(title: 'Failed to Check for Alerts', error: error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      appBar: _appBar(),
      body: _body(),
      drawer: const LunaDrawer(page: MODULE_NOTIFICATIONS_KEY),
    );
  }

  PreferredSizeWidget _appBar() {
    return LunaAppBar(
      title: LunaModule.NOTIFICATIONS.title,
      useDrawer: true,
      scrollControllers: [scrollController],
      actions: [
        LunaIconButton(
          icon: Icons.delete_sweep_rounded,
          onPressed: _clearInbox,
        ),
        LunaIconButton(
          icon: Icons.settings_rounded,
          onPressed: SettingsRoutes.CONFIGURATION_NOTIFICATIONS.go,
        ),
      ],
    );
  }

  Future<void> _clearInbox() async {
    if (LunaBox.notifications.isEmpty) return;
    await LunaBox.notifications.clear();
    showLunaSuccessSnackBar(
      title: 'Inbox Cleared',
      message: 'New alerts will keep arriving',
    );
  }

  Widget _body() {
    return LunaRefreshIndicator(
      context: context,
      key: _refreshKey,
      onRefresh: _refresh,
      child: LunaBox.notifications.listenableBuilder(
        builder: (context, _) {
          final notifications = LunaBox.notifications.data.toList()
            ..sort((a, b) => b.time.compareTo(a.time));
          if (notifications.isEmpty) return _empty();
          WidgetsBinding.instance.addPostFrameCallback((_) => _markAllRead());
          return LunaListViewBuilder(
            controller: scrollController,
            itemCount: notifications.length,
            itemBuilder: (context, index) => _tile(notifications[index]),
          );
        },
      ),
    );
  }

  Widget _empty() {
    final configured = NotificationsDatabase.URL.read().isNotEmpty;
    final failed = NotificationsDatabase.SETUP_STATE.read() == 'failed';
    // LunaMessage is centered and unscrollable — wrap in a list so
    // pull-to-refresh still works on the empty state.
    return LunaListView(
      controller: scrollController,
      children: [
        if (configured) ...[
          LunaMessage.inList(text: 'No Notifications'),
          LunaMessage.inList(
            text:
                'Alerts arrive live while the app is open and are checked periodically in the background',
          ),
        ] else ...[
          LunaMessage.inList(text: 'Notifications Are Not Set Up'),
          LunaBlock(
            title: failed ? 'Automatic Setup Failed' : 'Set Up Notifications',
            body: [
              TextSpan(
                text: failed
                    ? NotificationsDatabase.SETUP_ERROR.read()
                    : 'Devices on a Tailarr Server are configured automatically — open setup to get started',
                style: failed
                    ? const TextStyle(
                        color: LunaColours.red,
                        fontWeight: LunaUI.FONT_WEIGHT_BOLD,
                      )
                    : null,
              ),
            ],
            trailing: LunaIconButton(
              icon: failed ? Icons.cloud_off_rounded : Icons.cloud_sync_rounded,
              color: failed ? LunaColours.red : LunaColours.accent,
            ),
            onTap: SettingsRoutes.CONFIGURATION_NOTIFICATIONS.go,
          ),
        ],
      ],
    );
  }

  Widget _tile(LunaNotification notification) {
    final label = ntfyTopicLabel(notification.topic);
    final Color color;
    if (notification.priority >= 5) {
      color = LunaColours.red;
    } else if (notification.priority == 4) {
      color = LunaColours.orange;
    } else {
      color = LunaModule.NOTIFICATIONS.color;
    }

    return LunaBlock(
      title: notification.title?.isNotEmpty == true
          ? notification.title!
          : label,
      body: [
        if (notification.body?.isNotEmpty == true)
          TextSpan(text: notification.body),
        TextSpan(
          children: [
            TextSpan(
              text: label,
              style: TextStyle(
                color: color,
                fontWeight: LunaUI.FONT_WEIGHT_BOLD,
              ),
            ),
            TextSpan(
              text:
                  '${LunaUI.TEXT_BULLET.pad()}${notification.timestamp.asAge()}',
            ),
          ],
        ),
      ],
      trailing: LunaIconButton(
        icon: _topicIcon(notification.topic),
        color: color,
      ),
      // TODO: deep link media notifications into the matching module
      // (topic tlr-media-<service> → that module's relevant screen).
    );
  }

  IconData _topicIcon(String topic) {
    if (topic == 'tlr-ops') return Icons.dns_rounded;
    if (topic.startsWith('tlr-media-')) {
      final service = topic.substring('tlr-media-'.length);
      final module = LunaModule.fromKey(service);
      if (module != null) return module.icon;
    }
    return Icons.notifications_rounded;
  }
}
