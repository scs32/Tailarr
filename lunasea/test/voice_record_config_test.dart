import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/modules/voice/core/voice_audio_io.dart';
import 'package:record/record.dart';

/// Two flags in the mic config are load-bearing, invisible, and default to the
/// wrong thing. Both were wrong in build 48 and both are one argument, which is
/// exactly the shape of change that silently regresses. These assert the values
/// that actually cross the platform channel (`toMap()`), not the Dart field.
void main() {
  group('VoiceAudioIO.micConfig', () {
    final wire = VoiceAudioIO.micConfig.toMap();

    test('echoCancel is ON — record_ios will not enable AEC otherwise', () {
      // record_ios calls inputNode.setVoiceProcessingEnabled(config.echoCancel)
      // on EVERY startStream. The AVAudioSession's voiceChat mode does not
      // reach that call. With the package default (false), voice processing is
      // explicitly DISABLED while our output goes to the loudspeaker, the mic
      // hears the speaker, and Gemini's server VAD fires a false barge-in.
      expect(wire['echoCancel'], isTrue);
    });

    test('audioInterruption is pauseResume — the mic must come back', () {
      // record_ios pauses on AVAudioSession interruption `.began` and resumes
      // on `.ended` ONLY in pauseResume. The default `pause` means "resumes
      // MANUALLY", and nothing in this app ever resumed it: an iOS suspension
      // delivers that interruption, so the mic died on the first background.
      expect(
        wire['audioInterruption'],
        AudioInterruptionMode.pauseResume.index,
      );
      expect(
        VoiceAudioIO.micConfig.audioInterruption,
        isNot(AudioInterruptionMode.pause),
      );
    });

    test('still 16kHz mono s16le, and record still does not own the session',
        () {
      expect(wire['sampleRate'], 16000);
      expect(wire['numChannels'], 1);
      expect(wire['encoder'], AudioEncoder.pcm16bits.name);
      expect(
        (wire['iosConfig'] as Map)['manageAudioSession'],
        isFalse,
        reason: 'audio_session owns the AVAudioSession category, not record',
      );
    });
  });
}
