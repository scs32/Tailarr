import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/modules/tailarr_server.dart';
import 'package:lunasea/router/routes/settings.dart';

class ConfigurationTailarrServerRoute extends StatefulWidget {
  const ConfigurationTailarrServerRoute({
    Key? key,
  }) : super(key: key);

  @override
  State<ConfigurationTailarrServerRoute> createState() => _State();
}

class _State extends State<ConfigurationTailarrServerRoute>
    with LunaScrollControllerMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      appBar: _appBar(),
      body: _body(),
    );
  }

  PreferredSizeWidget _appBar() {
    return LunaAppBar(
      title: LunaModule.TAILARR_SERVER.title,
      scrollControllers: [scrollController],
    );
  }

  Widget _body() {
    return LunaListView(
      controller: scrollController,
      children: [
        LunaModule.TAILARR_SERVER.informationBanner(),
        _enabledToggle(),
        _connectionDetailsPage(),
      ],
    );
  }

  Widget _enabledToggle() {
    return LunaBox.profiles.listenableBuilder(
      builder: (context, _) => LunaBlock(
        title: 'settings.EnableModule'
            .tr(args: [LunaModule.TAILARR_SERVER.title]),
        trailing: LunaSwitch(
          value: LunaProfile.current.tailarrServerEnabled,
          onChanged: (value) {
            LunaProfile.current.tailarrServerEnabled = value;
            LunaProfile.current.save();
            context.read<TailarrServerState>().reset();
          },
        ),
      ),
    );
  }

  Widget _connectionDetailsPage() {
    return LunaBlock(
      title: 'settings.ConnectionDetails'.tr(),
      body: [
        TextSpan(
          text: 'settings.ConnectionDetailsDescription'.tr(
            args: [LunaModule.TAILARR_SERVER.title],
          ),
        ),
      ],
      trailing: const LunaIconButton.arrow(),
      onTap: SettingsRoutes.CONFIGURATION_TAILARR_SERVER_CONNECTION_DETAILS.go,
    );
  }
}
