import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/router/router.dart';
import 'package:lunasea/router/routes.dart';
import 'package:lunasea/utils/profile_tools.dart';

class LunaDrawerHeader extends StatelessWidget {
  final String page;

  const LunaDrawerHeader({
    Key? key,
    required this.page,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return LunaSeaDatabase.ENABLED_PROFILE.listenableBuilder(
      builder: (context, _) {
        // Basic (server-tagged) profiles get a stripped shell: no Settings
        // gear, no profile switching — but they MUST keep an escape hatch, so
        // a server-owned Basic profile shows "Leave Server" in its place.
        final basic = LunaProfile.current.uiHidesSettings;
        final serverOwned = LunaProfile.current.serverOwned;
        return Container(
        child: LunaAppBar.dropdown(
          backgroundColor: Colors.transparent,
          hideLeading: true,
          useDrawer: false,
          title: LunaBox.profiles.keys.length == 1 || basic
              ? 'Tailarr'
              : LunaSeaDatabase.ENABLED_PROFILE.read(),
          profiles: basic ? [] : LunaBox.profiles.keys.cast<String>().toList(),
          actions: [
            if (!basic)
              LunaIconButton(
                icon: LunaIcons.SETTINGS,
                onPressed: page == LunaModule.SETTINGS.key
                    ? Navigator.of(context).pop
                    : LunaModule.SETTINGS.launch,
              )
            else if (serverOwned)
              LunaIconButton(
                icon: Icons.logout_rounded,
                onPressed: () => _leaveServer(context),
              ),
          ],
        ),
        decoration: BoxDecoration(
          color: LunaColours.accent,
          image: DecorationImage(
            image: const AssetImage(LunaAssets.brandingLogo),
            colorFilter: ColorFilter.mode(
              LunaColours.primary.withOpacity(0.15),
              BlendMode.dstATop,
            ),
            fit: BoxFit.cover,
          ),
        ),
      );
      },
    );
  }

  Future<void> _leaveServer(BuildContext context) async {
    final serverName = LunaSeaDatabase.ENABLED_PROFILE.read();
    final confirmed =
        await LunaDialogs().confirmLeaveServer(context, serverName);
    if (!confirmed) return;
    await LunaProfileTools().leaveServer();
    // Land on home (the destination profile / first-run); router uses the
    // global navigator so no stale-context concern after the await.
    LunaRouter.router.go(LunaRoutes.initialLocation);
  }
}
