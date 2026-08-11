/// Device audio I/O for the in-app Gemini Live voice lane.
///
/// This is the ONLY part of the voice module that touches iOS/Android audio
/// hardware, so it is kept out of the pure-Dart core (`voice_session.dart`,
/// `gemini_live_client.dart`, `mcp_tool_proxy.dart`) that the standalone proof
/// harness (`tool/voice_smoke.dart`) exercises. The Flutter state layer wires
/// this to a [VoiceSession]:
///
///   record  (mic)  --16kHz s16le mono PCM-->  session.sendAudioChunk
///   session.audio  --24kHz s16le mono PCM-->  flutter_sound (speaker)
///   session.interrupted (barge-in)         -->  flushPlayback()
///
/// ## The AVAudioSession trap (documented mitigation)
/// `record` and `flutter_sound` each, by default, call
/// `AVAudioSession.setCategory(...)` on iOS. If both configure the session they
/// clobber each other: a `.playback`-only category kills the mic, and a
/// `.playAndRecord` category without `.defaultToSpeaker` routes TTS to the quiet
/// earpiece. Left alone, whichever plugin starts last wins — a classic duplex-
/// voice bug.
///
/// Fix: make **one** owner of the session — the `audio_session` package — and
/// tell the plugins to keep their hands off:
///   * We configure ONE category, `playAndRecord`, mode `voiceChat`
///     (`voiceChat` turns on the system's acoustic echo canceller, so the mic
///     doesn't hear the speaker and trigger false barge-ins), with
///     `defaultToSpeaker | allowBluetooth | mixWithOthers`, and `setActive(true)`
///     BEFORE any capture/playback starts.
///   * `record` is started with `IosRecordConfig(manageAudioSession: false)` so
///     it uses our session verbatim and never calls `setCategory`.
///   * `flutter_sound` 9.30 no longer exposes Dart-side category control; its
///     precompiled core is session-agnostic when a compatible `playAndRecord`
///     session is already active. We open + start the player first and then
///     re-assert our category, so our configuration is the final word.
///
/// Real-device caveat: the iOS Simulator has no reliable microphone path, so the
/// full duplex loop (AEC, routing, barge-in timing) must be confirmed on
/// hardware; the permission prompt and playback are exercisable in the sim.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:lunasea/system/logger.dart';
import 'package:lunasea/modules/voice/core/voice_session.dart'
    show kMicSampleRate, kOutputSampleRate;
import 'package:lunasea/modules/voice/core/pcm_playback_queue.dart';

class VoiceAudioIO {
  VoiceAudioIO({
    this.onPlaybackDrained,
    this.onPlaybackUnavailable,
    @visibleForTesting Future<void> Function()? openPlayerStream,
    @visibleForTesting Future<void> Function()? closePlayerStream,
    @visibleForTesting Future<void> Function(Uint8List frame)? feedPlayerStream,
    @visibleForTesting Stream<AudioInterruptionEvent>? interruptionEvents,
    @visibleForTesting Stream<void>? becomingNoisyEvents,
    @visibleForTesting Future<void> Function(bool active)? setSessionActive,
  })  : _setSessionActive = setSessionActive,
        _openPlayerStream = openPlayerStream,
        _closePlayerStream = closePlayerStream,
        _feedPlayerStream = feedPlayerStream,
        _interruptionEvents = interruptionEvents,
        _becomingNoisyEvents = becomingNoisyEvents;

  /// Seams for the M6 interruption/route-change subscriptions, so the RESPONSE
  /// to a phone call or a yanked headset is testable without an AVAudioSession.
  /// Null in production — see [configureSession].
  final Stream<AudioInterruptionEvent>? _interruptionEvents;
  final Stream<void>? _becomingNoisyEvents;

  /// Seam for `AVAudioSession.setActive(...)` — the one call in this class with
  /// PROCESS-WIDE effect, and therefore the only one whose ordering across
  /// instances matters. Null in production.
  final Future<void> Function(bool active)? _setSessionActive;

  /// Seams so the playback LIFECYCLE (restart-failed recovery in particular) is
  /// testable without an audio device. Null in production — see
  /// [_startPlayerStream] / [_stopPlayerStream] / [_feedFrame].
  final Future<void> Function()? _openPlayerStream;
  final Future<void> Function()? _closePlayerStream;
  final Future<void> Function(Uint8List frame)? _feedPlayerStream;

  /// Fired when a spoken turn's audio has all been handed to the speaker (the
  /// closest signal to "finished speaking" available off-device) so the caller
  /// can drop the orb back to `listening` only once queued speech has played,
  /// not the instant Gemini stops PRODUCING.
  final void Function()? onPlaybackDrained;

