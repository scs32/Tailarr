import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:lunasea/system/state.dart';
import 'package:lunasea/system/logger.dart';
import 'package:lunasea/modules/voice/core/voice_session.dart';
import 'package:lunasea/modules/voice/core/voice_audio_io.dart';
import 'package:lunasea/modules/voice/core/voice_credentials.dart';

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

/// What the voice lane should do in response to an app-lifecycle transition.
enum VoiceLifecycleAction {
  /// Nothing to do.
  none,

  /// The app is going away while voice is live. Remember that, so the next
  /// `resumed` knows the session crossed a suspension.
  markSuspended,

  /// The app came back after a suspension. iOS tore down the AVAudioSession,
  /// the flutter_sound player and (usually) the Live WebSocket underneath us,
  /// so the lane must be torn down honestly rather than left looking alive.
  teardown,
}

/// The lifecycle decision, as a pure function so it is unit-testable without a
/// widget tree, a device or a live session.
///
/// `inactive` deliberately does NOT count as a suspension: it fires for the app
/// switcher, Control Centre and incoming-call banners, none of which tear the
/// audio stack down. Only a real background/detach does.
VoiceLifecycleAction voiceLifecycleActionFor({
  required AppLifecycleState state,
  required bool voiceActive,
  required bool suspendedWhileActive,
}) {
  if (!voiceActive) return VoiceLifecycleAction.none;
  switch (state) {
    case AppLifecycleState.paused:
    case AppLifecycleState.detached:
    case AppLifecycleState.hidden:
      return VoiceLifecycleAction.markSuspended;
    case AppLifecycleState.resumed:
      return suspendedWhileActive
          ? VoiceLifecycleAction.teardown
          : VoiceLifecycleAction.none;
    case AppLifecycleState.inactive:
      return VoiceLifecycleAction.none;
  }
}

/// State for the in-app Gemini Live voice assistant.
///
/// CREDENTIALS ARE FETCHED AT RUNTIME — nothing secret is compiled into the
/// build. On voice-session start the app asks the Tailarr controller (through
/// the whois-authenticated `tailarr-gate` node) for a short-lived Gemini Live
/// **ephemeral token** and the caller's own **MCP bearer**, both gated on the
/// person's AI badge (see [VoiceCredentialBroker]). A TestFlight build therefore
/// carries NO Gemini key and NO MCP token.
///
/// The three `--dart-define` reads below are a DEV-ONLY fallback: they are
/// consumed ONLY when the build is compiled with
/// `--dart-define=VOICE_DEV_DIRECT_KEYS=true` AND all three are supplied, for a
/// local dev/harness run against a raw key. The DEFAULT (shipping) path never
/// touches them and never carries a baked secret.
class VoiceAssistantState extends LunaModuleState {
  VoiceAssistantState() {
    reset();
  }

  /// Opt-in flag for the dev raw-key path. False in every normal/TestFlight
  /// build, so the compiler tree-shakes the defines out of the default flow.
  static const bool devDirectKeys =
      bool.fromEnvironment('VOICE_DEV_DIRECT_KEYS', defaultValue: false);

  /// DEV-ONLY (see class doc + [devDirectKeys]). Never read on the ship path.
  static const String _devGeminiApiKey =
      String.fromEnvironment('GEMINI_API_KEY');
  static const String _devMcpUrl = String.fromEnvironment('TAILARR_MCP_URL');
  static const String _devMcpToken =
      String.fromEnvironment('TAILARR_MCP_TOKEN');

  /// Live model when running the dev raw-key path. The shipping path uses the
  /// server-bound model returned with the ephemeral token.
  static const String _devModel = String.fromEnvironment(
    'GEMINI_LIVE_MODEL',
    defaultValue: kDefaultLiveModel,
  );

  /// True only for a dev build explicitly wired with all three raw defines.
  static bool get _devConfigured =>
      devDirectKeys &&
      _devGeminiApiKey.isNotEmpty &&
      _devMcpUrl.isNotEmpty &&
      _devMcpToken.isNotEmpty;

