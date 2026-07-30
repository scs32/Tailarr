import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/database/backup_encryption.dart';
import 'package:lunasea/database/config.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/system/filesystem/filesystem.dart';

class SettingsSystemBackupRestoreBackupTile extends StatelessWidget {
  const SettingsSystemBackupRestoreBackupTile({
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return LunaBlock(
      title: 'settings.BackupToDevice'.tr(),
      body: [TextSpan(text: 'settings.BackupToDeviceDescription'.tr())],
      trailing: const LunaIconButton(icon: Icons.upload_rounded),
      onTap: () async => _backup(context),
    );
  }

  Future<void> _backup(BuildContext context) async {
    try {
      // M3: a backup is a user-shareable file that still carries live service
      // API keys, so encrypt the ENTIRE payload with a user passphrase before
      // it ever touches disk / the share sheet. The passphrase (min 8 chars) is
      // enforced by the dialog; the user re-enters it to restore.
      final values = await SettingsDialogs().backupConfiguration(context);
      if (!values.item1) return;
      String data = LunaConfig().export();
      String encrypted = LunaBackupEncryption.encrypt(data, values.item2);
      String name = DateFormat('y-MM-dd kk-mm-ss').format(DateTime.now());
      bool result = await LunaFileSystem().save(
        context,
        '$name.lunasea',
        encrypted.codeUnits,
      );
      if (result) {
        showLunaSuccessSnackBar(
          title: 'settings.BackupToCloudSuccess'.tr(),
          message: '$name.lunasea',
        );
      }
    } catch (error, stack) {
      LunaLogger().error('Failed to create device backup', error, stack);
      showLunaErrorSnackBar(
        title: 'settings.BackupToCloudFailure'.tr(),
        error: error,
      );
    }
  }
}
