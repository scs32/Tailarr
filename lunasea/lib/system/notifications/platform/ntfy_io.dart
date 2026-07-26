import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import 'package:lunasea/api/ntfy/models.dart';
import 'package:lunasea/api/ntfy/ntfy.dart';
import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/models/notification.dart';
import 'package:lunasea/database/models/profile.dart';
import 'package:lunasea/database/tables/lunasea.dart';
import 'package:lunasea/database/tables/notifications.dart';
import 'package:lunasea/system/gateway/gateway_host.dart';
import 'package:lunasea/system/gateway/gateway_jellyfin.dart';
import 'package:lunasea/system/gateway/gateway_services.dart';
import 'package:lunasea/system/logger.dart';
import 'package:lunasea/system/notifications/platform/ntfy_shared_state.dart';

/// Entry point for the ntfy notification pipeline: foreground stream while
/// the app is active, one-shot polls for pull-to-refresh, and an
/// opportunistic background-refresh task that posts local notifications.
class LunaNtfy {
  static bool get isSupported => true;
  static bool get isBackgroundRefreshSupported =>
      Platform.isIOS || Platform.isAndroid;

  /// Must match the BGTaskSchedulerPermittedIdentifiers entry in Info.plist
  /// and the identifier registered in AppDelegate.swift.
  static const BACKGROUND_TASK_ID = 'com.stephenspeicher.tailarr.ntfy-refresh';

  Future<void> initialize() async {
    await NtfySync.mirrorConfig();
    if (isBackgroundRefreshSupported) {
      await NtfyLocalNotifications.initialize();
      await Workmanager().initialize(ntfyBackgroundDispatcher);
    }
    NtfyStreamManager.instance.initialize();
    // Notifications are not optional plumbing the user assembles — they
    // are on, configured by the server. Unconfigured devices quietly ask
    // the gateway on every launch (hourly throttle; every attempt is
    // still recorded on the status card).
    unawaited(_autoConfigureIfUnconfigured());
    // Idempotent token refresh on every launch (contract: re-register
    // freely; iOS rotates tokens across restores/reinstalls).
    unawaited(NtfyPush.register());
  }

  /// Retry an unconfigured device's gateway setup — called on launch and on
  /// every foreground. Public so the lifecycle observer can re-trigger it
  /// once the Tailscale node has had time to connect.
  Future<void> retryAutoConfigureIfUnconfigured() =>
      _autoConfigureIfUnconfigured();

  Future<void> _autoConfigureIfUnconfigured() async {
    if (NotificationsDatabase.URL.read().isNotEmpty) return;
    final last = NotificationsDatabase.LAST_ATTEMPT.read();
    final now = DateTime.now().millisecondsSinceEpoch;
    // Short cooldown, not hourly: a startup-race failure should re-attempt on
    // the next foreground/module-open, not sit "Not Connected" for an hour.
    if (now - last < const Duration(minutes: 2).inMilliseconds) return;

    // The gateway is a bare MagicDNS short name routed through the embedded
    // Tailscale node, which comes up a few seconds AFTER launch. A single
    // immediate attempt loses that race ("Failed host lookup: tailarr-gate")
    // and the hourly throttle then leaves it stuck. Retry across the startup
    // window: stop on success or a definitive refusal (device unassigned /
    // server too old); keep retrying only transport/routing failures.
    for (var attempt = 0; attempt < 6; attempt++) {
      try {
        final creds = await autoConfigure();
        if (creds == null || creds.ok || creds.isUnassigned) return;
        // A parsed-but-incomplete handout isn't going to fix itself by
        // retrying — stop and leave the recorded failure.
        return;
      } catch (_) {
        // Transport/routing error — the node likely isn't up yet. Wait and
        // retry through the connect window.
        await Future.delayed(const Duration(seconds: 5));
      }
    }
  }

  Future<int> syncInbox() => NtfySync.syncInbox();