  /// Injectable credential fetch — the live broker by default; tests replace it
  /// with a stub. Returns the runtime-fetched, non-baked voice credentials.
  Future<VoiceCredentialResult> Function()? credentialFetcher;

  /// The caller's MCP bearer, cached for the app-process lifetime so a reconnect
  /// doesn't mint a fresh 30-day token each time. Not persisted — a cold launch
  /// re-mints (cheap, and keeps nothing secret on disk).
  String? _cachedMcpToken;

  /// Why the last connect attempt found voice unavailable (badge/config/etc.),
  /// or null when available. Drives the "ask your admin" UX.
  VoiceUnavailableReason? _unavailableReason;
  VoiceUnavailableReason? get unavailableReason => _unavailableReason;

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

  /// Lifecycle bridge. Before this, the ONLY `WidgetsBindingObserver` in the
  /// whole app was the ntfy stream manager — nothing told the voice lane that
  /// iOS had suspended it, so a resumed app sat on a torn-down AVAudioSession,
  /// a dead flutter_sound player and (usually) a closed Live socket while the
  /// orb still rendered "ready".
  _VoiceLifecycleObserver? _lifecycleObserver;

  /// Set when the app backgrounds while the voice lane is live.
  bool _suspendedWhileActive = false;

  /// THE echo detector. Characters of the user's transcribed speech that
  /// arrived while the model was still speaking. Non-zero while the user is
  /// silent is direct proof the mic is hearing our own loudspeaker.
  ///
  /// ⚠️ A COUNT, never the text.
  int inputTranscriptCharsWhileSpeaking = 0;

  /// Serialises lifecycle-driven teardown against start/stop so a resume can
  /// never interleave with a start. (This branch has no `_voiceChain`; that
  /// machinery is on PR #18. This is the minimal equivalent.)
  Future<void> _voiceOps = Future<void>.value();
  Future<T> _enqueueVoiceOp<T>(Future<T> Function() op) {
    final next = _voiceOps.then((_) => op());
    _voiceOps = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  @override
  void reset() {
    _detachLifecycleObserver();
    _suspendedWhileActive = false;
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
    _unavailableReason = null;
    notifyListeners();
  }

  void _setActivity(VoiceActivity a) {
    if (_activity == a) return;
    _activity = a;
    notifyListeners();
  }

  void _attachLifecycleObserver() {
    if (_lifecycleObserver != null) return;
    final observer = _VoiceLifecycleObserver(handleLifecycleState);
    // Guarded: a pure unit test may construct the state without a binding.
    final binding = WidgetsBinding.instance;
    binding.addObserver(observer);
    _lifecycleObserver = observer;
  }

  void _detachLifecycleObserver() {
    final observer = _lifecycleObserver;
    if (observer == null) return;
    _lifecycleObserver = null;
    WidgetsBinding.instance.removeObserver(observer);
  }

  /// The lifecycle entry point. Public so the decision + its effect are
  /// testable without pumping a real app through background/foreground.
  void handleLifecycleState(AppLifecycleState state) {
    final action = voiceLifecycleActionFor(
      state: state,
      voiceActive: _voiceActive,
      suspendedWhileActive: _suspendedWhileActive,
    );
    switch (action) {
      case VoiceLifecycleAction.none:
        return;
      case VoiceLifecycleAction.markSuspended:
        _suspendedWhileActive = true;
        LunaLogger().warning(
          'voice/lifecycle: app suspended while voice was live',
          'VoiceAssistantState',
          'handleLifecycleState',
        );
        return;
      case VoiceLifecycleAction.teardown:
        _suspendedWhileActive = false;
        LunaLogger().warning(
          'voice/lifecycle: resumed after suspension — tearing the voice lane '
          'down (session is not trustworthy across a suspend)',
          'VoiceAssistantState',
          'handleLifecycleState',
        );
        // Deliberately a teardown, NOT a reconnection state machine: iOS took
        // the audio session, the player and usually the socket. Restarting on
        // the next explicit tap is honest and cannot leave a half-live lane.
        _enqueueVoiceOp(() async {
          await _stopVoice();
          await _dropSession(
            'Voice stopped while the app was in the background. '
            'Tap the mic to start again.',
          );
        });
        return;
    }
  }

  /// Close the Live session and leave `ready`, so nothing can claim the lane is
  /// usable over a dead socket. [message] is shown in the transcript.
  Future<void> _dropSession(String message) async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final session = _session;
    _session = null;
    _turnInProgress = false;
    _exposedTools = const [];
    if (_status == VoiceConnectionStatus.ready ||
        _status == VoiceConnectionStatus.connecting) {
      _status = VoiceConnectionStatus.idle;
    }
    _addSystem(message, isError: true);
    notifyListeners();
    try {
      await session?.close();
    } catch (_) {}
  }

