import 'package:lunasea/database/table.dart';

enum TailarrServerDatabase<T> with LunaTableMixin<T> {
  NAVIGATION_INDEX<int>(0),
  REFRESH_RATE<int>(15);

  @override
  LunaTable get table => LunaTable.tailarrServer;

  @override
  final T fallback;

  const TailarrServerDatabase(this.fallback);
}
