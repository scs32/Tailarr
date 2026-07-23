import 'package:flutter/material.dart';
import 'package:lunasea/api/ntfy/models.dart';
import 'package:lunasea/api/ntfy/ntfy.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/database/tables/notifications.dart';
import 'package:lunasea/extensions/datetime.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/system/notifications/notifications.dart';

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
        NotificationsDatabase.TOKEN,
        NotificationsDatabase.TOPICS,
        NotificationsDatabase.BACKGROUND_REFRESH,
        NotificationsDatabase.GATEWAY_MANAGED,
        NotificationsDatabase.SETUP_STATE,
        NotificationsDatabase.SETUP_ERROR,
        NotificationsDatabase.LAST_SYNC,
      ],
      builder: (context, _) => LunaListView(
        controller: scrollController,
        children: [
          LunaModule.NOTIFICATIONS.informationBanner(),
          if (LunaNtfy.isSupported) ..._setupStatusCard(),
          _enabledToggle(),
          const LunaHeader(
            text: 'Manual Setup',
            subtitle: 'Fallback — for servers without the self-config '
                'gateway (pre-v0.21) or the official ntfy app',
          ),
          _importSubscription(),
          _serverUrl(),
          _accessToken(),
          _topics(),
          LunaDivider(),
          _backgroundRefreshToggle(),
        ],
      ),
    );
  }

  /// The provisioning state machine, always visible: NOT SET UP,
  /// SETTING UP, CONFIGURED (automatic or manual), or FAILED with the
  /// verbatim error + the exact request that was dialed. A failed attempt
  /// must never look like "nothing happened".
  List<Widget> _setupStatusCard() {
    final state = NotificationsDatabase.SETUP_STATE.read();
    final managed = NotificationsDatabase.GATEWAY_MANAGED.read();
    final url = NotificationsDatabase.URL.read();

    if (_settingUp) {
      return [
        const LunaBlock(
          title: 'Automatic Setup',
          body: [TextSpan(text: 'Setting up — asking your Tailarr Server…')],
          trailing: LunaIconButton(icon: Icons.downloading_rounded),
        ),
      ];
    }

    if (managed && url.isNotEmpty) {
      final topics = NotificationsDatabase.TOPICS
          .read()
          .map((t) => t.toString())
          .toList();
      final synced = NotificationsDatabase.LAST_SYNC.read();
      return [
        LunaBlock(
          title: 'Automatic Setup',
          body: [
            const TextSpan(
              text: 'Configured from your Tailarr Server',
              style: TextStyle(
                color: LunaColours.accent,
                fontWeight: LunaUI.FONT_WEIGHT_BOLD,
              ),
            ),
            TextSpan(text: url),
            TextSpan(text: topics.join(', ')),
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

    if (url.isNotEmpty) {
      return [
        LunaBlock(
          title: 'Automatic Setup',
          body: const [
            TextSpan(text: 'Configured manually'),
            TextSpan(text: 'Tap to switch to automatic setup'),
          ],
          trailing: const LunaIconButton(icon: Icons.cloud_sync_rounded),
          onTap: _runAutomaticSetup,
        ),
      ];
    }

    if (state == 'failed') {
      final attempted = NotificationsDatabase.LAST_ATTEMPT.read();
      return [
        LunaBlock(
          title: 'Automatic Setup Failed',
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
                  '${LunaUI.TEXT_BULLET.pad()}Tap to retry, or set up manually below',
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
        title: 'Set Up Automatically',
        body: const [
          TextSpan(
            text: 'Fetch your credentials from your Tailarr Server over '
                'the tailnet — no typing needed',
          ),
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
      } else if (creds.isUnassigned == true) {
        showLunaErrorSnackBar(
          title: 'Device Not Assigned',
          message:
              'Ask your Tailarr Server admin to assign this device to a user',
        );
      } else {
        showLunaErrorSnackBar(
          title: 'Automatic Setup Failed',
          message: creds.error ?? 'Unknown error',
        );
      }
    } catch (error) {
      // Full dial detail is in Settings > System > Logs (logged by
      // autoConfigure) — the snackbar keeps the human guidance.
      showLunaErrorSnackBar(
        title: 'Server Not Reachable',
        message:
            'Needs Tailscale enabled and a Tailarr Server v0.21+ with notifications set up — or use manual entry below. Details in Settings > System > Logs.',
      );
    }
  }

  Future<void> _onConfigChanged() async {
    await LunaNtfy().onConfigChanged();
  }

  Widget _enabledToggle() {
    return LunaBlock(
      title: 'settings.EnableModule'.tr(args: [LunaModule.NOTIFICATIONS.title]),
      trailing: LunaSwitch(
        value: NotificationsDatabase.ENABLED.read(),
        onChanged: (value) async {
          NotificationsDatabase.ENABLED.update(value);
          await _onConfigChanged();
          // Fresh enable with nothing configured: try the self-service
          // gateway before asking the user to type anything.
          if (value &&
              LunaNtfy.isSupported &&
              NotificationsDatabase.URL.read().isEmpty) {
            await _runAutomaticSetup();
          }
        },
      ),
    );
  }

  /// Accepts the server handout — the JSON blob (or future deep link) from
  /// the server's "Alerts on your phone" card — and fills every field.
  Widget _importSubscription() {
    return LunaBlock(
      title: 'Import Subscription',
      body: const [
        TextSpan(
          text: 'Paste the subscription from your server\'s Notifications page',
        ),
      ],
      trailing: const LunaIconButton(icon: Icons.qr_code_rounded),
      onTap: () async {
        final values = await _NotificationsDialogs.pasteSubscription(context);
        if (!values.item1) return;
        final subscription = NtfySubscription.parse(values.item2);
        if (subscription == null) {
          showLunaErrorSnackBar(
            title: 'Invalid Subscription',
            message: 'Expected the JSON or link handed out by Tailarr Server',
          );
          return;
        }
        NotificationsDatabase.URL.update(subscription.url);
        NotificationsDatabase.TOKEN.update(subscription.token);
        NotificationsDatabase.TOPICS.update(subscription.topics);
        NotificationsDatabase.GATEWAY_MANAGED.update(false);
        await _onConfigChanged();
        showLunaSuccessSnackBar(
          title: 'Subscription Imported',
          message: subscription.topics.join(', '),
        );
      },
    );
  }

  Widget _serverUrl() {
    final url = NotificationsDatabase.URL.read();
    return LunaBlock(
      title: 'Server URL',
      body: [TextSpan(text: url.isEmpty ? 'lunasea.NotSet'.tr() : url)],
      trailing: const LunaIconButton.arrow(),
      onTap: () async {
        final values = await SettingsDialogs().editHost(
          context,
          prefill: url,
        );
        if (values.item1) {
          NotificationsDatabase.URL
              .update(values.item2.trim().replaceAll(RegExp(r'/+$'), ''));
          NotificationsDatabase.GATEWAY_MANAGED.update(false);
          _onConfigChanged();
        }
      },
    );
  }

  Widget _accessToken() {
    final token = NotificationsDatabase.TOKEN.read();
    return LunaBlock(
      title: 'Access Token',
      body: [
        TextSpan(
          text: token.isEmpty
              ? 'lunasea.NotSet'.tr()
              : LunaUI.TEXT_OBFUSCATED_PASSWORD,
        ),
      ],
      trailing: const LunaIconButton.arrow(),
      onTap: () async {
        final values = await _NotificationsDialogs.editToken(
          context,
          prefill: token,
        );
        if (values.item1) {
          NotificationsDatabase.TOKEN.update(values.item2.trim());
          NotificationsDatabase.GATEWAY_MANAGED.update(false);
          _onConfigChanged();
        }
      },
    );
  }

  Widget _topics() {
    final topics = NotificationsDatabase.TOPICS
        .read()
        .map((t) => t.toString())
        .toList();
    return LunaBlock(
      title: 'Topics',
      body: [
        TextSpan(
          text: topics.isEmpty ? 'lunasea.NotSet'.tr() : topics.join(', '),
        ),
      ],
      trailing: const LunaIconButton.arrow(),
      onTap: () async {
        final values = await _NotificationsDialogs.editTopics(
          context,
          prefill: topics.join(', '),
        );
        if (values.item1) {
          NotificationsDatabase.TOPICS.update(
            values.item2
                .split(',')
                .map((t) => t.trim())
                .where((t) => t.isNotEmpty)
                .toList(),
          );
          NotificationsDatabase.GATEWAY_MANAGED.update(false);
          _onConfigChanged();
        }
      },
    );
  }

  Widget _backgroundRefreshToggle() {
    return LunaBlock(
      title: 'Background Refresh',
      body: const [
        TextSpan(
          text: 'Checked periodically while the app is closed — new alerts '
              'post as notifications. Delivery is opportunistic until instant '
              'push arrives in a later update.',
        ),
      ],
      trailing: LunaSwitch(
        value: NotificationsDatabase.BACKGROUND_REFRESH.read(),
        onChanged: LunaNtfy.isBackgroundRefreshSupported
            ? (value) async {
                NotificationsDatabase.BACKGROUND_REFRESH.update(value);
                if (value) {
                  final granted = await LunaNtfy().enableBackgroundRefresh();
                  if (!granted) {
                    showLunaErrorSnackBar(
                      title: 'Notifications Not Allowed',
                      message:
                          'Allow notifications for Tailarr in system settings',
                    );
                  }
                } else {
                  await LunaNtfy().disableBackgroundRefresh();
                }
              }
            : null,
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
            title: 'settings.HostRequired'.tr(),
            message: 'Set a server URL and at least one topic first',
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

class _NotificationsDialogs {
  static Future<Tuple2<bool, String>> _input(
    BuildContext context, {
    required String title,
    required List<String> hints,
    String prefill = '',
    String? Function(String?)? validator,
  }) async {
    bool flag = false;
    final formKey = GlobalKey<FormState>();
    final textController = TextEditingController()..text = prefill;

    void setValues(bool value) {
      if (formKey.currentState!.validate()) {
        flag = value;
        Navigator.of(context).pop();
      }
    }

    await LunaDialog.dialog(
      context: context,
      title: title,
      buttons: [
        LunaDialog.button(
          text: 'lunasea.Set'.tr(),
          onPressed: () => setValues(true),
        ),
      ],
      content: [
        for (final hint in hints)
          LunaDialog.textContent(
            text: '${LunaUI.TEXT_BULLET} $hint',
            textAlign: TextAlign.left,
          ),
        Form(
          key: formKey,
          child: LunaDialog.textFormInput(
            controller: textController,
            title: title,
            onSubmitted: (_) => setValues(true),
            validator: validator ?? (_) => null,
          ),
        ),
      ],
      contentPadding: LunaDialog.inputTextDialogContentPadding(),
    );
    return Tuple2(flag, textController.text);
  }

  static Future<Tuple2<bool, String>> editToken(
    BuildContext context, {
    String prefill = '',
  }) {
    return _input(
      context,
      title: 'Access Token',
      hints: [
        'The ntfy access token from your server (starts with tk_)',
        'The server operator can mint one from the Notifications page',
      ],
      prefill: prefill,
    );
  }

  static Future<Tuple2<bool, String>> editTopics(
    BuildContext context, {
    String prefill = '',
  }) {
    return _input(
      context,
      title: 'Topics',
      hints: [
        'Comma-separated list of topics to subscribe to',
        'tlr-ops carries server alerts; tlr-media-<service> carries media events',
      ],
      prefill: prefill,
    );
  }

  static Future<Tuple2<bool, String>> pasteSubscription(BuildContext context) {
    return _input(
      context,
      title: 'Import Subscription',
      hints: [
        'Paste the subscription JSON or link from your server',
        'Format: {"url": …, "token": …, "topics": […]}',
      ],
    );
  }
}
