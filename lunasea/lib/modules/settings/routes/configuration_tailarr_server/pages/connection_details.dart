import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/modules/tailarr_server.dart';
import 'package:lunasea/router/routes/settings.dart';

class ConfigurationTailarrServerConnectionDetailsRoute extends StatefulWidget {
  const ConfigurationTailarrServerConnectionDetailsRoute({
    Key? key,
  }) : super(key: key);

  @override
  State<ConfigurationTailarrServerConnectionDetailsRoute> createState() =>
      _State();
}

class _State extends State<ConfigurationTailarrServerConnectionDetailsRoute>
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

  /// Tailarr Server has no API key: it is only reachable over the tailnet,
  /// which is the entire security model. The app should only ever talk to it
  /// through the embedded Tailscale node.
  bool _isTailnetHost(String host) {
    final uri = Uri.tryParse(host);
    final target = uri?.host ?? host;
    if (target.endsWith('.ts.net')) return true;
    final ip = RegExp(r'^100\.(\d+)\.').firstMatch(target);
    if (ip != null) {
      final second = int.tryParse(ip.group(1)!) ?? 0;
      return second >= 64 && second <= 127;
    }
    return false;
  }

  Widget _body() {
    return LunaBox.profiles.listenableBuilder(
      builder: (context, _) {
        final host = LunaProfile.current.tailarrServerHost;
        return LunaListView(
          controller: scrollController,
          children: [
            if (host.isNotEmpty && !_isTailnetHost(host)) _publicHostWarning(),
            if (_isTailnetHost(host) &&
                !LunaSeaDatabase.TAILSCALE_ENABLED.read())
              _tailscaleDisabledWarning(),
            _host(),
            _customHeaders(),
          ],
        );
      },
    );
  }

  Widget _publicHostWarning() {
    return const LunaBlock(
      title: 'Not a Tailnet Address',
      body: [
        TextSpan(
          text:
              'Tailarr Server has no authentication — it must only be reached over your tailnet. Use its https://…ts.net address.',
          style: TextStyle(color: LunaColours.red),
        ),
      ],
      trailing: LunaIconButton(
        icon: Icons.warning_rounded,
        color: LunaColours.red,
      ),
    );
  }

  Widget _tailscaleDisabledWarning() {
    return const LunaBlock(
      title: 'Tailscale is Disabled',
      body: [
        TextSpan(
          text:
              'This server is only reachable over Tailscale — enable it in Settings > General > Network.',
          style: TextStyle(color: LunaColours.orange),
        ),
      ],
      trailing: LunaIconButton(
        icon: Icons.vpn_lock_rounded,
        color: LunaColours.orange,
      ),
    );
  }

  Widget _host() {
    String host = LunaProfile.current.tailarrServerHost;
    return LunaBlock(
      title: 'settings.Host'.tr(),
      body: [TextSpan(text: host.isEmpty ? 'lunasea.NotSet'.tr() : host)],
      trailing: const LunaIconButton.arrow(),
      onTap: () async {
        Tuple2<bool, String> _values = await SettingsDialogs().editHost(
          context,
          prefill: LunaProfile.current.tailarrServerHost,
        );
        if (_values.item1) {
          LunaProfile.current.tailarrServerHost = _values.item2;
          LunaProfile.current.save();
          context.read<TailarrServerState>().reset();
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
        if (_profile.tailarrServerHost.isEmpty) {
          showLunaErrorSnackBar(
            title: 'settings.HostRequired'.tr(),
            message: 'settings.HostRequiredMessage'
                .tr(args: [LunaModule.TAILARR_SERVER.title]),
          );
          return;
        }
        TailarrServerAPI(
          host: _profile.tailarrServerHost,
          headers: Map<String, dynamic>.from(_profile.tailarrServerHeaders),
        ).getInfo().then((info) {
          if (info.apiVersion < 1) {
            showLunaErrorSnackBar(
              title: 'Server Upgrade Required',
              message:
                  'This Tailarr Server predates the mobile API — upgrade it to the latest release.',
            );
            return;
          }
          showLunaSuccessSnackBar(
            title: 'settings.ConnectedSuccessfully'.tr(),
            message: 'Tailarr Server v${info.version}',
          );
        }).catchError((error, trace) {
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
      onTap: SettingsRoutes
          .CONFIGURATION_TAILARR_SERVER_CONNECTION_DETAILS_HEADERS.go,
    );
  }
  Widget _shareConfiguration() {
    return LunaButton.text(
      text: 'Share',
      icon: Icons.ios_share_rounded,
      onTap: () async {
        if (LunaProfile.current.tailarrServerHost.isEmpty) {
          showLunaErrorSnackBar(
            title: 'Nothing to Share',
            message: 'Set a host before sharing this configuration',
          );
          return;
        }
        await SharedModuleConfiguration.fromProfile(LunaModule.TAILARR_SERVER)!
            .share(context);
      },
    );
  }
}