  /// Fired when the output stream could not be (re)opened, so nothing will play
  /// until recovery succeeds. Without this a failed restart was completely
  /// silent: no audio, no orb change, no error — see [flushPlayback].
  final void Function()? onPlaybackUnavailable;

  /// Constructed lazily: `AudioRecorder()`'s constructor makes a platform-channel
  /// call, so building one eagerly touches the mic plugin even for a playback-only
  /// instance (and makes the class untestable off-device).
  AudioRecorder? _recorderInstance;
  AudioRecorder get _recorder => _recorderInstance ??= AudioRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  /// Instance-terminal, set SYNCHRONOUSLY by [stop] before its first await.
  ///
  /// `_playerClosed` says the same thing for the player lane; this is the
  /// whole-instance form, read by the session arbiter and by [captureInto], so
  /// a platform call that state.dart abandoned and that answers later cannot
  /// apply a side effect (activating the shared session, opening a mic) on
  /// behalf of an instance that is already gone.
  bool _terminal = false;

  bool _sessionConfigured = false;
  /// True only when a REAL platform AVAudioSession was configured by us, and so
  /// is ours to deactivate in [stop]. False under the test seams.
  bool _sessionOwned = false;

  /// PROCESS-WIDE ownership of the shared AVAudioSession.
  ///
  /// The lane above serializes one instance's player. It cannot serialize
  /// ACROSS instances — and it does not have to, except for `setActive(false)`,
  /// which is global. That matters because teardown is deliberately bounded
  /// (see [teardownTimeout] and state.dart's `_disposeBounded`): when a hung
  /// teardown is abandoned, the old instance's `stop()` is still alive and may
  /// reach `setActive(false)` long after a NEW instance has activated the
  /// session — silently deafening the live lane. Bounding teardown traded a
  /// permanent wedge for that race; this epoch closes it.
  ///
  /// Every instance that activates the shared session takes the next epoch.
  /// Only the CURRENT owner may deactivate it; a superseded instance skips the
  /// call, because by then the session belongs to someone else.
  static int _sessionEpoch = 0;
  int _mySessionEpoch = 0;

  /// PROCESS-WIDE serialization of the shared session — the arbiter.
  ///
  /// An epoch COMPARISON is not enough on its own, because a comparison cannot
  /// revoke an effect that is already in flight. Two windows were reachable
  /// with a bare compare:
  ///
  ///   A. check-to-effect: the old instance reads `_mySessionEpoch ==
  ///      _sessionEpoch`, passes, and parks INSIDE `setActive(false)`. A new
  ///      instance activates and claims a newer epoch while that call is still
  ///      airborne. The old deactivation then lands on the live lane.
  ///   B. activation-to-claim: the new instance claimed its epoch only AFTER
  ///      `setActive(true)` returned, so an old instance checking in that gap
  ///      still saw itself as owner and deactivated a session already on.
  ///
  /// Both are one defect: validation and side effect were not atomic. The
  /// answer is a single process-wide lane on which claim-and-activate and
  /// validate-and-deactivate each run as an indivisible unit, so no other
  /// generation can transfer ownership in between.
  static Future<void> _sessionLane = Future<void>.value();

  /// Run [body] as one indivisible unit against the shared session.
  ///
  /// The CALLER's wait is bounded ([teardownTimeout]) but the body keeps its
  /// place in the queue. That is deliberate and is the trade the player lane
  /// already makes: ordering must never cost liveness, or one platform
  /// `setActive` that never returns would wedge every future voice instance —
  /// the N2 permanent-wedge shape, one level up. Abandoning the WAIT is safe
  /// because every body re-validates ownership and terminality at the moment it
  /// actually runs, so a body that executes late is inert, not damaging.
  /// Run [body] as one indivisible unit against the shared session, returning
  /// [onAbandon] if it does not finish in time.
  ///
  /// The BODY is bounded, not merely the caller's wait. Bounding only the wait
  /// was a strictly worse bug than the one it replaced: the lane is STATIC, so
  /// one platform `setActive` that never returned left `_sessionLane` pending
  /// forever and every future VoiceAudioIO in the process queued behind it,
  /// timed out, and silently never ran its body. A per-instance wedge became a
  /// process-lifetime one. Bounding the body means the lane always advances.
  ///
  /// The trade is explicit: after a hung call, ORDERING against that abandoned
  /// call is lost (nothing in Dart can revoke it) — but correctness does not
  /// rest on ordering alone. Every body re-validates ownership and terminality
  /// when it runs and again before it commits, so a late body is inert.
  /// Liveness is preserved unconditionally; that is the right way round.
  Future<T> _onSessionLane<T>(Future<T> Function() body, T onAbandon) {
    Future<T> run() => body().timeout(teardownTimeout, onTimeout: () {
          _logWarn('Shared audio session did not answer in time; '
              'abandoning the call and releasing the lane');
          return onAbandon;
        });
    final next = _sessionLane.then((_) => run(), onError: (_) => run());
    _sessionLane = next.then((_) {}, onError: (_) {});
    return next.catchError((_) => onAbandon);
  }