  /// Open the MCP + Gemini Live session if not already connected. Fetches
  /// short-lived, badge-gated credentials from the server first (default path;
  /// nothing secret is baked in). Sets a clear, non-crashing "AI access isn't
  /// enabled — ask your admin" state when the device lacks the AI badge or the
  /// server hasn't configured voice AI.
  Future<void> ensureConnected() async {
    if (_status == VoiceConnectionStatus.ready ||
        _status == VoiceConnectionStatus.connecting) {
      return;
    }

    _status = VoiceConnectionStatus.connecting;
    _unavailableReason = null;
    _addSystem('Connecting to Gemini Live and the Tailarr MCP…');
    notifyListeners();

    final VoiceSession session;
    if (_devConfigured) {
      // DEV-ONLY raw-key path (VOICE_DEV_DIRECT_KEYS=true). Never taken by a
      // shipping build — no secret is compiled in on the default path.
      session = VoiceSession(
        apiKey: _devGeminiApiKey,
        mcpUrl: _devMcpUrl,
        mcpToken: _devMcpToken,
        model: _devModel,
      );
    } else {
      // DEFAULT path: fetch runtime credentials (ephemeral Gemini token + MCP
      // bearer) from the server, gated on the person's AI badge.
      final fetch = credentialFetcher ??
          () => VoiceCredentialBroker.resolve(cachedMcpToken: _cachedMcpToken);
      final result = await fetch();
      if (!result.ok) {
        _unavailableReason = result.reason;
        _status = VoiceConnectionStatus.error;
        // Drop the "Connecting…" line so the transcript shows only the reason.
        messages.removeWhere((m) =>
            m.role == VoiceRole.system &&
            m.text == 'Connecting to Gemini Live and the Tailarr MCP…');
        _addSystem(result.message, isError: true);
        notifyListeners();
        return;
      }
      final creds = result.credentials!;
      _cachedMcpToken = creds.mcpToken;
      session = VoiceSession(
        apiKey: '',
        ephemeralToken: creds.ephemeralToken,
        mcpUrl: creds.mcpUrl,
        mcpToken: creds.mcpToken,
        model: creds.model.isNotEmpty ? creds.model : kDefaultLiveModel,
      );
    }

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

    // The user's own speech, transcribed, so the voice lane reads as a normal
    // back-and-forth instead of a one-sided transcript.
    //
    // ⚠️ This stream can legitimately be EMPTY: the shipping path uses the
    // constrained endpoint, which honours the setup BAKED INTO THE TOKEN and
    // ignores this client's setup frame — and the server does not yet bake
    // `inputAudioTranscription`. An empty stream must simply mean an empty
    // transcript. Nothing here fakes data or "fixes" the silence client-side.
    //
    // ⚠️ NEVER log the text: it is the user's speech. The COUNT is a diagnostic
    // (characters arriving while the model is speaking is direct evidence the
    // mic is hearing the loudspeaker); the text is not.
    _subs.add(session.inputTranscript.listen((fragment) {
      if (_activity == VoiceActivity.speaking) {
        inputTranscriptCharsWhileSpeaking += fragment.length;
      }
      _appendUser(fragment);
      notifyListeners();
    }));

    _subs.add(session.turnComplete.listen((_) {
      _turnInProgress = false;
      // A turn boundary always clears any barge-in suppression window, so a
      // fresh reply can never be silenced by a stale one.
      _audio?.resumePlayback();
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
      // User spoke over the model — stop feeding the abandoned turn and resume
      // listening. This deliberately does NOT tear down the native player
      // engine any more; that teardown is what crashed build 48 and what
      // produced the every-couple-of-seconds stutter. See voice_audio_io.dart.
      _audio?.flushPlayback(cause: VoiceFlushCause.bargeIn);
      _setActivity(VoiceActivity.listening);
    }));

    _subs.add(session.errors.listen((e) {
      _addSystem('Live error: $e', isError: true);
      _turnInProgress = false;
      notifyListeners();
    }));

    // An unexpected socket close MUST leave `ready`. Otherwise
    // `ensureConnected()` early-returns forever, the orb keeps rendering a live
    // session, and every mic chunk calls `ws.add` on a closed socket.
    _subs.add(session.closed.listen((detail) {
      LunaLogger().warning(
        'voice/live: socket closed after setup ($detail)',
        'VoiceAssistantState',
        '_wire',
      );
      _enqueueVoiceOp(() async {
        await _stopVoice();
        await _dropSession(
          'The assistant connection dropped. Tap the mic to reconnect.',
        );
      });
    }));
  }

