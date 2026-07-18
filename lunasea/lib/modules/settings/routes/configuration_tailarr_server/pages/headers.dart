import 'package:flutter/material.dart';
import 'package:lunasea/modules.dart';
import 'package:lunasea/modules/settings.dart';

class ConfigurationTailarrServerConnectionDetailsHeadersRoute
    extends StatelessWidget {
  const ConfigurationTailarrServerConnectionDetailsHeadersRoute({
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return const SettingsHeaderRoute(module: LunaModule.TAILARR_SERVER);
  }
}
