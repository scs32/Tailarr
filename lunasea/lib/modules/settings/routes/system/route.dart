import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/database/database.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/modules/settings/routes/system/widgets/backup_tile.dart';
import 'package:lunasea/modules/settings/routes/system/widgets/restore_tile.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/router/routes/settings.dart';
import 'package:lunasea/system/cache/image/image_cache.dart';
import 'package:lunasea/system/environment.dart';
import 'package:lunasea/system/flavor.dart';

class SystemRoute extends StatefulWidget {
  const SystemRoute({
    Key? key,
  }) : super(key: key);

  @override
  State<SystemRoute> createState() => _State();
}

class _State extends State<SystemRoute> with LunaScrollControllerMixin {
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
      title: 'settings.System'.tr(),
      scrollControllers: [scrollController],
    );
  }

  Widget _body() {
    return LunaListView(
      controller: scrollController,
      children: <Widget>[
        const SettingsSystemBackupRestoreBackupTile(),
        const SettingsSystemBackupRestoreRestoreTile(),
        LunaDivider(),
        _logs(),
        _clearImageCache(),
        _clearConfiguration(),
        LunaDivider(),
        _version(),
      ],
    );
  }

  Widget _version() {
    return FutureBuilder(
      future: PackageInfo.fromPlatform(),
      builder: (context, AsyncSnapshot<PackageInfo> snapshot) {
        final info = snapshot.data;
        final version = info == null
            ? '…'
            : '${info.version} (${info.buildNumber})';
        final flavor = LunaFlavor.current.key;
        final commit = LunaEnvironment.commit.length > 7
            ? LunaEnvironment.commit.substring(0, 7)
            : LunaEnvironment.commit;
        return LunaBlock(
          title: 'Tailarr $version',
          body: [TextSpan(text: '$flavor · $commit')],
          trailing: const LunaIconButton(icon: Icons.info_outline_rounded),
          onTap: () => 'Tailarr $version — $flavor · $commit'
              .copyToClipboard(),
        );
      },
    );
  }

  Widget _logs() {
    return LunaBlock(
      title: 'settings.Logs'.tr(),
      body: [TextSpan(text: 'settings.LogsDescription'.tr())],
      trailing: const LunaIconButton(icon: Icons.developer_mode_rounded),
      onTap: SettingsRoutes.SYSTEM_LOGS.go,
    );
  }

  Widget _clearImageCache() {
    return LunaBlock(
      title: 'settings.ClearImageCache'.tr(),
      body: [TextSpan(text: 'settings.ClearImageCacheDescription'.tr())],
      trailing: const LunaIconButton(icon: Icons.image_not_supported_rounded),
      onTap: () async {
        bool result = await SettingsDialogs().clearImageCache(context);
        if (result) {
          result = await LunaImageCache().clear();
          if (result) {
            showLunaSuccessSnackBar(
              title: 'settings.ImageCacheCleared'.tr(),
              message: 'settings.ImageCacheClearedDescription'.tr(),
            );
          } else {
            showLunaErrorSnackBar(
              title: 'settings.FailedToClearImageCache'.tr(),
              message: 'settings.FailedToClearImageCacheDescription'.tr(),
            );
          }
        }
      },
    );
  }

  Widget _clearConfiguration() {
    return LunaBlock(
      title: 'settings.ClearConfiguration'.tr(),
      body: [TextSpan(text: 'settings.CleanSlate'.tr())],
      trailing: const LunaIconButton(icon: Icons.delete_sweep_rounded),
      onTap: () async {
        bool result = await SettingsDialogs().clearConfiguration(context);
        if (result) {
          LunaDatabase().bootstrap();
          LunaState.reset(context);
          showLunaSuccessSnackBar(
            title: 'settings.ConfigurationCleared'.tr(),
            message: 'settings.ConfigurationClearedDescription'.tr(),
          );
        }
      },
    );
  }
}
