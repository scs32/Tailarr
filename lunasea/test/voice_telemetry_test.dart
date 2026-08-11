import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/modules/voice/core/state.dart';
import 'package:lunasea/modules/voice/core/voice_audio_io.dart';
import 'package:lunasea/modules/voice/core/voice_audio_probe.dart';

/// The telemetry has to survive contact with a ~50-entry log box, and it has to
/// be honest about what this branch cannot measure. Both are asserted here.
void main() {
  group('flush-cause tagging', () {
    test('every cause is counted separately, not inferred', () {
      final io = VoiceAudioIO();
      io.flushPlayback(cause: VoiceFlushCause.bargeIn);
      io.flushPlayback(cause: VoiceFlushCause.bargeIn);
      io.flushPlayback(cause: VoiceFlushCause.liveError);
      io.flushPlayback(cause: VoiceFlushCause.interruption);

      expect(io.flushes, 4);
      expect(io.flushesByCause[VoiceFlushCause.bargeIn], 2);
      expect(io.flushesByCause[VoiceFlushCause.liveError], 1);
      expect(io.flushesByCause[VoiceFlushCause.interruption], 1);
      expect(io.flushesByCause[VoiceFlushCause.becomingNoisy], isNull);
    });

    test('a flush is counted even when the player is not armed', () {
      // Otherwise the breakdown would silently under-report exactly the case
      // we care about: flushes arriving while playback is already dead.
      final io = VoiceAudioIO();
      expect(io.isPlaybackReady, isFalse);
      io.flushPlayback(cause: VoiceFlushCause.liveError);
      expect(io.flushes, 1);
    });

    test('the default cause is barge-in', () {
      final io = VoiceAudioIO();
      io.flushPlayback();
      expect(io.flushesByCause[VoiceFlushCause.bargeIn], 1);
    });
  });

  group('pcmReport', () {
    test('an empty reply reports zeroes and does not divide by zero', () {
      final io = VoiceAudioIO()..beginReply();
      final line = io.pcmReport();
      expect(line, startsWith('voice/pcm:'));
      expect(line, contains('chunks=0'));
      expect(line, contains('audioMs=0'));
      expect(line, contains('wallMs=0'));
      expect(line, contains('ratio=0.00'));
      expect(line, isNot(contains('NaN')));
      expect(line, isNot(contains('Infinity')));
    });

    test('queue fields are reported n/a, never invented as zero', () {
      // This branch has no PcmPlaybackQueue. Reporting `feedBlockedMs=0` would
      // read as "back-pressure never engaged" when the truth is "there is no
      // back-pressure to engage" — a very different conclusion.
      final line = (VoiceAudioIO()..beginReply()).pcmReport();
      for (final field in [
        'prerollWaits',
        'prerollMs',
        'qEmpty',
        'qMaxMs',
        'feedBlockedMs',
        'overflow',
      ]) {
        expect(line, contains('$field=n/a'), reason: '$field must be n/a');
        expect(line, isNot(contains('$field=0')));
      }
    });

    test('beginReply clears the previous reply window', () {
      final io = VoiceAudioIO();
      io.beginReply();
      expect(io.pcmReport(), contains('chunks=0'));
    });
  });

  group('sessionReportOnce', () {
    test('is null until a player start has produced a probe', () {
      expect(VoiceAudioIO().sessionReportOnce(), isNull);
    });

    test('emits exactly once per session', () {
      final io = VoiceAudioIO()
        ..lastStartProbe = const AudioSessionProbe(
          activated: true,
          sampleRate: 48000,
          outputChannels: 2,
          category: 'AVAudioSessionCategoryPlayAndRecord',
          mode: 'AVAudioSessionModeVoiceChat',
          route: 'Speaker',
        );
      final first = io.sessionReportOnce();
      expect(first, isNotNull);
      expect(first, startsWith('voice/session:'));
      expect(first, contains('hwRate=48000'));
      expect(first, contains('playerRate=24000'));
      // The two flags whose defaults were wrong belong in the session line, so
      // a device log proves what actually shipped rather than what was written.
      expect(first, contains('echoCancel=true'));
      expect(io.sessionReportOnce(), isNull, reason: 'once per session');
    });

    test('reports unobservable platform fields as unavailable', () {
      final io = VoiceAudioIO()
        ..lastStartProbe = const AudioSessionProbe(activated: true);
      expect(io.sessionReportOnce(), contains('hwRate=unavailable'));
    });
  });

  group('diagnostic affordances', () {
    test('playback-only mode is OFF unless explicitly defined', () {
      // It must never be on in a shipping build.
      expect(VoiceAssistantState.playbackOnly, isFalse);
    });
  });
}
