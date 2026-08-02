import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:audio_session/audio_session.dart';

import 'package:lunasea/modules/voice/core/voice_audio_io.dart';

/// N1: the player LIFECYCLE must have exactly ONE serialized owner.
///
/// The M4 lazy-recovery work added `_recovering`, which serializes recovery
/// against OTHER recoveries only. It does not serialize against
/// [VoiceAudioIO.flushPlayback], [VoiceAudioIO.stop] or
/// [VoiceAudioIO.dispose], so three races were reachable:
///
///   1. a second interruption flushes while a recovery is parked in open/close
///      -> BOTH close and reopen the same native flutter_sound stream;
///   2. one path sets `_playerReady = true` while the other is tearing the
///      stream down -> frames are admitted into a stream being destroyed;
///   3. a recovery that finishes AFTER stop()/dispose() logically RESURRECTS a
///      disposed player.
///
/// These tests park the injected device stream mid-operation, which is the only
/// way to observe the overlap. They are written from the FAILURE (a concurrent
/// second open; a feedable player after stop) rather than from the fix, so they
/// stay meaningful if the implementation shape changes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List pcm(int n) => Uint8List(n);

  /// Let every queued microtask/timer-free continuation run.
  Future<void> settle([int turns = 8]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// A [VoiceAudioIO] whose device stream is a fake that can be PARKED, so a
  /// test can hold one lifecycle operation open and drive another into it.
  ({
    VoiceAudioIO io,
    List<String> ops,
    void Function(bool) failOpen,
    void Function(Completer<void>?) parkOpen,
    void Function(Completer<void>?) parkClose,
    int Function() maxConcurrentOpen,
    int Function() maxConcurrentAny,
    int Function() unavailable,
  }) makeIO() {
    final ops = <String>[];
    var shouldFailOpen = false;
    var unavailable = 0;
    Completer<void>? openGate;
    Completer<void>? closeGate;
    var openInFlight = 0;
    var maxOpen = 0;
    var anyInFlight = 0;
    var maxAny = 0;

    void enter(bool isOpen) {
      anyInFlight++;
      if (anyInFlight > maxAny) maxAny = anyInFlight;
      if (isOpen) {
        openInFlight++;
        if (openInFlight > maxOpen) maxOpen = openInFlight;
      }
    }

    void leave(bool isOpen) {
      anyInFlight--;
      if (isOpen) openInFlight--;
    }

    final io = VoiceAudioIO(
      onPlaybackUnavailable: () => unavailable++,
      openPlayerStream: () async {
        ops.add('open');
        enter(true);
        try {
          final gate = openGate;
          if (gate != null) await gate.future;
          if (shouldFailOpen) throw StateError('device refused to open');
        } finally {
          leave(true);
        }
      },
      closePlayerStream: () async {
        ops.add('close');
        enter(false);
        try {
          final gate = closeGate;
          if (gate != null) await gate.future;
        } finally {
          leave(false);
        }
      },
      feedPlayerStream: (f) async {},
    );
    // Terminal teardown must not wait on a parked platform call; keep the bound
    // short so these tests assert the ABANDON path rather than sit on it.
    io.teardownTimeout = const Duration(milliseconds: 20);

    return (
      io: io,
      ops: ops,
      failOpen: (v) => shouldFailOpen = v,
      parkOpen: (c) => openGate = c,
      parkClose: (c) => closeGate = c,
      maxConcurrentOpen: () => maxOpen,
      maxConcurrentAny: () => maxAny,
      unavailable: () => unavailable,
    );
  }

  /// Drive the instance into the "restart failed, recovery is pending" state
  /// that [VoiceAudioIO.feedPlayback] and `endPlaybackTurn` lazily recover from.
  Future<void> breakThePlayer(dynamic t) async {
    await t.io.startPlayback();
    t.failOpen(true);
    await t.io.flushPlayback();
    t.failOpen(false);
  }

  interruptionTests();
  sharedSessionTests();

  group('N1: one serialized owner of the player lifecycle', () {
    test('a flush during an in-flight recovery must not double-open the stream',
        () async {
      final t = makeIO();
      await breakThePlayer(t);

      // Park the reopen so the recovery is demonstrably still in flight.
      final gate = Completer<void>();
      t.parkOpen(gate);
      t.io.feedPlayback(pcm(320)); // kicks the lazy recovery
      await settle();

      // A second interruption (phone call / AirPods yanked) lands mid-recovery.
      final flushing = t.io.flushPlayback();
      await settle();

      gate.complete();
      t.parkOpen(null);
      await flushing;
      await settle();

      expect(t.maxConcurrentOpen(), 1,
          reason: 'flush and recovery must never both be opening the same '
              'native stream — flutter_sound keeps ONE mutable needSomeFood '
              'completer, so two live opens desync playback');
      expect(t.maxConcurrentAny(), 1,
          reason: 'the whole lifecycle (open AND close) needs one lane, not '
              'a second independent in-flight flag');
    });

    test('a recovery finishing after stop() must not resurrect the player',
        () async {
      final t = makeIO();
      await breakThePlayer(t);

      final gate = Completer<void>();
      t.parkOpen(gate);
      t.io.feedPlayback(pcm(320)); // recovery parks inside open()
      await settle();

      await t.io.stop(); // the lane is terminal from here

      gate.complete(); // the platform finally answers the ABANDONED recovery
      t.parkOpen(null);
      await settle();

      expect(t.io.feedPlayback(pcm(320)), isFalse,
          reason: 'a stopped player must stay stopped: a late recovery must '
              'not flip _playerReady back on and admit frames into a stream '
              'that was already torn down');
    });

    test('a recovery finishing after dispose() must not resurrect the player',
        () async {
      final t = makeIO();
      await breakThePlayer(t);

      final gate = Completer<void>();
      t.parkOpen(gate);
      t.io.endPlaybackTurn(); // the other lazy-recovery entry point
      await settle();

      await t.io.dispose();

      gate.complete();
      t.parkOpen(null);
      await settle();

      expect(t.io.feedPlayback(pcm(320)), isFalse,
          reason: 'dispose() is terminal for the instance');
    });

    test('stop() during an in-flight flush does not overlap the device calls',
        () async {
      final t = makeIO();
      await t.io.startPlayback();

      final gate = Completer<void>();
      t.parkClose(gate);
      final flushing = t.io.flushPlayback(); // parks inside close()
      await settle();

      final stopping = t.io.stop();
      await settle();

      gate.complete();
      t.parkClose(null);
      await flushing;
      await stopping;
      await settle();

      expect(t.maxConcurrentAny(), 1,
          reason: 'stop() must queue behind the flush, not race it');
      expect(t.io.feedPlayback(pcm(320)), isFalse,
          reason: 'the flush must not re-arm a player that stop() ended');
    });

    test('a flush after stop() cannot bring the player back', () async {
      final t = makeIO();
      await t.io.startPlayback();
      await t.io.stop();

      await t.io.flushPlayback();

      expect(t.io.feedPlayback(pcm(320)), isFalse,
          reason: 'nothing may reopen a terminated instance');
    });
  });
}

