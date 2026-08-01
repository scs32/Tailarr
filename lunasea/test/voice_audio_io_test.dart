import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules/voice/core/voice_audio_io.dart';

/// codex#7 regression: feedPlayback must report whether the chunk was ACCEPTED,
/// so the caller only flips the orb to `speaking` for audio that will actually
/// play. Before playback is started (and during a barge-in flush) the player is
/// not ready, so a chunk is rejected and must NOT be reported as accepted —
/// otherwise an interrupted server frame that also carries audio would strand
/// the orb in `speaking` with no drain callback to restore `listening`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('feedPlayback returns false when the player is not ready', () {
    final io = VoiceAudioIO();
    expect(io.feedPlayback(Uint8List(320)), isFalse);
  });
}
