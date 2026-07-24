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
import 'package:lunasea/database/tables/notifications.dart';
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

  Future<void> _autoConfigureIfUnconfigured() async {
    if (NotificationsDatabase.URL.read().isNotEmpty) return;
    final last = NotificationsDatabase.LAST_ATTEMPT.read();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < Duration.millisecondsPerHour) return;
    try {
      await autoConfigure();
    } catch (_) {
      // Recorded on the status card; retried next launch/module open.
    }
  }

  Future<int> syncInbox() => NtfySync.syncInbox();

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
      creds = await NtfyGatewayClient().selfNotifications();
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
      _recordFailure(
        creds.error ?? 'Gateway returned an incomplete handout',
        'GET $_GATEWAY_URL → HTTP ${creds.statusCode ?? '-'} '
            'ok=${creds.ok} topics=${creds.topics}',
      );
    }
    return creds;
  }

  /// Call after any subscription/background setting changes: mirrors the
  /// Hive config to the shared-state file and reapplies stream + schedule.
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
      final response = await NtfyGatewayClient().selfPushToken(
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
      await NtfyGatewayClient().selfPushToken(
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

  /// Mirrors the Hive-backed settings into the shared-state file the
  /// background isolate reads. Preserves the since-markers.
  static Future<void> mirrorConfig() async {
    final state = await NtfySharedState.load();
    state.url = NotificationsDatabase.URL.read();
    state.token = NotificationsDatabase.TOKEN.read();
    state.topics = NotificationsDatabase.TOPICS
        .read()
        .map((t) => t.toString())
        .toList();
    state.backgroundEnabled = NotificationsDatabase.ENABLED.read() &&
        NotificationsDatabase.BACKGROUND_REFRESH.read();
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
      final creds = await NtfyGatewayClient().selfNotifications();
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

  /// One poll: everything since the inbox marker into Hive. Returns the
  /// number of messages that were new.
  static Future<int> syncInbox() async {
    final subscription = config();
    if (subscription == null) return 0;
    final state = await NtfySharedState.load();
    final messages =
        await NtfyClient(subscription).poll(since: state.sinceParameter);
    return _store(messages, state);
  }

  /// Stores stream-delivered messages through the same dedupe/marker path.
  static Future<int> storeMessages(List<NtfyMessage> messages) async {
    final state = await NtfySharedState.load();
    return _store(messages, state);
  }

  static Future<int> _store(
    List<NtfyMessage> messages,
    NtfySharedState state,
  ) async {
    int fresh = 0;
    int maxTime = state.since;

    for (final message in messages) {
      if (message.id.isEmpty) continue;
      if (message.time > maxTime) maxTime = message.time;
      // Existing entries keep their read flag — repeated polls overlap.
      if (LunaBox.notifications.contains(message.id)) continue;
      await LunaBox.notifications.update(
        message.id,
        LunaNotification(
          id: message.id,
          time: message.time,
          topic: message.topic,
          title: message.title,
          body: message.message,
          priority: message.priority,
          tags: message.tags,
        ),
      );
      fresh++;
    }

    _compact();

    if (maxTime > state.since || maxTime > state.bgSince) {
      state.since = maxTime;
      // Anything already visible in-app must not re-notify from background.
      if (maxTime > state.bgSince) state.bgSince = maxTime;
      await state.save();
    }
    return fresh;
  }

  static void _compact([int count = INBOX_LIMIT]) {
    if (LunaBox.notifications.size <= count) return;
    final items = LunaBox.notifications.data.toList()
      ..sort((a, b) => b.time.compareTo(a.time));
    items.skip(count).forEach((notification) => notification.delete());
  }

  /// Background-isolate fetch: file-backed state only — the Hive boxes are
  /// owned by the main isolate and must not be opened here. New messages are
  /// NOT stored; the inbox catches up from its own marker on next launch.
  static Future<List<NtfyMessage>> backgroundFetch() async {
    final state = await NtfySharedState.load();
    if (!state.backgroundEnabled) return [];
    final subscription = state.subscription;
    if (subscription == null) return [];

    // First background run with no marker: look back one hour, not the
    // entire server-side cache.
    final since = state.bgSince != 0
        ? state.bgSince
        : DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600;

    final messages =
        await NtfyClient(subscription).poll(since: since.toString());
    final fresh = messages
        .where((m) => m.id.isNotEmpty && !state.notifiedIds.contains(m.id))
        .toList();

    state.bgSince = since;
    for (final message in messages) {
      if (message.time > state.bgSince) state.bgSince = message.time;
    }
    state.notifiedIds = [
      ...fresh.map((m) => m.id),
      ...state.notifiedIds,
    ];
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
      await NtfySync.refreshFromGateway();
      unawaited(NtfyPush.register());
      if (!_foreground || generation != _generation) return;
      final subscription = NtfySync.config();
      if (subscription == null) return;
      try {
        // Catch up first so the stream only has to carry live messages.
        await NtfySync.syncInbox();
        final state = await NtfySharedState.load();
        final cancelToken = _cancelToken = CancelToken();
        final stream = NtfyClient(subscription).stream(
          since: state.sinceParameter,
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
