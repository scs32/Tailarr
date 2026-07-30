import 'package:flutter/material.dart';
import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/modules.dart';
import 'package:lunasea/modules/requests/routes/requests/route.dart';
import 'package:lunasea/router/routes.dart';
import 'package:lunasea/vendor.dart';

enum RequestsRoutes with LunaRoutesMixin {
  HOME('/requests');

  @override
  final String path;

  const RequestsRoutes(this.path);

  @override
  LunaModule get module => LunaModule.REQUESTS;

  @override
  bool isModuleEnabled(BuildContext context) {
    // Server-driven: visible only while the caller's person holds a request-
    // portal (seerr) badge. Read straight off the profile (no module state) —
    // the same flag the drawer's LunaModule.REQUESTS.isEnabled check uses.
    return LunaProfile.current.seerrEnabled;
  }

  @override
  GoRoute get routes {
    switch (this) {
      case RequestsRoutes.HOME:
        return route(widget: const RequestsRoute());
    }
  }
}
