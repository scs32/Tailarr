import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules/voice/core/gemini_live_client.dart';
import 'package:lunasea/modules/voice/core/mcp_tool_proxy.dart';

/// B30 regression guards for the APP half of the voice tool-calling contract:
///   1. MCP tool -> Gemini functionDeclaration mapping (schema sanitize),
///   2. the connect `setup` frame carries those functionDeclarations +
///      systemInstruction (raw-key path is authoritative for these), and
///   3. an inbound `toolCall` frame routes through the handler and a matching
///      `toolResponse` frame goes back out — for multiple calls incl. an error.
///
/// The runtime B30 fix is server-side (the ephemeral token bakes the tools); see
/// the library doc in gemini_live_client.dart. These lock the app's contribution.
void main() {
  group('MCP tool -> Gemini functionDeclaration mapping', () {
    test('sanitizeSchema strips closed-world keys and recurses', () {
      final cleaned = sanitizeSchema({
        'type': 'object',
        'additionalProperties': false, // Gemini rejects this — must be stripped
        r'$schema': 'https://json-schema.org/draft',
        'properties': {
          'query': {'type': 'string', 'description': 'text', 'title': 'Q'},
          'tags': {
            'type': 'array',
            'items': {'type': 'string', 'additionalProperties': false},
          },
        },
        'required': ['query'],
      });
      expect(cleaned.containsKey('additionalProperties'), isFalse);
      expect(cleaned.containsKey(r'$schema'), isFalse);
      // Nested: the stray key inside properties/items is stripped too.
      final q = (cleaned['properties'] as Map)['query'] as Map;
      expect(q.containsKey('title'), isFalse);
      expect(q['description'], 'text');
      final items = ((cleaned['properties'] as Map)['tags'] as Map)['items'] as Map;
      expect(items.containsKey('additionalProperties'), isFalse);
      expect(cleaned['required'], ['query']);
    });

    test('an arg tool maps name/description/parameters with required preserved', () {
      final decl = toFunctionDeclaration(McpTool(
        name: 'search_library',
        description: 'Search titles.',
        inputSchema: {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'query': {'type': 'string'},
            'media_type': {
              'type': 'string',
              'enum': ['movie', 'series', 'music']
            },
          },
          'required': ['query'],
        },
      ));
      expect(decl['name'], 'search_library');
      expect(decl['description'], 'Search titles.');
      final params = decl['parameters'] as Map;
      expect(jsonEncode(params).contains('additionalProperties'), isFalse);
      expect((params['properties'] as Map).keys, containsAll(['query', 'media_type']));
      expect(params['required'], ['query']);
      expect(((params['properties'] as Map)['media_type'] as Map)['enum'],
          ['movie', 'series', 'music']);
    });

    test('a no-arg tool omits `parameters` entirely', () {
      final decl = toFunctionDeclaration(McpTool(
        name: 'get_system_health',
        description: 'Overview.',
        inputSchema: {'type': 'object', 'properties': {}},
      ));
      expect(decl.containsKey('parameters'), isFalse);
      expect(decl['name'], 'get_system_health');
    });
  });

  group('setup frame declares tools + systemInstruction', () {
    test('buildSetupPayload carries functionDeclarations + systemInstruction', () {
      final decls = [
        toFunctionDeclaration(McpTool(
            name: 'get_system_health', description: 'h', inputSchema: const {})),
        toFunctionDeclaration(McpTool(
            name: 'search_library',
            description: 's',
            inputSchema: {
              'type': 'object',
              'properties': {'query': {'type': 'string'}},
              'required': ['query'],
            })),
      ];
      final client = GeminiLiveClient(
        apiKey: 'k',
        onToolCall: (_) async => const [],
        systemInstruction: 'You are the Tailarr assistant; use your tools.',
        functionDeclarations: decls,
      );
      final setup = client.buildSetupPayload();
      final tools = setup['tools'] as List;
      final fnDecls = (tools.single as Map)['functionDeclarations'] as List;
      expect(fnDecls.map((d) => (d as Map)['name']),
          containsAll(['get_system_health', 'search_library']));
      expect(((setup['systemInstruction'] as Map)['parts'] as List).first,
          {'text': 'You are the Tailarr assistant; use your tools.'});
    });

    test('no tools -> `tools` key omitted (Gemini rejects an empty tools array)', () {
      final client = GeminiLiveClient(apiKey: 'k', onToolCall: (_) async => const []);
      expect(client.buildSetupPayload().containsKey('tools'), isFalse);
    });
  });

  group('inbound toolCall routes to handler and emits toolResponse', () {
    test('multiple calls (incl. one that errors) round-trip to a toolResponse',
        () async {
      final outbound = <Map<String, dynamic>>[];
      final seen = <LiveFunctionCall>[];
      final client = GeminiLiveClient(
        apiKey: 'k',
        outboundSink: outbound,
        onToolCall: (calls) async {
          seen.addAll(calls);
          // Simulate the proxy: real result for one, an error result for the other.
          return [
            for (final c in calls)
              LiveFunctionResponse(
                id: c.id,
                name: c.name,
                response: c.name == 'search_library'
                    ? {'result': "Tool '${c.name}' is not permitted.", 'structured': null}
                    : {'result': '16/16 services running', 'structured': {'ok': true}},
              )
          ];
        },
      );

      await client.ingestFrameForTest(jsonEncode({
        'toolCall': {
          'functionCalls': [
            {'id': 'a', 'name': 'get_system_health', 'args': {}},
            {'id': 'b', 'name': 'search_library', 'args': {'query': 'dune'}},
          ]
        }
      }));

      // The handler saw BOTH calls with names + args intact.
      expect(seen.map((c) => c.name), ['get_system_health', 'search_library']);
      expect(seen[1].args, {'query': 'dune'});

      // Exactly one toolResponse frame went out, carrying both responses by id.
      final frame = outbound.single['toolResponse'] as Map;
      final responses = frame['functionResponses'] as List;
      expect(responses.length, 2);
      expect((responses[0] as Map)['id'], 'a');
      expect((responses[0] as Map)['name'], 'get_system_health');
      expect(((responses[0] as Map)['response'] as Map)['result'], contains('services running'));
      expect(((responses[1] as Map)['response'] as Map)['result'], contains('not permitted'));
    });

    test('a throwing handler still emits an error toolResponse (never hangs)',
        () async {
      final outbound = <Map<String, dynamic>>[];
      final client = GeminiLiveClient(
        apiKey: 'k',
        outboundSink: outbound,
        onToolCall: (_) async => throw StateError('mcp down'),
      );
      await client.ingestFrameForTest(jsonEncode({
        'toolCall': {
          'functionCalls': [
            {'id': 'x', 'name': 'whoami', 'args': {}}
          ]
        }
      }));
      final responses =
          (outbound.single['toolResponse'] as Map)['functionResponses'] as List;
      expect(responses.length, 1);
      expect(((responses.single as Map)['response'] as Map)['result'],
          contains('tool error'));
    });
  });
}