  /// Record that these message ids were deleted from the inbox so a later poll
  /// can't resurrect them (see [NtfyProfileState.dismissedIds]). Scoped to the
  /// active profile — the slice the inbox sync uses.
  Future<void> recordDismissed(Iterable<String> ids) async {
    final incoming = ids.where((id) => id.isNotEmpty).toList();
    if (incoming.isEmpty) return;
    final profile = LunaSeaDatabase.ENABLED_PROFILE.read();
    final state = await NtfySharedState.load();
    final slice = state.slice(profile);
    // Insertion-ordered set: existing ids first, new last; keep the newest 500.
    final merged = <String>{...slice.dismissedIds, ...incoming}.toList();
    slice.dismissedIds =
        merged.length > 500 ? merged.sublist(merged.length - 500) : merged;
    await state.save();
  }

  void restartStream() => NtfyStreamManager.instance.restart();

  /// Self-service setup via the tailarr-gate node (server v0.21.0+): the
  /// gateway identifies this device by its tailnet address and returns the
  /// owner's credentials. On success the config is stored, marked
  /// gateway-managed, and the module is enabled. Throws on transport
  /// errors (gateway absent — older server or notifications not set up).
  static const _GATEWAY_URL =
      'http://${NtfyGatewayClient.DEFAULT_HOST}/self/notifications';

  static void _recordFailure(String error, String detail) {
    NotificationsDatabase.SETUP_STATE.update('failed');
    NotificationsDatabase.SETUP_ERROR.update(error);
    NotificationsDatabase.SETUP_DETAIL.update(detail);
  }

  /// Every attempt — user-triggered or opportunistic — leaves a persisted
  /// trace (state + timestamps + verbatim error): a failed attempt must
  /// never be indistinguishable from "nothing was implemented".
  Future<NtfyGatewayCredentials?> autoConfigure() async {
    NotificationsDatabase.LAST_ATTEMPT
        .update(DateTime.now().millisecondsSinceEpoch);
    final NtfyGatewayCredentials creds;
    try {
      creds = await (await gatewayClient()).selfNotifications();
    } on DioException catch (error, stack) {
      // Capture exactly what came back (or didn't) — this detail decides
      // whether the next fix is app- or server-side.
      final detail = 'GET $_GATEWAY_URL → type=${error.type} '
          'status=${error.response?.statusCode ?? '-'} '
          'body=${error.response?.data ?? '(no response — resolve/dial failed)'}';
      _recordFailure(error.message ?? error.type.toString(), detail);
      LunaLogger().error('ntfy gateway dial failed: $detail', error, stack);
      rethrow;
    } catch (error, stack) {
      _recordFailure(error.toString(), 'GET $_GATEWAY_URL');
      LunaLogger().error('ntfy gateway setup failed', error, stack);
      rethrow;
    }
    LunaLogger().debug(
      'ntfy gateway → HTTP ${creds.statusCode} ok=${creds.ok} '
      'error=${creds.error} topics=${creds.topics}',
    );
    if (creds.ok && creds.subscription.isValid) {
      NotificationsDatabase.URL.update(creds.url);
      NotificationsDatabase.TOKEN.update(creds.token);
      NotificationsDatabase.TOPICS.update(creds.topics);
      NotificationsDatabase.GATEWAY_MANAGED.update(true);
      NotificationsDatabase.ENABLED.update(true);
      NotificationsDatabase.SETUP_STATE.update('configured');
      NotificationsDatabase.SETUP_ERROR.update('');
      NotificationsDatabase.SETUP_DETAIL.update('');
      NotificationsDatabase.LAST_SYNC
          .update(DateTime.now().millisecondsSinceEpoch);
      // Background delivery is part of the product, not an option: request
      // permission and schedule as soon as the server configures us.
      NotificationsDatabase.BACKGROUND_REFRESH.update(true);
      await enableBackgroundRefresh();
      // The person is known to the gateway now — the wake-push token can
      // register against them.
      unawaited(NtfyPush.register(force: true));
    } else {
      // ok=true but the subscription is unusable — the gateway reached us but
      // handed back an incomplete payload. Name the missing field(s): that is
      // the difference between "the ntfy pod URL isn't wired up" (url) and
      // "this person has no topics badged" (topics), and it decides which
      // server-side fix to make. Without this the card just says "incomplete".
      final missing = <String>[
        if (creds.url.isEmpty) 'url',
        if (creds.topics.isEmpty) 'topics',
      ];
      _recordFailure(
        creds.error ??
            (missing.isEmpty
                ? 'Gateway returned an incomplete handout'
                : 'Gateway handout missing ${missing.join(' + ')} '
                    '— check the server\'s ntfy setup'),
        'GET $_GATEWAY_URL → HTTP ${creds.statusCode ?? '-'} '
            'ok=${creds.ok} url=${creds.url.isEmpty ? '(empty)' : 'set'} '
            'token=${creds.token.isEmpty ? '(empty)' : 'set'} '
            'topics=${creds.topics}',
      );
    }
    return creds;
  }

