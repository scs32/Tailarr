/// Orchestrates the in-app voice loop: Gemini Live <-> Tailarr MCP.
///
///   text/mic -> Gemini Live -> function_call -> Tailarr MCP (funnel, as person)
///                    ^                                    |
///                    +----------- FunctionResponse <------+
///                    +-> 24kHz PCM audio -> speaker
///
/// Pure Dart (no Flutter) so the standalone proof harness exercises the exact
/// shipped orchestration. The Flutter screen wraps this in a ChangeNotifier.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:lunasea/modules/voice/core/gemini_live_client.dart';
import 'package:lunasea/modules/voice/core/mcp_tool_proxy.dart';

// Re-export so callers (state, harness) get kDefaultLiveModel / sample rates
// without importing the client directly.
export 'package:lunasea/modules/voice/core/gemini_live_client.dart'
    show kDefaultLiveModel, kMicSampleRate, kOutputSampleRate;

const String kVoiceSystemInstruction =
    'You are the voice of a household media server (Tailarr). Answer spoken '
    'questions about the server by calling the provided tools, then speak a '
    'short, natural summary of the result. Call `whoami` if you are unsure what '
    'you may do. Keep replies to one or two sentences. Never claim to have '
    'changed anything — these tools are read-only status/search tools.';

/// A record of one proxied tool call, surfaced for the transcript/debug view.
class ToolActivity {
  ToolActivity({required this.name, required this.args, this.result, this.isError = false});
  final String name;
  final Map<String, dynamic> args;
  String? result;
  bool isError;
}

class VoiceSession {
  VoiceSession({
    required this.apiKey,
    required this.mcpUrl,
    required this.mcpToken,
    this.model = kDefaultLiveModel,
    this.systemInstruction = kVoiceSystemInstruction,
    this.ephemeralToken,
  });

  final String apiKey;
  final String? ephemeralToken;
  final String mcpUrl;
  final String mcpToken;
  final String model;
  final String systemInstruction;

  late final TailarrMcp _mcp = TailarrMcp(url: mcpUrl, token: mcpToken);
  GeminiLiveClient? _client;
  List<McpTool> _tools = const [];

  final _toolActivity = StreamController<ToolActivity>.broadcast();

  /// Fires for each tool call proxied to the MCP.
  Stream<ToolActivity> get toolActivity => _toolActivity.stream;
  Stream<String> get outputTranscript => _client!.outputTranscript;
  Stream<String> get inputTranscript => _client!.inputTranscript;
  Stream<Uint8List> get audio => _client!.audio;
  Stream<void> get turnComplete => _client!.turnComplete;
  Stream<Object> get errors => _client!.errors;

  List<String> get exposedTools => [for (final t in _tools) t.name];

  /// Connect the MCP + open the Live session. Returns the whoami summary as a
  /// connectivity proof.
  Future<String> start() async {
    await _mcp.initialize();
    final whoami = await _mcp.callTool('whoami', {});
    _tools = await _mcp.listTools(readonlyOnly: true);
    final decls = [for (final t in _tools) toFunctionDeclaration(t)];

    _client = GeminiLiveClient(
      apiKey: apiKey,
      ephemeralToken: ephemeralToken,
      model: model,
      systemInstruction: systemInstruction,
      functionDeclarations: decls,
      onToolCall: _handleToolCalls,
    );
    await _client!.connect();
    return whoami.summary;
  }

  Future<List<LiveFunctionResponse>> _handleToolCalls(List<LiveFunctionCall> calls) async {
    final responses = <LiveFunctionResponse>[];
    for (final fc in calls) {
      final activity = ToolActivity(name: fc.name, args: fc.args);
      _toolActivity.add(activity);
      final result = await _mcp.callTool(fc.name, fc.args);
      activity.result = result.summary;
      activity.isError = result.isError;
      _toolActivity.add(activity);
      responses.add(LiveFunctionResponse(
        id: fc.id,
        name: fc.name,
        // Return BOTH the one-line summary and the full structured envelope —
        // Gemini reads titles/detail from `structured`, not just `result`.
        response: {'result': result.summary, 'structured': result.structured},
      ));
    }
    return responses;
  }

  /// Send a text turn and resolve with the full spoken answer once the turn
  /// completes. Used by the text lane and the proof harness.
  Future<String> driveTextTurn(String text, {Duration timeout = const Duration(seconds: 45)}) {
    final client = _client!;
    final buffer = StringBuffer();
    final completer = Completer<String>();
    late final StreamSubscription outSub;
    late final StreamSubscription doneSub;
    late final StreamSubscription errSub;
    void finish([Object? error]) {
      if (completer.isCompleted) return;
      outSub.cancel();
      doneSub.cancel();
      errSub.cancel();
      if (error != null) {
        completer.completeError(error);
      } else {
        completer.complete(buffer.toString().trim());
      }
    }

    outSub = client.outputTranscript.listen(buffer.write);
    doneSub = client.turnComplete.listen((_) => finish());
    errSub = client.errors.listen(finish);
    client.sendText(text);
    return completer.future.timeout(timeout, onTimeout: () {
      finish();
      return buffer.toString().trim();
    });
  }

  /// Fire-and-forget text turn for the UI (updates arrive via the streams).
  void sendUserText(String text) => _client!.sendText(text);

  void sendAudioChunk(List<int> pcm16) => _client!.sendAudioChunk(pcm16);
  void sendAudioStreamEnd() => _client!.sendAudioStreamEnd();

  Future<void> close() async {
    await _client?.close();
    _mcp.close();
    await _toolActivity.close();
  }
}
