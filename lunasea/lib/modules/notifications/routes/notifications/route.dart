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

enum _InboxFilter {
  all('All'),
  media('Media'),
  server('Server');

  final String label;
  const _InboxFilter(this.label);

  bool matches(LunaNotification notification) {
    switch (this) {
      case _InboxFilter.all:
        return true;
      case _InboxFilter.media:
        return notification.topic.startsWith('tlr-media-');
      case _InboxFilter.server:
        return !notification.topic.startsWith('tlr-media-');
    }
  }
}

class _State extends State<NotificationsRoute> with LunaScrollControllerMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();

  _InboxFilter _filter = _InboxFilter.all;

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
        PopupMenuButton<_InboxFilter>(
          icon: Icon(
            Icons.filter_list_rounded,
            color: _filter == _InboxFilter.all
                ? LunaColours.white
                : LunaModule.NOTIFICATIONS.color,
          ),
          onSelected: (filter) => setState(() => _filter = filter),
          itemBuilder: (context) => [
            for (final filter in _InboxFilter.values)
              PopupMenuItem(
                value: filter,
                child: Text(
                  filter.label,
                  style: TextStyle(
                    fontSize: LunaUI.FONT_SIZE_H3,
                    color: _filter == filter
                        ? LunaModule.NOTIFICATIONS.color
                        : LunaColours.white,
                  ),
                ),
              ),
          ],
        ),
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
          final filtered = notifications.where(_filter.matches).toList();
          if (filtered.isEmpty) {
            return LunaListView(
              controller: scrollController,
              children: [
                LunaMessage.inList(
                  text: 'No ${_filter.label} Notifications',
                ),
              ],
            );
          }
          return LunaListViewBuilder(
            controller: scrollController,
            itemCount: filtered.length,
            itemBuilder: (context, index) => _tile(filtered[index]),
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

    return Dismissible(
      key: ValueKey('notification-${notification.id}'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => notification.delete(),
      background: Container(
        color: LunaColours.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete_rounded, color: LunaColours.white),
      ),
      child: LunaBlock(
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
        onTap: () => _showDetails(notification, label, color),
        // TODO: deep link media notifications into the matching module
        // (topic tlr-media-<service> → that module's relevant screen).
      ),
    );
  }

  void _showDetails(
    LunaNotification notification,
    String label,
    Color color,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_topicIcon(notification.topic), color: color),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      notification.title?.isNotEmpty == true
                          ? notification.title!
                          : label,
                      style: const TextStyle(
                        fontSize: LunaUI.FONT_SIZE_H1,
                        fontWeight: LunaUI.FONT_WEIGHT_BOLD,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (notification.body?.isNotEmpty == true) ...[
                SelectableText(notification.body!),
                const SizedBox(height: 12),
              ],
              // Human-facing only — the ntfy topic, raw priority, and tags
              // are internal plumbing and stay out of the sheet.
              LunaTableCard(
                content: [
                  LunaTableContent(title: 'from', body: label),
                  LunaTableContent(
                    title: 'received',
                    body: notification.timestamp.asDateTime(),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: LunaButton.text(
                      text: 'Dismiss',
                      icon: Icons.delete_rounded,
                      color: LunaColours.red,
                      onTap: () async {
                        await notification.delete();
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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
