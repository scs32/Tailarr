import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules/voice/core/pcm_playback_queue.dart';

/// Unit tests for the streamed-PCM jitter buffer — the pure buffering/scheduling
/// logic behind the "speaks in chunks" fix. No audio device: the back-pressured
/// device sink is stubbed so pre-roll, ordering, gaplessness, per-turn re-arm and
/// barge-in are all deterministically checkable.
void main() {
  /// A stub device sink that records every frame it is handed, in order, and
  /// (optionally) applies back-pressure by not completing until released.
  Uint8List concat(List<Uint8List> frames) {
    final b = BytesBuilder();
    for (final f in frames) {
      b.add(f);
    }
    return b.takeBytes();
  }

  Uint8List ramp(int start, int len) =>
      Uint8List.fromList([for (var i = 0; i < len; i++) (start + i) & 0xff]);

  group('pre-roll gating', () {
    test('nothing is fed until the pre-roll threshold is reached', () async {
      final fed = <Uint8List>[];
      final q = PcmPlaybackQueue(
        feed: (f) async => fed.add(f),
        preRollBytes: 100,
        frameBytes: 1000, // one frame, so ordering is trivial
      );

      q.add(ramp(0, 40));
      q.add(ramp(40, 40));
      await Future<void>.delayed(Duration.zero);
      expect(fed, isEmpty, reason: 'below pre-roll: hold');
      expect(q.isFlowing, isFalse);
      expect(q.bufferedBytes, 80);

      q.add(ramp(80, 40)); // now 120 >= 100
      await Future<void>.delayed(Duration.zero);
      expect(q.isFlowing, isTrue);
      // Everything buffered so far is flushed, in arrival order, byte-exact.
      expect(concat(fed), equals(ramp(0, 120)));
    });

    test('once flowing, later chunks pass straight through in order', () async {
      final fed = <Uint8List>[];
      final q = PcmPlaybackQueue(
        feed: (f) async => fed.add(f),
        preRollBytes: 10,
        frameBytes: 1000,
      );
      q.add(ramp(0, 10)); // reaches pre-roll, flushes
      await Future<void>.delayed(Duration.zero);
      q.add(ramp(10, 5));
      q.add(ramp(15, 5));
      await Future<void>.delayed(Duration.zero);
      expect(concat(fed), equals(ramp(0, 20)));
    });
  });

  group('framing / gaplessness', () {
    test('output is sliced into frameBytes-sized frames, losing no bytes',
        () async {
      final fed = <Uint8List>[];
      final q = PcmPlaybackQueue(
        feed: (f) async => fed.add(f),
        preRollBytes: 250,
        frameBytes: 100,
      );
      q.add(ramp(0, 250)); // hits pre-roll -> flush of 250 bytes
      await Future<void>.delayed(Duration.zero);
      expect(fed.length, 3, reason: '250 / 100 -> 100,100,50');
      expect(fed.map((f) => f.length).toList(), [100, 100, 50]);
      expect(concat(fed), equals(ramp(0, 250)));
    });
  });

  group('back-pressure', () {
    test('feeds are serialized: no new feed starts before the prior completes',
        () async {
      var inFlight = 0;
      var maxConcurrent = 0;
      final completers = <Completer<void>>[];
      final q = PcmPlaybackQueue(
        feed: (f) async {
          inFlight++;
          maxConcurrent = inFlight > maxConcurrent ? inFlight : maxConcurrent;
          final c = Completer<void>();
          completers.add(c);
          await c.future;
          inFlight--;
        },
        preRollBytes: 10,
        frameBytes: 10,
      );

      q.add(ramp(0, 50)); // 5 frames queued behind back-pressure
      await Future<void>.delayed(Duration.zero);
      // Only the first frame is in flight; the rest wait.
      expect(maxConcurrent, 1);
      // Release them one at a time; concurrency never exceeds 1.
      while (completers.isNotEmpty) {
        completers.removeAt(0).complete();
        await Future<void>.delayed(Duration.zero);
        expect(inFlight, lessThanOrEqualTo(1));
      }
      expect(maxConcurrent, 1);
    });
  });

  group('per-turn re-arm', () {
    test('endTurn flushes a reply shorter than the pre-roll', () async {
      final fed = <Uint8List>[];
      final q = PcmPlaybackQueue(
        feed: (f) async => fed.add(f),
        preRollBytes: 1000,
        frameBytes: 1000,
      );
      q.add(ramp(0, 30)); // well under pre-roll -> held
      await Future<void>.delayed(Duration.zero);
      expect(fed, isEmpty);

      q.endTurn(); // short utterance must still play
      await Future<void>.delayed(Duration.zero);
      expect(concat(fed), equals(ramp(0, 30)));
    });

    test('after endTurn the next turn re-accumulates the pre-roll', () async {
      final fed = <Uint8List>[];
      final q = PcmPlaybackQueue(
        feed: (f) async => fed.add(f),
        preRollBytes: 50,
        frameBytes: 1000,
      );
      q.add(ramp(0, 50)); // turn 1 reaches pre-roll
      await Future<void>.delayed(Duration.zero);
      q.endTurn();
      await Future<void>.delayed(Duration.zero);
      expect(q.isFlowing, isFalse, reason: 'pre-roll re-armed for next turn');
      fed.clear();

      q.add(ramp(0, 20)); // turn 2 below pre-roll again -> held
      await Future<void>.delayed(Duration.zero);
      expect(fed, isEmpty);
    });
  });

  group('barge-in / reset', () {
    test('reset drops queued audio and re-arms the pre-roll', () async {
      final fed = <Uint8List>[];
      final q = PcmPlaybackQueue(
        feed: (f) async => fed.add(f),
        preRollBytes: 1000,
        frameBytes: 1000,
      );
      q.add(ramp(0, 40)); // held below pre-roll
      q.reset();
      await Future<void>.delayed(Duration.zero);
      expect(fed, isEmpty, reason: 'abandoned-turn audio is dropped');
      expect(q.bufferedBytes, 0);
      expect(q.isFlowing, isFalse);
    });

    test('reset mid-drain stops feeding the stale turn', () async {
      final fed = <Uint8List>[];
      final gate = <Completer<void>>[];
      final q = PcmPlaybackQueue(
        feed: (f) async {
          fed.add(f);
          final c = Completer<void>();
          gate.add(c);
          await c.future;
        },
        preRollBytes: 10,
        frameBytes: 10,
      );
      q.add(ramp(0, 50)); // 5 frames; first is in flight, 4 pending
      await Future<void>.delayed(Duration.zero);
      expect(fed.length, 1);

      q.reset(); // barge-in while draining
      gate.removeAt(0).complete(); // let the in-flight feed finish
      await Future<void>.delayed(Duration.zero);
      // The 4 pending frames of the abandoned turn are NOT fed.
      expect(fed.length, 1);
    });
  });

  group('close', () {
    test('after close, add is a no-op', () async {
      final fed = <Uint8List>[];
      final q = PcmPlaybackQueue(
        feed: (f) async => fed.add(f),
        preRollBytes: 1,
        frameBytes: 10,
      );
      q.close();
      q.add(ramp(0, 100));
      await Future<void>.delayed(Duration.zero);
      expect(fed, isEmpty);
    });
  });
}