  /// Call after any subscription/background setting changes: mirrors the
  /// Hive config to the shared-state file and reapplies stream + schedule.
  /// Move a profile's per-profile notification state when its name (which is
  /// its Hive key) changes — server-driven profile renames rely on this so a
  /// rename doesn't orphan the subscription, inbox, or push registration.
  /// Migrates three name-keyed stores: the `NOTIFICATIONS_*@<profile>` config
  /// keys, the inbox entries (box key + `profile` tag), and the shared-state
  /// slice (preserving its since-markers). No-op when the names match.
  Future<void> migrateProfileName(String oldName, String newName) async {
    if (oldName == newName || newName.isEmpty) return;

    // 1. Config keys: NOTIFICATIONS_<FIELD>@<profile> (see Notifications
    // Database.key). Copy each present field to the new suffix, drop the old.
    const prefix = 'NOTIFICATIONS_'; // LunaTable.notifications.key.toUpperCase()
    for (final field in NotificationsDatabase.values) {
      final oldKey = '$prefix${field.name}@$oldName';
      if (!LunaBox.lunasea.contains(oldKey)) continue;
      await LunaBox.lunasea
          .update('$prefix${field.name}@$newName', LunaBox.lunasea.read(oldKey));
      await LunaBox.lunasea.delete(oldKey);
    }

    // 2. Inbox: entries carry an immutable `profile` tag and a
    // profile-namespaced box key — re-create each under the new name.
    for (final key in LunaBox.notifications.keys.toList()) {
      final n = LunaBox.notifications.read(key);
      if (n == null || n.profile != oldName) continue;
      await LunaBox.notifications.update(
        LunaNotification.boxKey(newName, n.id),
        LunaNotification(
          id: n.id,
          time: n.time,
          topic: n.topic,
          title: n.title,
          body: n.body,
          priority: n.priority,
          tags: n.tags,
          read: n.read,
          profile: newName,
        ),
      );
      await LunaBox.notifications.delete(key);
    }

    // 3. Shared-state slice: rename in place, preserving since-markers so the
    // renamed profile doesn't re-notify its backlog.
    final state = await NtfySharedState.load();
    state.renameProfile(oldName, newName);
    await state.save();
  }

  Future<void> onConfigChanged() async {
    await NtfySync.mirrorConfig();
    NtfyStreamManager.instance.restart();
    if (!NotificationsDatabase.ENABLED.read()) {
      unawaited(NtfyPush.unregister());
    }
    if (!isBackgroundRefreshSupported) return;
    if (NotificationsDatabase.ENABLED.read() &&
        NotificationsDatabase.BACKGROUND_REFRESH.read()) {
      await _schedule();
    } else {
      await Workmanager().cancelByUniqueName(BACKGROUND_TASK_ID);
    }
  }

  /// Requests notification permission and schedules the periodic refresh.
  /// Returns whether the permission was granted.
  Future<bool> enableBackgroundRefresh() async {
    if (!isBackgroundRefreshSupported) return false;
    final granted = await NtfyLocalNotifications.requestPermissions();
    await onConfigChanged();
    return granted;
  }

  Future<void> disableBackgroundRefresh() async {
    if (!isBackgroundRefreshSupported) return;
    await onConfigChanged();
  }

  Future<void> _schedule() async {
    await Workmanager().registerPeriodicTask(
      BACKGROUND_TASK_ID,
      BACKGROUND_TASK_ID,
      // iOS ignores the frequency here (set in AppDelegate.swift); Android
      // clamps to its 15-minute minimum anyway.
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }
}

/// APNs wake-push registration (stage 3, server v0.26.0+): the device token
/// goes to the whois-authenticated gateway, the server fans out content-free
/// wakes when messages land on the person's topics, and the Notification
/// Service Extension fetches the real content. The app never talks to the
/// public relay — no auth material for it exists here.
class NtfyPush {
  NtfyPush._();

