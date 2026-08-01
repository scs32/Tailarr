/// Gemini Live API client for the in-app Tailarr voice assistant.
///
/// Dart port of the session half of `spikes/gemini-live-mcp/gemini_live_mcp.py`.
/// Hand-rolled WebSocket against the Gemini Live "BidiGenerateContent" endpoint
/// (no Firebase, no google_genai SDK). Chosen because it:
///   - matches the proven Python spike message-for-message,
///   - depends only on dart:io/dart:convert so the SAME shipped code runs in the
///     standalone proof harness (`tool/voice_smoke.dart`),
///   - routes DIRECT to googleapis.com through the app's split-tunnel while the
///     MCP leg tunnels to the tailnet — no proxy conflict, and
///   - swaps to a server-minted ephemeral token in Phase 2 by changing ONLY the
///     connect URL (`?key=` -> `BidiGenerateContentConstrained?access_token=`),
///     so the raw API key never has to ship in the app.
///
/// Protocol (v1beta): first frame is `{"setup": {...}}`; wait for
/// `{"setupComplete": {}}`; then `{"clientContent": {turns, turnComplete}}` for a
/// text turn, `{"realtimeInput": {audio}}` for mic PCM, and
/// `{"toolResponse": {functionResponses}}` to answer a `{"toolCall": {...}}`.
/// Server audio arrives as `serverContent.modelTurn.parts[].inlineData` (24kHz
/// PCM base64); transcripts as `serverContent.{input,output}Transcription.text`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const String kDefaultLiveModel = 'gemini-3.1-flash-live-preview';
const int kMicSampleRate = 16000; // mic -> Gemini
const int kOutputSampleRate = 24000; // Gemini -> speaker

/// A function-call requested by Gemini.
class LiveFunctionCall {
  LiveFunctionCall({required this.id, required this.name, required this.args});
  final String? id;
  final String name;
  final Map<String, dynamic> args;
}

/// A function-call response returned to Gemini.
class LiveFunctionResponse {
  LiveFunctionResponse({this.id, required this.name, required this.response});
  final String? id;
  final String name;
  final Map<String, dynamic> response;

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        'name': name,
        'response': response,
      };
}

/// Callback that executes the requested tool calls and returns their responses.
typedef ToolCallHandler = Future<List<LiveFunctionResponse>> Function(
    List<LiveFunctionCall> calls);

class GeminiLiveClient {
  GeminiLiveClient({
    required this.apiKey,
    required this.onToolCall,
    this.model = kDefaultLiveModel,
    this.systemInstruction,
    this.functionDeclarations = const [],
    this.responseModalities = const ['AUDIO'],
    this.host = 'generativelanguage.googleapis.com',
    this.ephemeralToken,
  });

  /// AI Studio API key (Phase 1, via --dart-define). Ignored if [ephemeralToken]
  /// is set.
  final String apiKey;

  /// Phase 2: a server-minted short-lived Live token. When set, the client uses
  /// the constrained endpoint and never sends the raw key.
  final String? ephemeralToken;

  final String model;
  final String? systemInstruction;
  final List<Map<String, dynamic>> functionDeclarations;
  final List<String> responseModalities;
  final String host;
  final ToolCallHandler onToolCall;

  WebSocket? _ws;
  final _setupComplete = Completer<void>();

  // ---- Event streams (UI subscribes to these) ----
  final _outputTranscript = StreamController<String>.broadcast();
  final _inputTranscript = StreamController<String>.broadcast();
  final _audio = StreamController<Uint8List>.broadcast();
  final _turnComplete = StreamController<void>.broadcast();
  final _interrupted = StreamController<void>.broadcast();
  final _errors = StreamController<Object>.broadcast();

  /// Text of what Gemini is speaking (streamed in fragments).
  Stream<String> get outputTranscript => _outputTranscript.stream;

  /// Transcription of the user's spoken input.
  Stream<String> get inputTranscript => _inputTranscript.stream;

  /// Raw 24kHz mono s16le PCM audio chunks to play.
  Stream<Uint8List> get audio => _audio.stream;

  /// Fires when Gemini finishes a turn.
  Stream<void> get turnComplete => _turnComplete.stream;

  /// Fires when the model's turn was interrupted by the user speaking over it
  /// (barge-in). The player must immediately DROP any already-buffered output
  /// audio for the abandoned turn.
  Stream<void> get interrupted => _interrupted.stream;

  Stream<Object> get errors => _errors.stream;

  Uri get _uri {
    if (ephemeralToken != null) {
      return Uri.parse(
        'wss://$host/ws/google.ai.generativelanguage.v1beta.'
        'GenerativeService.BidiGenerateContentConstrained'
        '?access_token=$ephemeralToken',
      );
    }
    return Uri.parse(
      'wss://$host/ws/google.ai.generativelanguage.v1beta.'
      'GenerativeService.BidiGenerateContent?key=$apiKey',
    );
  }

