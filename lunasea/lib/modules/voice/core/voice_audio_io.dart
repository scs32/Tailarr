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
  })  : _openPlayerStream = openPlayerStream,
        _closePlayerStream = closePlayerStream,
        _feedPlayerStream = feedPlayerStream;

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

  bool _sessionConfigured = false;
  bool _playerReady = false;

  /// True when the output stream is DOWN but should be up — a restart failed.
  /// Drives the lazy recovery in [feedPlayback]/[endPlaybackTurn]; without it a
  /// failed restart was terminal, because nothing in the app ever calls
  /// [startPlayback] again for an existing instance.
  bool _needsPlayerRestart = false;
  bool _recovering = false;
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
    await session.setActive(true);
    _sessionConfigured = true;

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
    _interruptionSub = session.interruptionEventStream.listen((event) {
      if (event.begin) {
        _logWarn('Voice audio interrupted (${event.type}); flushing playback');
        unawaited(flushPlayback());
      }
    });
    await _noisySub?.cancel();
    // Headphones/Bluetooth yanked mid-reply: iOS reroutes to the speaker and the
    // stream can be left in a bad state, so rebuild it rather than play on.
    _noisySub = session.becomingNoisyEventStream.listen((_) {
      _logWarn('Voice audio route became noisy; flushing playback');
      unawaited(flushPlayback());
    });
  }

  /// Open the speaker stream for Gemini's 24kHz PCM output.
  Future<void> startPlayback() async {
    // Test seam: with an injected stream opener there is no plugin to open.
    if (_openPlayerStream != null) {
      await _startPlayerStream();
      return;
    }
    await configureSession();
    if (_player.isOpen()) return;
    await _player.openPlayer();
    await _startPlayerStream();
    // Re-assert our category AFTER the player core has initialised so ours wins.
    final session = await AudioSession.instance;
    await session.setActive(true);
  }

  Future<void> _startPlayerStream() async {
    final open = _openPlayerStream;
    if (open != null) {
      await open();
    } else {
      await _player.startPlayerFromStream(
        codec: Codec.pcm16,
        interleaved: true,
        numChannels: 1,
        sampleRate: kOutputSampleRate,
        bufferSize: 8192,
      );
    }
    _playerReady = true;
    _needsPlayerRestart = false;
  }

  Future<void> _stopPlayerStream() =>
      (_closePlayerStream ?? _player.stopPlayer)();

  Future<void> _feedFrame(Uint8List frame) =>
      (_feedPlayerStream ?? _player.feedUint8FromStream)(frame);

  /// Attempt to re-open a stream that failed to restart. Serialized (one attempt
  /// at a time) and only ever entered from [feedPlayback]/[endPlaybackTurn], so
  /// a device that is genuinely gone costs one attempt per turn, not a spin.
  Future<void> _recoverPlayer() async {
    if (_recovering || _playerReady || !_needsPlayerRestart) return;
    _recovering = true;
    try {
      try {
        await _stopPlayerStream();
      } catch (_) {
        // Best effort: the stream may already be down. What matters is the open.
      }
      await _startPlayerStream();
      _logWarn('Voice playback stream recovered after a failed restart');
    } catch (e, st) {
      _logError('Voice playback stream recovery failed', e, st);
      onPlaybackUnavailable?.call();
    } finally {
      _recovering = false;
    }
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
      // for the rest of the session; this chunk is still rejected.
      if (_needsPlayerRestart) unawaited(_recoverPlayer());
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
      unawaited(_recoverPlayer());
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
  Future<void> flushPlayback() async {
    if (!_playerReady && !_needsPlayerRestart) return;
    _playerReady = false;
    _playback.reset();
    try {
      await _stopPlayerStream();
      await _startPlayerStream();
    } catch (e, st) {
      // A failed restart used to be swallowed silently AND was terminal: the
      // old comment claimed "next turn re-opens it", but no turn ever calls
      // startPlayback() — startVoice only ever constructs new instances. So
      // every later feedPlayback() returned false forever: no audio, no orb, no
      // error. Log it, flag it for lazy recovery on the next feed/turn, and
      // tell the state layer so the orb does not strand in `speaking`.
      _logError('Voice playback stream restart failed', e, st);
      _needsPlayerRestart = true;
      onPlaybackUnavailable?.call();
    }
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
    _micSub = stream.listen(onChunk);
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
    await stopCapture();
    _playerReady = false;
    _needsPlayerRestart = false;
    await _interruptionSub?.cancel();
    _interruptionSub = null;
    await _noisySub?.cancel();
    _noisySub = null;
    // Terminal for this instance: cancel timers, drop the buffer, and unpark any
    // drain awaiting a feed that will never return once the player is stopped.
    _playback.close();
    if (_player.isOpen()) {
      try {
        await _stopPlayerStream();
      } catch (_) {}
      await _player.closePlayer();
    }
    if (_sessionConfigured) {
      final session = await AudioSession.instance;
      await session.setActive(false);
      _sessionConfigured = false;
    }
  }

  Future<void> dispose() async {
    await stop();
    await _recorderInstance?.dispose();
    _recorderInstance = null;
  }
}
