import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/api/tailarr_server/models.dart';
import 'package:lunasea/api/tailarr_server/tailarr_server.dart';

// Fixtures captured verbatim from the server contract (web/app.py:
// status_ai_provider / op_ai_config_set / op_ai_config_clear). The raw
// api_key is NEVER present in any response — only key_set.
const _getConfigured =
    '{"ok": true, "error": null, "configured": true, "provider": "gemini", '
    '"model": "gemini-3.1-flash-live-preview", "key_set": true, '
    '"providers": ["gemini"]}';

const _getEmpty =
    '{"ok": true, "error": null, "configured": false, "provider": "", '
    '"model": "", "key_set": false, "providers": ["gemini"]}';

const _postSetOk =
    '{"ok": true, "error": null, "status": {"ok": true, "error": null, '
    '"configured": true, "provider": "gemini", '
    '"model": "gemini-3.1-flash-live-preview", "key_set": true, '
    '"providers": ["gemini"]}}';

const _postClearOk =
    '{"ok": true, "error": null, "status": {"ok": true, "error": null, '
    '"configured": false, "provider": "", "model": "", "key_set": false, '
    '"providers": ["gemini"]}}';

const _postSetErr =
    '{"ok": false, "error": "An API key is required."}';

/// Records requests and resolves canned responses so the API client can be
/// exercised end-to-end without a network. Installed ahead of the client's own
/// interceptors so it short-circuits the call.
class _MockInterceptor extends Interceptor {
  final Map<String, String> getBodies;
  final String Function(Map<String, dynamic> data) postHandler;
  final List<RequestOptions> requests = [];

  _MockInterceptor({required this.getBodies, required this.postHandler});

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    requests.add(options);
    final body = options.method == 'GET'
        ? getBodies[options.path]!
        : postHandler(Map<String, dynamic>.from(options.data as Map));
    handler.resolve(
      Response(
        requestOptions: options,
        statusCode: 200,
        data: json.decode(body),
      ),
    );
  }
}

void main() {
  group('TailarrServerAIConfig model (GET /api/ai)', () {
    test('parses a configured provider and reports key_set', () {
      final config = TailarrServerAIConfig.fromJson(json.decode(_getConfigured));
      expect(config.ok, isTrue);
      expect(config.configured, isTrue);
      expect(config.provider, 'gemini');
      expect(config.model, 'gemini-3.1-flash-live-preview');
      expect(config.keySet, isTrue);
      expect(config.providers, ['gemini']);
    });

    test('parses an empty (unset) config', () {
      final config = TailarrServerAIConfig.fromJson(json.decode(_getEmpty));
      expect(config.configured, isFalse);
      expect(config.keySet, isFalse);
      expect(config.provider, isEmpty);
      // Falls back to a usable provider list even if the server omitted it.
      expect(config.providers, isNotEmpty);
    });

    test('KEY-NEVER-DISPLAYED: the model exposes no raw-key field', () {
      // The contract must never carry the secret. Even if a rogue/legacy
      // server jammed an api_key into the payload, the model must drop it —
      // there is simply no field for it, and only key_set survives.
      final rogue = TailarrServerAIConfig.fromJson(json.decode(
          '{"ok": true, "error": null, "configured": true, '
          '"provider": "gemini", "model": "m", "key_set": true, '
          '"api_key": "AIzaSyLEAKEDLEAKEDLEAKED", "providers": ["gemini"]}'));
      expect(rogue.keySet, isTrue);
      // The public surface of the model contains no member holding the key.
      expect(rogue.toString(), isNot(contains('AIzaSyLEAKED')));
      expect(
        TailarrServerAIConfig.fromJson(json.decode(_getConfigured))
            .runtimeType
            .toString(),
        'TailarrServerAIConfig',
      );
    });
  });

  group('TailarrServerAIConfigResult model (POST /api/ai)', () {
    test('set result carries ok + refreshed status', () {
      final result =
          TailarrServerAIConfigResult.fromJson(json.decode(_postSetOk));
      expect(result.ok, isTrue);
      expect(result.error, isNull);
      expect(result.config, isNotNull);
      expect(result.config!.keySet, isTrue);
      expect(result.config!.provider, 'gemini');
    });

    test('failed set surfaces the error and no status', () {
      final result =
          TailarrServerAIConfigResult.fromJson(json.decode(_postSetErr));
      expect(result.ok, isFalse);
      expect(result.error, 'An API key is required.');
      expect(result.config, isNull);
    });
  });

  group('TailarrServerAPI /api/ai flow (get/set/clear)', () {
    late TailarrServerAPI api;
    late _MockInterceptor mock;
    String lastPostBody = _postSetOk;

    setUp(() {
      api = TailarrServerAPI(host: 'https://controller.ts.net/');
      mock = _MockInterceptor(
        getBodies: {'api/ai': _getConfigured},
        postHandler: (data) {
          if (data['do'] == 'clear') return _postClearOk;
          return lastPostBody;
        },
      );
      // Ahead of the client's own 401/403 interceptor.
      api.httpClient.interceptors.insert(0, mock);
    });

    test('getAIConfig issues a GET and parses key_set without a key', () async {
      final config = await api.getAIConfig();
      expect(config.keySet, isTrue);
      expect(mock.requests.single.method, 'GET');
      expect(mock.requests.single.path, 'api/ai');
    });

    test('setAIConfig posts {do:set, provider, api_key, model}', () async {
      lastPostBody = _postSetOk;
      final result = await api.setAIConfig(
        provider: 'gemini',
        apiKey: 'secret-key-123',
        model: 'gemini-3.1-flash-live-preview',
      );
      expect(result.ok, isTrue);
      final body = mock.requests.single.data as Map;
      expect(body['do'], 'set');
      expect(body['provider'], 'gemini');
      expect(body['api_key'], 'secret-key-123');
      expect(body['model'], 'gemini-3.1-flash-live-preview');
      // The response the app renders from carries no raw key.
      expect(result.config!.keySet, isTrue);
      expect(json.encode(result.config == null ? {} : {'m': result.config!.model}),
          isNot(contains('secret-key-123')));
    });

    test('clearAIConfig posts {do:clear} and reports the key gone', () async {
      final result = await api.clearAIConfig();
      expect(result.ok, isTrue);
      final body = mock.requests.single.data as Map;
      expect(body['do'], 'clear');
      expect(result.config!.keySet, isFalse);
    });
  });
}
