import 'package:lunasea/database/table.dart';
import 'package:lunasea/database/tables/lunasea.dart';

/// Notification + gateway self-config + push state, scoped PER PROFILE.
/// Every server-owned profile joins a different Tailarr Server (its own
/// person, topics, inbox, push registration), so none of this can be
/// global — the key is namespaced by the enabled profile so switching
/// profiles switches the entire notification world with zero leakage.
enum NotificationsDatabase<T> with LunaTableMixin<T> {
  ENABLED<bool>(false),
  URL<String>(''),
  TOKEN<String>(''),
  TOPICS<List>([]),
  BACKGROUND_REFRESH<bool>(false),

  /// Config came from the tailarr-gate self-service endpoint and is
  /// re-queried periodically (topics change when the admin flips services).
  /// Any manual edit turns this off.
  GATEWAY_MANAGED<bool>(false),

  /// Provisioning state machine, persisted so every attempt leaves a
  /// visible trace: '' (never attempted) | 'configured' | 'failed'.
  SETUP_STATE<String>(''),

  /// Verbatim error from the last failed attempt (gateway refusal text or
  /// transport error), plus the concrete request detail (host dialed,
  /// HTTP status, response body).
  SETUP_ERROR<String>(''),
  SETUP_DETAIL<String>(''),

  /// Epoch ms of the last attempt and the last SUCCESSFUL gateway sync.
  LAST_ATTEMPT<int>(0),
  LAST_SYNC<int>(0),

  /// Epoch ms of the last successful /self/services reconcile (server
  /// v0.23.0+). Lives here because this table is the gateway self-config
  /// state, notifications and services alike.
  SERVICES_LAST_SYNC<int>(0),

  /// APNs wake-push registration (server v0.26.0+). TOKEN is the last hex
  /// device token handed to the gateway; STATE is '' (never attempted) |
  /// 'registered' | 'failed' | 'unavailable' (server too old) |
  /// 'unassigned' (device not attached to a person); DETAIL carries the
  /// verbatim error for the failed states.
  PUSH_TOKEN<String>(''),
  PUSH_STATE<String>(''),
  PUSH_DETAIL<String>(''),
  PUSH_LAST_ATTEMPT<int>(0);

  @override
  LunaTable get table => LunaTable.notifications;

  /// Per-profile key: `NOTIFICATIONS_<FIELD>@<profile>`. Reads/writes/watches
  /// all resolve against the currently enabled profile, so every consumer
  /// (settings UI, stream manager, gateway sync, push) is profile-scoped
  /// for free. Legacy global keys (`NOTIFICATIONS_<FIELD>`) are simply left
  /// behind — notifications self-configure from the gateway, so a profile
  /// with no stored config just re-fetches.
  @override
  String get key {
    final profile = LunaSeaDatabase.ENABLED_PROFILE.read();
    return '${table.key.toUpperCase()}_${name}@$profile';
  }

  @override
  final T fallback;

  const NotificationsDatabase(this.fallback);
}
