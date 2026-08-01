import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules/voice/core/pcm_playback_queue.dart';

/// Unit tests for the streamed-PCM jitter buffer — the pure buffering/scheduling
/// logic behind the "speaks in chunks" fix, plus the teardown / error / turn /
/// latency / memory boundaries surfaced in review. No audio device: the
/// back-pressured device sink is stubbed so every path is deterministic.
void main() {
  // Yield enough event-loop turns for the (async, one-frame-at-a-time) drain to
  // make progress. Each feed await suspends, so multi-frame drains need several.
  Future<void> pump([int times = 30]) async {
    for (var i = 0; i < times; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Uint8List concat(List<Uint8List> frames) {
    final b = BytesBuilder();
    for (final f in frames) {
      b.add(f);
    }
    return b.takeBytes();
  }

  Uint8List ramp(int start, int len) =>
      Uint8List.fromList([for (var i = 0; i < len; i++) (start + i) & 0xff]);

  // Track queues so we always cancel timers / unpark drains after each test.
  final live = <PcmPlaybackQueue>[];
  PcmPlaybackQueue make({
    required Future<void> Function(Uint8List) feed,
    int? preRollBytes,
    int? frameBytes,
    int? maxBufferedBytes,
    Duration maxPreRoll = const Duration(minutes: 10), // effectively off
    Duration feedRetryDelay = const Duration(minutes: 10), // effectively off
    void Function()? onDrained,
    void Function(int)? onOverflow,
    void Function()? onFeedError,
  }) {
    final q = PcmPlaybackQueue(
      feed: feed,
      preRollBytes: preRollBytes,
      frameBytes: frameBytes,
      maxBufferedBytes: maxBufferedBytes,
      maxPreRoll: maxPreRoll,
      feedRetryDelay: feedRetryDelay,
      onDrained: onDrained,
      onOverflow: onOverflow,
      onFeedError: onFeedError,
    );
    live.add(q);
    return q;
  }

  tearDown(() {
    for (final q in live) {
      q.close();
    }
    live.clear();
  });

  group('pre-roll gating', () {
    test('nothing is fed until the pre-roll threshold is reached', () async {
      final fed = <Uint8List>[];
      final q = make(
          feed: (f) async => fed.add(f), preRollBytes: 100, frameBytes: 1000);

      q.add(ramp(0, 40));
      q.add(ramp(40, 40));
      await pump();
      expect(fed, isEmpty, reason: 'below pre-roll: hold');
      expect(q.isFlowing, isFalse);
      expect(q.bufferedBytes, 80);

      q.add(ramp(80, 40)); // now 120 >= 100
      await pump();
      expect(q.isFlowing, isTrue);
      expect(concat(fed), equals(ramp(0, 120)));
    });

    test('once flowing, later chunks pass straight through in order', () async {
      final fed = <Uint8List>[];
      final q =
          make(feed: (f) async => fed.add(f), preRollBytes: 10, frameBytes: 1000);
      q.add(ramp(0, 10));
      await pump();
      q.add(ramp(10, 6));
      q.add(ramp(16, 4));
      await pump();
      expect(concat(fed), equals(ramp(0, 20)));
    });
  });

  group('framing / gaplessness', () {
    test('output is sliced into frameBytes-sized frames, losing no bytes',
        () async {
      final fed = <Uint8List>[];
      final q =
          make(feed: (f) async => fed.add(f), preRollBytes: 250, frameBytes: 100);
      q.add(ramp(0, 250));
      await pump();
      expect(fed.map((f) => f.length).toList(), [100, 100, 50]);
      expect(concat(fed), equals(ramp(0, 250)));
    });
  });

  group('back-pressure', () {
    test('feeds are serialized: concurrency never exceeds 1', () async {
      var inFlight = 0;
      var maxConcurrent = 0;
      final gates = <Completer<void>>[];
      final q = make(
        feed: (f) async {
          inFlight++;
          maxConcurrent = inFlight > maxConcurrent ? inFlight : maxConcurrent;
          final c = Completer<void>();
          gates.add(c);
          await c.future;
          inFlight--;
        },
        preRollBytes: 10,
        frameBytes: 10,
      );

      q.add(ramp(0, 50)); // 5 frames behind back-pressure
      await pump();
      expect(maxConcurrent, 1);
      while (gates.isNotEmpty) {
        gates.removeAt(0).complete();
        await pump();
        expect(inFlight, lessThanOrEqualTo(1));
      }
      expect(maxConcurrent, 1);
    });
  });

  group('F1 — barge-in must never wedge the drain', () {
    test('a feed parked on the ring buffer is unparked by reset; next turn plays',
        () async {
      final fed = <Uint8List>[];
      var calls = 0;
      Completer<void>? parked;
      final q = make(
        feed: (f) async {
          calls++;
          fed.add(f);
          if (calls == 1) {
            parked = Completer<void>();
            await parked!.future; // never completes — mimics flutter_sound wedge
          }
        },
        preRollBytes: 10,
        frameBytes: 10,
      );

      q.add(ramp(0, 10)); // turn 1: first frame fed, then parked
      await pump();
      expect(fed.length, 1);

      q.reset(); // barge-in while the feed is parked
      await pump();

      // Turn 2 must still play — the drain is NOT wedged.
      q.add(ramp(100, 10));
      await pump();
      expect(fed.length, 2);
      expect(fed.last, equals(ramp(100, 10)));
      expect(q.bufferedBytes, 0);

      parked?.complete(); // tidy the leaked future
    });
  });

  group('feed exception must not drop the tail', () {
    test('a throwing feed re-queues its frame; the rest of the tail survives',
        () async {
      final fed = <Uint8List>[];
      var calls = 0;
      var errors = 0;
      final q = make(
        feed: (f) async {
          calls++;
          if (calls == 1) throw StateError('device busy');
          fed.add(f);
        },
        preRollBytes: 10,
        frameBytes: 10,
        onFeedError: () => errors++,
      );

      q.add(ramp(0, 50)); // first frame throws
      await pump();
      expect(errors, 1);
      expect(fed, isEmpty, reason: 'the failing frame was NOT delivered');
      expect(q.bufferedBytes, 50, reason: 'nothing dropped — all 50 preserved');

      q.add(ramp(50, 10)); // re-kicks the drain; feeds now succeed
      await pump();
      expect(concat(fed), equals(ramp(0, 60)),
          reason: 'byte-exact, in order, no hole from the earlier exception');
    });
  });

  group('F3 — endTurn is a real boundary', () {
    test('audio arriving after endTurn re-accumulates the pre-roll (not swept)',
        () async {
      final fed = <Uint8List>[];
      var calls = 0;
      Completer<void>? parked;
      final q = make(
        feed: (f) async {
          calls++;
          fed.add(f);
          if (calls == 1) {
            parked = Completer<void>();
            await parked!.future; // hold turn N's frame in flight
          }
        },
        preRollBytes: 100,
        frameBytes: 100,
      );

      q.add(ramp(0, 100)); // turn N reaches pre-roll; frame parked
      await pump();
      expect(fed.length, 1);

      q.endTurn(); // boundary while N's frame is still draining
      q.add(ramp(200, 50)); // turn N+1 audio, below pre-roll
      await pump();
      expect(q.isFlowing, isFalse, reason: 'N+1 was NOT swept into passthrough');

      parked?.complete(); // let N's frame finish
      await pump();
      expect(fed.length, 1, reason: 'N+1 held: still below its own pre-roll');

      q.add(ramp(250, 50)); // N+1 now reaches pre-roll
      await pump();
      expect(concat(fed.sublist(1)), equals(ramp(200, 100)));
    });
  });

  group('per-turn re-arm + drained signal', () {
    test('endTurn flushes a reply shorter than the pre-roll and signals drained',
        () async {
      final fed = <Uint8List>[];
      var drained = 0;
      final q = make(
        feed: (f) async => fed.add(f),
        preRollBytes: 1000,
        frameBytes: 1000,
        onDrained: () => drained++,
      );
      q.add(ramp(0, 30)); // under pre-roll -> held
      await pump();
      expect(fed, isEmpty);
      expect(drained, 0);

      q.endTurn();
      await pump();
      expect(concat(fed), equals(ramp(0, 30)));
      expect(drained, 1, reason: 'drained fires once the tail reaches the device');
    });

    test('after endTurn the next turn re-accumulates the pre-roll', () async {
      final fed = <Uint8List>[];
      final q =
          make(feed: (f) async => fed.add(f), preRollBytes: 50, frameBytes: 1000);
      q.add(ramp(0, 50));
      await pump();
      q.endTurn();
      await pump();
      expect(q.isFlowing, isFalse);
      fed.clear();

      q.add(ramp(0, 20)); // below pre-roll again
      await pump();
      expect(fed, isEmpty);
    });
  });

  group('NEW-1 — odd-total turn does not leak the flush boundary', () {
    test('the next turn still pre-rolls normally after an odd-total turn',
        () async {
      final fed = <Uint8List>[];
      var drained = 0;
      final q = make(
        feed: (f) async => fed.add(f),
        preRollBytes: 100, // turn N stays below this -> flushed by endTurn
        frameBytes: 10,
        onDrained: () => drained++,
      );

      // Turn N: an ODD total (31 bytes) -> a lone carry-byte is left over.
      q.add(ramp(0, 31));
      await pump();
      q.endTurn();
      await pump();
      expect(drained, 1);
      expect(concat(fed), equals(ramp(0, 30)),
          reason: 'even prefix played; the odd carry-byte is dropped as drained');
      fed.clear();

      // Turn N+1: enough to meet the pre-roll. If _flushBytes leaked (==1), the
      // pre-roll branch would be skipped forever and this would stay silent.
      q.add(ramp(100, 200));
      await pump();
      expect(q.isFlowing, isTrue, reason: 'boundary was not leaked');
      expect(concat(fed), equals(ramp(100, 200)));
    });
  });

  group('NEW-2 — feed error on the LAST frame is retried', () {
    test('a throwing final frame still plays and signals drained (no new add)',
        () async {
      final fed = <Uint8List>[];
      var calls = 0;
      var drained = 0;
      final q = make(
        feed: (f) async {
          calls++;
          if (calls == 2) throw StateError('device busy'); // the final frame
          fed.add(f);
        },
        preRollBytes: 1000, // never flows on its own -> endTurn flushes
        frameBytes: 10,
        feedRetryDelay: const Duration(milliseconds: 20),
        onDrained: () => drained++,
      );

      q.add(ramp(0, 20)); // two 10-byte frames
      await pump();
      q.endTurn(); // no further add() will come to re-kick the drain
      await pump();
      expect(fed.length, 1, reason: 'first frame played; the last one threw');
      expect(drained, 0);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      await pump();
      expect(concat(fed), equals(ramp(0, 20)),
          reason: 'the retry replayed the failed last frame');
      expect(drained, 1, reason: 'drained fires after the retry succeeds');
    });
  });

  group('C — wall-clock pre-roll ceiling', () {
    test('a short reply plays after maxPreRoll even without endTurn', () async {
      final fed = <Uint8List>[];
      final q = make(
        feed: (f) async => fed.add(f),
        preRollBytes: 10000, // never reached
        frameBytes: 1000,
        maxPreRoll: const Duration(milliseconds: 30),
      );
      q.add(ramp(0, 40));
      await pump();
      expect(fed, isEmpty, reason: 'still within the pre-roll window');

      await Future<void>.delayed(const Duration(milliseconds: 60));
      await pump();
      expect(concat(fed), equals(ramp(0, 40)),
          reason: 'wall-clock ceiling forced playback');
    });
  });

  group('codex#4 — drained fires at the turn boundary, not FIFO emptiness', () {
    test('turn-1 drained fires before turn-2 audio is fed', () async {
      final fed = <Uint8List>[];
      var calls = 0;
      var drainedCount = 0;
      var drainedAtLen = -1;
      Completer<void>? parked;
      final q = make(
        feed: (f) async {
          calls++;
          fed.add(f);
          if (calls == 1) {
            parked = Completer<void>();
            await parked!.future; // hold turn-1's only frame in flight
          }
        },
        preRollBytes: 20,
        frameBytes: 20,
        onDrained: () {
          drainedCount++;
          drainedAtLen = fed.length;
        },
      );

      q.add(ramp(0, 20)); // turn 1 -> flowing; frame 1 goes in-flight (parked)
      await pump();
      q.endTurn(); // turn-1 boundary while its frame is still in flight
      q.add(ramp(100, 40)); // turn-2 audio arrives BEFORE turn 1 drains
      await pump();
      expect(drainedCount, 0, reason: 'turn-1 frame not yet accepted');

      parked!.complete(); // turn-1's frame is accepted
      await pump();
      expect(drainedCount, 1);
      expect(drainedAtLen, 1,
          reason: 'fired at the turn-1 boundary, before any turn-2 frame');
      expect(fed.length, greaterThan(1), reason: 'turn 2 then keeps playing');
    });
  });

  group('codex#5 — the memory cap is HARD', () {
    test('a chunk larger than remaining capacity is prefix-accepted', () async {
      final dropped = <int>[];
      Completer<void>? parked;
      final q = make(
        feed: (f) async {
          parked ??= Completer<void>();
          await parked!.future; // stall after the first frame goes in-flight
        },
        preRollBytes: 40,
        frameBytes: 20,
        maxBufferedBytes: 100,
        onOverflow: dropped.add,
      );

      q.add(ramp(0, 40)); // -> flowing; first 20-byte frame in-flight (parked)
      await pump(2);
      q.add(ramp(40, 50)); // remaining 60 -> full accept; buffered 20+50=70
      await pump(2);
      q.add(ramp(90, 30)); // remaining 10 (incl. in-flight 20) -> keep 10, drop 20
      await pump(2);
      q.add(ramp(120, 50)); // remaining 0 -> drop all 50
      await pump(2);
      expect(q.bufferedBytes, 80, reason: '70 + a 10-byte prefix');
      expect(dropped, [20, 50]);

      parked?.complete();
    });
  });

  group('C — bounded memory', () {
    test('a stalled feed cannot grow the buffer past maxBufferedBytes', () async {
      final dropped = <int>[];
      Completer<void>? parked;
      final q = make(
        feed: (f) async {
          parked ??= Completer<void>();
          await parked!.future; // stall forever after the first frame
        },
        preRollBytes: 20,
        frameBytes: 20,
        maxBufferedBytes: 100,
        onOverflow: dropped.add,
      );

      for (var i = 0; i < 10; i++) {
        q.add(ramp(i * 20, 20)); // 200 bytes offered; feed is stalled
        await pump(2);
      }
      expect(q.bufferedBytes, lessThanOrEqualTo(100));
      expect(dropped, isNotEmpty, reason: 'excess was dropped, not buffered');

      parked?.complete();
    });
  });

  group('barge-in / reset', () {
    test('reset drops queued audio and re-arms the pre-roll', () async {
      final fed = <Uint8List>[];
      final q = make(
          feed: (f) async => fed.add(f), preRollBytes: 1000, frameBytes: 1000);
      q.add(ramp(0, 40));
      q.reset();
      await pump();
      expect(fed, isEmpty);
      expect(q.bufferedBytes, 0);
      expect(q.isFlowing, isFalse);
    });
  });

  group('odd-length safety', () {
    test('odd chunks never yield an odd frame and lose no bytes', () async {
      final fed = <Uint8List>[];
      final q =
          make(feed: (f) async => fed.add(f), preRollBytes: 4, frameBytes: 4);
      q.add(ramp(0, 5)); // odd
      await pump();
      q.add(ramp(5, 5)); // odd; carry-byte merges across the boundary
      await pump();
      for (final f in fed) {
        expect(f.length.isEven, isTrue,
            reason: 'flutter_sound rejects odd frames');
      }
      expect(concat(fed), equals(ramp(0, 10)), reason: 'no byte lost');
    });
  });

  group('close', () {
    test('after close, add is a no-op', () async {
      final fed = <Uint8List>[];
      final q =
          make(feed: (f) async => fed.add(f), preRollBytes: 1, frameBytes: 10);
      q.close();
      q.add(ramp(0, 100));
      await pump();
      expect(fed, isEmpty);
    });
  });
}
