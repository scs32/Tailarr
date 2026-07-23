import 'package:lunasea/database/table.dart';

enum NotificationsDatabase<T> with LunaTableMixin<T> {
  ENABLED<bool>(false),
  URL<String>(''),
  TOKEN<String>(''),
  TOPICS<List>([]),
  BACKGROUND_REFRESH<bool>(false),

  /// Config came from the tailarr-gate self-service endpoint and is
  /// re-queried periodically (topics change when the admin flips services).
  /// Any manual edit turns this off.
  GATEWAY_MANAGED<bool>(false);

  @override
  LunaTable get table => LunaTable.notifications;

  @override
  final T fallback;

  const NotificationsDatabase(this.fallback);
}
