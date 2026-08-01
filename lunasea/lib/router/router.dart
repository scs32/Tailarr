import 'package:flutter/material.dart';

import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/modules/settings/routes/import_configuration/route.dart';
import 'package:lunasea/modules/voice/routes/voice/route.dart';
import 'package:lunasea/router/routes/settings.dart';
import 'package:lunasea/system/logger.dart';
import 'package:lunasea/utils/profile_tools.dart';
import 'package:lunasea/widgets/pages/error_route.dart';
import 'package:lunasea/widgets/pages/first_run_landing.dart';
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
        final location = state.matchedLocation;
        // First run — nothing configured anywhere: send to the landing so the
        // user picks Join or Demo. Never redirect away from /landing itself or
        // /import (the deep-link join target) or we'd loop.
        if (LunaProfileTools.isFirstRun() &&
            location != FirstRunLandingRoute.path &&
            location != '/import') {
          return FirstRunLandingRoute.path;
        }
        if (basicBlocksSettingsRoute(
          location,
          uiHidesSettings: LunaProfile.current.uiHidesSettings,
        )) {
          return LunaRoutes.initialLocation;
        }
        return null;
      },
      routes: [
        ...LunaRoutes.values.map((r) => r.root.routes),
        // First-run landing: Join a Tailarr Server or Start Demo Mode.
        GoRoute(
          path: FirstRunLandingRoute.path,
          builder: (context, state) => const FirstRunLandingRoute(),
        ),
        // Shared-configuration deep links: https://tailarr.com/import#payload
        // (universal link) and tailarr:///import#payload (custom scheme).
        // The payload rides in the fragment so it never reaches a server;
        // ?c= is accepted as a fallback for contexts that strip fragments.
        // In-app Gemini Live voice assistant (Phase 1). Reachable via the
        // drawer and deep link tailarr:///voice_assistant.
        GoRoute(
          path: VoiceRoute.path,
          builder: (context, state) => const VoiceRoute(),
        ),
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
