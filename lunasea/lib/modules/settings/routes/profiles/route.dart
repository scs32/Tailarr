import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/utils/profile_tools.dart';

class ProfilesRoute extends StatefulWidget {
  const ProfilesRoute({
    Key? key,
  }) : super(key: key);

  @override
  State<ProfilesRoute> createState() => _State();
}

class _State extends State<ProfilesRoute> with LunaScrollControllerMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      appBar: _appBar() as PreferredSizeWidget?,
      body: _body(),
    );
  }

  Widget _appBar() {
    return LunaAppBar(
      title: 'settings.Profiles'.tr(),
      scrollControllers: [scrollController],
    );
  }

  Widget _body() {
    return LunaListView(
      controller: scrollController,
      children: [
        SettingsBanners.PROFILES_SUPPORT.banner(),
        _enabledProfile(),
        _addProfile(),
        _renameProfile(),
        _deleteProfile(),
      ],
    );
  }

  Widget _addProfile() {
    return LunaBlock(
      title: 'settings.AddProfile'.tr(),
      body: const [
        TextSpan(text: 'Manually add a profile for another service — Pro'),
      ],
      trailing: const LunaIconButton(icon: Icons.workspace_premium_rounded),
      onTap: _showProComing,
    );
  }

  /// Manually-added (non-Tailarr-Server) profiles are a forthcoming Pro
  /// feature. Tailarr's free experience is server-driven: you join a Tailarr
  /// Server with an invite and everything configures itself.
  Future<void> _showProComing() async {
    await LunaDialog.dialog(
      context: context,
      title: 'Pro Mode Coming Soon',
      buttons: [
        LunaDialog.button(
          text: 'lunasea.OK'.tr(),
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
      ],
      content: [
        LunaDialog.textContent(
          text: 'Tailarr configures itself from your Tailarr Server — join '
              'one with an invite and your services set up automatically, '
              'no typing.\n\nManually adding profiles to connect to other '
              'services will arrive in a future Pro upgrade.',
        ),
      ],
      contentPadding: LunaDialog.textDialogContentPadding(),
    );
  }

  Widget _renameProfile() {
    return LunaBlock(
      title: 'settings.RenameProfile'.tr(),
      body: [TextSpan(text: 'settings.RenameProfileDescription'.tr())],
      trailing: const LunaIconButton(icon: LunaIcons.RENAME),
      onTap: () async {
        final dialogs = SettingsDialogs();
        final context = LunaState.context;
        // Server-owned profiles have server-driven, locked names.
        final profiles = LunaProfile.list.where((name) {
          return !(LunaBox.profiles.read(name)?.serverOwned ?? false);
        }).toList();

        if (profiles.isEmpty) {
          showLunaInfoSnackBar(
            title: 'No Profiles to Rename',
            message: 'Server-managed profiles are named by their server',
          );
          return;
        }

        final selected = await dialogs.renameProfile(context, profiles);
        if (selected.item1) {
          final name = await dialogs.renameProfileSelected(context, profiles);
          if (name.item1) {
            LunaProfileTools().rename(selected.item2, name.item2);
          }
        }
      },
    );
  }

  Widget _deleteProfile() {
    return LunaBlock(
        title: 'settings.DeleteProfile'.tr(),
        body: [TextSpan(text: 'settings.DeleteProfileDescription'.tr())],
        trailing: const LunaIconButton(icon: LunaIcons.DELETE),
        onTap: () async {
          final dialogs = SettingsDialogs();
          final enabledProfile = LunaSeaDatabase.ENABLED_PROFILE.read();
          final context = LunaState.context;
          final profiles = LunaProfile.list;
          profiles.removeWhere((p) => p == enabledProfile);

          if (profiles.isEmpty) {
            showLunaInfoSnackBar(
              title: 'settings.NoProfilesFound'.tr(),
              message: 'settings.NoAdditionalProfilesAdded'.tr(),
            );
            return;
          }

          final selected = await dialogs.deleteProfile(context, profiles);
          if (selected.item1) {
            LunaProfileTools().remove(selected.item2);
          }
        });
  }

  Widget _enabledProfile() {
    const db = LunaSeaDatabase.ENABLED_PROFILE;
    return db.listenableBuilder(
      builder: (context, _) {
        final name = db.read();
        final serverOwned =
            LunaBox.profiles.read(name)?.serverOwned ?? false;
        return LunaBlock(
          title: 'settings.EnabledProfile'.tr(),
          body: [
            TextSpan(text: name),
            if (serverOwned)
              const TextSpan(
                text: 'Managed by your Tailarr Server',
                style: TextStyle(color: LunaColours.accent),
              ),
          ],
          trailing: LunaIconButton(
            icon: serverOwned ? Icons.dns_rounded : LunaIcons.USER,
            color: serverOwned ? LunaColours.accent : LunaColours.white,
          ),
        onTap: () async {
          final dialogs = SettingsDialogs();
          final enabledProfile = LunaSeaDatabase.ENABLED_PROFILE.read();
          final context = LunaState.context;
          final profiles = LunaProfile.list;
          profiles.removeWhere((p) => p == enabledProfile);

          if (profiles.isEmpty) {
            showLunaInfoSnackBar(
              title: 'settings.NoProfilesFound'.tr(),
              message: 'settings.NoAdditionalProfilesAdded'.tr(),
            );
            return;
          }

          final selected = await dialogs.enabledProfile(context, profiles);
          if (selected.item1) {
            LunaProfileTools().changeTo(selected.item2);
          }
        },
        );
      },
    );
  }
}