  static const _channel = MethodChannel('com.stephenspeicher.tailarr/push');
  static const _ATTEMPT_INTERVAL = Duration(hours: 1);

  /// Registration is opportunistic and idempotent: on every launch, on
  /// foreground (throttled), and forced after Automatic Setup succeeds.
  /// Every attempt leaves a persisted trace in PUSH_STATE/PUSH_DETAIL.
  static Future<void> register({bool force = false}) async {
    if (!Platform.isIOS) return;
    if (!NotificationsDatabase.ENABLED.read()) return;
    final last = NotificationsDatabase.PUSH_LAST_ATTEMPT.read();
    if (!force &&
        DateTime.now().millisecondsSinceEpoch - last <
            _ATTEMPT_INTERVAL.inMilliseconds) {
      return;
    }
    NotificationsDatabase.PUSH_LAST_ATTEMPT
        .update(DateTime.now().millisecondsSinceEpoch);

    final String token;
    try {
      await NtfyLocalNotifications.requestPermissions();
      token = await _channel.invokeMethod<String>('requestPushToken') ?? '';
    } catch (error) {
      NotificationsDatabase.PUSH_STATE.update('failed');
      NotificationsDatabase.PUSH_DETAIL.update('APNs registration: $error');
      LunaLogger().debug('push: APNs registration failed: $error');
      return;
    }
    if (token.isEmpty) {
      NotificationsDatabase.PUSH_STATE.update('failed');
      NotificationsDatabase.PUSH_DETAIL.update('APNs returned an empty token');
      return;
    }

    // The APNs environment follows the SIGNING, not the Dart build mode: a
    // dev-signed release build (cable install) still gets sandbox tokens.
    // The native side reads aps-environment from the embedded profile.
    bool sandbox;
    try {
      sandbox =
          await _channel.invokeMethod<String>('getPushEnvironment') ==
              'development';
    } catch (_) {
      sandbox = kDebugMode;
    }

    try {
      final response = await (await gatewayClient()).selfPushToken(
        token: token,
        sandbox: sandbox,
      );
      if (response.ok && response.registered) {
        NotificationsDatabase.PUSH_TOKEN.update(token);
        NotificationsDatabase.PUSH_STATE.update('registered');
        NotificationsDatabase.PUSH_DETAIL.update('');
        LunaLogger().debug(
          'push: token registered (${response.count} for this person)',
        );
      } else if (response.isUnavailable) {
        NotificationsDatabase.PUSH_STATE.update('unavailable');
        NotificationsDatabase.PUSH_DETAIL
            .update('Server too old for push (needs v0.26.0+)');
      } else if (response.isUnassigned) {
        NotificationsDatabase.PUSH_STATE.update('unassigned');
        NotificationsDatabase.PUSH_DETAIL
            .update(response.error ?? 'Device not assigned to a user');
      } else {
        NotificationsDatabase.PUSH_STATE.update('failed');
        NotificationsDatabase.PUSH_DETAIL
            .update(response.error ?? 'Gateway refused the token');
      }
    } catch (error) {
      // Gateway unreachable — polling remains the fallback; retried on the
      // next launch/foreground.
      NotificationsDatabase.PUSH_STATE.update('failed');
      NotificationsDatabase.PUSH_DETAIL.update('Gateway dial: $error');
      LunaLogger().debug('push: gateway registration failed: $error');
    }
  }

  /// Called when notifications are disabled: best-effort token removal —
  /// the server also self-cleans tokens Apple reports dead.
  static Future<void> unregister() async {
    final token = NotificationsDatabase.PUSH_TOKEN.read();
    if (token.isEmpty) return;
    NotificationsDatabase.PUSH_TOKEN.update('');
    NotificationsDatabase.PUSH_STATE.update('');
    NotificationsDatabase.PUSH_DETAIL.update('');
    try {
      await (await gatewayClient()).selfPushToken(
        token: token,
        sandbox: kDebugMode,
        register: false,
      );
    } catch (_) {}
  }
}

/// Fetch-and-store, kept free of any widget so the exact same path can be
/// invoked from pull-to-refresh, the foreground stream, the background task,
/// and — in stage 3 — a content-free push wake-up.
class NtfySync {
  NtfySync._();

