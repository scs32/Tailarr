import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/modules/voice/core/gemini_live_client.dart';
import 'package:lunasea/modules/voice/core/state.dart';

/// The three independently-sufficient causes of "voice stops working COMPLETELY
/// after an app resume". Two of them are testable here; the third
/// (`RecordConfig.audioInterruption`) is a native `record_ios` behaviour and is
/// covered by voice_record_config_test.dart reading the wire map.
void main() {
  group('voiceLifecycleActionFor', () {
    test('does nothing at all when the voice lane is not active', () {
      for (final s in AppLifecycleState.values) {
        expect(
          voiceLifecycleActionFor(
            state: s,
            voiceActive: false,
            suspendedWhileActive: false,
          ),
          VoiceLifecycleAction.none,
          reason: '$s with voice off',
        );
      }
    });

    test('backgrounding a live lane records the suspension', () {
      for (final s in [
        AppLifecycleState.paused,
        AppLifecycleState.detached,
        AppLifecycleState.hidden,
      ]) {
        expect(
          voiceLifecycleActionFor(
            state: s,
            voiceActive: true,
            suspendedWhileActive: false,
          ),
          VoiceLifecycleAction.markSuspended,
          reason: '$s should mark suspended',
        );
      }
    });

    test('inactive is NOT a suspension', () {
      // App switcher / Control Centre / a call banner do not tear the audio
      // stack down. Treating them as a suspension would kill voice constantly.
      expect(
        voiceLifecycleActionFor(
          state: AppLifecycleState.inactive,
          voiceActive: true,
          suspendedWhileActive: false,
        ),
        VoiceLifecycleAction.none,
      );
    });

    test('resuming AFTER a suspension tears the lane down', () {
      expect(
        voiceLifecycleActionFor(
          state: AppLifecycleState.resumed,
          voiceActive: true,
          suspendedWhileActive: true,
        ),
        VoiceLifecycleAction.teardown,
      );
    });

    test('resuming WITHOUT a suspension does nothing', () {
      // e.g. returning from an `inactive` blip. Nothing was torn down, so
      // nothing should be.
      expect(
        voiceLifecycleActionFor(
          state: AppLifecycleState.resumed,
          voiceActive: true,
          suspendedWhileActive: false,
        ),
        VoiceLifecycleAction.none,
      );
    });
  });

  group('GeminiLiveClient post-setup close', () {
    Future<GeminiLiveClient> connected() async {
      final client = GeminiLiveClient(
        apiKey: 'x',
        onToolCall: (_) async => [],
        outboundSink: [],
      );
      await client.ingestFrameForTest('{"setupComplete":{}}');
      return client;
    }

    test('an unexpected close is OBSERVABLE (it used to be silent)', () async {
      final client = await connected();
      final seen = <String>[];
      client.closed.listen(seen.add);
      client.simulateDoneForTest();
      await Future<void>.delayed(Duration.zero);
      expect(seen, hasLength(1),
          reason: 'a socket that dies after setup must announce itself; '
              'silence here is what left the UI "ready" over a dead socket');
    });

    test('an intentional close() does NOT report a disconnect', () async {
      final client = await connected();
      final seen = <String>[];
      client.closed.listen(seen.add);
      await client.close();
      client.simulateDoneForTest();
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty);
    });
  });
}