  /// Claim ownership and activate, atomically. Returns whether the session is
  /// actually active and ours as a result — the caller MUST NOT record itself
  /// as configured otherwise, or it proceeds to open a speaker and a mic
  /// against a session that was never activated, and never retries.
  ///
  /// Skipped entirely once this instance is terminal: an abandoned configure
  /// that finally gets its turn must not steal the epoch from — or re-activate
  /// under — a live instance.
  Future<bool> _acquireSession() => _onSessionLane<bool>(() async {
        if (_terminal) return false;
        _claimSession();
        await _setActive(true);
        // NOTE: deliberately NO post-activation terminality re-check here.
        // One was added and then removed: `stop()` unconditionally queues
        // `_releaseSession` behind this body, so an activation that completes
        // for an instance stopped mid-call is already deactivated by that
        // release — and if this call never returns, a re-check placed after it
        // never runs either. No test could distinguish the guard's presence
        // from its absence, which is the definition of dead machinery. This
        // series has cost enough in unreviewed additions; the release is the
        // single owner of deactivation and stays that way.
        return true;
      }, false);

  /// Re-assert activation WITHOUT taking a new epoch (see [startPlayback]).
  /// Inert unless this instance is still the owner.
  Future<void> _reassertSession() => _onSessionLane<void>(() async {
        if (_terminal || !_ownsSession) return;
        await _setActive(true);
      }, null);

  /// Validate ownership and deactivate, atomically.
  Future<void> _releaseSession() => _onSessionLane<void>(() async {
        if (!_sessionOwned) return;
        if (_mySessionEpoch != _sessionEpoch) {
          // A newer instance owns the shared session — most likely because our
          // own teardown was abandoned by a timeout and a fresh lane started
          // meanwhile. Deactivating now would deafen the LIVE instance.
          _logWarn('Skipping AVAudioSession deactivation: a newer voice '
              'instance owns it');
          _sessionOwned = false;
          return;
        }
        await _setActive(false);
        _sessionOwned = false;
      }, null);

  /// The single funnel for the process-wide activation call. Only ever invoked
  /// from inside a [_onSessionLane] body.
  Future<void> _setActive(bool active) async {
    final seam = _setSessionActive;
    if (seam != null) return seam(active);
    final session = await AudioSession.instance;
    await session.setActive(active);
  }

  /// Claim process-wide ownership of the shared session. Synchronous on
  /// purpose, and called from inside the arbiter BEFORE the activation it
  /// guards — never after, or window B above reopens.
  void _claimSession() {
    _sessionOwned = true;
    _mySessionEpoch = ++_sessionEpoch;
  }

  /// True while this instance is still the process-wide session owner. Every
  /// side effect on the shared session — activation as well as deactivation —
  /// is gated on it, so a superseded instance can apply neither.
  bool get _ownsSession => _sessionOwned && _mySessionEpoch == _sessionEpoch;

  bool _playerReady = false;

  /// True when the output stream is DOWN but should be up — a restart failed.
  /// Drives the lazy recovery in [feedPlayback]/[endPlaybackTurn]; without it a
  /// failed restart was terminal, because nothing in the app ever calls
  /// [startPlayback] again for an existing instance.
  bool _needsPlayerRestart = false;

