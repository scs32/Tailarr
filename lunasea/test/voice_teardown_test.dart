import 'package:flutter_test/flutter_test.dart';
import 'package:lunasea/modules/voice/core/voice_audio_io.dart';

/// Voice teardown must be INFALLIBLE.
///
/// ## The defect this locks
///
/// `VoiceAudioIO.stop()` had three unguarded awaits — `stopCapture()`,
/// `closePlayer()` and the audio-session `setActive(false)` (only
/// `stopPlayer()` was caught). Every one of those is a plugin call made against
/// an audio stack iOS has just torn down, which is exactly the state where they
/// are most likely to throw.
///
/// That mattered far more than "an exception in cleanup", because of what sits
/// AROUND it. Both call sites in `VoiceAssistantState` are:
///
/// ```dart
/// _enqueueVoiceOp(() async {
///   await _stopVoice();      // throws here…
///   await _dropSession(...); // …so this never runs
/// });
/// ```
///
/// `_enqueueVoiceOp` swallows the rejection to keep the chain progressing
/// (`onError: (_) {}`) and both call sites discard the returned future — so the
/// failure was **completely silent**, and it left the single worst state
/// available: `_status` still `ready` over a dead socket, `ensureConnected()`
/// early-returning forever, and the next mic tap capturing into a session that
/// no longer exists. That is the "dead lane, orb says ready" symptom the resume
/// fix exists to eliminate, reachable through the resume fix's own error path.
///
/// ## Why this test needs no fakes, and why that is the point
///
/// The recorder and player are `late final` real plugin objects — there is no
/// injection seam. There does not need to be: **a plain unit test IS the
/// hostile environment.** With no Flutter platform channels registered,
/// `_recorder.isRecording()` raises `MissingPluginException`, which is a
/// faithful stand-in for the on-device failure (a plugin call that throws
/// during teardown) rather than a fake that re-implements the logic under test.
///
/// ⚠️ So this asserts on the SHIPPED body, not on a re-implementation of it —
/// the harness stubs the TRANSPORT (by having none), never the decision.
///
/// RED without the fix: `stop()` propagates `MissingPluginException` and both
/// tests fail. This was proven through CI, not locally — `dart` hangs on the
/// maintainer's machine, so a local pass or fail here is not evidence either
/// way.
void main() {
  group('VoiceAudioIO teardown is infallible', () {
    test('stop() completes even when every plugin call throws', () async {
      final io = VoiceAudioIO();
      // Must not throw. `expectLater(..., completes)` rather than a bare await
      // so a rejection fails as an assertion instead of as a test-runner error.
      await expectLater(io.stop(), completes);
    });

    test('stop() is idempotent — a second teardown also cannot throw', () async {
      final io = VoiceAudioIO();
      await expectLater(io.stop(), completes);
      // The real second-call path: a lifecycle teardown racing an explicit
      // stop. `_sessionConfigured` has already been cleared, so this covers the
      // branch where cleanup runs against state it has itself dismantled.
      await expectLater(io.stop(), completes);
    });

    test('stopCapture() alone is infallible — it is the first step, and the '
        'one that aborted the rest', () async {
      final io = VoiceAudioIO();
      // The original failure ordering: `stopCapture()` is the FIRST statement in
      // stop(), so its throw skipped the player close, the session release AND
      // the caller's _dropSession. Locking it directly means a future refactor
      // that reorders stop() cannot quietly re-expose it.
      await expectLater(io.stopCapture(), completes);
    });
  });
}