  /// Enter the live-voice lane: open the mic + speaker and stream to Gemini.
  /// Safe to call when already active (no-op). Requires a granted mic
  /// permission; surfaces a clear message if denied.
  Future<void> startVoice() => _enqueueVoiceOp(_startVoice);

  Future<void> _startVoice() async {
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
      // `_session?`, not `_session!`: the session can be dropped underneath the
      // mic (dead socket, lifecycle teardown) and a null-check throwing out of
      // a stream callback is not a recoverable place to find that out.
      await audio.captureInto((pcm) => _session?.sendAudioChunk(pcm));
      _audio = audio;
      _voiceActive = true;
      _suspendedWhileActive = false;
      _attachLifecycleObserver();
      _setActivity(VoiceActivity.listening);
      _addSystem('Listening… speak, and tap the mic to stop.');
    } on VoiceAudioUnavailable catch (e, st) {
      // The player-start guard refused (see voice_audio_probe.dart). Refusing is
      // correct — starting anyway can abort the process from ObjC — but it MUST
      // be visible: a silent no-op here is exactly what "voice stopped working
      // completely" looks like from the outside.
      LunaLogger().error('Voice playback refused to start', e, st);
      LunaLogger().warning(
        'voice/audio: player start REFUSED — ${e.reason} '
        '(${e.probe?.describe() ?? 'no probe'})',
        'VoiceAssistantState',
        'startVoice',
      );
      _addSystem(
        'Audio could not start: ${e.reason}. Close and reopen the assistant to '
        'try again.',
        isError: true,
      );
      await audio.dispose();
      _voiceActive = false;
      _setActivity(VoiceActivity.idle);
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
  Future<void> stopVoice() => _enqueueVoiceOp(_stopVoice);

  Future<void> _stopVoice() async {
    _detachLifecycleObserver();
    _suspendedWhileActive = false;
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
    _session?.sendUserText(trimmed);
  }

  void _appendAssistant(String fragment) {
    if (messages.isNotEmpty && messages.last.role == VoiceRole.assistant) {
      messages.last.text += fragment;
    } else {
      messages.add(VoiceMessage(VoiceRole.assistant, fragment));
    }
  }

  /// Same coalescing rule as [_appendAssistant] — deliberately, so the two
  /// sides of the conversation behave identically in the transcript.
  void _appendUser(String fragment) {
    if (messages.isNotEmpty && messages.last.role == VoiceRole.user) {
      messages.last.text += fragment;
    } else {
      messages.add(VoiceMessage(VoiceRole.user, fragment));
    }
  }

  void _addSystem(String text, {bool isError = false}) {
    messages.add(VoiceMessage(VoiceRole.system, text, isError: isError));
  }
}

/// Thin adapter so [VoiceAssistantState] does not have to be a widget-binding
/// observer itself (it is a ChangeNotifier owned by a Provider, and mixing the
/// two lifetimes is how observers get leaked).
class _VoiceLifecycleObserver extends WidgetsBindingObserver {
  _VoiceLifecycleObserver(this.onState);
  final void Function(AppLifecycleState) onState;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => onState(state);
}
