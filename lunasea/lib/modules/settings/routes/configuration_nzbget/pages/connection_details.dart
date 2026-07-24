import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/modules/nzbget.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/router/routes/settings.dart';
import 'package:lunasea/system/gateway/gateway_services.dart';
import 'package:lunasea/modules/settings/core/server_driven_connection.dart';

class ConfigurationNZBGetConnectionDetailsRoute extends StatefulWidget {
  const ConfigurationNZBGetConnectionDetailsRoute({
    Key? key,
  }) : super(key: key);

  @override
  State<ConfigurationNZBGetConnectionDetailsRoute> createState() => _State();
}

class _State extends State<ConfigurationNZBGetConnectionDetailsRoute>
    with LunaScrollControllerMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      appBar: _appBar() as PreferredSizeWidget?,
      body: _body(),
      bottomNavigationBar: _bottomActionBar(),
    );
  }

  Widget _appBar() {
    return LunaAppBar(
      title: 'settings.ConnectionDetails'.tr(),
      scrollControllers: [scrollController],
    );
  }

  Widget _bottomActionBar() {
    return LunaBottomActionBar(
      actions: [
        _testConnection(),
        _shareConfiguration(),
      ],
    );
  }

  Widget _body() {
    return LunaBox.profiles.listenableBuilder(
      builder: (context, _) => LunaListView(
        controller: scrollController,
        children: ServerDrivenConnection.isManaged('nzbget')
            ? ServerDrivenConnection.managedBlocks(
                context: context,
                type: 'nzbget',
                host: LunaProfile.current.nzbgetHost,
                hasCredential: LunaProfile.current.nzbgetPass.isNotEmpty || LunaProfile.current.nzbgetUser.isNotEmpty,
              )
            : [
                ...ServerDrivenConnection.adoptBlocks(
                  context: context,
                  type: 'nzbget',
                ),
                _host(),
                _username(),
                _password(),
                _customHeaders(),
              ],
      ),
    );
  }

  Widget _host() {
    String host = LunaProfile.current.nzbgetHost;
    return LunaBlock(
      title: 'settings.Host'.tr(),
      body: [TextSpan(text: host.isEmpty ? 'lunasea.NotSet'.tr() : host)],
      trailing: const LunaIconButton.arrow(),
      onTap: () async {
        Tuple2<bool, String> _values = await SettingsDialogs().editHost(
          context,
          prefill: host,
        );
        if (_values.item1) {
          LunaProfile.current.nzbgetHost = _values.item2;
          GatewayServicesSync.markManual('nzbget');
          LunaProfile.current.save();
          context.read<NZBGetState>().reset();
        }
      },
    );
  }

  Widget _username() {
    String username = LunaProfile.current.nzbgetUser;
    return LunaBlock(
      title: 'settings.Username'.tr(),
      body: [
        TextSpan(text: username.isEmpty ? 'lunasea.NotSet'.tr() : username),
      ],
      trailing: const LunaIconButton.arrow(),
      onTap: () async {
        Tuple2<bool, String> _values = await LunaDialogs().editText(
          context,
          'settings.Username'.tr(),
          prefill: username,
        );
        if (_values.item1) {
          LunaProfile.current.nzbgetUser = _values.item2;
          GatewayServicesSync.markManual('nzbget');
          LunaProfile.current.save();
          context.read<NZBGetState>().reset();
        }
      },
    );
  }

  Widget _password() {
    String password = LunaProfile.current.nzbgetPass;
    return LunaBlock(
      title: 'settings.Password'.tr(),
      body: [
        TextSpan(
          text: password.isEmpty
              ? 'lunasea.NotSet'.tr()
              : LunaUI.TEXT_OBFUSCATED_PASSWORD,
        ),
      ],
      trailing: const LunaIconButton.arrow(),
      onTap: () async {
        Tuple2<bool, String> _values = await LunaDialogs().editText(
          context,
          'settings.Password'.tr(),
          prefill: password,
          extraText: [
            LunaDialog.textSpanContent(
              text: '${LunaUI.TEXT_BULLET} ${'settings.PasswordHint1'.tr()}',
            ),
          ],
        );
        if (_values.item1) {
          LunaProfile.current.nzbgetPass = _values.item2;
          GatewayServicesSync.markManual('nzbget');
          LunaProfile.current.save();
          context.read<NZBGetState>().reset();
        }
      },
    );
  }

  Widget _testConnection() {
    return LunaButton.text(
      text: 'settings.TestConnection'.tr(),
      icon: LunaIcons.CONNECTION_TEST,
      onTap: () async {
        LunaProfile _profile = LunaProfile.current;
        if (_profile.nzbgetHost.isEmpty) {
          showLunaErrorSnackBar(
            title: 'settings.HostRequired'.tr(),
            message: 'settings.HostRequiredMessage'
                .tr(args: [LunaModule.NZBGET.title]),
          );
          return;
        }
        NZBGetAPI.from(LunaProfile.current)
            .testConnection()
            .then((_) => showLunaSuccessSnackBar(
                  title: 'settings.ConnectedSuccessfully'.tr(),
                  message: 'settings.ConnectedSuccessfullyMessage'
                      .tr(args: [LunaModule.NZBGET.title]),
                ))
            .catchError((error, trace) {
          LunaLogger().error('Connection Test Failed', error, trace);
          showLunaErrorSnackBar(
            title: 'settings.ConnectionTestFailed'.tr(),
            error: error,
          );
        });
      },
    );
  }

  Widget _customHeaders() {
    return LunaBlock(
      title: 'settings.CustomHeaders'.tr(),
      body: [TextSpan(text: 'settings.CustomHeadersDescription'.tr())],
      trailing: const LunaIconButton.arrow(),
      onTap: SettingsRoutes.CONFIGURATION_NZBGET_CONNECTION_DETAILS_HEADERS.go,
    );
  }
  Widget _shareConfiguration() {
    return LunaButton.text(
      text: 'Share',
      icon: Icons.ios_share_rounded,
      onTap: () async {
        if (LunaProfile.current.nzbgetHost.isEmpty) {
          showLunaErrorSnackBar(
            title: 'Nothing to Share',
            message: 'Set a host before sharing this configuration',
          );
          return;
        }
        await SharedModuleConfiguration.fromProfile(LunaModule.NZBGET)!
            .share(context);
      },
    );
  }
}
