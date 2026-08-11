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
///   * We configure ONE category, `playAndRecord`, mode `voiceChat`, with
///     `defaultToSpeaker | allowBluetooth | mixWithOthers`, and `setActive(true)`
///     BEFORE any capture/playback starts.
///   * `record` is started with `IosRecordConfig(manageAudioSession: false)` so
///     it uses our session verbatim and never calls `setCategory`.
///   * `flutter_sound` 9.30 no longer exposes Dart-side category control; its
///     precompiled core is session-agnostic when a compatible `playAndRecord`
///     session is already active. We open + start the player first and then
///     re-assert our category, so our configuration is the final word.
///
/// ## ⚠️ Acoustic echo cancellation is NOT a property of the session mode here
///
/// An earlier version of this comment asserted that `AVAudioSessionMode
/// .voiceChat` "turns on the system's acoustic echo canceller". **That is false
/// for this plugin stack**, and it sent a whole investigation down the wrong
/// path, so it is corrected here rather than deleted.
///
/// What actually decides AEC is `record`, not the session mode.
/// `record_ios`'s stream delegate calls
/// `audioEngine.inputNode.setVoiceProcessingEnabled(config.echoCancel)` on every
/// `startStream` (`record_ios-1.2.1/.../delegate/RecorderStreamDelegate.swift:128`),
/// and `RecordConfig.echoCancel` **defaults to `false`**
/// (`record_platform_interface-1.6.0/.../record_config.dart`). Setting the
/// session mode does not reach that call: `record` does not inherit voice
/// processing from the session mode and has to be told **explicitly**. With
/// `echoCancel` left at its default, voice processing was being explicitly
/// DISABLED on the input node while our output went to the loudspeaker
/// (`defaultToSpeaker`) — so the mic heard the speaker, Gemini's server VAD
/// fired `serverContent.interrupted`, and playback was flushed every couple of
/// seconds. See [startCapture].
///
/// ## ⚠️ Do not rebuild the player engine on a transient event
///
/// Build 11.0.0 (48) produced a TestFlight `EXC_CRASH (SIGABRT)` inside
/// `-[AVAudioEngine connect:to:format:]` reached from `startPlayerFromStream`.
/// `AVAudioEngine.connect` raises an **Objective-C** exception on an invalid
/// format (classically `sampleRate == 0`, what an inactive session reports),
/// and an ObjC exception cannot be caught from Dart — the process aborts.
///
/// The old [flushPlayback] tore the native engine down and rebuilt it on every
/// barge-in, session interruption and Live error: it restarted the engine
/// precisely when the session was most likely inactive or mid-reconfiguration.
/// That single behaviour produced all three field symptoms — the stutter (audio
/// discarded then re-prerolled), the crash, and the dead-after-resume state.
///
/// So: [flushPlayback] no longer touches the engine at all, and the one
/// remaining path that starts the player goes through [_startPlayerStreamGuarded],
/// which refuses when the session is not demonstrably safe (see
/// `voice_audio_probe.dart`).
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

import 'package:lunasea/modules/voice/core/voice_audio_probe.dart';
import 'package:lunasea/modules/voice/core/voice_session.dart'
    show kMicSampleRate, kOutputSampleRate;
import 'package:lunasea/system/logger.dart';

/// Thrown when the audio lane refuses to start rather than risking the native
/// abort. Carries a message intended for the user-visible transcript: the UI
/// must NOT be left looking ready with dead audio.
class VoiceAudioUnavailable implements Exception {
  VoiceAudioUnavailable(this.reason, {this.probe});
  final String reason;
  final AudioSessionProbe? probe;

  @override
  String toString() => 'Audio is unavailable: $reason';
}

/// Why [VoiceAudioIO.flushPlayback] was called. Tagged at the call site so the
/// breakdown in the telemetry is derived rather than inferred.
enum VoiceFlushCause { bargeIn, liveError, interruption, becomingNoisy, teardown }

