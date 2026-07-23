/// Dart client for consuming ntfy topics over plain HTTP — no SDK, no
/// Firebase. The Tailarr Server ntfy pod is exposed via Tailscale Funnel
/// (public HTTPS, deny-all auth), so this client works with or without the
/// embedded Tailscale node — which is exactly what the future push wake-up
/// path (stage 3) needs: it runs where the tunnel does not.
library ntfy;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:lunasea/api/ntfy/models.dart';

/// Client for the tailarr-gate self-service endpoint (server v0.21.0+).
///
/// Plain HTTP on :80 to the bare MagicDNS short name — the tailnet encrypts
/// and authenticates; the request must go out through the app's embedded
/// Tailscale node (TailscaleHttpOverrides routes dotless hosts there).
class NtfyGatewayClient {
  static const DEFAULT_HOST = 'tailarr-gate';

  final Dio httpClient;

  NtfyGatewayClient._internal({required this.httpClient});

  factory NtfyGatewayClient({String host = DEFAULT_HOST}) {
    final dio = Dio(
      BaseOptions(
        baseUrl: 'http://$host/',
        responseType: ResponseType.json,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        // {ok:false, error} refusals come back as 4xx — parse, don't throw.
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    return NtfyGatewayClient._internal(httpClient: dio);
  }

  /// Returns the CALLER'S notification credentials. Throws on transport
  /// errors (gateway absent: server < 0.21.0 or notifications not set up).
  Future<NtfyGatewayCredentials> selfNotifications() async {
    final response = await httpClient.get('self/notifications');
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw FormatException(
        'Unexpected gateway response '
        '(HTTP ${response.statusCode}): ${response.data}'.trim(),
      );
    }
    return NtfyGatewayCredentials.fromJson(
      data,
      statusCode: response.statusCode,
    );
  }

  /// Returns every service the CALLER'S person is badged for (server
  /// v0.23.0+). Older gateways 404 and older controllers answer with the
  /// notifications payload — both surface via [GatewayServicesResponse]
  /// skew flags, not exceptions. Throws only on transport errors.
  Future<GatewayServicesResponse> selfServices() async {
    final response = await httpClient.get('self/services');
    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw FormatException(
        'Unexpected gateway response '
        '(HTTP ${response.statusCode}): ${response.data}'.trim(),
      );
    }
    return GatewayServicesResponse.fromJson(
      data,
      statusCode: response.statusCode,
    );
  }
}

class NtfyClient {
  final NtfySubscription subscription;
  final Dio httpClient;

  NtfyClient._internal({required this.subscription, required this.httpClient});

  factory NtfyClient(NtfySubscription subscription) {
    final dio = Dio(
      BaseOptions(
        baseUrl: '${subscription.url}/',
        responseType: ResponseType.plain,
        headers: {
          if (subscription.token.isNotEmpty)
            'Authorization': 'Bearer ${subscription.token}',
        },
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    return NtfyClient._internal(subscription: subscription, httpClient: dio);
  }

  /// Comma-joined topics — one connection for the whole subscription.
  String get _topicPath => subscription.topics.join(',');

  /// One-shot poll: fetches everything after [since] (a message id, unix
  /// timestamp, or 'all') and returns only real messages, oldest first.
  Future<List<NtfyMessage>> poll({String since = 'all'}) async {
    final response = await httpClient.get(
      '$_topicPath/json',
      queryParameters: {'poll': '1', 'since': since},
    );
    return const LineSplitter()
        .convert(response.data as String? ?? '')
        .map(NtfyMessage.fromLine)
        .whereType<NtfyMessage>()
        .where((m) => m.isMessage)
        .toList();
  }

  /// Long-lived ndjson stream. Emits messages as the server publishes them;
  /// keepalive/open events are consumed silently. The stream ends when the
  /// server closes the connection — callers own reconnection policy.
  Stream<NtfyMessage> stream({
    String? since,
    CancelToken? cancelToken,
  }) async* {
    final response = await httpClient.get<ResponseBody>(
      '$_topicPath/json',
      queryParameters: {if (since != null) 'since': since},
      options: Options(
        responseType: ResponseType.stream,
        // The connection stays open indefinitely; ntfy keepalives arrive
        // every ~45s, so time out only if the line goes fully silent.
        receiveTimeout: const Duration(minutes: 3),
      ),
      cancelToken: cancelToken,
    );

    final lines = response.data!.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      final message = NtfyMessage.fromLine(line);
      if (message != null && message.isMessage) yield message;
    }
  }
}
