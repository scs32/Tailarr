import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules/voice/core/state.dart';
import 'package:lunasea/modules/voice/core/voice_audio_io.dart';
import 'package:lunasea/modules/voice/core/voice_session.dart';

/// N2 + N3: the voice lane must never be permanently wedged.
///
/// N2 — `_startVoiceBody` awaited `ensureConnected()`, the mic permission,
/// `startPlayback()`, `captureInto()` and the aborted-instance disposal with no
/// timeout, and `_voiceChain` waits on that body. One platform future that
/// never completes therefore blocked EVERY queued stop and retry forever:
/// voice dead until app restart. The generation counter stops a stale
/// publication but cannot release the lane, and the UI flags clear
/// synchronously so nothing even looks hung.
///
/// N3 — `reset()` disposed the audio instance unawaited and OFF the chain, so a
/// later start could activate a new instance while the old teardown was still
/// running `setActive(false)` on the process-wide AVAudioSession.
///
/// These are written from the FAILURE: a stop that never returns, and a new
/// start whose speaker opens before the old instance finished releasing the
/// shared session.
class _FakeAudio implements VoiceAudioIO {
  _FakeAudio({
    required this.log,
    required this.name,
    this.playbackGate,
    this.disposeGate,
  });

  /// Shared, ordered record of the audio lifecycle across ALL instances — the
  /// only way to assert cross-generation ordering.
  final List<String> log;
  final String name;

  /// Parks `startPlayback()` / `dispose()` so a test can act during the window.
  final Completer<void>? playbackGate;
  final Completer<void>? disposeGate;

  bool capturing = false;
  bool disposed = false;

  @override
  Future<bool> ensureMicPermission() async => true;

  @override
  Future<bool> isMicPermanentlyDenied() async => false;

  @override
  Future<void> startPlayback() async {
    log.add('$name:startPlayback');
    if (playbackGate != null) await playbackGate!.future;
    log.add('$name:startPlayback-done');
  }

  @override
  Future<void> captureInto(void Function(Uint8List pcm16) onChunk) async {
    capturing = true; // the mic is LIVE from here
    log.add('$name:capture');
  }

  @override
  Future<void> stopCapture() async => capturing = false;

  @override
  Future<void> stop() async => capturing = false;

  @override
  Future<void> dispose() async {
    log.add('$name:dispose');
    if (disposeGate != null) await disposeGate!.future;
    await stop();
    disposed = true;
    // Stands in for VoiceAudioIO.stop()'s setActive(false) on the shared,
    // process-wide AVAudioSession — the call whose ordering actually matters.
    log.add('$name:dispose-done');
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
    // Keep the bound far below the test timeout so a wedge is a FAILED
    // assertion with a readable message, not an opaque suite timeout.
    state.startupTimeout = const Duration(milliseconds: 60);
    state.debugSetConnected(VoiceSession(
      apiKey: 'test-key',
      mcpUrl: 'https://example.invalid/mcp',
      mcpToken: 'test-token',
    ));
    return state;
  }

  /// Fails with a clear message instead of hanging the suite forever.
  Future<void> mustComplete(Future<void> f, String what) async {
    var done = false;
    unawaited(f.then((_) => done = true, onError: (_) => done = true));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(done, isTrue,
        reason: '$what never completed — the voice lane is permanently '
            'wedged, which is exactly the N2 hard-lock');
  }

