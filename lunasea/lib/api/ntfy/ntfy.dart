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
