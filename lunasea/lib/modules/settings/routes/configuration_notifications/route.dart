import 'package:flutter/material.dart';
import 'package:lunasea/api/ntfy/models.dart';
import 'package:lunasea/api/ntfy/ntfy.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/database/tables/notifications.dart';
import 'package:lunasea/extensions/datetime.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/system/gateway/gateway_services.dart';
import 'package:lunasea/system/notifications/notifications.dart';

/// Notifications are not user-assembled plumbing: they are on, and the
/// server configures them (topics mirror the person's access). This screen
/// is a STATUS surface — what state provisioning is in, and a re-sync
/// affordance — deliberately without toggles, topic pickers, or manual
/// credential entry.
class ConfigurationNotificationsRoute extends StatefulWidget {
  const ConfigurationNotificationsRoute({
    Key? key,
  }) : super(key: key);

  @override
  State<ConfigurationNotificationsRoute> createState() => _State();
}

class _State extends State<ConfigurationNotificationsRoute>
    with LunaScrollControllerMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  /// A setup attempt is in flight (SETTING UP state on the status card).
  bool _settingUp = false;

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      appBar: _appBar(),
      body: _body(),
      bottomNavigationBar: _bottomActionBar(),
    );
  }

  PreferredSizeWidget _appBar() {
    return LunaAppBar(
      title: LunaModule.NOTIFICATIONS.title,
      scrollControllers: [scrollController],
    );
  }

  Widget _bottomActionBar() {
    return LunaBottomActionBar(
      actions: [
        _testConnection(),
      ],
    );
  }

  Widget _body() {
    return LunaBox.lunasea.listenableBuilder(
      selectItems: [
        NotificationsDatabase.ENABLED,
        NotificationsDatabase.URL,
        NotificationsDatabase.TOPICS,
        NotificationsDatabase.SETUP_STATE,
        NotificationsDatabase.SETUP_ERROR,
        NotificationsDatabase.LAST_SYNC,
        NotificationsDatabase.PUSH_STATE,
        NotificationsDatabase.PUSH_DETAIL,
      ],
      builder: (context, _) => LunaListView(
        controller: scrollController,
        children: [
          LunaModule.NOTIFICATIONS.informationBanner(),
          if (LunaNtfy.isSupported) ..._setupStatusCard(),
          if (LunaNtfy.isSupported) _pushStatus(),
        ],
      ),
    );
  }

  /// The provisioning state machine, always visible: NOT SET UP,
  /// SETTING UP, CONFIGURED, or FAILED with the verbatim error + the exact
  /// request that was dialed. A failed attempt must never look like
  /// "nothing happened".
  List<Widget> _setupStatusCard() {
    final state = NotificationsDatabase.SETUP_STATE.read();
    final url = NotificationsDatabase.URL.read();

    if (_settingUp) {
      return [
        const LunaBlock(
          title: 'Notifications',
          body: [TextSpan(text: 'Setting up — asking your Tailarr Server…')],
          trailing: LunaIconButton(icon: Icons.downloading_rounded),
        ),
      ];
    }

    if (url.isNotEmpty) {
      final topics = NotificationsDatabase.TOPICS
          .read()
          .map((t) => t.toString())
          .toList();
      final synced = NotificationsDatabase.LAST_SYNC.read();
      return [
        LunaBlock(
          title: 'Notifications',
          body: [
            const TextSpan(
              text: 'Configured by your Tailarr Server',
              style: TextStyle(
                color: LunaColours.accent,
                fontWeight: LunaUI.FONT_WEIGHT_BOLD,
              ),
            ),
            TextSpan(
              text: topics.map(ntfyTopicLabel).join(', '),
            ),
            if (synced > 0)
              TextSpan(
                text: 'Synced '
                    '${DateTime.fromMillisecondsSinceEpoch(synced).asAge()}'
                    '${LunaUI.TEXT_BULLET.pad()}Tap to re-sync',
              ),
          ],
          trailing: const LunaIconButton(
            icon: Icons.cloud_done_rounded,
            color: LunaColours.accent,
          ),
          onTap: _runAutomaticSetup,
        ),
      ];
    }

    if (state == 'failed') {
      final attempted = NotificationsDatabase.LAST_ATTEMPT.read();
      return [
        LunaBlock(
          title: 'Not Connected',
          body: [
            TextSpan(
              text: NotificationsDatabase.SETUP_ERROR.read(),
              style: const TextStyle(
                color: LunaColours.red,
                fontWeight: LunaUI.FONT_WEIGHT_BOLD,
              ),
            ),
            TextSpan(text: NotificationsDatabase.SETUP_DETAIL.read()),
            TextSpan(
              text: (attempted > 0
                      ? 'Attempted ${DateTime.fromMillisecondsSinceEpoch(attempted).asAge()}'
                      : '') +
                  '${LunaUI.TEXT_BULLET.pad()}Tap to retry',
            ),
          ],
          trailing: const LunaIconButton(
            icon: Icons.cloud_off_rounded,
            color: LunaColours.red,
          ),
          onTap: _runAutomaticSetup,
        ),
      ];
    }

    return [
      LunaBlock(
        title: 'Notifications',
        body: const [
          TextSpan(
            text: 'Configured automatically by your Tailarr Server — '
                'alerts follow the access you\'ve been granted',
          ),
          TextSpan(text: 'Tap to connect now'),
        ],
        trailing: const LunaIconButton(
          icon: Icons.cloud_sync_rounded,
          color: LunaColours.accent,
        ),
        onTap: _runAutomaticSetup,
      ),
    ];
  }

  Future<void> _runAutomaticSetup() async {
    if (_settingUp) return;
    setState(() => _settingUp = true);
    try {
      await _attemptAutomaticSetup();
    } finally {
      if (mounted) setState(() => _settingUp = false);
    }
  }

  Future<void> _attemptAutomaticSetup() async {
    try {
      final creds = await LunaNtfy().autoConfigure();
      if (creds == null) return;
      if (creds.ok) {
        showLunaSuccessSnackBar(
          title: 'Notifications Configured',
          message: (creds.topics as List).join(', '),
        );
        await _syncServices();
      } else if (creds.isUnassigned == true) {
        showLunaErrorSnackBar(
          title: 'Device Not Assigned',
          message:
              'Ask your Tailarr Server admin to assign this device to a user',
        );
      } else {
        showLunaErrorSnackBar(
          title: 'Setup Failed',
          message: creds.error ?? 'Unknown error',
        );
      }
    } catch (error) {
      // Full dial detail is in Settings > System > Logs (logged by
      // autoConfigure) — the snackbar keeps the human guidance.
      showLunaErrorSnackBar(
        title: 'Server Not Reachable',
        message:
            'Needs Tailscale enabled and a Tailarr Server v0.21+ with notifications set up. Details in Settings > System > Logs.',
      );
    }
  }

  /// Piggybacks on a successful notifications setup: materialize the
  /// person's badged services as modules (server v0.23.0+). Version skew —
  /// old gateway 404 or old controller answering the notifications payload —
  /// degrades silently per the contract; only real changes get a snackbar.
  Future<void> _syncServices() async {
    try {
      final outcome = await GatewayServicesSync.sync();
      final result = outcome.result;
      if (result == null || result.isEmpty) return;
      final summary = [
        ...result.configured.map((t) => t.toTitleCase()),
        if (result.bookmarked.isNotEmpty)
          '${result.bookmarked.length} bookmark(s)',
      ].join(', ');
      showLunaSuccessSnackBar(
        title: 'Services Configured',
        message: result.missingAuth.isEmpty
            ? summary
            : '$summary — ${result.missingAuth.join(', ')} still need(s) an API key',
      );
    } catch (error, stack) {
      // Transport failure after notifications just succeeded is unusual —
      // log it, but services self-config is best-effort by design.
      LunaLogger().error('gateway services sync failed', error, stack);
    }
  }

  /// Instant-push registration state — informational, no toggle: push is
  /// additive over background refresh and manages itself.
  Widget _pushStatus() {
    final state = NotificationsDatabase.PUSH_STATE.read();
    final detail = NotificationsDatabase.PUSH_DETAIL.read();
    final String label;
    final Color color;
    switch (state) {
      case 'registered':
        label = 'Active';
        color = LunaColours.accent;
        break;
      case 'unavailable':
        label = 'Server too old (needs v0.26+)';
        color = LunaColours.grey;
        break;
      case 'unassigned':
        label = 'Device not assigned to a user';
        color = LunaColours.orange;
        break;
      case 'failed':
        label = 'Unavailable — using background refresh';
        color = LunaColours.grey;
        break;
      default:
        label = 'Not set up';
        color = LunaColours.grey;
    }
    return LunaBlock(
      title: 'Instant Push',
      body: [
        TextSpan(
          text: label,
          style: TextStyle(color: color, fontWeight: LunaUI.FONT_WEIGHT_BOLD),
        ),
        if (detail.isNotEmpty) TextSpan(text: detail),
        const TextSpan(
          text: 'Alert content never leaves your server — the public relay '
              'sees only an opaque device token and the word "wake".',
        ),
      ],
      trailing: Icon(
        state == 'registered' ? Icons.bolt_rounded : Icons.bolt_outlined,
        color: color,
      ),
    );
  }

  Widget _testConnection() {
    return LunaButton.text(
      text: 'settings.TestConnection'.tr(),
      icon: LunaIcons.CONNECTION_TEST,
      onTap: () async {
        final subscription = NtfySubscription(
          url: NotificationsDatabase.URL.read(),
          token: NotificationsDatabase.TOKEN.read(),
          topics: NotificationsDatabase.TOPICS
              .read()
              .map((t) => t.toString())
              .toList(),
        );
        if (!subscription.isValid) {
          showLunaErrorSnackBar(
            title: 'Not Configured',
            message: 'Connect to your Tailarr Server first',
          );
          return;
        }
        NtfyClient(subscription).poll().then((messages) {
          showLunaSuccessSnackBar(
            title: 'settings.ConnectedSuccessfully'.tr(),
            message: messages.isEmpty
                ? 'Subscribed — no cached messages'
                : '${messages.length} cached message(s) available',
          );
        }).catchError((error, trace) {
          LunaLogger().error('ntfy Connection Test Failed', error, trace);
          showLunaErrorSnackBar(
            title: 'settings.ConnectionTestFailed'.tr(),
            error: error,
          );
        });
      },
    );
  }
}
