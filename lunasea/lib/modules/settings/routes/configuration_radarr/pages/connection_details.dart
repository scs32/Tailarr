import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/modules/radarr.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/router/routes/settings.dart';
import 'package:lunasea/system/gateway/gateway_services.dart';
import 'package:lunasea/modules/settings/core/server_driven_connection.dart';

class ConfigurationRadarrConnectionDetailsRoute extends StatefulWidget {
  const ConfigurationRadarrConnectionDetailsRoute({
    Key? key,
  }) : super(key: key);

  @override
  State<ConfigurationRadarrConnectionDetailsRoute> createState() => _State();
}

class _State extends State<ConfigurationRadarrConnectionDetailsRoute>
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
        children: ServerDrivenConnection.isManaged('radarr')
            ? ServerDrivenConnection.managedBlocks(
                context: context,
                type: 'radarr',
                host: LunaProfile.current.radarrHost,
                hasCredential: LunaProfile.current.radarrKey.isNotEmpty,
              )
            : [
                _host(),
                _apiKey(),
                _customHeaders(),
              ],
      ),
    );
  }

  Widget _host() {
    String host = LunaProfile.current.radarrHost;
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
          LunaProfile.current.radarrHost = _values.item2;
          GatewayServicesSync.markManual('radarr');
          LunaProfile.current.save();
          context.read<RadarrState>().reset();
        }
      },
    );
  }

  Widget _apiKey() {
    String apiKey = LunaProfile.current.radarrKey;
    return LunaBlock(
      title: 'settings.ApiKey'.tr(),
      body: [
        TextSpan(
          text: apiKey.isEmpty
              ? 'lunasea.NotSet'.tr()
              : LunaUI.TEXT_OBFUSCATED_PASSWORD,
        ),
      ],
      trailing: const LunaIconButton.arrow(),
      onTap: () async {
        Tuple2<bool, String> _values = await LunaDialogs().editText(
          context,
          'settings.ApiKey'.tr(),
          prefill: apiKey,
        );
        if (_values.item1) {
          LunaProfile.current.radarrKey = _values.item2;
          GatewayServicesSync.markManual('radarr');
          LunaProfile.current.save();
          context.read<RadarrState>().reset();
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
        if (_profile.radarrHost.isEmpty) {
          showLunaErrorSnackBar(
            title: 'settings.HostRequired'.tr(),
            message: 'settings.HostRequiredMessage'
                .tr(args: [LunaModule.RADARR.title]),
          );
          return;
        }
        if (_profile.radarrKey.isEmpty) {
          showLunaErrorSnackBar(
            title: 'settings.ApiKeyRequired'.tr(),
            message: 'settings.ApiKeyRequiredMessage'
                .tr(args: [LunaModule.RADARR.title]),
          );
          return;
        }
        RadarrAPI(
          host: _profile.radarrHost,
          apiKey: _profile.radarrKey,
          headers: Map<String, dynamic>.from(_profile.radarrHeaders),
        )
            .system
            .status()
            .then(
              (_) => showLunaSuccessSnackBar(
                title: 'settings.ConnectedSuccessfully'.tr(),
                message: 'settings.ConnectedSuccessfullyMessage'
                    .tr(args: [LunaModule.RADARR.title]),
              ),
            )
            .catchError(
          (error, trace) {
            LunaLogger().error(
              'Connection Test Failed',
              error,
              trace,
            );
            showLunaErrorSnackBar(
              title: 'settings.ConnectionTestFailed'.tr(),
              error: error,
            );
          },
        );
      },
    );
  }

  Widget _customHeaders() {
    return LunaBlock(
      title: 'settings.CustomHeaders'.tr(),
      body: [TextSpan(text: 'settings.CustomHeadersDescription'.tr())],
      trailing: const LunaIconButton.arrow(),
      onTap: SettingsRoutes.CONFIGURATION_RADARR_CONNECTION_DETAILS_HEADERS.go,
    );
  }
  Widget _shareConfiguration() {
    return LunaButton.text(
      text: 'Share',
      icon: Icons.ios_share_rounded,
      onTap: () async {
        if (LunaProfile.current.radarrHost.isEmpty) {
          showLunaErrorSnackBar(
            title: 'Nothing to Share',
            message: 'Set a host before sharing this configuration',
          );
          return;
        }
        await SharedModuleConfiguration.fromProfile(LunaModule.RADARR)!
            .share(context);
      },
    );
  }
}
