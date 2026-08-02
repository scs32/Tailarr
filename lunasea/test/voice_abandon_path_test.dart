import 'dart:async';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules/voice/core/state.dart';
import 'package:lunasea/modules/voice/core/voice_audio_io.dart';
import 'package:lunasea/modules/voice/core/voice_credentials.dart';
import 'package:lunasea/modules/voice/core/voice_session.dart';

/// THE ABANDON PATH — the schedule six rounds of tests never ran.
///
/// Dart futures cannot be cancelled: `.timeout()` abandons the AWAIT, not the
/// WORK. Every bounded await therefore leaves an orphan that is still running
/// and can still (a) publish a result, (b) mutate shared state, or (c) apply a
/// process-wide platform side effect — after its generation was superseded.
///
/// The suite kept passing over exactly this because every test either released
/// its gate UNDER the configured bound (so the abandon path never ran at all)
/// or bypassed the operation under test entirely (`debugSetConnected` skips
/// `ensureConnected`, so the first bounded await was never exercised).
///
/// So every test here follows one rule, and it is the rule the codebase was
/// missing:
///
///   1. hold the gate PAST the bound, and assert the world moved on;
///   2. THEN release it, and assert the orphan's completion changed nothing.
///
/// Assertions taken only after step 1 prove nothing about an orphan.
/// A REAL [VoiceAudioIO] — session arbiter, player lane and all — with only the
/// two mic entry points stubbed, because `permission_handler` and `record` are
/// unmocked platform channels in a unit test.
///
/// This matters: the existing state-level tests swap the whole class out for a
/// fake, so the session-ownership machinery — the entire B2 fix — was never
/// executed by any state-level test. Here it is.
class _TestableIO extends VoiceAudioIO {
  _TestableIO({
    required super.openPlayerStream,
    required super.closePlayerStream,
    required super.feedPlayerStream,
    required super.interruptionEvents,
    required super.setSessionActive,
  });

  @override
  Future<bool> ensureMicPermission() async => true;

  @override
  Future<bool> isMicPermanentlyDenied() async => false;

  @override
  Future<void> captureInto(void Function(Uint8List pcm16) onChunk) async {}

  /// Production `startPlayback()` configures the shared session first; its
  /// seam branch returns before doing so. Restore the real ordering, or the
  /// test never exercises session ownership at all.
  @override
  Future<void> startPlayback() async {
    await configureSession();
    await super.startPlayback();
  }
}

/// An instance that hangs inside `configureSession()` BEFORE it ever reaches
/// the session arbiter — the production shape being `session.configure(...)`
/// or the platform `AudioSession.instance` hop not returning.
///
/// This is the hang point that makes a zombie claim reachable: because the
/// instance never submitted its claim, a newer instance's claim is submitted
/// and lands FIRST, and the old one's claim arrives afterwards — from an
/// instance that has already been disposed.
class _LateConfigureIO extends _TestableIO {
  _LateConfigureIO({
    required this.gate,
    required super.openPlayerStream,
    required super.closePlayerStream,
    required super.feedPlayerStream,
    required super.interruptionEvents,
    required super.setSessionActive,
  });

  final Future<void> gate;

  @override
  Future<void> configureSession() async {
    await gate;
    await super.configureSession();
  }
}

/// An instance whose microphone stream arrives late, so `captureInto`'s
/// publication point is exercised without the `record` platform channel.
/// Extends [VoiceAudioIO] directly, NOT `_TestableIO`, because the real
/// `captureInto` is the code under test here.
class _LateMicIO extends VoiceAudioIO {
  _LateMicIO({
    required this.gate,
    required super.openPlayerStream,
    required super.closePlayerStream,
    required super.feedPlayerStream,
    required super.interruptionEvents,
    required super.setSessionActive,
  });

  final Future<void> gate;

  @override
  Future<Stream<Uint8List>> startCapture() async {
    await gate;
    return const Stream<Uint8List>.empty();
  }
}

/// An instance whose `dispose()` parks — exactly what `_disposeBounded`
/// abandons when a teardown outruns `startupTimeout`. The park is placed
/// BEFORE `super.dispose()`, so when it is finally released the REAL
/// `stop()` runs and reaches the REAL session release, late.
class _GatedIO extends _TestableIO {
  _GatedIO({
    required this.gate,
    required super.openPlayerStream,
    required super.closePlayerStream,
    required super.feedPlayerStream,
    required super.interruptionEvents,
    required super.setSessionActive,
  });

  final Future<void> gate;

