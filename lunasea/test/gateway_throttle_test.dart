import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/system/gateway/gateway_host.dart';

/// Locks the gateway self-config throttle behaviour that caused the
/// "it doesn't seem to be autoconfiguring" bug: a FAILED dial (node not up
/// yet) must only hold for the short cooldown, never the long interval, so a
/// cold-launch race recovers on the next foreground/reconnect.
void main() {
  final now = DateTime(2026, 7, 26, 12, 0, 0);
  const reached = Duration(minutes: 15);
  const cooled = Duration(seconds: 30);

  bool throttled({DateTime? lastReached, DateTime? lastFailure}) =>
      gatewaySyncThrottled(
        lastReached: lastReached,
        lastFailure: lastFailure,
        now: now,
        reached: reached,
        cooled: cooled,
      );

  group('gatewaySyncThrottled', () {
    test('fresh state never throttles', () {
      expect(throttled(), isFalse);
    });

    test('a recent SUCCESS holds for the long interval', () {
      expect(throttled(lastReached: now.subtract(const Duration(minutes: 5))),
          isTrue);
    });

    test('an old success no longer throttles', () {
      expect(throttled(lastReached: now.subtract(const Duration(minutes: 16))),
          isFalse);
    });

    test('THE FIX: a failure only holds for the short cooldown, not 15 min', () {
      // 1 minute after a failed dial — old code armed the 15-min throttle here
      // and stranded the device at "Request Access". It must retry now.
      expect(throttled(lastFailure: now.subtract(const Duration(minutes: 1))),
          isFalse);
    });

    test('a very recent failure is briefly cooled down (no hammering)', () {
      expect(throttled(lastFailure: now.subtract(const Duration(seconds: 10))),
          isTrue);
    });

    test('a live success wins even with an old failure on record', () {
      expect(
        throttled(
          lastReached: now.subtract(const Duration(minutes: 2)),
          lastFailure: now.subtract(const Duration(hours: 1)),
        ),
        isTrue,
      );
    });
  });
}