  static const INBOX_LIMIT = 200;

  /// The active subscription from Hive settings, or null when the module is
  /// disabled/unconfigured. Main-isolate only.
  static NtfySubscription? config() {
    if (!NotificationsDatabase.ENABLED.read()) return null;
    final subscription = NtfySubscription(
      url: NotificationsDatabase.URL.read(),
      token: NotificationsDatabase.TOKEN.read(),
      topics: NotificationsDatabase.TOPICS
          .read()
          .map((t) => t.toString())
          .toList(),
    );
    return subscription.isValid ? subscription : null;
  }

  /// The Hive-stored subscription for a specific profile, read by explicit
  /// per-profile key (so we can mirror EVERY profile into the shared file,
  /// not just the active one). Main-isolate only.
  static NtfySubscription? _hiveSubscriptionFor(String profile) {
    final url =
        LunaBox.lunasea.read('NOTIFICATIONS_URL@$profile', fallback: '')
            as String;
    final token =
        LunaBox.lunasea.read('NOTIFICATIONS_TOKEN@$profile', fallback: '')
            as String;
    final topics =
        (LunaBox.lunasea.read('NOTIFICATIONS_TOPICS@$profile', fallback: [])
                as List)
            .map((t) => t.toString())
            .toList();
    final sub = NtfySubscription(url: url, token: token, topics: topics);
    return sub.isValid ? sub : null;
  }

  /// Mirrors EVERY profile's Hive-backed subscription into the shared-state
  /// file the background isolate + NSE read — so push and background refresh
  /// cover all server-owned profiles, each attributed to its own inbox.
  /// Preserves each slice's since-markers.
  static Future<void> mirrorConfig() async {
    final state = await NtfySharedState.load();
    final active = LunaSeaDatabase.ENABLED_PROFILE.read();
    state.activeProfile = active;
    state.backgroundEnabled = NotificationsDatabase.BACKGROUND_REFRESH.read();

    final present = <String>{};
    for (final name in LunaProfile.list) {
      final sub = _hiveSubscriptionFor(name);
      if (sub == null) continue;
      present.add(name);
      final slice = state.slice(name);
      slice.url = sub.url;
      slice.token = sub.token;
      slice.topics = sub.topics;
    }
    // Drop slices for profiles that no longer have a subscription (deleted
    // or de-configured) so their stale config can't wake the device.
    state.profiles.removeWhere((name, _) => !present.contains(name));
    await state.save();
  }

