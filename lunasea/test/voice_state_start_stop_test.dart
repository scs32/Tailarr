import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules/voice/core/state.dart';
import 'package:lunasea/modules/voice/core/voice_audio_io.dart';
import 'package:lunasea/modules/voice/core/voice_session.dart';

/// M5: start/stop ordering for the voice lane.
///
/// `startVoice()` awaits credentials, mic permission, the player and the
/// recorder before it publishes anything. It used to set `_voiceActive` only
/// AFTER all of that, so `stopVoice()` — whose guard was `if (!_voiceActive)
/// return;` — did nothing when tapped during startup, and the start it was
/// meant to cancel went on to turn the MICROPHONE ON after the user had
/// already stopped it. Two quick Start taps could likewise build two
/// VoiceAudioIO instances and orphan a recorder/player.
class _FakeAudio implements VoiceAudioIO {
  _FakeAudio({this.playbackGate});

  /// Parks `startPlayback()` so a test can act during the startup window.
  final Completer<void>? playbackGate;

  bool capturing = false;
  bool disposed = false;
  int playbackStarts = 0;

  @override
  Future<bool> ensureMicPermission() async => true;

  @override
  Future<bool> isMicPermanentlyDenied() async => false;

  @override
  Future<void> startPlayback() async {
    playbackStarts++;
    if (playbackGate != null) await playbackGate!.future;
  }

  @override
  Future<void> captureInto(void Function(Uint8List pcm16) onChunk) async {
    capturing = true; // the mic is LIVE from here
  }

  @override
  Future<void> stopCapture() async => capturing = false;

  @override
  Future<void> stop() async => capturing = false;

  @override
  Future<void> dispose() async {
    await stop();
    disposed = true;
  }

  @override
  bool get isCapturing => capturing;

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  VoiceAssistantState connectedState() {
    final state = VoiceAssistantState();
    state.debugSetConnected(VoiceSession(
      apiKey: 'test-key',
      mcpUrl: 'https://example.invalid/mcp',
      mcpToken: 'test-token',
    ));
    return state;
  }

  test('Stop during startup must not leave the microphone on', () async {
    final state = connectedState();
    final gate = Completer<void>();
    final fakes = <_FakeAudio>[];
    state.audioFactory = ({onPlaybackDrained, onPlaybackUnavailable}) {
      final f = _FakeAudio(playbackGate: gate);
      fakes.add(f);
      return f;
    };

    final starting = state.startVoice();
    await Future<void>.delayed(Duration.zero);
    expect(state.voiceStarting, isTrue,
        reason: 'the startup window must be observable to stopVoice');

    final stopping = state.stopVoice(); // user taps Stop mid-startup
    gate.complete(); // ...and the startup then completes
    await starting;
    await stopping;

    expect(state.voiceActive, isFalse);
    expect(fakes.single.capturing, isFalse,
        reason: 'the mic must NOT be left streaming after an explicit Stop');
    expect(fakes.single.disposed, isTrue,
        reason: 'the abandoned instance must be torn down, not orphaned');
    expect(state.activity, VoiceActivity.idle);
  });

  test('two rapid Start taps build exactly one audio instance', () async {
    final state = connectedState();
    final gate = Completer<void>();
    final fakes = <_FakeAudio>[];
    state.audioFactory = ({onPlaybackDrained, onPlaybackUnavailable}) {
      final f = _FakeAudio(playbackGate: gate);
      fakes.add(f);
      return f;
    };

    final a = state.startVoice();
    final b = state.startVoice(); // double tap
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    await a;
    await b;

    expect(fakes.length, 1,
        reason: 'a second tap must coalesce, not orphan a recorder/player');
    expect(state.voiceActive, isTrue);
  });

  test('start -> stop -> start ends active on the NEWEST instance', () async {
    final state = connectedState();
    final gate1 = Completer<void>();
    final fakes = <_FakeAudio>[];
    var n = 0;
    state.audioFactory = ({onPlaybackDrained, onPlaybackUnavailable}) {
      // Only the first startup is parked; the second runs straight through.
      final f = _FakeAudio(playbackGate: n++ == 0 ? gate1 : null);
      fakes.add(f);
      return f;
    };

    final first = state.startVoice();
    await Future<void>.delayed(Duration.zero);
    final stopping = state.stopVoice();
    final second = state.startVoice();
    gate1.complete();
    await first;
    await stopping;
    await second;

    expect(fakes.length, 2);
    expect(fakes[0].disposed, isTrue, reason: 'the cancelled start cleans up');
    expect(fakes[0].capturing, isFalse);
    expect(fakes[1].capturing, isTrue, reason: 'the newest start owns the mic');
    expect(state.voiceActive, isTrue);
    expect(state.voiceStarting, isFalse,
        reason: 'a stale body must not clear a newer startup flag, nor stick');
  });

  test('toggleVoice during startup cancels instead of re-starting', () async {
    final state = connectedState();
    final gate = Completer<void>();
    final fakes = <_FakeAudio>[];
    state.audioFactory = ({onPlaybackDrained, onPlaybackUnavailable}) {
      final f = _FakeAudio(playbackGate: gate);
      fakes.add(f);
      return f;
    };

    final starting = state.startVoice();
    await Future<void>.delayed(Duration.zero);
    final toggled = state.toggleVoice(); // second tap on the mic button
    gate.complete();
    await starting;
    await toggled;

    expect(state.voiceActive, isFalse,
        reason: 'a tap during startup must be a cancel, not a no-op start');
    expect(fakes.single.capturing, isFalse);
  });
}