  // --- N1: ONE serialized owner of the player lifecycle -------------------
  //
  // The M4 lazy recovery originally serialized itself against OTHER recoveries
  // with a `_recovering` flag. That is not enough: recovery also races
  // [flushPlayback], [stop] and [dispose], because all four close and reopen
  // the SAME native flutter_sound stream. Three failures were reachable:
  //
  //   * a second interruption flushed while a recovery was parked in
  //     close/open, so both rebuilt the one native stream — and flutter_sound
  //     9.30 keeps a SINGLE mutable needSomeFood completer, which is exactly
  //     the desync codex#8 already cost us once;
  //   * one path set `_playerReady = true` while the other was tearing the
  //     stream down, admitting frames into a stream being destroyed;
  //   * a recovery that finished AFTER stop()/dispose() logically RESURRECTED a
  //     disposed player, re-arming playback on an instance whose AVAudioSession
  //     had already been deactivated.
  //
  // The fix is deliberately NOT a second independent flag. Every lifecycle
  // transition — start, flush, recovery and the terminal stop — is submitted to
  // one lane:
  //
  //   * [_playerLane] is a Future chain, so at most ONE native close/open pair
  //     is ever in flight. That kills the double-rebuild.
  //   * [_playerGen] is bumped SYNCHRONOUSLY when an op is submitted, so an op
  //     that is queued (or parked mid-await) can tell it has been superseded by
  //     a newer intent and must not publish its result. That kills stale intent.
  //   * [_playerClosed] is terminal and never cleared, and is likewise set
  //     synchronously by [stop]. That kills resurrection: readiness is only
  //     ever committed inside a lane body under [_laneCurrent], so no queued or
  //     parked op can set `_playerReady = true` after the instance is done.
  //
  // Deadlock safety (the one invariant to preserve): nothing on the lane ever
  // awaits the [PcmPlaybackQueue] drain, and nothing on the drain path ever
  // awaits the lane. [feedPlayback]/[endPlaybackTurn] only fire-and-forget a
  // recovery request, and `_playback.reset()`/`close()` are SYNCHRONOUS, so the
  // cancel that unparks a drain stuck in `await feed(...)` lands before the
  // lane awaits any native call.
  Future<void> _playerLane = Future<void>.value();
  int _playerGen = 0;
  bool _playerClosed = false;

  /// How long the TERMINAL teardown will wait for the lane to drain before
  /// abandoning the native close.
  ///
  /// The lane gives correct ordering, but ordering must never cost liveness:
  /// if a platform call ahead of us is hung (flutter_sound is documented to
  /// wedge on the feed path) an unbounded wait here would wedge `stop()` —
  /// and through it `dispose()`, `_stopVoiceBody` and the whole `_voiceChain`.
  /// That is the same permanent-wedge shape as N2, so it gets the same answer:
  /// bound it. Safe to abandon, because the instance is already terminal — no
  /// abandoned op can resurrect it.
  @visibleForTesting
  Duration teardownTimeout = const Duration(seconds: 5);

  /// Whether the output stream is SUPPOSED to be up. Needed because
  /// `_playerReady` is false for the whole duration of a rebuild, so it cannot
  /// by itself tell "never started / stopped" apart from "mid-flush" — which is
  /// how two overlapping flushes used to make the second silently no-op and
  /// skip its jitter-buffer reset.
  bool _playerWanted = false;

  /// Dedupes recovery REQUESTS only (the lane does the serializing). Without it
  /// a burst of chunks would each submit an op, and each submission bumps the
  /// generation — which would supersede the recovery already running and spin
  /// forever under continuous websocket audio.
  ///
  /// KNOWN, ACCEPTED LIMIT: this clears only when the lane op completes, so a
  /// native open/close that never returns leaves it true and starves further
  /// recovery for this instance. That is deliberate. If the platform has hung
  /// the player, retrying it is pointless, and the instance is already
  /// unusable. What matters is that the failure stays CONTAINED: the terminal
  /// teardown is bounded by [teardownTimeout] and state.dart's disposal is
  /// bounded too, so `stopVoice()` still returns, `_voiceChain` is still
  /// released, and the user gets a working lane from a FRESH instance on the
  /// next tap. A hung player costs one instance, never the app.
  bool _recoveryPending = false;
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<AudioInterruptionEvent>? _interruptionSub;
  StreamSubscription<void>? _noisySub;

  /// Pre-roll jitter buffer between Gemini's bursty 24kHz output and the speaker.
  /// Without it, each websocket chunk was fed straight into flutter_sound's
  /// no-flow-control sink, so playback underran between bursts (and dropped
  /// tails when the device was momentarily full) — the "speaks in chunks" bug.
  /// It hands audio to the player through the BACK-PRESSURED `feedUint8FromStream`
  /// so nothing is dropped and the native ring never overruns.
  late final PcmPlaybackQueue _playback = PcmPlaybackQueue(
    feed: (frame) async {
      if (_playerReady) await _feedFrame(frame);
    },
    onDrained: () => onPlaybackDrained?.call(),
    onOverflow: _noteOverflow,
    onFeedError: () =>
        _logWarn('Voice playback feed failed; retrying next chunk'),
  );


