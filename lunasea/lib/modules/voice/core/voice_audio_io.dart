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

import 'package:lunasea/modules/voice/core/voice_session.dart'
    show kMicSampleRate, kOutputSampleRate;

class VoiceAudioIO {
  final AudioRecorder _recorder = AudioRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  bool _sessionConfigured = false;
  bool _playerReady = false;
  StreamSubscription<Uint8List>? _micSub;

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
  }

  /// Open the speaker stream for Gemini's 24kHz PCM output.
  Future<void> startPlayback() async {
    await configureSession();
    if (_player.isOpen()) return;
    await _player.openPlayer();
    await _startPlayerStream();
    // Re-assert our category AFTER the player core has initialised so ours wins.
    final session = await AudioSession.instance;
    await session.setActive(true);
  }

  Future<void> _startPlayerStream() async {
    await _player.startPlayerFromStream(
      codec: Codec.pcm16,
      interleaved: true,
      numChannels: 1,
      sampleRate: kOutputSampleRate,
      bufferSize: 8192,
    );
    _playerReady = true;
  }

  /// Feed one chunk of Gemini's output PCM to the speaker.
  void feedPlayback(Uint8List pcm24) {
    if (_playerReady) _player.uint8ListSink?.add(pcm24);
  }

  /// Barge-in: drop everything still queued for the abandoned model turn by
  /// tearing the output stream down and re-arming it (a fresh StreamController
  /// discards the old buffer; the native ring buffer is dropped by stopPlayer).
  Future<void> flushPlayback() async {
    if (!_playerReady) return;
    _playerReady = false;
    try {
      await _player.stopPlayer();
      await _startPlayerStream();
    } catch (_) {
      // If the player is mid-teardown, leave it stopped; next turn re-opens it.
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
    if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
  }

  /// Stop everything and release the audio session so other apps regain focus.
  Future<void> stop() async {
    await stopCapture();
    _playerReady = false;
    if (_player.isOpen()) {
      try {
        await _player.stopPlayer();
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
    await _recorder.dispose();
  }
}
