import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/modules/lidarr.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/router/routes/settings.dart';
import 'package:lunasea/system/gateway/gateway_services.dart';
import 'package:lunasea/modules/settings/core/server_driven_connection.dart';

class ConfigurationLidarrConnectionDetailsRoute extends StatefulWidget {
  const ConfigurationLidarrConnectionDetailsRoute({
    Key? key,
  }) : super(key: key);

  @override
  State<ConfigurationLidarrConnectionDetailsRoute> createState() => _State();
}

class _State extends State<ConfigurationLidarrConnectionDetailsRoute>
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
        children: ServerDrivenConnection.isManaged('lidarr')
            ? ServerDrivenConnection.managedBlocks(
                context: context,
                type: 'lidarr',
                host: LunaProfile.current.lidarrHost,
                hasCredential: LunaProfile.current.lidarrKey.isNotEmpty,
              )
            : [
                ...ServerDrivenConnection.adoptBlocks(
                  context: context,
                  type: 'lidarr',
                ),
                _host(),
                _apiKey(),
                _customHeaders(),
              ],
      ),
    );
  }

  Widget _host() {
    String host = LunaProfile.current.lidarrHost;
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
          LunaProfile.current.lidarrHost = _values.item2;
          GatewayServicesSync.markManual('lidarr');
          LunaProfile.current.save();
          context.read<LidarrState>().reset();
        }
      },
    );
  }

  Widget _apiKey() {
    String apiKey = LunaProfile.current.lidarrKey;
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
          LunaProfile.current.lidarrKey = _values.item2;
          GatewayServicesSync.markManual('lidarr');
          LunaProfile.current.save();
          context.read<LidarrState>().reset();
        }
      },
    );
  }

  Widget _testConnection() {
    return LunaButton.text(
      text: 'settings.TestConnection'.tr(),
      icon: Icons.wifi_tethering_rounded,
      onTap: () async {
        LunaProfile _profile = LunaProfile.current;
        if (_profile.lidarrHost.isEmpty) {
          showLunaErrorSnackBar(
            title: 'settings.HostRequired'.tr(),
            message: 'settings.HostRequiredMessage'.tr(
              args: [LunaModule.LIDARR.title],
            ),
          );
          return;
        }
        if (_profile.lidarrKey.isEmpty) {
          showLunaErrorSnackBar(
            title: 'settings.ApiKeyRequired'.tr(),
            message: 'settings.ApiKeyRequiredMessage'.tr(
              args: [LunaModule.LIDARR.title],
            ),
          );
          return;
        }
        LidarrAPI.from(LunaProfile.current)
            .testConnection()
            .then(
              (_) => showLunaSuccessSnackBar(
                title: 'settings.ConnectedSuccessfully'.tr(),
                message: 'settings.ConnectedSuccessfullyMessage'.tr(
                  args: [LunaModule.LIDARR.title],
                ),
              ),
            )
            .catchError((error, trace) {
          LunaLogger().error(
            'Connection Test Failed',
            error,
            trace,
          );
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
      onTap: SettingsRoutes.CONFIGURATION_LIDARR_CONNECTION_DETAILS_HEADERS.go,
    );
  }
  Widget _shareConfiguration() {
    return LunaButton.text(
      text: 'Share',
      icon: Icons.ios_share_rounded,
      onTap: () async {
        if (LunaProfile.current.lidarrHost.isEmpty) {
          showLunaErrorSnackBar(
            title: 'Nothing to Share',
            message: 'Set a host before sharing this configuration',
          );
          return;
        }
        await SharedModuleConfiguration.fromProfile(LunaModule.LIDARR)!
            .share(context);
      },
    );
  }
}