  @override
  Future<void> dispose() async {
    await gate;
    await super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // --- B1: the connection is an operation that owns its own bound ---------

  group('B1: a timed-out connect must leave voice RETRYABLE', () {
    VoiceAssistantState hungConnectState({
      required Completer<VoiceCredentialResult> gate,
      required List<String> fetches,
    }) {
      final state = VoiceAssistantState();
      state.startupTimeout = const Duration(milliseconds: 60);
      state.credentialFetcher = () {
        fetches.add('fetch');
        return gate.future;
      };
      return state;
    }

    test('a hung ensureConnected() does not block every later retry', () async {
      final fetches = <String>[];
      // Never answers: the credential broker simply does not come back.
      final gate = Completer<VoiceCredentialResult>();
      final state = hungConnectState(gate: gate, fetches: fetches);

      await state.startVoice();

      // Step 1: the bound has passed and the world must have moved on.
      expect(state.status, isNot(VoiceConnectionStatus.connecting),
          reason: 'ensureConnected() sets `connecting` BEFORE its risky await. '
              'If the abandon path does not restore it, every retry hits the '
              '`connecting` early-return and voice is dead until app restart');

      // The actual user-visible proof: a second tap really tries again.
      await state.startVoice();
      expect(fetches.length, 2,
          reason: 'the retry must reach the credential fetch again — a lane '
              'that is free but a status that is stuck is still a wedge');
    });

    test('a timed-out startup tells the user something', () async {
      final state = hungConnectState(
          gate: Completer<VoiceCredentialResult>(), fetches: <String>[]);

      await state.startVoice();

      expect(
        state.messages.any((m) => m.isError),
        isTrue,
        reason: 'on the exact failure this machinery exists for, the user was '
            'told nothing and the orb just quietly stopped',
      );
    });

    test('an abandoned connect cannot publish its result LATE', () async {
      final gate = Completer<VoiceCredentialResult>();
      final state = hungConnectState(gate: gate, fetches: <String>[]);

      await state.startVoice();
      expect(state.status, isNot(VoiceConnectionStatus.connecting));

      // A newer generation establishes the real truth.
      state.debugSetConnected(VoiceSession(
        apiKey: 'test-key',
        mcpUrl: 'https://example.invalid/mcp',
        mcpToken: 'test-token',
      ));
      expect(state.status, VoiceConnectionStatus.ready);

      // Step 2: NOW the orphan finally answers.
      gate.complete(VoiceCredentialResult.fail(
        VoiceUnavailableReason.noBadge,
        'AI access is not enabled for this device.',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(state.status, VoiceConnectionStatus.ready,
          reason: 'the abandoned attempt was superseded; publishing its own '
              'outcome now overwrites the live generation');
      expect(state.unavailableReason, isNull,
          reason: 'a superseded attempt must mutate no shared state at all');
    });

    test('reset() invalidates an in-flight connect', () async {
      final gate = Completer<VoiceCredentialResult>();
      final state = hungConnectState(gate: gate, fetches: <String>[]);
      state.startupTimeout = const Duration(seconds: 30); // outlive the reset

      unawaited(state.startVoice());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(state.status, VoiceConnectionStatus.connecting);

      state.reset();
      gate.complete(VoiceCredentialResult.fail(
        VoiceUnavailableReason.noBadge,
        'AI access is not enabled for this device.',
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(state.status, VoiceConnectionStatus.idle,
          reason: 'a connect parked across a reset() must publish nothing '
              'into the state the reset just cleared');
      expect(state.messages, isEmpty);
    });
  });

  // --- B2: the shared AVAudioSession has exactly one owner ----------------

  group('B2: a superseded instance can never touch the shared session', () {
    VoiceAudioIO makeIO(String name, List<String> log,
            {Future<void> Function(bool active)? setActive}) =>
        VoiceAudioIO(
          openPlayerStream: () async {},
          closePlayerStream: () async {},
          feedPlayerStream: (f) async {},
          interruptionEvents: const Stream<AudioInterruptionEvent>.empty(),
          setSessionActive: setActive ??
              (active) async => log.add('$name:setActive($active)'),
        )..teardownTimeout = const Duration(milliseconds: 40);

    test(
        'an old teardown deactivating WHILE a new instance activates cannot '
        'deafen the new one', () async {
      final log = <String>[];
      final activateGate = Completer<void>();

      final a = makeIO('old', log);
      await a.configureSession();

      // The new instance parks INSIDE setActive(true) — the window in which
      // the old instance's ownership check used to still pass, because the
      // claim only landed once the platform activation RETURNED.
      final b = makeIO('new', log, setActive: (active) async {
        log.add('new:setActive($active)');
        if (active) await activateGate.future;
      });
      final bConfigure = b.configureSession();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // The old instance's abandoned teardown finally runs, right here.
      final aStop = a.stop();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      activateGate.complete();
      await bConfigure;
      await aStop;

      expect(log, isNot(contains('old:setActive(false)')),
          reason: 'the old instance deactivated the process-wide session '
              'after the new one had already activated it — the live lane is '
              'now silently deaf');

      // ...and ownership genuinely transferred, so the session is still
      // released when the real owner is done. A guard that over-skips would
      // leave every other app ducked forever.
      await b.stop();
      expect(log.last, 'new:setActive(false)');
    });

    test('a ZOMBIE startup cannot steal ownership from the live instance',
        () async {
      // The nastiest shape: instance A hangs inside its own activation, is
      // abandoned and DISPOSED, a fresh instance B goes live — and only then
      // does A's platform call answer. If A claims ownership at that point it
      // is a disposed instance holding the newest epoch, and its teardown then
      // lawfully deactivates the session out from under live B.
      final log = <String>[];
      final configureGate = Completer<void>();

      // A hangs BEFORE it ever submits its ownership claim, so the claim it
      // eventually makes arrives after the live instance's.
      final a = _LateConfigureIO(
        gate: configureGate.future,
        openPlayerStream: () async {},
        closePlayerStream: () async {},
        feedPlayerStream: (f) async {},
        interruptionEvents: const Stream<AudioInterruptionEvent>.empty(),
        setSessionActive: (active) async =>
            log.add('zombie:setActive($active)'),
      )..teardownTimeout = const Duration(milliseconds: 40);
      unawaited(a.configureSession());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Abandoned and torn down while its configure is still airborne.
      await a.dispose();

      final b = makeIO('live', log);
      await b.configureSession();

      // Step 2: the zombie's configure finally answers and reaches the arbiter.
      configureGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await a.dispose(); // the onLate teardown, exactly as state.dart runs it

      await b.stop();
      expect(log.where((l) => l == 'live:setActive(false)').length, 1,
          reason: 'the live instance must still own — and therefore release — '
              'the shared session; if the zombie stole the epoch, the live '
              'instance skips its own deactivation and the session leaks');
      expect(log.indexOf('live:setActive(false)'), log.length - 1,
          reason: 'nothing may touch the shared session after the live '
              "instance's own release");
    });

    test('a microphone that arrives after stop() is never opened', () async {
      // captureInto() publishes `_micSub` AFTER an await that state.dart
      // BOUNDS. A late completion used to open a LIVE MIC on a dead instance —
      // the one orphan side effect a user would actually notice.
      final micGate = Completer<void>();
      final io = _LateMicIO(
        gate: micGate.future,
        openPlayerStream: () async {},
        closePlayerStream: () async {},
        feedPlayerStream: (f) async {},
        interruptionEvents: const Stream<AudioInterruptionEvent>.empty(),
        setSessionActive: (active) async {},
      )..teardownTimeout = const Duration(milliseconds: 40);

      final capture = io.captureInto((_) {});
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Step 1: the instance is torn down while the mic is still airborne.
      await io.stop();

      // Step 2: the microphone finally arrives.
      micGate.complete();
      await capture;

      expect(io.isCapturing, isFalse,
          reason: 'the platform answered after stop(); subscribing now opens a '
              'live microphone on an instance nobody owns');
    });
  });

  // --- B2 end-to-end, through the state layer -----------------------------

  group('B2 end-to-end: disposal abandoned by state.dart', () {
    test(
        'an old disposal that EXCEEDS the bound cannot deactivate the '
        "replacement's session", () async {
      final log = <String>[];
      final disposeGate = Completer<void>();
      var built = 0;

      final state = VoiceAssistantState();
      // The bound the disposal must exceed.
      state.startupTimeout = const Duration(milliseconds: 60);
      state.debugSetConnected(VoiceSession(
        apiKey: 'test-key',
        mcpUrl: 'https://example.invalid/mcp',
        mcpToken: 'test-token',
      ));

      state.audioFactory = ({onPlaybackDrained, onPlaybackUnavailable}) {
        final name = built++ == 0 ? 'old' : 'new';
        Future<void> setActive(bool active) async =>
            log.add('$name:setActive($active)');
        // The FIRST instance's dispose() parks far past state.dart's 60ms
        // bound, so `_disposeBounded` genuinely ABANDONS it — the path the N3
        // ordering test never reached, because it released under the bound.
        if (name == 'old') {
          return _GatedIO(
            gate: disposeGate.future,
            openPlayerStream: () async {},
            closePlayerStream: () async {},
            feedPlayerStream: (f) async {},
            interruptionEvents: const Stream<AudioInterruptionEvent>.empty(),
            setSessionActive: setActive,
          )..teardownTimeout = const Duration(milliseconds: 40);
        }
        return _TestableIO(
          openPlayerStream: () async {},
          closePlayerStream: () async {},
          feedPlayerStream: (f) async {},
          interruptionEvents: const Stream<AudioInterruptionEvent>.empty(),
          setSessionActive: setActive,
        )..teardownTimeout = const Duration(milliseconds: 40);
      };

      await state.startVoice();
      expect(state.voiceActive, isTrue);

      // Tear down and immediately bring up a replacement. The old disposal is
      // still parked in its native close.
      state.reset();
      state.debugSetConnected(VoiceSession(
        apiKey: 'test-key',
        mcpUrl: 'https://example.invalid/mcp',
        mcpToken: 'test-token',
      ));
      await state.startVoice();

      // Step 1: the replacement is live and the old disposal is STILL running.
      expect(log, contains('new:setActive(true)'));
      expect(log, isNot(contains('old:setActive(false)')));

      // Step 2: only now does the abandoned disposal complete.
      disposeGate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(log, isNot(contains('old:setActive(false)')),
          reason: 'this is the whole of B2: serializing until a timeout does '
              'NOT serialize the eventual platform side effect. The old '
              "teardown must be INERT, not merely late");
      expect(log.last, 'new:setActive(true)',
          reason: 'the live instance must still hold an ACTIVE session after '
              'the old teardown finally lands');
    });
  });
}
