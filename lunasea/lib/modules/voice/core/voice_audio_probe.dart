/// AVAudioSession probe + the pure guard that decides whether it is safe to
/// start the native stream player.
///
/// ## Why this file exists (build 48 crash, `EXC_CRASH (SIGABRT)`)
///
/// A TestFlight crash on build 11.0.0 (48) aborted here:
///
/// ```
/// -[FlutterSoundPlayer startPlayer:result:]        FlutterSoundPlayer.mm:219
/// -[FlautoPlayer startPlayerCodec:…]               FlautoPlayer.mm:182
/// -[AudioEngine init:codec:channels:…]             FlautoPlayerEngine.mm:222
/// -[AVAudioEngine connect:to:format:]  ->  _AVAE_CheckAndReturnErr
///   -> +[NSException raise:format:] -> objc_exception_throw -> abort()
/// ```
///
/// `AVAudioEngine.connect` raises an **Objective-C** exception when its format
/// is invalid — classically a `sampleRate` of 0, which is exactly what the
/// nodes report while the `AVAudioSession` is NOT ACTIVE (or while the
/// hardware rate is being changed underneath).
///
/// ⚠️ **An ObjC exception is not catchable from Dart.** A `try`/`catch` around
/// `startPlayerFromStream` is decoration: the process is already aborting by
/// the time Dart would see anything. The check therefore has to happen
/// **before** the call, and the failure path has to return an error instead of
/// proceeding and gambling.
///
/// [probeAudioSession] reads the live session from the platform (iOS only) and
/// [playerStartRefusalReason] is the pure decision — kept separate precisely so
/// the decision is unit-testable without a device or a native engine.
library;

import 'package:flutter/services.dart';

/// A read of the live `AVAudioSession` immediately before a player start.
///
/// Every numeric field is nullable and `null` means **not observable here**
/// (Android, web, the simulator without the channel, a unit test) — NOT "zero".
/// The guard treats an unobservable field as "cannot refuse on this basis"
/// rather than inventing a value.
class AudioSessionProbe {
  const AudioSessionProbe({
    required this.activated,
    this.sampleRate,
    this.ioBufferDuration,
    this.outputChannels,
    this.inputChannels,
    this.category,
    this.mode,
    this.route,
  });

  /// Whether `AudioSession.setActive(true)` reported success just now. This is
  /// the only "is the session active" signal available: `AVAudioSession` has no
  /// public `isActive` property.
  final bool activated;

  /// `AVAudioSession.sampleRate` — the hardware rate. **0.0 here is the crash
  /// precursor**: it is what an inactive session reports, and it is the value
  /// that makes `AVAudioEngine.connect` raise.
  final double? sampleRate;
  final double? ioBufferDuration;
  final int? outputChannels;
  final int? inputChannels;
  final String? category;
  final String? mode;
  final String? route;

  /// Compact `key=value` rendering for a log line. Unobservable fields render
  /// as `unavailable` — never as a fabricated zero.
  String describe() {
    String n(num? v, {int frac = 0}) =>
        v == null ? 'unavailable' : v.toStringAsFixed(frac);
    return 'active=$activated '
        'hwRate=${n(sampleRate)} '
        'ioBuf=${ioBufferDuration == null ? 'unavailable' : ioBufferDuration!.toStringAsFixed(4)} '
        'outCh=${outputChannels ?? 'unavailable'} '
        'inCh=${inputChannels ?? 'unavailable'} '
        'category=${category ?? 'unavailable'} '
        'mode=${mode ?? 'unavailable'} '
        'route=${route ?? 'unavailable'}';
  }
}

/// Sane bounds for an `AVAudioSession` hardware rate. Anything outside this —
/// above all **0** — means the session is not in a state where an
/// `AVAudioEngine` graph can legally be connected.
const double kMinSaneHardwareRate = 8000;
const double kMaxSaneHardwareRate = 192000;

/// The guard, as a pure function.
///
/// Returns `null` when it is safe to call `startPlayerFromStream`, or a short
/// human-readable reason to REFUSE. The caller must surface the reason and must
/// not start the player anyway — see the library doc: there is no recovering
/// from the abort on the other side.
String? playerStartRefusalReason(AudioSessionProbe probe) {
  if (!probe.activated) {
    return 'the audio session could not be activated';
  }
  final rate = probe.sampleRate;
  if (rate != null &&
      (rate < kMinSaneHardwareRate || rate > kMaxSaneHardwareRate)) {
    // 0.0 lands here. So does any other nonsense the session reports mid
    // route/rate change.
    return 'the audio session reported an unusable hardware sample rate '
        '(${rate.toStringAsFixed(0)} Hz)';
  }
  final out = probe.outputChannels;
  if (out != null && out <= 0) {
    return 'the audio session reported no audio output';
  }
  return null;
}

/// Platform channel carrying the session read. iOS only; every other platform
/// (and every unit test) gets a [MissingPluginException], which is translated
/// into "unobservable", not into a failure.
const MethodChannel kVoiceAudioChannel =
    MethodChannel('com.stephenspeicher.tailarr/voice_audio');

/// Read the live session. [activated] is passed in by the caller because only
/// the caller knows whether its `setActive(true)` succeeded.
Future<AudioSessionProbe> probeAudioSession({required bool activated}) async {
  try {
    final raw = await kVoiceAudioChannel
        .invokeMapMethod<String, dynamic>('probeSession');
    if (raw == null) return AudioSessionProbe(activated: activated);
    double? d(String k) => (raw[k] as num?)?.toDouble();
    int? i(String k) => (raw[k] as num?)?.toInt();
    return AudioSessionProbe(
      activated: activated,
      sampleRate: d('sampleRate'),
      ioBufferDuration: d('ioBufferDuration'),
      outputChannels: i('outputChannels'),
      inputChannels: i('inputChannels'),
      category: raw['category'] as String?,
      mode: raw['mode'] as String?,
      route: raw['route'] as String?,
    );
  } catch (_) {
    // MissingPluginException (non-iOS / test) or any platform hiccup: the
    // fields are simply unobservable. Do NOT downgrade this to "rate 0" —
    // that would refuse to play on every platform that lacks the channel.
    return AudioSessionProbe(activated: activated);
  }
}