class VoiceAudioIO {
  // `late final`, not `final`: `AudioRecorder()`'s constructor immediately calls
  // into the platform channel (`_platform.create(...)`, unawaited), so an eager
  // field would make merely CONSTRUCTING this class throw an unhandled
  // MissingPluginException anywhere without a live plugin — including every
  // unit test of the counters below. Deferring creation to first real use costs
  // nothing and keeps the accounting testable off-device.
  late final AudioRecorder _recorder = AudioRecorder();
  late final FlutterSoundPlayer _player = FlutterSoundPlayer();

  bool _sessionConfigured = false;
  bool _playerReady = false;
  StreamSubscription<Uint8List>? _micSub;

  /// Barge-in suppression window: while `now` is before this, incoming model
  /// PCM is dropped instead of being fed to the player. See [flushPlayback].
  DateTime? _suppressFeedUntil;

  /// How long a barge-in suppresses inbound model audio. Bounded on purpose:
  /// an un-bounded "suppress until the next turn" flag would wedge the lane
  /// silently if the abandoned turn never produced a `turnComplete`.
  static const Duration kBargeInSuppression = Duration(milliseconds: 600);

  /// The probe read immediately before the last player start, kept for the
  /// session telemetry line and for error reporting.
  AudioSessionProbe? lastStartProbe;

  /// Counters. ⚠️ AGGREGATE ONLY — `LunaLogger` keeps ~50 entries, so a
  /// per-chunk log would evict the entire diagnostic window in one reply.
  /// Nothing here logs per chunk; the counters are emitted once per reply.
  int flushes = 0;
  final Map<VoiceFlushCause, int> flushesByCause = {};
  int playerStarts = 0;
  int playerStartsRefused = 0;

  // ---- Per-reply playback counters (reset by [beginReply]) ----
  int _chunks = 0;
  int _bytes = 0;
  int _chunksDropped = 0;
  DateTime? _firstFeedAt;
  DateTime? _lastFeedAt;
  int _gapOver250 = 0;
  int _gapOver500 = 0;
  int _gapOver1000 = 0;
  int _maxGapMs = 0;

  /// Emitted once per voice session, not per reply.
  bool _sessionLineEmitted = false;

  /// Milliseconds of audio implied by [_bytes]: 24kHz, mono, 16-bit = 48
  /// bytes per millisecond.
  int get _audioMs => _bytes ~/ (kOutputSampleRate * 2 ~/ 1000);

  /// Start a fresh per-reply accounting window.
  void beginReply() {
    _chunks = 0;
    _bytes = 0;
    _chunksDropped = 0;
    _firstFeedAt = null;
    _lastFeedAt = null;
    _gapOver250 = 0;
    _gapOver500 = 0;
    _gapOver1000 = 0;
    _maxGapMs = 0;
  }

  /// The per-reply playback line.
  ///
  /// The field that carries the weight is **`ratio`** — produced audio ms over
  /// wall-clock ms between the first and last chunk of the reply. Below ~1.0
  /// means the model is not delivering audio as fast as it plays, and **no
  /// client-side buffer of any depth fixes that**; the stutter would then be
  /// upstream, not ours. `maxGap`/`gap>N` say whether the shortfall is a steady
  /// drip or a few long stalls.
  ///
  /// ⚠️ This branch has NO `PcmPlaybackQueue` (that is PR #18), so the queue
  /// fields have no source and are reported `n/a` rather than invented. In
  /// particular `feedBlockedMs` — the field that would prove whether
  /// back-pressure ever engaged — cannot exist here: chunks go straight to the
  /// native sink, so the client-side path IS a pass-through by construction.
  String pcmReport() {
    final first = _firstFeedAt;
    final last = _lastFeedAt;
    final wallMs =
        (first == null || last == null) ? 0 : last.difference(first).inMilliseconds;
    final audioMs = _audioMs;
    final ratio = wallMs > 0 ? audioMs / wallMs : 0.0;
    return 'voice/pcm: chunks=$_chunks audioMs=$audioMs wallMs=$wallMs '
        'ratio=${ratio.toStringAsFixed(2)} '
        'gap>250=$_gapOver250 >500=$_gapOver500 >1000=$_gapOver1000 '
        'maxGap=${_maxGapMs}ms dropped=$_chunksDropped '
        'playerStarts=$playerStarts refused=$playerStartsRefused '
        'rearms=0 prerollWaits=n/a prerollMs=n/a qEmpty=n/a qMaxMs=n/a '
        'feedBlockedMs=n/a overflow=n/a (no PcmPlaybackQueue on this branch)';
  }