  /// Silent gateway re-query for gateway-managed configs — topics change
  /// when the admin flips the person's services. Failures are ignored (the
  /// stored config keeps working); refusals (device unassigned) are also
  /// left alone rather than wiping a working subscription.
  static Future<void> refreshFromGateway() async {
    if (!NotificationsDatabase.ENABLED.read()) return;
    if (!NotificationsDatabase.GATEWAY_MANAGED.read()) return;
    try {
      final creds = await (await gatewayClient()).selfNotifications();
      if (!creds.ok || !creds.subscription.isValid) return;
      final changed = creds.url != NotificationsDatabase.URL.read() ||
          creds.token != NotificationsDatabase.TOKEN.read() ||
          !listEquals(
            creds.topics,
            NotificationsDatabase.TOPICS
                .read()
                .map((t) => t.toString())
                .toList(),
          );
      if (changed) {
        NotificationsDatabase.URL.update(creds.url);
        NotificationsDatabase.TOKEN.update(creds.token);
        NotificationsDatabase.TOPICS.update(creds.topics);
        await mirrorConfig();
      }
      NotificationsDatabase.SETUP_STATE.update('configured');
      NotificationsDatabase.LAST_SYNC
          .update(DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      // Gateway unreachable — keep the stored config.
    }
  }

  /// One poll: everything since the ACTIVE profile's inbox marker into Hive,
  /// tagged with the active profile. Returns the number of new messages.
  static Future<int> syncInbox() async {
    final subscription = config();
    if (subscription == null) return 0;
    final profile = LunaSeaDatabase.ENABLED_PROFILE.read();
    final state = await NtfySharedState.load();
    final slice = state.slice(profile);
    final messages =
        await NtfyClient(subscription).poll(since: slice.sinceParameter);
    return _store(messages, slice, state);
  }

  /// Stores stream-delivered messages (active profile) through the same
  /// dedupe/marker path.
  static Future<int> storeMessages(List<NtfyMessage> messages) async {
    final profile = LunaSeaDatabase.ENABLED_PROFILE.read();
    final state = await NtfySharedState.load();
    return _store(messages, state.slice(profile), state);
  }

  static Future<int> _store(
    List<NtfyMessage> messages,
    NtfyProfileState slice,
    NtfySharedState state,
  ) async {
    int fresh = 0;
    int maxTime = slice.since;
    bool sawConfigControl = false;

    for (final message in messages) {
      if (message.id.isEmpty) continue;
      if (message.time > maxTime) maxTime = message.time;
      // Silent config-changed signal (v0.74.0+): never an inbox item — it
      // forces an immediate self-config re-sync instead. The marker still
      // advances above so it isn't re-fetched forever.
      if (message.isConfigControl) {
        sawConfigControl = true;
        continue;
      }
      // The user deleted this one — a poll re-fetches it (ntfy `since` is
      // inclusive), so honor the dismissal instead of resurrecting it.
      if (slice.dismissedIds.contains(message.id)) continue;
      final key = LunaNotification.boxKey(slice.profile, message.id);
      // Existing entries keep their read flag — repeated polls overlap.
      if (LunaBox.notifications.contains(key)) continue;
      await LunaBox.notifications.update(
        key,
        LunaNotification(
          id: message.id,
          time: message.time,
          topic: message.topic,
          title: message.title,
          body: message.message,
          priority: message.priority,
          tags: message.tags,
          profile: slice.profile,
        ),
      );
      fresh++;
    }

    _compact();

    if (maxTime > slice.since || maxTime > slice.bgSince) {
      slice.since = maxTime;
      // Anything already visible in-app must not re-notify from background.
      if (maxTime > slice.bgSince) slice.bgSince = maxTime;
      await state.save();
    }
    if (sawConfigControl) _scheduleConfigResync();
    return fresh;
  }

  /// A server config-changed signal forces an immediate self-config re-sync
  /// (bypassing the 15-min throttle), debounced so a burst of admin badge
  /// flips coalesces into one re-fetch. This is the fast path; the throttled
  /// pull on foreground/reconnect stays as the backstop for missed pushes.
  static Timer? _configResyncTimer;
  static void _scheduleConfigResync() {
    _configResyncTimer?.cancel();
    _configResyncTimer = Timer(const Duration(seconds: 2), () async {
      LunaLogger().debug('gateway config-changed signal → forced re-sync');
      await GatewayServicesSync.refresh(force: true);
      await GatewayJellyfinSync.refresh(force: true);
    });
  }

  static void _compact([int count = INBOX_LIMIT]) {
    if (LunaBox.notifications.size <= count) return;
    final items = LunaBox.notifications.data.toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    items.skip(count).forEach((notification) => notification.delete());
  }

  /// Background-isolate fetch across EVERY server-owned profile: file-backed
  /// state only — Hive is owned by the main isolate. New messages are NOT
  /// stored; each profile's inbox catches up from its own marker on next
  /// launch. Returns fresh messages (any profile) to post as local
  /// notifications.
  static Future<List<NtfyMessage>> backgroundFetch() async {
    final state = await NtfySharedState.load();
    if (!state.backgroundEnabled) return [];

    final fresh = <NtfyMessage>[];
    for (final slice in state.subscribed) {
      final subscription = slice.subscription;
      if (subscription == null) continue;
      try {
        final since = slice.bgSince != 0
            ? slice.bgSince
            : DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;
        final messages =
            await NtfyClient(subscription).poll(since: since.toString());
        final newForSlice = messages
            .where((m) =>
                m.id.isNotEmpty &&
                !slice.notifiedIds.contains(m.id) &&
                // Silent config-changed signal must never surface as a local
                // notification; the main isolate handles it on next catch-up.
                !m.isConfigControl)
            .toList();

        slice.bgSince = since;
        for (final message in messages) {
          if (message.time > slice.bgSince) slice.bgSince = message.time;
        }
        slice.notifiedIds = [
          ...newForSlice.map((m) => m.id),
          ...slice.notifiedIds,
        ];
        fresh.addAll(newForSlice);
      } catch (_) {
        // One server unreachable shouldn't block the others.
      }
    }
    await state.save();
    return fresh;
  }
}

/// Keeps a live ndjson stream open while the app is foregrounded, with
/// exponential backoff reconnects, and tears it down on suspend (iOS kills
/// the socket anyway — reconnecting on resume also re-polls anything missed).
class NtfyStreamManager with WidgetsBindingObserver {
  NtfyStreamManager._();
  static final NtfyStreamManager instance = NtfyStreamManager._();