/// M6 left the interruption + route-change SUBSCRIPTIONS with no coverage at
/// all, even though they are the paths that fire `flushPlayback()` concurrently
/// with everything else — i.e. the exact second actor in the N1 race. These use
/// injected event streams so the RESPONSE is testable without an AVAudioSession.
void interruptionTests() {
  Uint8List pcm(int n) => Uint8List(n);

  Future<void> settle([int turns = 8]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  ({
    VoiceAudioIO io,
    List<String> ops,
    StreamController<AudioInterruptionEvent> interruptions,
    StreamController<void> noisy,
  }) makeIO() {
    final ops = <String>[];
    final interruptions = StreamController<AudioInterruptionEvent>.broadcast();
    final noisy = StreamController<void>.broadcast();
    final io = VoiceAudioIO(
      openPlayerStream: () async => ops.add('open'),
      closePlayerStream: () async => ops.add('close'),
      feedPlayerStream: (f) async {},
      interruptionEvents: interruptions.stream,
      becomingNoisyEvents: noisy.stream,
    );
    io.teardownTimeout = const Duration(milliseconds: 20);
    return (io: io, ops: ops, interruptions: interruptions, noisy: noisy);
  }

  group('M6: interruption + route-change subscriptions', () {
    test('an interruption BEGIN rebuilds the output stream', () async {
      final t = makeIO();
      await t.io.configureSession();
      await t.io.startPlayback();
      expect(t.ops, equals(['open']));

      t.interruptions.add(AudioInterruptionEvent(
          true, AudioInterruptionType.pause)); // incoming phone call
      await settle();

      expect(t.ops, equals(['open', 'close', 'open']),
          reason: 'an interruption must rebuild the native stream — merely '
              'dropping the Dart buffer leaves the drain parked in feed()');
      expect(t.io.feedPlayback(pcm(320)), isTrue,
          reason: 'playback is usable again for the NEXT turn');
    });

    test('an interruption END must NOT resume a stale stream', () async {
      final t = makeIO();
      await t.io.configureSession();
      await t.io.startPlayback();

      t.interruptions
          .add(AudioInterruptionEvent(false, AudioInterruptionType.pause));
      await settle();

      expect(t.ops, equals(['open']),
          reason: "the interrupted turn's audio is gone and Gemini will speak "
              'again; silently resuming a stale stream is worse than waiting');
    });

    test('a becoming-noisy route change rebuilds the stream', () async {
      final t = makeIO();
      await t.io.configureSession();
      await t.io.startPlayback();

      t.noisy.add(null); // AirPods yanked; iOS reroutes to the speaker
      await settle();

      expect(t.ops, equals(['open', 'close', 'open']));
    });

    test('a burst of interruptions never overlaps the device calls', () async {
      final t = makeIO();
      await t.io.configureSession();
      await t.io.startPlayback();

      // Interruption + route change land together — the real N1 second actor.
      for (var i = 0; i < 5; i++) {
        t.interruptions
            .add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
        t.noisy.add(null);
      }
      await settle(20);

      // Every rebuild is a well-formed close/open pair in order: no interleave.
      final rest = t.ops.skip(1).toList();
      expect(rest.length.isEven, isTrue, reason: 'ops=$rest');
      for (var i = 0; i < rest.length; i += 2) {
        expect(rest[i], 'close', reason: 'ops=$rest');
        expect(rest[i + 1], 'open', reason: 'ops=$rest');
      }
      expect(t.io.feedPlayback(pcm(320)), isTrue);
    });

    test('after stop(), a late interruption must not reopen the stream',
        () async {
      final t = makeIO();
      await t.io.configureSession();
      await t.io.startPlayback();
      await t.io.stop();
      final after = t.ops.length;

      t.interruptions
          .add(AudioInterruptionEvent(true, AudioInterruptionType.pause));
      t.noisy.add(null);
      await settle();

      expect(t.ops.length, after,
          reason: 'stop() cancels the subscriptions, and the lane is terminal: '
              'a late event must not resurrect the player');
      expect(t.io.feedPlayback(pcm(320)), isFalse);
    });
  });
}

/// Codex re-review: the player lane serializes ONE instance. `setActive()` on
/// the AVAudioSession is PROCESS-WIDE, so its ordering across instances is not
/// something any per-instance lane can fix.
///
/// This matters because teardown is deliberately bounded (teardownTimeout, and
/// state.dart's _disposeBounded). Bounding it is what stops the N2 permanent
/// wedge — but an abandoned `stop()` is still ALIVE, and could later reach
/// `setActive(false)` after a NEW instance had already activated the session,
/// silently deafening the live lane. Written from that failure.
void sharedSessionTests() {
  ({VoiceAudioIO io, List<String> log}) makeIO(String name, List<String> log) {
    final io = VoiceAudioIO(
      openPlayerStream: () async {},
      closePlayerStream: () async {},
      feedPlayerStream: (f) async {},
      interruptionEvents: const Stream<AudioInterruptionEvent>.empty(),
      setSessionActive: (active) async => log.add('$name:setActive($active)'),
    );
    io.teardownTimeout = const Duration(milliseconds: 20);
    return (io: io, log: log);
  }

  group('process-wide AVAudioSession ownership', () {
    test('a superseded instance must not deactivate the shared session',
        () async {
      final log = <String>[];
      final a = makeIO('old', log);
      await a.io.configureSession();

      // A new lane starts before the old one finished tearing down — exactly
      // what an abandoned, timed-out teardown leaves behind.
      final b = makeIO('new', log);
      await b.io.configureSession();

      // The abandoned old teardown finally runs.
      await a.io.stop();

      expect(log, isNot(contains('old:setActive(false)')),
          reason: 'the old instance no longer owns the shared session; '
              'deactivating it here deafens the LIVE instance');
      expect(log, equals(['old:setActive(true)', 'new:setActive(true)']));

      // ...and the current owner still releases it properly.
      await b.io.stop();
      expect(log.last, 'new:setActive(false)',
          reason: 'the CURRENT owner must still hand the session back, or '
              'other apps never regain audio focus');
    });

    test('a single instance still releases the session on stop', () async {
      final log = <String>[];
      final a = makeIO('solo', log);
      await a.io.configureSession();
      await a.io.stop();
      expect(log, equals(['solo:setActive(true)', 'solo:setActive(false)']));
    });

    test('stop() is idempotent and does not double-deactivate', () async {
      final log = <String>[];
      final a = makeIO('solo', log);
      await a.io.configureSession();
      await a.io.stop();
      await a.io.stop();
      await a.io.dispose();
      expect(log.where((l) => l.contains('setActive(false)')).length, 1);
    });
  });
}