  /// The once-per-session audio line, or null if it has already been emitted or
  /// no player start has happened yet. Everything here is READ from the live
  /// session — `unavailable` where the platform does not expose it.
  String? sessionReportOnce() {
    if (_sessionLineEmitted) return null;
    final probe = lastStartProbe;
    if (probe == null) return null;
    _sessionLineEmitted = true;
    return 'voice/session: ${probe.describe()} '
        'playerRate=$kOutputSampleRate bufferSize=8192 '
        'micRate=$kMicSampleRate echoCancel=${micConfig.echoCancel} '
        'autoGain=${micConfig.autoGain}';
  }

  /// True once the mic is streaming into the capture sink.
  bool get isCapturing => _micSub != null;

  /// Whether the speaker stream is armed and accepting audio.
  bool get isPlaybackReady => _playerReady;

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
    final session = await AudioSession.instance;
    // Not const: the `|` combinator on AVAudioSessionCategoryOptions is a runtime
    // operator, so the configuration cannot be a const expression.
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.defaultToSpeaker |
          AVAudioSessionCategoryOptions.allowBluetooth |
          AVAudioSessionCategoryOptions.mixWithOthers,
      // NOTE: `voiceChat` shapes routing/latency. It does NOT enable the
      // canceller for `record` — see the class doc and [startCapture].
      avAudioSessionMode: AVAudioSessionMode.voiceChat,
    ));
    await session.setActive(true);
    _sessionConfigured = true;
  }

  /// Activate the session and read it back. Never throws: the returned probe
  /// carries `activated: false` when activation failed, which the guard treats
  /// as a refusal.
  Future<AudioSessionProbe> _activateAndProbe() async {
    bool activated = false;
    try {
      await configureSession();
      final session = await AudioSession.instance;
      activated = await session.setActive(true);
    } catch (_) {
      activated = false;
    }
    return probeAudioSession(activated: activated);
  }

  /// The ONLY path that calls `startPlayerFromStream`.
  ///
  /// ⚠️ The guard runs BEFORE the call and refuses by throwing a Dart
  /// exception. It cannot be a try/catch AROUND the call: `AVAudioEngine
  /// .connect` raises an ObjC exception straight through the Dart VM into
  /// `abort()`. See `voice_audio_probe.dart`.
  Future<void> _startPlayerStreamGuarded() async {
    final probe = await _activateAndProbe();
    lastStartProbe = probe;
    final refusal = playerStartRefusalReason(probe);
    if (refusal != null) {
      playerStartsRefused += 1;
      throw VoiceAudioUnavailable(refusal, probe: probe);
    }
    await _player.startPlayerFromStream(
      codec: Codec.pcm16,
      interleaved: true,
      numChannels: 1,
      sampleRate: kOutputSampleRate,
      bufferSize: 8192,
    );
    playerStarts += 1;
    _playerReady = true;
    _suppressFeedUntil = null;
  }

  /// Open the speaker stream for Gemini's 24kHz PCM output.
  ///
  /// Throws [VoiceAudioUnavailable] rather than starting the player into a
  /// session that could abort the process. Callers MUST surface that — a silent
  /// no-op here is what "voice stopped working completely" looks like.
  Future<void> startPlayback() async {
    await configureSession();
    if (_player.isOpen() && _playerReady) return;
    if (!_player.isOpen()) await _player.openPlayer();
    await _startPlayerStreamGuarded();
    // Re-assert our category AFTER the player core has initialised so ours wins.
    final session = await AudioSession.instance;
    await session.setActive(true);
  }

  /// Feed one chunk of Gemini's output PCM to the speaker.
  void feedPlayback(Uint8List pcm24) {
    if (!_playerReady) return;
    final now = DateTime.now();
    final until = _suppressFeedUntil;
    if (until != null) {
      if (now.isBefore(until)) {
        _chunksDropped += 1; // barge-in drain window
        return;
      }
      _suppressFeedUntil = null;
    }
    // Aggregate accounting only — one counter bump, never a log line.
    final last = _lastFeedAt;
    if (last != null) {
      final gap = now.difference(last).inMilliseconds;
      if (gap > _maxGapMs) _maxGapMs = gap;
      if (gap > 250) _gapOver250 += 1;
      if (gap > 500) _gapOver500 += 1;
      if (gap > 1000) _gapOver1000 += 1;
    }
    _firstFeedAt ??= now;
    _lastFeedAt = now;
    _chunks += 1;
    _bytes += pcm24.length;
    _player.uint8ListSink?.add(pcm24);
  }

  /// Barge-in / abandon: stop feeding the abandoned model turn.
  ///
  /// ⚠️ This used to `stopPlayer()` + `startPlayerFromStream()` — destroying and
  /// rebuilding the native `AVAudioEngine` on a transient event. That is the
  /// path that crashed build 48 (see the class doc), and the same teardown is
  /// what produced the stutter (discard, then re-preroll). It no longer touches
  /// the engine.
  ///
  /// ⚠️ **The cost is NOT ~170ms, and an earlier version of this comment said
  /// it was.** That number described the native 8KB buffer and would have been
  /// right if [feedPlayback] fed the engine directly. It does not: it adds every
  /// chunk to `_player.uint8ListSink`, and in `flutter_sound` 9.30 that sink is
  /// a plain **unbounded** `StreamController` (`_pcmUint8Controller =
  /// StreamController();`) whose subscription pauses itself on each `_feed`,
  /// i.e. it drains at real-time playback rate. Gemini Live streams TTS FASTER
  /// than real time, so at any moment the queued backlog is
  /// *(generated so far − played so far)* — potentially **seconds**.
  ///
  /// So a barge-in currently drops almost nothing already queued;
  /// [kBargeInSuppression] only refuses chunks that arrive AFTER it. The model
  /// can keep talking over the user for the length of that backlog.
  ///
  /// The corroborating detail: the OLD code's comment said flush existed to
  /// "drop everything still queued for the abandoned model turn". If the buffer
  /// really were 170ms, that flush would never have been worth writing.
  ///
  /// This is still the right trade against a process abort — a stale tail is a
  /// UX defect, a SIGABRT is a crash — but it is a MUCH bigger stale tail than
  /// was claimed, and it is a KNOWN, MEASURED cost rather than a rounding error.
  /// Bounding it needs real backpressure (feed with an awaited
  /// `feedUint8FromStream`, keeping ≤1 buffer in flight behind an app-side queue
  /// that CAN be dropped). Tracked separately — do not "fix" it by restoring the
  /// engine teardown, which is the crash.
  void flushPlayback({VoiceFlushCause cause = VoiceFlushCause.bargeIn}) {
    flushes += 1;
    flushesByCause[cause] = (flushesByCause[cause] ?? 0) + 1;
    if (!_playerReady) return;
    _suppressFeedUntil = DateTime.now().add(kBargeInSuppression);
  }

  /// Clear any barge-in suppression — called when a new model turn starts, so a
  /// fresh reply is never silenced by a stale window.
  void resumePlayback() => _suppressFeedUntil = null;

  /// The mic configuration, hoisted to a named constant so the two flags that
  /// are load-bearing and invisible (`echoCancel`, `audioInterruption`) can be
  /// asserted by a unit test instead of merely being written down once.
  static const RecordConfig micConfig = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: kMicSampleRate,
      numChannels: 1,
      // ⚠️ REQUIRED for acoustic echo cancellation. `record_ios` calls
      // `inputNode.setVoiceProcessingEnabled(config.echoCancel)` on every
      // startStream and this flag DEFAULTS TO FALSE — the AVAudioSession's
      // `voiceChat` mode does NOT enable it. Without this the mic hears our own
      // loudspeaker output and Gemini's server VAD fires a false barge-in every
      // couple of seconds.
      echoCancel: true,
      // ⚠️ REQUIRED for the mic to survive an interruption. `record_ios`
      // registers its own AVAudioSession.interruptionNotification observer;
      // on `.began` it calls pause(), and it resumes on `.ended` ONLY when the
      // mode is pauseResume (RecorderSessionExtension.swift:79-92). The default
      // is `pause` — "pauses automatically, resumes MANUALLY" — and nothing in
      // this app ever resumed it. iOS suspension delivers exactly that
      // interruption, so with the default the mic went dead on the first
      // background and never came back.
      audioInterruption: AudioInterruptionMode.pauseResume,
      // Keep record from re-managing the session (we own it via audio_session).
      // ignore: deprecated_member_use
      iosConfig: IosRecordConfig(manageAudioSession: false),
      androidConfig: AndroidRecordConfig(useLegacy: false));

  /// Start mic capture. Emits 16kHz mono s16le PCM chunks. `manageAudioSession`
  /// is OFF so `record` uses our shared session and never touches the category.
  Future<Stream<Uint8List>> startCapture() async {
    await configureSession();
    return _recorder.startStream(micConfig);
  }

  /// Convenience: pipe mic PCM straight into a sink (e.g. session.sendAudioChunk).
  Future<void> captureInto(void Function(Uint8List pcm16) onChunk) async {
    final stream = await startCapture();
    _micSub = stream.listen(onChunk);
  }

  /// Run one teardown step, absorbing any failure.
  ///
  /// ⚠️ **Cleanup must be infallible.** Every call below is a plugin call made
  /// against an audio stack iOS has just torn down — deactivating a session,
  /// closing a player, stopping a recorder — which is precisely the state where
  /// they are most likely to throw. Before this existed, the FIRST such throw
  /// aborted the rest of `stop()` AND the `_dropSession(...)` that follows it in
  /// the same queued op, while `_enqueueVoiceOp` swallowed the rejection and
  /// both call sites discarded the returned future. The failure was therefore
  /// completely silent, and it left the worst possible state: `_status` still
  /// `ready` over a dead socket, so `ensureConnected()` early-returns forever
  /// and the next mic tap captures into a session that is gone.
  ///
  /// Absorbing here rather than at the call site is deliberate — it guarantees
  /// EVERY later step still runs, which per-step try/catch at one outer level
  /// cannot do.
  Future<void> _teardownStep(String what, Future<void> Function() step) async {
    // MUTANT (proof only): the guard removed. Teardown throws again.
    await step();
    // ignore: dead_code
    if (false) LunaLogger().error('Voice teardown step failed: $what', '', StackTrace.empty);
  }

  Future<void> stopCapture() async {
    await _teardownStep('cancel mic subscription', () async {
      await _micSub?.cancel();
    });
    _micSub = null;
    await _teardownStep('stop recorder', () async {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    });
  }

  /// Stop everything and release the audio session so other apps regain focus.
  ///
  /// Never throws — see [_teardownStep].
  Future<void> stop() async {
    await stopCapture();
    _playerReady = false;
    _suppressFeedUntil = null;
    if (_player.isOpen()) {
      await _teardownStep('stop player', () => _player.stopPlayer());
      await _teardownStep('close player', () => _player.closePlayer());
    }
    if (_sessionConfigured) {
      // Cleared BEFORE the await, so a throwing deactivation cannot leave this
      // true and make a later stop() believe it still owns a live session.
      _sessionConfigured = false;
      await _teardownStep('deactivate audio session', () async {
        final session = await AudioSession.instance;
        await session.setActive(false);
      });
    }
  }

  Future<void> dispose() async {
    await stop();
    await _recorder.dispose();
  }
}
