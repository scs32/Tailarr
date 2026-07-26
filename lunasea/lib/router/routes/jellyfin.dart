import 'package:flutter/material.dart';
import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/modules.dart';
import 'package:lunasea/modules/jellyfin/routes/jellyfin/route.dart';
import 'package:lunasea/router/routes.dart';
import 'package:lunasea/vendor.dart';

enum JellyfinRoutes with LunaRoutesMixin {
  HOME('/jellyfin');

  @override
  final String path;

  const JellyfinRoutes(this.path);

  @override
  LunaModule get module => LunaModule.JELLYFIN;

  @override
  bool isModuleEnabled(BuildContext context) {
    // Server-driven: visible only while the caller's person holds a Jellyfin
    // badge. Read straight off the profile (no module state) — the same flag
    // the drawer's LunaModule.JELLYFIN.isEnabled check uses.
    return LunaProfile.current.jellyfinEnabled;
  }

  @override
  GoRoute get routes {
    switch (this) {
      case JellyfinRoutes.HOME:
        return route(widget: const JellyfinRoute());
    }
  }
}
