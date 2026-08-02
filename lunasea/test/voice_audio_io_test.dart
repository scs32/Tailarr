import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules/voice/core/voice_audio_io.dart';

/// Playback-lifecycle tests for [VoiceAudioIO].
///
/// The device stream is injected, so these exercise the REAL state machine
/// (ready / flush / failed-restart / recovery) rather than just poking a
/// never-started player. The round-4 review flagged the previous version of
/// this file as hollow: it asserted only that a fresh instance rejects a chunk,
/// which stays true even with the whole flush path reverted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Uint8List pcm(int n) => Uint8List(n);

  /// A VoiceAudioIO whose device stream is a controllable fake.
  ({
    VoiceAudioIO io,
    List<Uint8List> fed,
    List<String> ops,
    void Function(bool) failOpen,
    void Function(Completer<void>?) parkOpen,
    int Function() unavailable,
  }) makeIO() {
    final fed = <Uint8List>[];
    final ops = <String>[];
    var shouldFailOpen = false;
    var unavailable = 0;
    Completer<void>? openGate;
    final io = VoiceAudioIO(
      onPlaybackUnavailable: () => unavailable++,
      openPlayerStream: () async {
        ops.add('open');
        final gate = openGate;
        if (gate != null) await gate.future;
        if (shouldFailOpen) throw StateError('device refused to open');
      },
      closePlayerStream: () async => ops.add('close'),
      feedPlayerStream: (f) async => fed.add(f),
    );
    io.teardownTimeout = const Duration(milliseconds: 20);
    return (
      io: io,
      fed: fed,
      ops: ops,
      failOpen: (v) => shouldFailOpen = v,
      parkOpen: (c) => openGate = c,
      unavailable: () => unavailable,
    );
  }

  group('playback readiness', () {
    test('a chunk is rejected before playback is started', () {
      final t = makeIO();
      expect(t.io.feedPlayback(pcm(320)), isFalse);
    });

    test('a chunk is accepted once playback is started', () async {
      final t = makeIO();
      await t.io.startPlayback();
      expect(t.io.feedPlayback(pcm(320)), isTrue);
    });
  });

  group('flushPlayback rebuilds the stream (real flush, not a stub)', () {
    test('a successful flush stops and restarts, and stays feedable', () async {
      final t = makeIO();
      await t.io.startPlayback();
      expect(t.ops, equals(['open']));

      await t.io.flushPlayback(); // barge-in
      expect(t.ops, equals(['open', 'close', 'open']),
          reason: 'the native stream must actually be rebuilt (codex#8)');
      expect(t.unavailable(), 0);
      expect(t.io.feedPlayback(pcm(320)), isTrue,
          reason: 'playback is usable again immediately after a flush');
    });
  });

  // M4: a failed restart used to be swallowed by `catch (_) {}` with the comment
  // "next turn re-opens it" — but nothing ever calls startPlayback() again for a
  // live instance, so the session went permanently, silently mute.
  group('a failed player restart is reported and recovered (M4)', () {
    test('the failure is surfaced instead of swallowed', () async {
      final t = makeIO();
      await t.io.startPlayback();

      t.failOpen(true);
      await t.io.flushPlayback();

      expect(t.unavailable(), 1,
          reason: 'a dead output stream must not be silent: no audio, no orb, '
              'no error was the whole bug');
      expect(t.io.feedPlayback(pcm(320)), isFalse);
    });

    test('the next chunk lazily re-opens the stream instead of staying mute',
        () async {
      final t = makeIO();
      await t.io.startPlayback();
      t.failOpen(true);
      await t.io.flushPlayback();
      expect(t.io.feedPlayback(pcm(320)), isFalse);

      // The device comes back (e.g. the interruption ended).
      t.failOpen(false);
      t.io.feedPlayback(pcm(320)); // kicks recovery; this chunk still rejected
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(t.io.feedPlayback(pcm(320)), isTrue,
          reason: 'a transient restart failure must not mute the whole session');
    });

    test('endPlaybackTurn also drives recovery', () async {
      final t = makeIO();
      await t.io.startPlayback();
      t.failOpen(true);
      await t.io.flushPlayback();

      t.failOpen(false);
      t.io.endPlaybackTurn();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(t.io.feedPlayback(pcm(320)), isTrue);
    });

    // This test previously asserted `lessThanOrEqualTo(1)` — which is satisfied
    // by ZERO, so it passed against a build with recovery deleted outright. It
    // guarded nothing. It now parks the reopen so the single attempt is
    // provably IN FLIGHT, and requires EXACTLY one: 0 fails (no recovery) and
    // 20 fails (one attempt per chunk).
    test('recovery is serialized: a burst of chunks makes EXACTLY one attempt',
        () async {
      final t = makeIO();
      await t.io.startPlayback();
      t.failOpen(true);
      await t.io.flushPlayback();
      final opensAfterFailure = t.ops.length;

      // Park the reopen: the recovery cannot complete and quietly re-arm, so
      // every one of the 20 chunks below hits the same "restart failed" state
      // that a real websocket burst would.
      final gate = Completer<void>();
      t.parkOpen(gate);
      t.failOpen(false);

      // A real reply delivers chunks at websocket rate; recovery must not spin.
      for (var i = 0; i < 20; i++) {
        t.io.feedPlayback(pcm(320));
      }
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      final attempts =
          t.ops.skip(opensAfterFailure).where((o) => o == 'open').length;
      expect(attempts, 1,
          reason: 'exactly ONE recovery attempt must be in flight: zero means '
              'the lazy recovery is gone, twenty means it spins once per chunk');

      // ...and the parked attempt is the real thing: releasing it restores
      // playback, so the assertion above is counting a WORKING recovery.
      gate.complete();
      t.parkOpen(null);
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(t.io.feedPlayback(pcm(320)), isTrue);
    });
  });
}
