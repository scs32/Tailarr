import 'dart:async';

import 'package:lunasea/system/state.dart';
import 'package:lunasea/system/logger.dart';
import 'package:lunasea/modules/voice/core/voice_session.dart';
import 'package:lunasea/modules/voice/core/voice_audio_io.dart';

/// Who authored a line in the transcript.
enum VoiceRole { user, assistant, tool, system }

/// The live-voice state machine surfaced to the orb.
///
///   idle       -> not in a voice session (text lane / disconnected)
///   listening  -> mic open, waiting for / hearing the user
///   thinking   -> user turn ended, model is working (e.g. running MCP tools)
///   speaking   -> model TTS audio is playing back
enum VoiceActivity { idle, listening, thinking, speaking }

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
  VoiceAudioIO? _audio;
  final List<VoiceMessage> messages = [];
  final List<StreamSubscription> _subs = [];

  VoiceConnectionStatus _status = VoiceConnectionStatus.idle;
  VoiceConnectionStatus get status => _status;

  bool _turnInProgress = false;
  bool get turnInProgress => _turnInProgress;

  /// Whether the live mic/voice lane is active (vs the typed text lane).
  bool _voiceActive = false;
  bool get voiceActive => _voiceActive;

  VoiceActivity _activity = VoiceActivity.idle;

  /// The live-voice orb state. `idle` whenever the voice lane is off.
  VoiceActivity get activity => _activity;

  List<String> _exposedTools = const [];
  List<String> get exposedTools => _exposedTools;

  @override
  void reset() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _audio?.dispose();
    _audio = null;
    _session?.close();
    _session = null;
    messages.clear();
    _status = VoiceConnectionStatus.idle;
    _turnInProgress = false;
    _voiceActive = false;
    _activity = VoiceActivity.idle;
    _exposedTools = const [];
    notifyListeners();
  }

  void _setActivity(VoiceActivity a) {
    if (_activity == a) return;
    _activity = a;
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
      // A tool call in-flight during a voice turn = the model is "thinking".
      if (_voiceActive && a.result == null) _setActivity(VoiceActivity.thinking);
      notifyListeners();
    }));

    _subs.add(session.outputTranscript.listen((fragment) {
      _appendAssistant(fragment);
      notifyListeners();
    }));

    _subs.add(session.turnComplete.listen((_) {
      _turnInProgress = false;
      // Model finished speaking: back to listening if the mic is live, else idle.
      if (_voiceActive) _setActivity(VoiceActivity.listening);
      notifyListeners();
    }));

    // --- Voice lane: play Gemini's audio + honour barge-in ---
    _subs.add(session.audio.listen((chunk) {
      if (!_voiceActive) return;
      _audio?.feedPlayback(chunk);
      _setActivity(VoiceActivity.speaking);
    }));

    _subs.add(session.interrupted.listen((_) {
      if (!_voiceActive) return;
      // User spoke over the model — drop the queued TTS and resume listening.
      _audio?.flushPlayback();
      _setActivity(VoiceActivity.listening);
    }));

    _subs.add(session.errors.listen((e) {
      _addSystem('Live error: $e', isError: true);
      _turnInProgress = false;
      notifyListeners();
    }));
  }

  /// Enter the live-voice lane: open the mic + speaker and stream to Gemini.
  /// Safe to call when already active (no-op). Requires a granted mic
  /// permission; surfaces a clear message if denied.
  Future<void> startVoice() async {
    if (_voiceActive) return;
    await ensureConnected();
    if (_status != VoiceConnectionStatus.ready) return;

    final audio = VoiceAudioIO();
    final granted = await audio.ensureMicPermission();
    if (!granted) {
      final permanent = await audio.isMicPermanentlyDenied();
      _addSystem(
        permanent
            ? 'Microphone access is off. Enable it in Settings to talk.'
            : 'Microphone permission is needed to talk.',
        isError: true,
      );
      await audio.dispose();
      notifyListeners();
      return;
    }

    try {
      await audio.startPlayback();
      await audio.captureInto((pcm) => _session!.sendAudioChunk(pcm));
      _audio = audio;
      _voiceActive = true;
      _setActivity(VoiceActivity.listening);
      _addSystem('Listening… speak, and tap the mic to stop.');
    } catch (e, st) {
      LunaLogger().error('Failed to start voice lane', e, st);
      _addSystem('Could not start the microphone: $e', isError: true);
      await audio.dispose();
      _voiceActive = false;
      _setActivity(VoiceActivity.idle);
    }
    notifyListeners();
  }

  /// Leave the live-voice lane (mic + speaker off). The Gemini/MCP session stays
  /// connected so the text lane keeps working.
  Future<void> stopVoice() async {
    if (!_voiceActive) return;
    _voiceActive = false;
    _setActivity(VoiceActivity.idle);
    await _audio?.stop();
    await _audio?.dispose();
    _audio = null;
    notifyListeners();
  }

  Future<void> toggleVoice() => _voiceActive ? stopVoice() : startVoice();

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
