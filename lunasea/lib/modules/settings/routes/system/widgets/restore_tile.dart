import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/database/backup_encryption.dart';
import 'package:lunasea/database/config.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/system/filesystem/file.dart';
import 'package:lunasea/system/filesystem/filesystem.dart';

class SettingsSystemBackupRestoreRestoreTile extends StatelessWidget {
  const SettingsSystemBackupRestoreRestoreTile({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return LunaBlock(
      title: 'settings.RestoreFromDevice'.tr(),
      body: [TextSpan(text: 'settings.RestoreFromDeviceDescription'.tr())],
      trailing: const LunaIconButton(icon: Icons.download_rounded),
      onTap: () async => _restore(context),
    );
  }

  Future<void> _restore(BuildContext context) async {
    try {
      LunaFile? file = await LunaFileSystem().read(context, ['lunasea']);
      if (file != null) await _decryptBackup(context, file);
    } catch (error, stack) {
      LunaLogger().error('Failed to restore device backup', error, stack);
      showLunaErrorSnackBar(
        title: 'settings.RestoreFromCloudFailure'.tr(),
        error: error,
      );
    }
  }

  Future<void> _decryptBackup(
    BuildContext context,
    LunaFile file,
  ) async {
    String contents = String.fromCharCodes(file.data);
    // M3: current backups are AES-256-GCM envelopes — prompt for the passphrase
    // and decrypt to the plaintext config before importing. Legacy plaintext
    // backups (build 39 and earlier) have no envelope and import directly, so
    // an older backup still restores.
    String plaintext;
    if (LunaBackupEncryption.isEncrypted(contents)) {
      final values = await SettingsDialogs().decryptBackup(context);
      if (!values.item1) return;
      try {
        plaintext = LunaBackupEncryption.decrypt(contents, values.item2);
      } catch (_) {
        // Wrong passphrase or a corrupt/tampered file (GCM tag mismatch) — let
        // the user retry the key without re-picking the file.
        showLunaErrorSnackBar(
          title: 'settings.RestoreFromCloudFailure'.tr(),
          message: 'lunasea.IncorrectEncryptionKey'.tr(),
          showButton: true,
          buttonText: 'lunasea.Retry'.tr(),
          buttonOnPressed: () async => _decryptBackup(context, file),
        );
        return;
      }
    } else {
      plaintext = contents;
    }
    try {
      await LunaConfig().import(context, plaintext);
      showLunaSuccessSnackBar(
        title: 'settings.RestoreFromCloudSuccess'.tr(),
        message: 'settings.RestoreFromCloudSuccessMessage'.tr(),
      );
    } on FormatException catch (error) {
      // A validated-but-unusable backup (bad JSON / shape / no profiles). The
      // existing config was rolled back untouched — tell the user why.
      showLunaErrorSnackBar(
        title: 'settings.RestoreFromCloudFailure'.tr(),
        message: error.message,
      );
    } catch (error, stack) {
      // Import itself failed AFTER a successful decrypt/plaintext parse — a
      // genuine restore error, not a bad passphrase (that is handled above).
      LunaLogger().error('Failed to restore device backup', error, stack);
      showLunaErrorSnackBar(
        title: 'settings.RestoreFromCloudFailure'.tr(),
        error: error,
      );
    }
  }
}