  /// Logging must never take down the audio pipeline. [LunaLogger] writes to a
  /// Hive box and throws if the database is not open (early startup, or a unit
  /// test) — and because the write is `async` and unawaited, that surfaces as an
  /// UNHANDLED zone error rather than something a try/catch can hold. Every log
  /// on the playback path therefore goes through a guarded zone.
  void _safeLog(void Function() emit) => runZonedGuarded(emit, (_, __) {});

  void _logWarn(String message) => _safeLog(() => LunaLogger().warning(message));

  void _logError(String message, Object error, StackTrace stackTrace) =>
      _safeLog(() => LunaLogger().error(message, error, stackTrace));

  /// Overflow arrives at websocket-chunk rate, so one log line per dropped chunk
  /// is log spam that can itself hurt. Coalesce into one line per second with a
  /// running byte total.
  int _overflowBytes = 0;
  DateTime? _lastOverflowLog;

  void _noteOverflow(int dropped) {
    _overflowBytes += dropped;
    final now = DateTime.now();
    final last = _lastOverflowLog;
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _lastOverflowLog = now;
    _logWarn('Voice playback buffer overflow: dropped $_overflowBytes bytes');
    _overflowBytes = 0;
  }

  /// True once the mic is streaming into [micStream].
  bool get isCapturing => _micSub != null;

  /// Request the OS microphone permission. Returns true if granted. Surfacing
  /// the prompt is the caller's job (call this on an explicit mic tap).
  Future<bool> ensureMicPermission() async {
    final status = await Permission.microphone.request();
    return status.isGranted || status.isLimited;
  }

  /// Whether the mic permission is permanently denied (needs Settings).
  Future<bool> isMicPermanentlyDenied() =>
      Permission.microphone.isPermanentlyDenied;

