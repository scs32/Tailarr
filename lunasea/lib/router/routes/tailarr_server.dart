import 'package:flutter/material.dart';
import 'package:lunasea/modules.dart';
import 'package:lunasea/modules/tailarr_server/core/state.dart';
import 'package:lunasea/modules/tailarr_server/routes/pod_backups/route.dart';
import 'package:lunasea/modules/tailarr_server/routes/pod_details/route.dart';
import 'package:lunasea/modules/tailarr_server/routes/pod_logs/route.dart';
import 'package:lunasea/modules/tailarr_server/routes/tailarr_server/route.dart';
import 'package:lunasea/modules/tailarr_server/routes/updates/route.dart';
import 'package:lunasea/modules/tailarr_server/routes/person_details/route.dart';
import 'package:lunasea/modules/tailarr_server/routes/user_details/route.dart';
import 'package:lunasea/modules/tailarr_server/routes/users/route.dart';
import 'package:lunasea/router/routes.dart';
import 'package:lunasea/vendor.dart';

enum TailarrServerRoutes with LunaRoutesMixin {
  HOME('/tailarr_server'),
  POD_DETAILS('pod/:pod'),
  POD_LOGS('logs'),
  POD_BACKUPS('backups'),
  UPDATES('updates'),
  USERS('users'),
  USER_DETAILS('user/:id'),
  PERSON_DETAILS('person/:id');

  @override
  final String path;

  const TailarrServerRoutes(this.path);

  @override
  LunaModule get module => LunaModule.TAILARR_SERVER;

  @override
  bool isModuleEnabled(BuildContext context) {
    return context.read<TailarrServerState>().enabled;
  }

  @override
  GoRoute get routes {
    switch (this) {
      case TailarrServerRoutes.HOME:
        return route(widget: const TailarrServerRoute());
      case TailarrServerRoutes.POD_DETAILS:
        return route(builder: (_, state) {
          return PodDetailsRoute(pod: state.pathParameters['pod'] ?? '');
        });
      case TailarrServerRoutes.POD_LOGS:
        return route(builder: (_, state) {
          return PodLogsRoute(pod: state.pathParameters['pod'] ?? '');
        });
      case TailarrServerRoutes.POD_BACKUPS:
        return route(builder: (_, state) {
          return PodBackupsRoute(pod: state.pathParameters['pod'] ?? '');
        });
      case TailarrServerRoutes.UPDATES:
        return route(widget: const UpdatesRoute());
      case TailarrServerRoutes.USERS:
        return route(widget: const UsersRoute());
      case TailarrServerRoutes.USER_DETAILS:
        return route(builder: (_, state) {
          return UserDetailsRoute(id: state.pathParameters['id'] ?? '');
        });
      case TailarrServerRoutes.PERSON_DETAILS:
        return route(builder: (_, state) {
          return PersonDetailsRoute(id: state.pathParameters['id'] ?? '');
        });
    }
  }

  @override
  List<GoRoute> get subroutes {
    switch (this) {
      case TailarrServerRoutes.HOME:
        return [
          TailarrServerRoutes.POD_DETAILS.routes,
          TailarrServerRoutes.UPDATES.routes,
          TailarrServerRoutes.USERS.routes,
        ];
      case TailarrServerRoutes.USERS:
        return [
          TailarrServerRoutes.USER_DETAILS.routes,
          TailarrServerRoutes.PERSON_DETAILS.routes,
        ];
      case TailarrServerRoutes.POD_DETAILS:
        return [
          TailarrServerRoutes.POD_LOGS.routes,
          TailarrServerRoutes.POD_BACKUPS.routes,
        ];
      default:
        return const <GoRoute>[];
    }
  }
}