  /// Open the socket, send `setup`, and complete once `setupComplete` arrives.
  ///
  /// The Gemini Live endpoint (and, in Phase 2, the tsnet cold-start path) can
  /// answer the WebSocket upgrade with a transient **502** while a backend spins
  /// up. Those are retried with backoff; a bad key / 4xx is surfaced immediately.
  Future<void> connect({
    Duration timeout = const Duration(seconds: 20),
    int maxRetries = 3,
  }) async {
    var attempt = 0;
    while (true) {
      try {
        return await _connectOnce(timeout);
      } catch (e) {
        attempt += 1;
        if (attempt > maxRetries || !isRetryableConnectError(e)) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
  }

  /// A cold-start 502 (or a dropped upgrade) is worth retrying; a 4xx (bad key,
  /// forbidden) is not. Public so the retry policy is unit-testable.
  static bool isRetryableConnectError(Object e) {
    final s = e.toString();
    return s.contains('502') ||
        s.contains('503') ||
        s.contains('504') ||
        e is SocketException ||
        (e is WebSocketException && !s.contains('40'));
  }

  Future<void> _connectOnce(Duration timeout) async {
    final ws = await WebSocket.connect(_uri.toString()).timeout(timeout);
    _ws = ws;
    ws.listen(_onFrame, onError: _errors.add, onDone: _onDone, cancelOnError: false);
    _send({
      'setup': {
        'model': 'models/$model',
        'generationConfig': {'responseModalities': responseModalities},
        if (systemInstruction != null)
          'systemInstruction': {
            'parts': [
              {'text': systemInstruction}
            ]
          },
        if (functionDeclarations.isNotEmpty)
          'tools': [
            {'functionDeclarations': functionDeclarations}
          ],
        // Empty configs enable transcription of both directions.
        'inputAudioTranscription': <String, dynamic>{},
        'outputAudioTranscription': <String, dynamic>{},
      }
    });
    await _setupComplete.future.timeout(timeout);
  }

  /// Send one text turn (the text lane / fallback).
  void sendText(String text) {
    _send({
      'clientContent': {
        'turns': [
          {
            'role': 'user',
            'parts': [
              {'text': text}
            ]
          }
        ],
        'turnComplete': true,
      }
    });
  }

  /// Stream a chunk of mic PCM (16-bit, 16kHz, little-endian mono).
  void sendAudioChunk(List<int> pcm16) {
    _send({
      'realtimeInput': {
        'audio': {
          'data': base64Encode(pcm16),
          'mimeType': 'audio/pcm;rate=$kMicSampleRate',
        }
      }
    });
  }

  /// Signal end of the user's spoken turn (VAD usually handles this, but this is
  /// explicit for push-to-talk).
  void sendAudioStreamEnd() {
    _send({
      'realtimeInput': {'audioStreamEnd': true}
    });
  }

  void _send(Map<String, dynamic> msg) {
    final ws = _ws;
    if (ws == null) throw StateError('GeminiLiveClient not connected');
    ws.add(jsonEncode(msg));
  }

  /// Testing hook: feed a raw server frame (String JSON or bytes) through the
  /// exact production parser so the protocol handling — including barge-in and
  /// audio decode — is unit-testable without opening a socket. NOT for
  /// production callers. (Kept as a plain method, not `@visibleForTesting`, so
  /// this file stays pure `dart:io` and still runs under `dart run`.)
  Future<void> ingestFrameForTest(Object frame) => _onFrame(frame);

  Future<void> _onFrame(dynamic frame) async {
    final Map<String, dynamic> msg;
    try {
      final text = frame is String ? frame : utf8.decode(frame as List<int>);
      msg = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (e) {
      _errors.add(e);
      return;
    }

    if (msg.containsKey('setupComplete')) {
      if (!_setupComplete.isCompleted) _setupComplete.complete();
      return;
    }

    final toolCall = msg['toolCall'];
    if (toolCall is Map) {
      await _handleToolCall(toolCall.cast<String, dynamic>());
      return;
    }

    final sc = msg['serverContent'];
    if (sc is Map) {
      final content = sc.cast<String, dynamic>();
      // Barge-in: the user spoke over the model. Gemini abandons the current
      // output turn; the player must drop everything still buffered.
      if (content['interrupted'] == true) {
        _interrupted.add(null);
      }
      final inputT = content['inputTranscription'];
      if (inputT is Map && inputT['text'] is String) {
        _inputTranscript.add(inputT['text'] as String);
      }
      final outputT = content['outputTranscription'];
      if (outputT is Map && outputT['text'] is String) {
        _outputTranscript.add(outputT['text'] as String);
      }
      final modelTurn = content['modelTurn'];
      if (modelTurn is Map) {
        final parts = (modelTurn['parts'] as List?) ?? const [];
        for (final p in parts) {
          final part = (p as Map).cast<String, dynamic>();
          final inline = part['inlineData'];
          if (inline is Map && inline['data'] is String) {
            _audio.add(base64Decode(inline['data'] as String));
          }
        }
      }
      if (content['turnComplete'] == true) {
        _turnComplete.add(null);
      }
    }
  }

  Future<void> _handleToolCall(Map<String, dynamic> toolCall) async {
    final rawCalls = (toolCall['functionCalls'] as List?) ?? const [];
    final calls = <LiveFunctionCall>[];
    for (final c in rawCalls) {
      final m = (c as Map).cast<String, dynamic>();
      calls.add(LiveFunctionCall(
        id: m['id'] as String?,
        name: m['name'] as String,
        args: (m['args'] as Map?)?.cast<String, dynamic>() ?? {},
      ));
    }
    List<LiveFunctionResponse> responses;
    try {
      responses = await onToolCall(calls);
    } catch (e) {
      _errors.add(e);
      responses = [
        for (final c in calls)
          LiveFunctionResponse(
            id: c.id,
            name: c.name,
            response: {'result': 'tool error: $e', 'structured': null},
          )
      ];
    }
    _send({
      'toolResponse': {
        'functionResponses': [for (final r in responses) r.toJson()],
      }
    });
  }

  void _onDone() {
    if (!_setupComplete.isCompleted) {
      _setupComplete.completeError(
        StateError('WebSocket closed before setupComplete '
            '(code=${_ws?.closeCode} reason=${_ws?.closeReason})'),
      );
    }
  }

  Future<void> close() async {
    await _ws?.close();
    await _outputTranscript.close();
    await _inputTranscript.close();
    await _audio.close();
    await _turnComplete.close();
    await _interrupted.close();
    await _errors.close();
  }
}
