import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

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
