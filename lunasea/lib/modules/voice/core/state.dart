import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

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

  /// True while [startVoice] is between its first await and publishing [_audio].
  /// Without this window being observable, [stopVoice] saw `_voiceActive == false`
  /// and returned, and the start it was meant to cancel went on to turn the MIC
  /// ON after the user had already stopped it.
  bool _voiceStarting = false;
  bool get voiceStarting => _voiceStarting;

  /// Generation counter for start/stop. Bumped SYNCHRONOUSLY by every
  /// [startVoice], [stopVoice] and [reset], so an in-flight startup can tell
  /// after each await that it has been superseded and must tear itself down
  /// instead of publishing a mic nobody asked for.
  int _voiceOp = 0;

  /// Serializes start/stop bodies. The generation bump above is the CANCEL
  /// signal (synchronous, so it lands even while a startup is parked); this
  /// chain then guarantees the cancelled startup finishes disposing before the
  /// next start begins. Both are needed: `VoiceAudioIO.stop()` calls
  /// `setActive(false)` on the process-wide AVAudioSession, so an aborted
  /// start's teardown running LATE would deactivate the session out from under
  /// a newer, live instance.
  Future<void> _voiceChain = Future<void>.value();

  /// Builds the device-audio layer. Overridden in tests so the start/stop
  /// ORDERING can be exercised without a microphone.
  @visibleForTesting
  VoiceAudioIO Function({
    void Function()? onPlaybackDrained,
    void Function()? onPlaybackUnavailable,
  })? audioFactory;

  /// Test seam: pretend the Gemini/MCP session is already connected.
  @visibleForTesting
  void debugSetConnected(VoiceSession session) {
    _session = session;
    _status = VoiceConnectionStatus.ready;
  }

  Future<void> _enqueueVoiceOp(Future<void> Function() body) {
    final next = _voiceChain.then((_) => body(), onError: (_) => body());
    _voiceChain = next.catchError((_) {});
    return next;
  }

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
    // Invalidate any in-flight startup, or it would survive the reset and turn
    // the mic on afterwards — the original bug through a different door.
    _voiceOp++;
    _voiceStarting = false;
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

    _subs.add(session.turnComplete.listen((_) {
      _turnInProgress = false;
      // turnComplete = Gemini finished PRODUCING, not that the buffered speech
      // has played. Flush this turn's tail (incl. a reply shorter than the
      // pre-roll) and re-arm the jitter buffer; the orb stays `speaking` until
      // the playback-drained callback fires (see startVoice), so it doesn't flip
      // to `listening` while queued audio is still playing.
      if (_voiceActive) {
        _audio?.endPlaybackTurn();
      }
      notifyListeners();
    }));

    // --- Voice lane: play Gemini's audio + honour barge-in ---
    _subs.add(session.audio.listen((chunk) {
      if (!_voiceActive) return;
      // Only show `speaking` if the chunk was actually accepted for playback.
      // A chunk arriving during a barge-in flush is rejected; flipping to
      // `speaking` for it would strand the orb (no drain callback follows).
      final accepted = _audio?.feedPlayback(chunk) ?? false;
      if (accepted) _setActivity(VoiceActivity.speaking);
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
      // A mid-turn error/disconnect strands sub-pre-roll audio in the buffer,
      // which would otherwise prepend as a stale tail onto the next turn. Flush
      // it (also resets the native stream so no stale plugin callback lingers —
      // codex#8) and drop the orb out of `speaking`.
      if (_voiceActive) {
        _audio?.flushPlayback();
        _setActivity(VoiceActivity.listening);
      }
      notifyListeners();
    }));
  }

  /// Enter the live-voice lane: open the mic + speaker and stream to Gemini.
  /// Safe to call when already active (no-op). Requires a granted mic
  /// permission; surfaces a clear message if denied.
  Future<void> startVoice() {
    // A second tap during startup coalesces onto the first rather than building
    // a second VoiceAudioIO (which would orphan a recorder/player). Cancelling
    // is what toggleVoice routes to stopVoice for.
    if (_voiceActive || _voiceStarting) return _voiceChain;
    _voiceStarting = true;
    final myOp = ++_voiceOp;
    notifyListeners();
    return _enqueueVoiceOp(() => _startVoiceBody(myOp));
  }

  Future<void> _startVoiceBody(int myOp) async {
    // Superseded before we even got a turn on the chain.
    if (_voiceOp != myOp) return;
    VoiceAudioIO? audio;
    var published = false;
    try {
      await ensureConnected();
      if (_voiceOp != myOp) return;
      if (_status != VoiceConnectionStatus.ready) return;
      final session = _session;
      if (session == null) return;

      final build = audioFactory ?? VoiceAudioIO.new;
      final instance = build(
        // When the turn's speech has all reached the speaker, drop the orb back
        // to listening — not the instant Gemini stops producing (turnComplete).
        // Identity-checked so a stale instance can never drive the live orb.
        onPlaybackDrained: () {
          if (_voiceActive &&
              identical(_audio, audio) &&
              _activity == VoiceActivity.speaking) {
            _setActivity(VoiceActivity.listening);
          }
        },
        // The output stream died and could not be rebuilt: nothing more will
        // play, so release the orb instead of stranding it in `speaking`.
        onPlaybackUnavailable: () {
          if (_voiceActive && identical(_audio, audio)) {
            _addSystem('Audio playback stopped working; text still works.',
                isError: true);
            if (_activity == VoiceActivity.speaking) {
              _setActivity(VoiceActivity.listening);
            }
            notifyListeners();
          }
        },
      );
      audio = instance;

      final granted = await instance.ensureMicPermission();
      if (_voiceOp != myOp) return;
      if (!granted) {
        final permanent = await instance.isMicPermanentlyDenied();
        if (_voiceOp != myOp) return;
        _addSystem(
          permanent
              ? 'Microphone access is off. Enable it in Settings to talk.'
              : 'Microphone permission is needed to talk.',
          isError: true,
        );
        return;
      }

      await instance.startPlayback();
      if (_voiceOp != myOp) return;
      // Capture the session locally: _session can be replaced/closed under us,
      // and the mic callback outlives this frame.
      await instance.captureInto((pcm) {
        if (_voiceOp != myOp) return; // stale instance: stop feeding Gemini
        session.sendAudioChunk(pcm);
      });
      // The mic IS live from here; only the teardown below turns it off again.
      if (_voiceOp != myOp) return;

      // No await between here and publishing, so a cancel cannot interleave.
      _audio = instance;
      _voiceActive = true;
      published = true;
      _setActivity(VoiceActivity.listening);
      _addSystem('Listening… speak, and tap the mic to stop.');
    } catch (e, st) {
      LunaLogger().error('Failed to start voice lane', e, st);
      if (_voiceOp == myOp) {
        _addSystem('Could not start the microphone: $e', isError: true);
        _setActivity(VoiceActivity.idle);
      }
    } finally {
      // Anything not published is ours to tear down — including a startup the
      // user cancelled after the mic was already streaming.
      if (!published) {
        try {
          await audio?.dispose();
        } catch (e, st) {
          LunaLogger().error('Failed to dispose an aborted voice lane', e, st);
        }
      }
      // Op-conditional: a stale body must not clear a NEWER startup's flag.
      if (_voiceOp == myOp) _voiceStarting = false;
      notifyListeners();
    }
  }

  /// Leave the live-voice lane (mic + speaker off). The Gemini/MCP session stays
  /// connected so the text lane keeps working. Also the CANCEL path for a
  /// startup still in flight.
  Future<void> stopVoice() {
    if (!_voiceActive && !_voiceStarting) return _voiceChain;
    // Synchronous cancel signal + immediate UI truth, so an in-flight startup
    // sees it while parked and never publishes a mic the user has stopped.
    _voiceOp++;
    _voiceStarting = false;
    _voiceActive = false;
    _setActivity(VoiceActivity.idle);
    return _enqueueVoiceOp(_stopVoiceBody);
  }

  Future<void> _stopVoiceBody() async {
    final audio = _audio;
    _audio = null;
    // dispose() already calls stop(); calling both just tore it down twice.
    await audio?.dispose();
    notifyListeners();
  }

  Future<void> toggleVoice() =>
      (_voiceActive || _voiceStarting) ? stopVoice() : startVoice();

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