  /// Configure the single shared AVAudioSession (see the class doc) and activate
  /// it. Idempotent.
  Future<void> configureSession() async {
    if (_sessionConfigured) return;
    // Test seam: injected event streams mean there is no platform session to
    // configure or own — just wire the handlers.
    if (_interruptionEvents != null || _becomingNoisyEvents != null) {
      if (_setSessionActive != null && !await _acquireSession()) {
        // Not active and not ours: stay UNconfigured so the next call retries,
        // rather than opening a speaker and a mic against a dead session.
        return;
      }
      _sessionConfigured = true;
      await _subscribeAudioEvents(
        _interruptionEvents ?? const Stream<AudioInterruptionEvent>.empty(),
        _becomingNoisyEvents ?? const Stream<void>.empty(),
      );
      return;
    }
    final session = await AudioSession.instance;
    // Not const: the `|` combinator on AVAudioSessionCategoryOptions is a runtime
    // operator, so the configuration cannot be a const expression.
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.defaultToSpeaker |
          AVAudioSessionCategoryOptions.allowBluetooth |
          AVAudioSessionCategoryOptions.mixWithOthers,
      // voiceChat => system acoustic echo cancellation for full-duplex voice.
      avAudioSessionMode: AVAudioSessionMode.voiceChat,
    ));
    // Only a REAL platform session is ours to deactivate again in stop(), and
    // the claim must be atomic with the activation — see [_sessionLane].
    // `_sessionConfigured` is committed ONLY on success: recording success for
    // an abandoned activation left the instance permanently unable to retry.
    if (!await _acquireSession()) return;
    _sessionConfigured = true;
    await _subscribeAudioEvents(
      session.interruptionEventStream,
      session.becomingNoisyEventStream,
    );
  }

  /// Subscribe to the M6 interruption + route-change signals.
  Future<void> _subscribeAudioEvents(
    Stream<AudioInterruptionEvent> interruptions,
    Stream<void> becomingNoisy,
  ) async {
    // --- Interruptions and route changes (M6) ---
    // The module previously subscribed to NEITHER, and the jitter buffer made
    // that strictly worse than the old fire-and-forget sink: the drain parks in
    // `await feed(...)`, and the cancel signal only fires on barge-in/stop
    // (feedRetryDelay rescues feeds that THROW, not feeds that HANG). A phone
    // call, a backgrounding, or AirPods walking out of range therefore wedged
    // playback permanently instead of merely dropping audio.
    //
    // flushPlayback() is the right response to all of them: it drops the
    // abandoned turn and rebuilds the native stream, which also unparks the
    // drain. On interruption END we deliberately do NOT auto-resume — the
    // interrupted turn's audio is gone and Gemini will speak again; silently
    // resuming a stale stream is worse than waiting for the next turn.
    await _interruptionSub?.cancel();
    _interruptionSub = interruptions.listen((event) {
      if (event.begin) {
        _logWarn('Voice audio interrupted (${event.type}); flushing playback');
        unawaited(flushPlayback());
      }
    });
    await _noisySub?.cancel();
    // Headphones/Bluetooth yanked mid-reply: iOS reroutes to the speaker and the
    // stream can be left in a bad state, so rebuild it rather than play on.
    _noisySub = becomingNoisy.listen((_) {
      _logWarn('Voice audio route became noisy; flushing playback');
      unawaited(flushPlayback());
    });
  }

  /// True while [gen] is still the newest intent AND the instance is alive.
  /// Checked after every await, and ALWAYS immediately before committing
  /// readiness — that check is what makes resurrection impossible.
  bool _laneCurrent(int gen) => !_playerClosed && _playerGen == gen;

  /// Submit one lifecycle transition to the single player lane.
  ///
  /// The generation is bumped synchronously HERE, at submission, not when the
  /// body runs — so a newer intent supersedes an older one even while the older
  /// one is parked inside a platform call that may never return.
  ///
  /// [terminal] ops (stop/dispose teardown) run even though they set
  /// `_playerClosed`, and are idempotent; every other op is skipped once the
  /// instance is closed or superseded.
  Future<void> _enqueuePlayerOp(
    Future<void> Function(int gen) body, {
    bool terminal = false,
  }) {
    final gen = ++_playerGen;
    Future<void> run(_) {
      if (!terminal && !_laneCurrent(gen)) return Future<void>.value();
      return body(gen);
    }

    final next = _playerLane.then(run, onError: run);
    _playerLane = next.catchError((_) {});
    return next;
  }

  /// Open the speaker stream for Gemini's 24kHz PCM output.
  Future<void> startPlayback() async {
    if (_playerClosed) return;
    _playerWanted = true;
    // Test seam: with an injected stream opener there is no plugin to open.
    if (_openPlayerStream != null) {
      await _enqueuePlayerOp(_openStream);
      return;
    }
    // configureSession() installs the interruption/noisy subscriptions, which
    // fire flushPlayback() — so it must complete BEFORE the open is submitted,
    // and the open itself must be on the lane or a first-frame interruption
    // could rebuild the stream underneath this very startup.
    await configureSession();
    await _enqueuePlayerOp((gen) async {
      if (_player.isOpen()) return;
      await _player.openPlayer();
      await _openStream(gen);
    });
    // Re-assert our category AFTER the player core has initialised so ours
    // wins. This is a process-wide side effect like any other, so it goes
    // through the arbiter instead of calling setActive directly: `stop()` is
    // terminal and can land in between, and re-acquiring audio focus after a
    // terminal stop — or after a newer instance took the epoch — steals it
    // back from whatever now owns it. [_reassertSession] re-validates both at
    // the moment the call is actually issued, not before the await.
    await _reassertSession();
  }

  /// Raw native open. Sets NO state — committing readiness is the lane's job
  /// (see [_openStream]); this used to set `_playerReady = true` unconditionally,
  /// which is precisely how a superseded or post-stop open resurrected a player.
  Future<void> _rawOpenPlayerStream() async {
    final open = _openPlayerStream;
    if (open != null) return open();
    // `openPlayer()` used to live ONLY in startPlayback's lane op, which is
    // non-terminal and therefore supersedable: `_playerWanted` is set before
    // `configureSession()` installs the interruption handlers, so an
    // interruption delivered in the microtask window between that op's
    // submission and its run submits a flush, bumps the generation, and the
    // open op is skipped — permanently. Nothing retried it, because flush and
    // recovery both come straight here, onto a player that was never opened.
    // Making the open idempotent HERE means every path that needs a stream
    // gets a player, whichever one wins the race.
    if (!_player.isOpen()) await _player.openPlayer();
    return _player.startPlayerFromStream(
      codec: Codec.pcm16,
      interleaved: true,
      numChannels: 1,
      sampleRate: kOutputSampleRate,
      bufferSize: 8192,
    );
  }

  /// Open the native stream and COMMIT readiness — but only if this op still
  /// owns the lane. An open that lands superseded (a newer flush) or after the
  /// instance is closed is thrown away and closed again rather than published.
  /// Must only ever be called from inside a lane body.
  Future<void> _openStream(int gen) async {
    await _rawOpenPlayerStream();
    if (!_laneCurrent(gen)) {
      // Nobody wants this stream any more. Best-effort close so the native
      // resource does not leak — and crucially, do NOT set `_playerReady`.
      try {
        await _stopPlayerStream();
      } catch (_) {}
      return;
    }
    _playerReady = true;
    _needsPlayerRestart = false;
  }

  Future<void> _stopPlayerStream() =>
      (_closePlayerStream ?? _player.stopPlayer)();

  Future<void> _feedFrame(Uint8List frame) =>
      (_feedPlayerStream ?? _player.feedUint8FromStream)(frame);

  /// Ask for a re-open of a stream that failed to restart. Deduped (see
  /// [_recoveryPending]) and serialized on the player lane, so a device that is
  /// genuinely gone costs one attempt per turn, not a spin — and a recovery can
  /// never overlap a flush, a stop or another recovery.
  void _requestRecovery() {
    if (_recoveryPending ||
        _playerClosed ||
        _playerReady ||
        !_needsPlayerRestart) {
      return;
    }
    _recoveryPending = true;
    unawaited(_enqueuePlayerOp((gen) async {
      // Re-check eligibility INSIDE the lane: a flush that ran ahead of us may
      // already have rebuilt the stream, making this a no-op.
      if (_playerReady || !_needsPlayerRestart) return;
      try {
        try {
          await _stopPlayerStream();
        } catch (_) {
          // Best effort: the stream may already be down. The open is what
          // matters.
        }
        if (!_laneCurrent(gen)) return;
        await _openStream(gen);
        if (_playerReady) {
          _logWarn('Voice playback stream recovered after a failed restart');
        }
      } catch (e, st) {
        _logError('Voice playback stream recovery failed', e, st);
        if (_laneCurrent(gen)) onPlaybackUnavailable?.call();
      }
    }).whenComplete(() => _recoveryPending = false));
  }

  /// Feed one chunk of Gemini's output PCM. Goes through the jitter buffer, which
  /// pre-rolls a cushion then feeds the speaker gaplessly under back-pressure.
  ///
  /// Returns whether the chunk was ACCEPTED into the pipeline. It is rejected
  /// while the player is torn down (e.g. mid barge-in flush), so the caller must
  /// NOT flip the orb to `speaking` for a chunk that was dropped — otherwise an
  /// interrupted server frame that also carries audio could strand the orb in
  /// `speaking` with no pending drain callback to restore `listening` (codex#7).
  bool feedPlayback(Uint8List pcm24) {
    if (!_playerReady) {
      // A previous restart failed. Try to come back rather than staying mute
      // for the rest of the session; this chunk is still rejected. Fire-and-
      // forget by design: the drain path must NEVER await the lifecycle lane.
      if (_needsPlayerRestart) _requestRecovery();
      return false;
    }
    _playback.add(pcm24);
    return true;
  }

  /// The model finished a spoken turn: flush any buffered tail (including a reply
  /// shorter than the pre-roll) and re-arm the pre-roll for the next turn.
  void endPlaybackTurn() {
    if (_playerReady) {
      _playback.endTurn();
    } else if (_needsPlayerRestart) {
      _requestRecovery();
    }
  }

  /// Barge-in OR a turn that ended abnormally (Live error / disconnect): drop
  /// everything still queued for the abandoned turn by clearing the jitter buffer
  /// AND tearing the output stream down and re-arming it.
  ///
  /// The native restart is load-bearing, not just a nicety: flutter_sound 9.30
  /// keeps a SINGLE mutable needSomeFood completer, so if we merely dropped the
  /// Dart-side buffer a stale native "needSomeFood" callback could later satisfy
  /// a NEWER feed's completer and desync playback (codex#8). stopPlayer() +
  /// a fresh startPlayerFromStream() resets that native state cleanly.
  Future<void> flushPlayback() {
    // Guarded on "the stream is SUPPOSED to be up" rather than on
    // `_playerReady`, which is false for the whole duration of a rebuild. The
    // old guard made a second interruption landing mid-flush return early and
    // silently skip its own jitter-buffer reset.
    if (_playerClosed || !_playerWanted) return Future<void>.value();
    // Synchronous intent gate, BEFORE anything is awaited: reject chunks in the
    // same event-loop turn (state.dart relies on a chunk arriving during a
    // barge-in being rejected, so the orb cannot strand in `speaking`) and
    // unpark a drain sitting in `await feed(...)`.
    _playerReady = false;
    _playback.reset();
    return _enqueuePlayerOp((gen) async {
      try {
        await _stopPlayerStream();
        if (!_laneCurrent(gen)) return;
        await _openStream(gen);
      } catch (e, st) {
        // A failed restart used to be swallowed silently AND was terminal: the
        // old comment claimed "next turn re-opens it", but no turn ever calls
        // startPlayback() — startVoice only ever constructs new instances. So
        // every later feedPlayback() returned false forever: no audio, no orb,
        // no error. Log it, flag it for lazy recovery on the next feed/turn,
        // and tell the state layer so the orb does not strand in `speaking`.
        _logError('Voice playback stream restart failed', e, st);
        // Only the CURRENT intent may leave the instance flagged for recovery
        // or fire the callback — a superseded flush must not, and a flush that
        // lost the race to stop() must never re-arm a terminated instance.
        if (_laneCurrent(gen)) {
          _needsPlayerRestart = true;
          onPlaybackUnavailable?.call();
        }
      }
    });
  }

  /// Start mic capture. Emits 16kHz mono s16le PCM chunks. `manageAudioSession`
  /// is OFF so `record` uses our shared session and never touches the category.
  Future<Stream<Uint8List>> startCapture() async {
    await configureSession();
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: kMicSampleRate,
      numChannels: 1,
      // Let the AVAudioSession's voiceChat mode do echo cancellation; keep
      // record from re-managing the session. (record 5.2.1 has no non-deprecated
      // equivalent — AudioRecorder.ios.manageAudioSession lands in a later major.)
      // ignore: deprecated_member_use
      iosConfig: IosRecordConfig(manageAudioSession: false),
      androidConfig: AndroidRecordConfig(useLegacy: false),
    ));
    return stream;
  }

  /// Convenience: pipe mic PCM straight into a sink (e.g. session.sendAudioChunk).
  Future<void> captureInto(void Function(Uint8List pcm16) onChunk) async {
    final stream = await startCapture();
    // Publication point: re-checked HERE, immediately before writing, not
    // before the await. `startStream()` is a platform call that state.dart
    // BOUNDS; if that wait is abandoned and the platform answers later,
    // subscribing now would open a LIVE MICROPHONE on an instance that has
    // already been stopped — the one late side effect in this class a user
    // would actually notice.
    if (_terminal) {
      await _abortLateCapture();
      return;
    }
    _micSub = stream.listen(onChunk);
  }

  /// Undo a capture that arrived after the instance was already terminal.
  Future<void> _abortLateCapture() async {
    _logWarn('Microphone stream arrived after stop(); discarding it');
    try {
      final rec = _recorderInstance;
      if (rec != null && await rec.isRecording()) await rec.stop();
    } catch (e, st) {
      _logError('Failed to stop a late microphone stream', e, st);
    }
  }

  Future<void> stopCapture() async {
    await _micSub?.cancel();
    _micSub = null;
    // Never instantiate the recorder just to stop one that was never started.
    final rec = _recorderInstance;
    if (rec == null) return;
    if (await rec.isRecording()) {
      await rec.stop();
    }
  }

  /// Stop everything and release the audio session so other apps regain focus.
  Future<void> stop() async {
    // TERMINAL, and terminal SYNCHRONOUSLY — before the first await. Everything
    // in this block must land in one event-loop turn so that a recovery or
    // flush already parked inside a platform call cannot come back afterwards
    // and commit readiness on a player we are tearing down (N1).
    _terminal = true;
    _playerClosed = true;
    _playerWanted = false;
    _playerGen++;
    _playerReady = false;
    _needsPlayerRestart = false;
    // Cancel timers, drop the buffer, and unpark any drain awaiting a feed that
    // will never return once the player is stopped. Synchronous, so it can
    // never deadlock against the lane op queued below.
    _playback.close();
    await stopCapture();
    await _interruptionSub?.cancel();
    _interruptionSub = null;
    await _noisySub?.cancel();
    _noisySub = null;
    // The native teardown goes ON the lane, so it lands AFTER any in-flight
    // open instead of interleaving with it (closePlayer racing a concurrent
    // startPlayerFromStream was the ugliest form of this bug).
    final teardown = _enqueuePlayerOp((_) async {
      if (_player.isOpen()) {
        try {
          await _stopPlayerStream();
        } catch (_) {}
        await _player.closePlayer();
      }
    }, terminal: true);
    try {
      await teardown.timeout(teardownTimeout);
    } on TimeoutException {
      // Bounded on purpose — see [teardownTimeout]. The queued teardown still
      // runs if the platform ever answers; we just stop waiting for it.
      _logWarn('Voice player teardown timed out; abandoning the native close');
    } catch (_) {}
    // Validate-and-deactivate, atomically (see [_sessionLane]). Checking the
    // epoch here and THEN awaiting setActive(false) was still racy: the check
    // cannot revoke a call already in flight.
    await _releaseSession();
    _sessionConfigured = false;
  }

  Future<void> dispose() async {
    await stop();
    await _recorderInstance?.dispose();
    _recorderInstance = null;
  }
}
