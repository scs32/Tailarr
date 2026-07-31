import 'dart:async';

import 'package:lunasea/system/state.dart';
import 'package:lunasea/system/logger.dart';
import 'package:lunasea/modules/voice/core/voice_session.dart';

/// Who authored a line in the transcript.
enum VoiceRole { user, assistant, tool, system }

class VoiceMessage {
  VoiceMessage(this.role, this.text, {this.isError = false});
  final VoiceRole role;
  String text;
  bool isError;
}

enum VoiceConnectionStatus { idle, connecting, ready, error }

/// State for the in-app Gemini Live voice assistant.
///
/// PHASE 1 (prototype) config is injected at compile time via --dart-define,
/// mirroring the app's existing TS_AUTHKEY test pattern. The Gemini API key
/// therefore does NOT ship in a normal build — pass it only for a dev/test run.
/// PHASE 2 replaces all three defines with a server-side ephemeral-token broker
/// (see handoff/voice-inapp-phase1.md): the box holds GEMINI_API_KEY and mints a
/// short-lived Live token, and the MCP token is minted in-app via /self/ai.
class VoiceAssistantState extends LunaModuleState {
  VoiceAssistantState() {
    reset();
  }

  static const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');
  static const String mcpUrl = String.fromEnvironment('TAILARR_MCP_URL');
  static const String mcpToken = String.fromEnvironment('TAILARR_MCP_TOKEN');
  static const String model = String.fromEnvironment(
    'GEMINI_LIVE_MODEL',
    defaultValue: kDefaultLiveModel,
  );

  bool get isConfigured =>
      geminiApiKey.isNotEmpty && mcpUrl.isNotEmpty && mcpToken.isNotEmpty;

  VoiceSession? _session;
  final List<VoiceMessage> messages = [];
  final List<StreamSubscription> _subs = [];

  VoiceConnectionStatus _status = VoiceConnectionStatus.idle;
  VoiceConnectionStatus get status => _status;

  bool _turnInProgress = false;
  bool get turnInProgress => _turnInProgress;

  List<String> _exposedTools = const [];
  List<String> get exposedTools => _exposedTools;

  @override
  void reset() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _session?.close();
    _session = null;
    messages.clear();
    _status = VoiceConnectionStatus.idle;
    _turnInProgress = false;
    _exposedTools = const [];
    notifyListeners();
  }

  /// Open the MCP + Gemini Live session if not already connected.
  Future<void> ensureConnected() async {
    if (_status == VoiceConnectionStatus.ready ||
        _status == VoiceConnectionStatus.connecting) {
      return;
    }
    if (!isConfigured) {
      _status = VoiceConnectionStatus.error;
      _addSystem(
        'Not configured. Build with --dart-define=GEMINI_API_KEY=… '
        '--dart-define=TAILARR_MCP_URL=… --dart-define=TAILARR_MCP_TOKEN=…',
        isError: true,
      );
      return;
    }

    _status = VoiceConnectionStatus.connecting;
    _addSystem('Connecting to Gemini Live and the Tailarr MCP…');
    notifyListeners();

    final session = VoiceSession(
      apiKey: geminiApiKey,
      mcpUrl: mcpUrl,
      mcpToken: mcpToken,
      model: model,
    );
    try {
      final whoami = await session.start();
      _session = session;
      _exposedTools = session.exposedTools;
      _wire(session);
      _status = VoiceConnectionStatus.ready;
      _addSystem('Connected as: $whoami');
      _addSystem('Tools available: ${_exposedTools.join(', ')}');
    } catch (e, st) {
      LunaLogger().error('Voice session failed to start', e, st);
      _status = VoiceConnectionStatus.error;
      _addSystem('Failed to connect: $e', isError: true);
      await session.close();
    }
    notifyListeners();
  }

  void _wire(VoiceSession session) {
    _subs.add(session.toolActivity.listen((a) {
      final label = a.result == null
          ? 'calling ${a.name}(${a.args})…'
          : '${a.name}(${a.args}) → ${a.result}';
      // Update the last matching in-progress tool line, else append.
      final idx = messages.lastIndexWhere(
        (m) => m.role == VoiceRole.tool && m.text.startsWith('calling ${a.name}('),
      );
      if (a.result != null && idx >= 0) {
        messages[idx].text = label;
        messages[idx].isError = a.isError;
      } else {
        messages.add(VoiceMessage(VoiceRole.tool, label, isError: a.isError));
      }
      notifyListeners();
    }));

    _subs.add(session.outputTranscript.listen((fragment) {
      _appendAssistant(fragment);
      notifyListeners();
    }));

    _subs.add(session.turnComplete.listen((_) {
      _turnInProgress = false;
      notifyListeners();
    }));

    _subs.add(session.errors.listen((e) {
      _addSystem('Live error: $e', isError: true);
      _turnInProgress = false;
      notifyListeners();
    }));
  }

  /// Send a typed turn. Streams the answer back into the transcript.
  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    await ensureConnected();
    if (_status != VoiceConnectionStatus.ready) return;

    messages.add(VoiceMessage(VoiceRole.user, trimmed));
    // Fresh assistant bubble the streamed transcript appends into.
    messages.add(VoiceMessage(VoiceRole.assistant, ''));
    _turnInProgress = true;
    notifyListeners();
    _session!.sendUserText(trimmed);
  }

  void _appendAssistant(String fragment) {
    if (messages.isNotEmpty && messages.last.role == VoiceRole.assistant) {
      messages.last.text += fragment;
    } else {
      messages.add(VoiceMessage(VoiceRole.assistant, fragment));
    }
  }

  void _addSystem(String text, {bool isError = false}) {
    messages.add(VoiceMessage(VoiceRole.system, text, isError: isError));
  }
}
