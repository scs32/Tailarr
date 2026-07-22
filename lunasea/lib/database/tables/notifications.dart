import 'package:lunasea/database/table.dart';

enum NotificationsDatabase<T> with LunaTableMixin<T> {
  ENABLED<bool>(false),
  URL<String>(''),
  TOKEN<String>(''),
  TOPICS<List>([]),
  BACKGROUND_REFRESH<bool>(false);

  @override
  LunaTable get table => LunaTable.notifications;

  @override
  final T fallback;

  const NotificationsDatabase(this.fallback);
}
