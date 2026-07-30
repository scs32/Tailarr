import 'package:flutter/material.dart';
import 'package:lunasea/modules.dart';
import 'package:lunasea/modules/settings.dart';

class ConfigurationSonarrConnectionDetailsHeadersRoute extends StatelessWidget {
  const ConfigurationSonarrConnectionDetailsHeadersRoute({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return const SettingsHeaderRoute(module: LunaModule.SONARR);
  }
}
