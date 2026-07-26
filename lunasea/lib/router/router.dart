import 'package:flutter/material.dart';

import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/modules/settings/routes/import_configuration/route.dart';
import 'package:lunasea/router/routes/settings.dart';
import 'package:lunasea/system/logger.dart';
import 'package:lunasea/widgets/pages/error_route.dart';
import 'package:lunasea/router/routes.dart';
import 'package:lunasea/vendor.dart';

/// Whether Basic mode should block navigation to [location]. Basic
/// (server-tagged) people have the entire Settings surface suppressed —
/// configuration, profiles, manual editors, Pro upsell all live under
/// `/settings`. Pure so the router's redirect guard is unit-testable, and so
/// the "deep-linked subroute is still caught" invariant is locked.
bool basicBlocksSettingsRoute(String location, {required bool uiHidesSettings}) {
  if (!uiHidesSettings) return false;
  final root = SettingsRoutes.HOME.path;
  return location == root || location.startsWith('$root/');
}

class LunaRouter {
  static late GoRouter router;
  static GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();

  void initialize() {
    router = GoRouter(
      navigatorKey: navigator,
      errorBuilder: (_, state) => ErrorRoutePage(exception: state.error),
      initialLocation: LunaRoutes.initialLocation,
      // Basic mode (server-tagged): the whole Settings surface — configuration,
      // profiles, manual editors, Pro upsell — is suppressed. Guard the ROUTE,
      // not just the drawer button, so a deep link or programmatic nav can't
      // reach it for a Basic person. Sends them home instead.
      redirect: (context, state) {
        if (basicBlocksSettingsRoute(
          state.matchedLocation,
          uiHidesSettings: LunaProfile.current.uiHidesSettings,
        )) {
          return LunaRoutes.initialLocation;
        }
        return null;
      },
      routes: [
        ...LunaRoutes.values.map((r) => r.root.routes),
        // Shared-configuration deep links: https://tailarr.com/import#payload
        // (universal link) and tailarr:///import#payload (custom scheme).
        // The payload rides in the fragment so it never reaches a server;
        // ?c= is accepted as a fallback for contexts that strip fragments.
        GoRoute(
          path: '/import',
          builder: (context, state) => ImportConfigurationRoute(
            encoded: state.uri.fragment.isNotEmpty
                ? state.uri.fragment
                : state.uri.queryParameters['c'] ?? '',
          ),
        ),
      ],
    );
  }

  void popSafely() {
    if (router.canPop()) router.pop();
  }

  void popToRootRoute() {
    if (navigator.currentState == null) {
      LunaLogger().warning('Not observing any navigation navigators, skipping');
      return;
    }
    navigator.currentState!.popUntil((route) => route.isFirst);
  }
}
