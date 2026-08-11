import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:lunasea/database/box.dart';
import 'package:lunasea/database/models/log.dart';
import 'package:lunasea/modules/voice/core/voice_audio_io.dart';
import 'package:lunasea/types/log_type.dart';

/// Voice teardown must be INFALLIBLE.
///
/// ## The defect this locks
///
/// `VoiceAudioIO.stop()` had three unguarded awaits — `stopCapture()`,
/// `closePlayer()` and the audio-session `setActive(false)` (only
/// `stopPlayer()` was caught). Every one is a plugin call made against an audio
/// stack iOS has just torn down, which is exactly the state where they throw.
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
/// failure was **completely silent**, and left the single worst state
/// available: `_status` still `ready` over a dead socket, `ensureConnected()`
/// early-returning forever, and the next mic tap capturing into a session that
/// no longer exists.
///
/// ## Why there are no fakes, and why that is the point
///
/// The recorder and player are `late final` real plugin objects with no
/// injection seam. None is needed: **a plain unit test IS the hostile
/// environment.** With no platform channels registered, `_recorder.isRecording()`
/// raises `MissingPluginException` — a faithful stand-in for the on-device
/// failure rather than a fake that re-implements the logic under test. So this
/// asserts on the SHIPPED body; the harness stubs the TRANSPORT, never the
/// decision.
///
/// ## ⚠️ The second assertion is the one that matters
///
/// "Does not throw" is satisfiable by a fix that swallows everything and tells
/// nobody — which would be a different silent failure, not a fix. So each test
/// also asserts the failure was REPORTED, against the real log records.
///
/// ## RED proof (this suite cannot be run locally — `dart` hangs on the
/// maintainer's machine, so the contrast comes from CI)
///
/// Two false reds were rejected before the real one:
///   1. no `TestWidgetsFlutterBinding` → died at `ServicesBinding.instance`
///      ("Binding has not yet been initialized") before any plugin call, which
///      fails identically with and without the fix;
///   2. no Hive `logs` box → `_teardownStep`'s own `LunaLogger` write raised
///      `HiveError: Box not found` asynchronously out of `LunaBox.create`,
///      which no try/catch at the call site can absorb. That is a harness gap,
///      not a product defect — same finding as `tailnet_link_dispatch_test`.
/// The genuine red was
/// `MissingPluginException(No implementation found for method create on channel
/// com.llfbandit.record/messages)`, 3 failures, no other test file affected.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('VoiceAudioIO teardown is infallible', () {
    late Directory dir;
    late List<String> recordCalls;

    /// The `record` plugin's method channel.
    ///
    /// ⚠️ WHY THIS IS STUBBED AT ALL, given the whole point is "no fakes".
    /// `AudioRecorder()`'s CONSTRUCTOR fires an unawaited `create` through its
    /// own semaphore. Off-device that rejects with `MissingPluginException`
    /// LATER, as an unhandled async error, outside any call chain the code
    /// under test owns — so `_teardownStep` structurally cannot catch it and
    /// the test dies for a reason that has nothing to do with the guard. That
    /// was the third false RED this gate produced.
    ///
    /// ⚠️ THE STUB IS THE TRANSPORT, NEVER THE LOGIC — and it is deliberately
    /// DANGEROUS where the kernel is: `create` succeeds so construction works,
    /// and EVERY other method throws, which is precisely the on-device
    /// condition (a plugin call against an audio stack iOS has torn down).
    /// Nothing here re-implements a decision `VoiceAudioIO` makes.
    const recordChannel = MethodChannel('com.llfbandit.record/messages');

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('tailarr_voice_teardown');
      Hive.init(dir.path);
      if (!Hive.isAdapterRegistered(23)) Hive.registerAdapter(LunaLogAdapter());
      if (!Hive.isAdapterRegistered(24)) {
        Hive.registerAdapter(LunaLogTypeAdapter());
      }
      await Hive.openBox<LunaLog>(LunaBox.logs.key);

      recordCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(recordChannel, (call) async {
        recordCalls.add(call.method);
        if (call.method == 'create') return null;
        throw PlatformException(
          code: 'AUDIO_STACK_GONE',
          message: 'the audio stack was torn down underneath us',
        );
      });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(recordChannel, null);
      await Hive.close();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    /// `LunaLogger` fires `LunaBox.logs.create` WITHOUT awaiting it, so let the
    /// write settle. Polls only while EMPTY, so a path that logs nothing waits
    /// the full budget and then fails its expectation — this cannot manufacture
    /// a pass in either direction.
    Future<List<LunaLog>> settledLogs() async {
      for (var i = 0; i < 50 && LunaBox.logs.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      return LunaBox.logs.data.toList();
    }

    test('stop() completes even when every plugin call throws', () async {
      final io = VoiceAudioIO();
      await expectLater(io.stop(), completes);

      // THE CALL WAS ACTUALLY MADE. Without this the test passes just as well
      // against a stop() that reaches no plugin at all — a guard proven against
      // a body that never runs is the first defect shape, not a gate.
      expect(recordCalls, contains('isRecording'),
          reason: 'stop() never reached the recorder, so nothing was guarded');

      // ...AND THE FAILURE WAS REPORTED. A teardown that swallows silently is
      // the defect wearing a different hat: "does not throw" is satisfied by a
      // fix that absorbs everything and tells nobody.
      final logs = await settledLogs();
      expect(logs.any((l) => l.message.contains('Voice teardown step failed')),
          isTrue,
          reason: 'teardown absorbed a plugin failure without reporting it');
    });

    test('stop() is idempotent — a second teardown also cannot throw', () async {
      final io = VoiceAudioIO();
      await expectLater(io.stop(), completes);
      // The real second-call path: a lifecycle teardown racing an explicit
      // stop. `_sessionConfigured` has already been cleared, so this covers
      // cleanup running against state it has itself dismantled.
      await expectLater(io.stop(), completes);
    });

    test(
        'stopCapture() alone is infallible — it is the first step, and the one '
        'that aborted the rest', () async {
      final io = VoiceAudioIO();
      // The original failure ordering: `stopCapture()` is the FIRST statement
      // in stop(), so its throw skipped the player close, the session release
      // AND the caller's `_dropSession`. Locking it directly means a refactor
      // that reorders stop() cannot quietly re-expose it.
      await expectLater(io.stopCapture(), completes);
      expect(await settledLogs(), isNotEmpty);
    });
  });
}