  group('N2: a hung startup must not permanently wedge the voice lane', () {
    test('a stop queued behind a startup that NEVER completes still runs',
        () async {
      final state = connectedState();
      final log = <String>[];
      // Never completed: the platform simply does not answer, forever.
      final neverAnswers = Completer<void>();
      final fakes = <_FakeAudio>[];
      state.audioFactory = ({onPlaybackDrained, onPlaybackUnavailable}) {
        final f = _FakeAudio(
            log: log, name: 'a', playbackGate: neverAnswers);
        fakes.add(f);
        return f;
      };

      final starting = state.startVoice();
      await Future<void>.delayed(Duration.zero);
      expect(state.voiceStarting, isTrue);

      final stopping = state.stopVoice();

      await mustComplete(starting, 'the hung startup');
      await mustComplete(stopping, 'the stop queued behind it');

      expect(state.voiceActive, isFalse);
      expect(state.voiceStarting, isFalse,
          reason: 'the startup flag must be released, not stuck true');
      expect(fakes.single.capturing, isFalse,
          reason: 'a startup that timed out before captureInto must never '
              'leave the microphone on');
    });

    test('the lane is REUSABLE after a hung startup: a later start works',
        () async {
      final state = connectedState();
      final log = <String>[];
      final neverAnswers = Completer<void>();
      final fakes = <_FakeAudio>[];
      var n = 0;
      state.audioFactory = ({onPlaybackDrained, onPlaybackUnavailable}) {
        // Only the first startup hangs; the retry must run normally.
        final f = _FakeAudio(
          log: log,
          name: 'gen${n}',
          playbackGate: n++ == 0 ? neverAnswers : null,
        );
        fakes.add(f);
        return f;
      };

      final first = state.startVoice();
      await mustComplete(first, 'the hung startup');

      // The user taps the mic again. This is the whole point: a wedged lane
      // made every retry silently do nothing until the app was restarted.
      final second = state.startVoice();
      await mustComplete(second, 'the retry after a hung startup');

      expect(state.voiceActive, isTrue,
          reason: 'voice must be recoverable without an app restart');
      expect(fakes.last.capturing, isTrue);
    });

    test('a LATE platform completion must not publish or activate the mic',
        () async {
      final state = connectedState();
      final log = <String>[];
      final late_ = Completer<void>();
      final fakes = <_FakeAudio>[];
      state.audioFactory = ({onPlaybackDrained, onPlaybackUnavailable}) {
        final f = _FakeAudio(log: log, name: 'a', playbackGate: late_);
        fakes.add(f);
        return f;
      };

      final starting = state.startVoice();
      await mustComplete(starting, 'the hung startup');
      expect(state.voiceActive, isFalse);

      // The platform finally answers, long after we gave up on it.
      late_.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(state.voiceActive, isFalse,
          reason: 'a late completion must not resurrect a startup the timeout '
              'already invalidated');
      expect(fakes.single.capturing, isFalse,
          reason: 'the abandoned instance must never turn the mic on');
      expect(fakes.single.disposed, isTrue,
          reason: 'the orphan must be torn down once the platform answers, '
              'not left holding the device');
    });
  });

  group('N3: reset() teardown is serialized against a new start', () {
    test('a new start does not activate until the reset teardown has finished',
        () async {
      final state = connectedState();
      final log = <String>[];
      final disposeGate = Completer<void>();
      var n = 0;
      state.audioFactory = ({onPlaybackDrained, onPlaybackUnavailable}) {
        // The FIRST instance's dispose is parked, so a new start has a real
        // window in which to overtake it.
        return _FakeAudio(
          log: log,
          name: 'old',
          disposeGate: n++ == 0 ? disposeGate : null,
        )..name;
      };

      // Bring a first instance fully up so reset() has something to tear down.
      await state.startVoice();
      expect(state.voiceActive, isTrue);

      state.audioFactory = ({onPlaybackDrained, onPlaybackUnavailable}) =>
          _FakeAudio(log: log, name: 'new');

      state.reset(); // off-chain teardown in the unfixed code
      // reset() drops the session too, so re-establish it — this test is about
      // the AUDIO teardown ordering, not about reconnecting.
      state.debugSetConnected(VoiceSession(
        apiKey: 'test-key',
        mcpUrl: 'https://example.invalid/mcp',
        mcpToken: 'test-token',
      ));
      final restart = state.startVoice();

      await Future<void>.delayed(const Duration(milliseconds: 30));
      disposeGate.complete();
      await mustComplete(restart, 'the start after reset');

      final oldDone = log.indexOf('old:dispose-done');
      final newStart = log.indexOf('new:startPlayback');
      expect(oldDone, greaterThanOrEqualTo(0),
          reason: 'reset() must actually tear the old instance down');
      expect(newStart, greaterThanOrEqualTo(0));
      expect(oldDone, lessThan(newStart),
          reason: "reset()'s teardown calls setActive(false) on the "
              'process-wide AVAudioSession; if a new instance configures and '
              'activates first, the old teardown deactivates the session out '
              'from under the live one');
    });

    test('a throwing teardown on reset does not escape as an unhandled error',
        () async {
      final state = connectedState();
      final log = <String>[];
      state.audioFactory = ({onPlaybackDrained, onPlaybackUnavailable}) =>
          _ThrowingAudio(log: log);

      await state.startVoice();
      expect(state.voiceActive, isTrue);

      // reset() used to call dispose() unawaited with no catch, so an async
      // throw became an UNHANDLED zone error nothing could hold.
      state.reset();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(state.voiceActive, isFalse);
    });
  });
}

class _ThrowingAudio extends _FakeAudio {
  _ThrowingAudio({required List<String> log}) : super(log: log, name: 'boom');

  @override
  Future<void> dispose() async {
    log.add('boom:dispose');
    throw StateError('the platform refused to release the audio session');
  }
}