  bool _foreground = true;
  int _generation = 0;
  CancelToken? _cancelToken;

  void initialize() {
    WidgetsBinding.instance.addObserver(this);
    restart();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      restart();
      // Foregrounding is another chance to configure an unconfigured device
      // whose launch attempt lost the Tailscale-startup race (throttled).
      unawaited(LunaNtfy().retryAutoConfigureIfUnconfigured());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      _stop();
    }
  }

  void restart() {
    _stop();
    if (_foreground) _run(++_generation);
  }

  void _stop() {
    _generation++;
    _cancelToken?.cancel();
    _cancelToken = null;
  }

  Future<void> _run(int generation) async {
    int backoff = 5;
    while (_foreground && generation == _generation) {
      // Gateway-managed configs re-sync on every (re)connect cycle. The
      // services reconcile and push-token refresh ride the same wake-up
      // (both self-throttled).
      await GatewayServicesSync.refresh();
      await GatewayJellyfinSync.refresh();
      await NtfySync.refreshFromGateway();
      unawaited(NtfyPush.register());
      if (!_foreground || generation != _generation) return;
      final subscription = NtfySync.config();
      if (subscription == null) return;
      try {
        // Catch up first so the stream only has to carry live messages.
        await NtfySync.syncInbox();
        final active = LunaSeaDatabase.ENABLED_PROFILE.read();
        final state = await NtfySharedState.load();
        final cancelToken = _cancelToken = CancelToken();
        final stream = NtfyClient(subscription).stream(
          since: state.slice(active).sinceParameter,
          cancelToken: cancelToken,
        );
        await for (final message in stream) {
          if (generation != _generation) return;
          backoff = 5;
          await NtfySync.storeMessages([message]);
        }
      } catch (error) {
        if (generation != _generation) return;
        LunaLogger().debug('ntfy stream dropped — reconnecting: $error');
      }
      if (!_foreground || generation != _generation) return;
      await Future.delayed(Duration(seconds: backoff));
      backoff = (backoff * 2).clamp(5, 120);
    }
  }
}

/// Posts local notifications for background-fetched messages. Runs in both
/// the main isolate (permission requests) and the background isolate (show).
class NtfyLocalNotifications {
  NtfyLocalNotifications._();
  static final _plugin = FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
  }

  static Future<bool> requestPermissions() async {
    if (Platform.isIOS) {
      final ios = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      return await ios?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          false;
    }
    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      return await android?.requestNotificationsPermission() ?? false;
    }
    return false;
  }

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'tailarr_ntfy',
      'Tailarr Alerts',
      channelDescription: 'Alerts from your Tailarr Server',
    ),
    iOS: DarwinNotificationDetails(),
  );

  static Future<void> show(List<NtfyMessage> messages) async {
    await initialize();
    for (final message in messages.take(5)) {
      await _plugin.show(
        message.id.hashCode,
        message.title?.isNotEmpty == true
            ? message.title
            : ntfyTopicLabel(message.topic),
        message.message ?? '',
        _details,
      );
    }
    if (messages.length > 5) {
      await _plugin.show(
        0,
        'Tailarr',
        '${messages.length - 5} more notifications in the inbox',
        _details,
      );
    }
  }
}

/// Background-isolate entry point — invoked by BGAppRefreshTask (iOS) /
/// WorkManager (Android). Keep it Hive-free: shared-state file + network +
/// local notifications only.
@pragma('vm:entry-point')
void ntfyBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      final fresh = await NtfySync.backgroundFetch();
      if (fresh.isNotEmpty) await NtfyLocalNotifications.show(fresh);
    } catch (_) {
      // Opportunistic by design — the next refresh or launch catches up.
    }
    return true;
  });
}
