import 'package:flutter/material.dart';
import 'package:lunasea/database/tables/notifications.dart';
import 'package:lunasea/modules.dart';
import 'package:lunasea/modules/notifications/routes/notifications/route.dart';
import 'package:lunasea/router/routes.dart';
import 'package:lunasea/vendor.dart';

// TODO: register a `tailarr://ntfy?url=…&token=…&topics=…` deep link that
// feeds NtfySubscription.fromUri straight into the settings — the parser and
// import path already exist (Settings > Notifications > Import Subscription).
enum NotificationsRoutes with LunaRoutesMixin {
  HOME('/notifications');

  @override
  final String path;

  const NotificationsRoutes(this.path);

  @override
  LunaModule get module => LunaModule.NOTIFICATIONS;

  @override
  bool isModuleEnabled(BuildContext context) {
    return NotificationsDatabase.ENABLED.read();
  }

  @override
  GoRoute get routes {
    switch (this) {
      case NotificationsRoutes.HOME:
        return route(widget: const NotificationsRoute());
    }
  }
}
