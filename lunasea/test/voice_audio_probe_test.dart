import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/modules/voice/core/voice_audio_probe.dart';

/// The guard that stands between us and the build-48 `EXC_CRASH (SIGABRT)`.
///
/// The crash itself is a native ObjC `NSException` raised by
/// `-[AVAudioEngine connect:to:format:]` inside a precompiled pod — it is not
/// reproducible from a Dart test, and it is not catchable from Dart either.
/// What IS testable, and what these cases lock, is the decision: given a
/// session that is inactive or reporting an impossible rate, the code must
/// REFUSE rather than call `startPlayerFromStream`.
void main() {
  group('playerStartRefusalReason', () {
    test('allows a healthy, active session', () {
      expect(
        playerStartRefusalReason(const AudioSessionProbe(
          activated: true,
          sampleRate: 48000,
          outputChannels: 2,
        )),
        isNull,
      );
    });

    test('refuses when the session could not be activated', () {
      final reason = playerStartRefusalReason(const AudioSessionProbe(
        activated: false,
        sampleRate: 48000,
        outputChannels: 2,
      ));
      expect(reason, isNotNull);
      expect(reason, contains('activat'));
    });

    test('refuses a zero hardware sample rate — the crash precursor', () {
      // sampleRate == 0 is what an INACTIVE AVAudioSession reports, and it is
      // the format value that makes AVAudioEngine.connect raise.
      final reason = playerStartRefusalReason(const AudioSessionProbe(
        activated: true,
        sampleRate: 0,
        outputChannels: 2,
      ));
      expect(reason, isNotNull);
      expect(reason, contains('sample rate'));
    });

    test('refuses an absurdly low or high rate', () {
      for (final rate in <double>[1, 7999.9, 192000.1, 1000000]) {
        expect(
          playerStartRefusalReason(
              AudioSessionProbe(activated: true, sampleRate: rate)),
          isNotNull,
          reason: 'rate $rate should be refused',
        );
      }
    });

    test('accepts the boundary rates', () {
      for (final rate in <double>[
        kMinSaneHardwareRate,
        16000,
        24000,
        44100,
        kMaxSaneHardwareRate,
      ]) {
        expect(
          playerStartRefusalReason(
              AudioSessionProbe(activated: true, sampleRate: rate)),
          isNull,
          reason: 'rate $rate should be allowed',
        );
      }
    });

    test('refuses when the session reports no output channels', () {
      final reason = playerStartRefusalReason(const AudioSessionProbe(
        activated: true,
        sampleRate: 48000,
        outputChannels: 0,
      ));
      expect(reason, isNotNull);
      expect(reason, contains('output'));
    });

    test(
        'an UNOBSERVABLE rate is not treated as zero — non-iOS must still play',
        () {
      // Android/web/tests have no probe channel. Refusing there would break
      // every platform that never had the bug.
      expect(
        playerStartRefusalReason(const AudioSessionProbe(activated: true)),
        isNull,
      );
    });

    test('describe() never fabricates a value for an unobservable field', () {
      final text = const AudioSessionProbe(activated: true).describe();
      expect(text, contains('hwRate=unavailable'));
      expect(text, contains('outCh=unavailable'));
      expect(text, isNot(contains('hwRate=0')));
    });
  });

  group('probeAudioSession', () {
    test('degrades to unobservable (not to a failure) with no platform channel',
        () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final probe = await probeAudioSession(activated: true);
      expect(probe.activated, isTrue);
      expect(probe.sampleRate, isNull);
      expect(playerStartRefusalReason(probe), isNull);
    });
  });
}
