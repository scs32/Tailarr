import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules/voice/core/gemini_live_client.dart';

/// Unit tests for the Gemini Live protocol parser and the cold-start retry
/// policy — the load-bearing logic of the audio lane (barge-in + audio decode +
/// 502 retry). Pure Dart: no socket, no Flutter platform channels.
void main() {
  GeminiLiveClient makeClient() => GeminiLiveClient(
        apiKey: 'test-key',
        onToolCall: (_) async => const [],
      );

  group('server frame parsing', () {
    test('outputTranscription streams the spoken text', () async {
      final client = makeClient();
      final got = <String>[];
      client.outputTranscript.listen(got.add);

      await client.ingestFrameForTest(
        jsonEncode({
          'serverContent': {
            'outputTranscription': {'text': 'the server is healthy'}
          }
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(got, ['the server is healthy']);
    });

    test('inlineData audio is base64-decoded to raw PCM bytes', () async {
      final client = makeClient();
      final pcm = Uint8List.fromList([0, 1, 2, 253, 254, 255]);
      Uint8List? got;
      client.audio.listen((b) => got = b);

      await client.ingestFrameForTest(
        jsonEncode({
          'serverContent': {
            'modelTurn': {
              'parts': [
                {
                  'inlineData': {'data': base64Encode(pcm)}
                }
              ]
            }
          }
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(got, isNotNull);
      expect(got, equals(pcm));
    });

    test('interrupted:true fires the barge-in stream (drop queued audio)',
        () async {
      final client = makeClient();
      var interruptions = 0;
      client.interrupted.listen((_) => interruptions++);

      await client.ingestFrameForTest(
        jsonEncode({
          'serverContent': {'interrupted': true}
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(interruptions, 1);
    });

    test('turnComplete fires once per completed turn', () async {
      final client = makeClient();
      var turns = 0;
      client.turnComplete.listen((_) => turns++);

      await client.ingestFrameForTest(
        jsonEncode({
          'serverContent': {'turnComplete': true}
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(turns, 1);
    });

    test('a frame carrying audio + interrupted routes both', () async {
      final client = makeClient();
      final pcm = Uint8List.fromList([9, 8, 7]);
      var interruptions = 0;
      Uint8List? audio;
      client.interrupted.listen((_) => interruptions++);
      client.audio.listen((b) => audio = b);

      await client.ingestFrameForTest(
        jsonEncode({
          'serverContent': {
            'interrupted': true,
            'modelTurn': {
              'parts': [
                {
                  'inlineData': {'data': base64Encode(pcm)}
                }
              ]
            }
          }
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(interruptions, 1);
      expect(audio, equals(pcm));
    });

    test('malformed frame is swallowed onto the error stream, not thrown',
        () async {
      final client = makeClient();
      Object? err;
      client.errors.listen((e) => err = e);

      await client.ingestFrameForTest('not json {');
      await Future<void>.delayed(Duration.zero);
      expect(err, isNotNull);
    });
  });

  group('cold-start retry classification', () {
    test('502/503/504 upgrade failures are retryable', () {
      expect(
        GeminiLiveClient.isRetryableConnectError(
            const WebSocketException('not upgraded to websocket (status 502)')),
        isTrue,
      );
      expect(
        GeminiLiveClient.isRetryableConnectError(
            const WebSocketException('status 503')),
        isTrue,
      );
    });

    test('socket errors (tsnet cold start) are retryable', () {
      expect(
        GeminiLiveClient.isRetryableConnectError(
            const SocketException('connection refused')),
        isTrue,
      );
    });

    test('a 4xx (bad key / forbidden) is NOT retried', () {
      expect(
        GeminiLiveClient.isRetryableConnectError(
            const WebSocketException('status 403 forbidden')),
        isFalse,
      );
      expect(
        GeminiLiveClient.isRetryableConnectError(
            const WebSocketException('status 401')),
        isFalse,
      );
    });
  });
}
