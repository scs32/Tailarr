import 'package:flutter/material.dart';
import 'package:lunasea/api/ntfy/models.dart';
import 'package:lunasea/api/ntfy/ntfy.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/database/tables/notifications.dart';
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
      ],
      builder: (context, _) => LunaListView(
        controller: scrollController,
        children: [
          LunaModule.NOTIFICATIONS.informationBanner(),
          _enabledToggle(),
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

  Future<void> _onConfigChanged() async {
    await LunaNtfy().onConfigChanged();
  }

  Widget _enabledToggle() {
    return LunaBlock(
      title: 'settings.EnableModule'.tr(args: [LunaModule.NOTIFICATIONS.title]),
      trailing: LunaSwitch(
        value: NotificationsDatabase.ENABLED.read(),
        onChanged: (value) {
          NotificationsDatabase.ENABLED.update(value);
          _onConfigChanged();
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
