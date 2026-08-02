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

  /// The transcript line [ensureConnected] adds before its risky awaits, and
  /// which every abandon/failure path removes again.
  static const String _kConnectingLine =
      'Connecting to Gemini Live and the Tailarr MCP…';

  /// Generation counter for CONNECTION startup, the exact analogue of
  /// [_voiceOp] for the audio lane. Bumped synchronously by every new attempt,
  /// by [reset], and by [_abandonConnect], so an attempt parked in a platform
  /// call that may never return can tell — at each publication point — that it
  /// has been superseded and must publish nothing.
  int _connectGen = 0;

  /// The in-flight connect, so concurrent callers coalesce onto one attempt.
  /// Only the generation that owns the slot ever clears it.
  Future<void>? _connectOp;

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

  /// Hard bound on every platform await in [_startVoiceBody] and on every
  /// teardown that runs on [_voiceChain].
  ///
  /// N2: the startup body awaited `ensureConnected()`, the mic permission,
  /// `startPlayback()`, `captureInto()` and the aborted-instance disposal with
  /// NO timeout — and `_voiceChain` waits on that body. A platform future that
  /// never completed therefore prevented EVERY queued stop and retry from ever
  /// running: voice dead until the app was restarted. The synchronous
  /// generation counter above prevents a stale publication but cannot RELEASE
  /// the lane. Worse, `stopVoice()` clears the UI flags synchronously, so the
  /// app did not even look hung — taps silently did nothing.
  ///
  /// This is reachable, not theoretical. `voice_audio_io.dart` documents
  /// flutter_sound wedging on the feed path, and the app backlog already
  /// carries a user-reported hard-lock of exactly this class: TailscaleGuard's
  /// `ensure()` with no timeout pinning a full-screen AbsorbPointer forever,
  /// with `if (_connecting) return;` blocking every retry. Shipping a second
  /// permanent-wedge path is not acceptable, so every await here is bounded.
  @visibleForTesting
  Duration startupTimeout = const Duration(seconds: 20);

  /// Logging must never take down the voice lane — the same rule
  /// `voice_audio_io.dart` already documents for the playback path.
  /// [LunaLogger] writes to a Hive box and THROWS if the database is not open
  /// (early app startup, or a unit test), and because the write is async and
  /// unawaited that surfaces as an UNHANDLED zone error rather than something a
  /// try/catch can hold. Every one of the logs below sits on a failure or
  /// teardown path, so an unguarded one would turn a handled error into a
  /// crash — precisely when the lane is already unwinding.
  void _logError(String message, Object error, StackTrace stackTrace) =>
      runZonedGuarded(() => LunaLogger().error(message, error, stackTrace),
          (_, __) {});

  /// Tear an instance down without ever letting the teardown itself wedge the
  /// lane — a hung `dispose()` is just as fatal as a hung `startPlayback()`.
  Future<void> _disposeBounded(VoiceAudioIO? audio, String context) async {
    if (audio == null) return;
    try {
      await audio.dispose().timeout(startupTimeout);
    } catch (e, st) {
      _logError('Failed to dispose $context', e, st);
    }
  }

  /// Builds the device-audio layer. Overridden in tests so the start/stop
  /// ORDERING can be exercised without a microphone.
  @visibleForTesting
  VoiceAudioIO Function({
    void Function()? onPlaybackDrained,
    void Function()? onPlaybackUnavailable,
  })? audioFactory;

  /// Test seam for the SESSION itself, so the connect path's publication points
  /// are exercisable without a network. Without it, `VoiceSession.start()` is a
  /// real websocket, which is precisely why the old tests had to reach for
  /// [debugSetConnected] and skip [ensureConnected] entirely — and why B1 lived
  /// six rounds without a test that could see it.
  @visibleForTesting
  VoiceSession Function({
    required String apiKey,
    String? ephemeralToken,
    required String mcpUrl,
    required String mcpToken,
    required String model,
  })? sessionFactory;

  VoiceSession _buildSession({
    required String apiKey,
    String? ephemeralToken,
    required String mcpUrl,
    required String mcpToken,
    required String model,
  }) {
    final build = sessionFactory;
    if (build != null) {
      return build(
        apiKey: apiKey,
        ephemeralToken: ephemeralToken,
        mcpUrl: mcpUrl,
        mcpToken: mcpToken,
        model: model,
      );
    }
    return VoiceSession(
      apiKey: apiKey,
      ephemeralToken: ephemeralToken,
      mcpUrl: mcpUrl,
      mcpToken: mcpToken,
      model: model,
    );
  }

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
    // ...and any in-flight CONNECT, for the same reason. Without this a connect
    // parked in `session.start()` would come back after the reset and publish
    // `_session` plus a fresh set of subscriptions into the `_subs` list this
    // method just cleared — live listeners on a state that believes it is idle.
    _connectGen++;
    _connectOp = null;
    _voiceStarting = false;
    final audio = _audio;
    _audio = null;
    final session = _session;
    _session = null;
    // N3: the teardown goes ON `_voiceChain`, even though reset() itself is
    // synchronous (the LunaModuleState API gives us no choice about that).
    //
    // It previously called `_audio?.dispose()` unawaited and OFF-chain. That is
    // exactly the cross-generation ordering `_voiceChain` exists to prevent:
    // `VoiceAudioIO.stop()` calls `setActive(false)` on the PROCESS-WIDE
    // AVAudioSession, so a later startVoice() could configure and activate a
    // fresh instance while this disposal was still in flight — and the old
    // instance's teardown would then deactivate the session out from under the
    // new, live one. Silent, and audio-dead until the next start.
    //
    // This is currently LATENT, not live: VoiceAssistantState is absent from
    // the LunaModule.state() switch (modules.dart:559ff), so LunaState.reset()
    // never reaches it and only the constructor calls reset() (with both fields
    // null). It is routed through the chain anyway because the moment voice
    // joins module lifecycle this becomes live, and it would fail silently.
    //
    // Both calls were also unawaited with no catch — an async throw from either
    // surfaced as an UNHANDLED zone error rather than something callers could
    // hold. Each is now bounded and logged independently, so a failing audio
    // teardown cannot skip the session close.
    if (audio != null || session != null) {
      unawaited(_enqueueVoiceOp(() async {
        await _disposeBounded(audio, 'the voice lane on reset');
        try {
          await session?.close().timeout(startupTimeout);
        } catch (e, st) {
          _logError('Failed to close the voice session on reset', e, st);
        }
      }));
    }
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
  Future<void> ensureConnected() {
    if (_status == VoiceConnectionStatus.ready) return Future<void>.value();
    // Coalesce onto the attempt already running rather than racing a second
    // one. Only the generation that OWNS the slot ever clears it, so an
    // abandoned attempt cannot free (or overwrite) a newer caller's slot.
    final inFlight = _connectOp;
    if (inFlight != null) return inFlight;

    final myGen = ++_connectGen;
    // The bound belongs to the OPERATION, not to one of its callers.
    //
    // B1: `_startVoiceBody` used to wrap this in its own `bounded(...)`. That
    // released the voice lane on a hang but left `_status == connecting`, which
    // this method sets before its risky awaits — so every retry hit the
    // early-return above, `_startVoiceBody` saw a non-ready status and exited,
    // and voice was dead until the app restarted. A bound that does not also
    // restore the state its operation set is not a fix, it is a slower wedge.
    final op = _runConnect(myGen)
        .timeout(startupTimeout, onTimeout: () => _abandonConnect(myGen));
    _connectOp = op;
    return op;
  }

  /// The abandon path for [ensureConnected]: invalidate the orphan so it can
  /// never publish, and RESTORE the pre-await state so the next attempt is not
  /// blocked by what this one left behind. Both halves are required.
  void _abandonConnect(int myGen) {
    if (_connectGen != myGen) return; // already superseded by someone else
    _connectGen++; // the orphan can no longer publish anything
    _connectOp = null; // ...and a retry may start immediately
    if (_status == VoiceConnectionStatus.connecting) {
      _status = VoiceConnectionStatus.error;
      _dropConnectingLine();
      _addSystem(
        'Could not reach Gemini Live (timed out). Tap to try again.',
        isError: true,
      );
    }
    notifyListeners();
  }

  void _dropConnectingLine() => messages.removeWhere(
      (m) => m.role == VoiceRole.system && m.text == _kConnectingLine);

  /// Close a session this attempt built but is no longer allowed to publish.
  /// Bounded and swallowed: an abandoned session's cleanup must never wedge or
  /// throw into the lane that superseded it.
  Future<void> _closeOrphanSession(VoiceSession session) async {
    try {
      await session.close().timeout(startupTimeout);
    } catch (e, st) {
      _logError('Failed to close a superseded voice session', e, st);
    }
  }

  /// The connection body. Never throws: every exit either publishes under its
  /// own generation or leaves the state untouched for whoever superseded it.
  Future<void> _runConnect(int myGen) async {
    _status = VoiceConnectionStatus.connecting;
    _unavailableReason = null;
    _addSystem(_kConnectingLine);
    notifyListeners();

    try {
    final VoiceSession session;
    if (_devConfigured) {
      // DEV-ONLY raw-key path (VOICE_DEV_DIRECT_KEYS=true). Never taken by a
      // shipping build — no secret is compiled in on the default path.
      session = _buildSession(
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
      // Publication check immediately before the first write, not before the
      // await: a timed-out or reset-superseded attempt must mutate nothing.
      if (_connectGen != myGen) return;
      if (!result.ok) {
        _unavailableReason = result.reason;
        _status = VoiceConnectionStatus.error;
        // Drop the "Connecting…" line so the transcript shows only the reason.
        _dropConnectingLine();
        _addSystem(result.message, isError: true);
        notifyListeners();
        return;
      }
      final creds = result.credentials!;
      _cachedMcpToken = creds.mcpToken;
      session = _buildSession(
        apiKey: '',
        ephemeralToken: creds.ephemeralToken,
        mcpUrl: creds.mcpUrl,
        mcpToken: creds.mcpToken,
        model: creds.model.isNotEmpty ? creds.model : kDefaultLiveModel,
      );
    }

    try {
      final whoami = await session.start();
      // THE publication point. A late `start()` must not install a session,
      // wire subscriptions onto a `_subs` list `reset()` has already cleared,
      // or flip a superseded attempt's status to `ready`.
      if (_connectGen != myGen) {
        unawaited(_closeOrphanSession(session));
        return;
      }
      _session = session;
      _exposedTools = session.exposedTools;
      _wire(session);
      _status = VoiceConnectionStatus.ready;
      _addSystem('Connected as: $whoami');
      _addSystem('Tools available: ${_exposedTools.join(', ')}');
    } catch (e, st) {
      _logError('Voice session failed to start', e, st);
      unawaited(_closeOrphanSession(session));
      // An abandoned attempt's FAILURE is just as much a late mutation as its
      // success: it would overwrite a newer attempt's status and transcript.
      if (_connectGen != myGen) return;
      _status = VoiceConnectionStatus.error;
      _addSystem('Failed to connect: $e', isError: true);
    }
    notifyListeners();
    } catch (e, st) {
      // The credential fetch itself can throw. Swallowed here so an ABANDONED
      // attempt's later failure cannot surface as an unhandled zone error on a
      // future nobody is awaiting any more.
      _logError('Voice connection failed', e, st);
      if (_connectGen != myGen) return;
      _status = VoiceConnectionStatus.error;
      _dropConnectingLine();
      _addSystem('Failed to connect: $e', isError: true);
      notifyListeners();
    } finally {
      // Only the generation that OWNS the slot may free it — otherwise an
      // abandoned attempt completing late would clear a newer caller's
      // `_connectOp` and let a third attempt race it.
      if (_connectGen == myGen) _connectOp = null;
    }
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

    // The generation this body still believes it owns. It equals [myOp] until
    // one of OUR OWN timeouts invalidates us, and then tracks that bump.
    //
    // Two distinct notions are needed and must not be conflated:
    //   * [myOp] is FROZEN. Every publication check and the mic callback below
    //     compare against it, so once a timeout has invalidated this startup
    //     they stay invalid forever — a late `captureInto` cannot start feeding
    //     Gemini again.
    //   * [ownGen] MOVES with our own invalidation, and is what the `finally`
    //     uses to decide whether `_voiceStarting` is still ours to clear.
    //     Comparing the frozen [myOp] there would leave the flag stuck TRUE
    //     after a timeout — and `startVoice()` early-returns on
    //     `_voiceStarting`, so the lane would be released but every retry would
    //     still silently no-op. That is the N2 wedge through a second door.
    var ownGen = myOp;

    /// Await [op] with a hard bound. On timeout, in this order:
    ///   1. invalidate this startup SYNCHRONOUSLY, exactly like [stopVoice], so
    ///      nothing later can publish `_audio` or activate the mic;
    ///   2. attach [onLate] to the abandoned future, so if the platform ever
    ///      does answer, the orphan is still torn down rather than left holding
    ///      a live microphone;
    ///   3. throw into the catch/finally below, which surfaces the failure,
    ///      tears down the unpublished instance, and — the whole point —
    ///      RELEASES the lane for the queued stop/retry.
    Future<T> bounded<T>(Future<T> op, String what,
        {void Function()? onLate}) {
      return op.timeout(startupTimeout, onTimeout: () {
        if (_voiceOp == ownGen) ownGen = ++_voiceOp;
        if (onLate != null) {
          // Fire-and-forget: this must never re-wedge the lane it just freed.
          unawaited(op.then((_) => onLate(), onError: (_) => onLate()));
        }
        throw TimeoutException(
          'Voice startup timed out waiting for $what',
          startupTimeout,
        );
      });
    }

    try {
      // NOT wrapped in `bounded(...)`: the connect owns its own bound now, and
      // that is the point of B1. An outer bound released this lane but left
      // `_status == connecting` behind, so every retry early-returned and voice
      // was dead for good. A bound placed at the CALLER can only ever free the
      // caller; only the operation itself can restore the state it set.
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

      final granted = await bounded(
          instance.ensureMicPermission(), 'the microphone permission');
      if (_voiceOp != myOp) return;
      if (!granted) {
        final permanent = await bounded(instance.isMicPermanentlyDenied(),
            'the microphone permission status');
        if (_voiceOp != myOp) return;
        _addSystem(
          permanent
              ? 'Microphone access is off. Enable it in Settings to talk.'
              : 'Microphone permission is needed to talk.',
          isError: true,
        );
        return;
      }

      // A LATE completion of either of these must not leave a live speaker or
      // microphone behind on an instance nobody owns, so both carry an onLate
      // teardown. dispose() is idempotent, and the timeout has already bumped
      // the generation, so the mic callback below is inert either way.
      await bounded(
        instance.startPlayback(),
        'the speaker',
        onLate: () => unawaited(
            _disposeBounded(instance, 'a timed-out voice lane (playback)')),
      );
      if (_voiceOp != myOp) return;
      // Capture the session locally: _session can be replaced/closed under us,
      // and the mic callback outlives this frame.
      await bounded(
        instance.captureInto((pcm) {
          if (_voiceOp != myOp) return; // stale instance: stop feeding Gemini
          session.sendAudioChunk(pcm);
        }),
        'the microphone',
        onLate: () => unawaited(
            _disposeBounded(instance, 'a timed-out voice lane (capture)')),
      );
      // The mic IS live from here; only the teardown below turns it off again.
      if (_voiceOp != myOp) return;

      // No await between here and publishing, so a cancel cannot interleave.
      _audio = instance;
      _voiceActive = true;
      published = true;
      _setActivity(VoiceActivity.listening);
      _addSystem('Listening… speak, and tap the mic to stop.');
    } catch (e, st) {
      _logError('Failed to start voice lane', e, st);
      // Compared against [ownGen], NOT the frozen [myOp]. On the exact failure
      // this machinery exists for — one of our OWN timeouts — `bounded` has
      // already bumped `_voiceOp`, so `myOp` never matches and the user was
      // told nothing: the orb just quietly stopped. `ownGen` tracks our own
      // invalidation, so it still matches unless a REAL stop/start superseded
      // us — which is the only case where staying silent is right.
      if (_voiceOp == ownGen) {
        _addSystem('Could not start the microphone: $e', isError: true);
        _setActivity(VoiceActivity.idle);
      }
    } finally {
      // Anything not published is ours to tear down — including a startup the
      // user cancelled after the mic was already streaming.
      if (!published) {
        // Bounded: an unbounded dispose here would wedge the lane just as
        // surely as the hung startup we are unwinding from.
        await _disposeBounded(audio, 'an aborted voice lane');
      }
      // Op-conditional: a stale body must not clear a NEWER startup's flag.
      if (_voiceOp == ownGen) _voiceStarting = false;
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
    // Bounded so a wedged platform teardown cannot pin the lane either.
    await _disposeBounded(audio, 'the voice lane');
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
