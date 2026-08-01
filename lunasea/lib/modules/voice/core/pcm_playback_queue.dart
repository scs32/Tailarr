/// Pre-roll jitter buffer + serialized, back-pressured feeder for the streamed
/// 24kHz PCM that Gemini Live sends down the voice websocket.
///
/// ## Why this exists (the "speaks in chunks" bug)
/// Gemini Live generates speech in BURSTS: it emits a run of audio, pauses while
/// it decodes/tool-calls, then emits more. The raw bytes therefore arrive faster
/// than realtime in spurts with gaps between them. The original playback path fed
/// every websocket chunk straight into flutter_sound's `uint8ListSink` — which
/// the plugin documents as the "no flow control" sink. Two failure modes result:
///
///   1. **Underrun gaps.** With no cushion, the speaker drains a chunk to empty
///      before the next burst arrives → audible silence between chunks → the
///      choppy "it speaks in chunks" symptom.
///   2. **Dropped tails.** The fire-and-forget sink never awaits the native ring
///      buffer, so when the device is momentarily full the chunk's tail is
///      silently discarded instead of retried, punching holes in the speech.
///
/// This class fixes both with a classic jitter buffer:
///   * **Pre-roll** — accumulate [preRollBytes] of audio before the FIRST frame
///     of a turn is played, so playback starts with a cushion that absorbs the
///     bursty, slower-than-realtime cadence.
///   * **Serialized, awaited feeding** — hand audio to the device through an
///     async [feed] sink that only completes once the bytes are accepted
///     (flutter_sound's `feedUint8FromStream`), so nothing is ever dropped and we
///     never overrun the native buffer.
///   * **Per-turn re-arm** — [endTurn] flushes a short final utterance and
///     re-arms the pre-roll so the next turn buffers afresh (steady latency).
///   * **Barge-in** — [reset] drops everything still queued for an abandoned
///     turn and re-arms the pre-roll.
///
/// Pure Dart (no Flutter, no plugins) so the buffering/scheduling logic is unit
/// testable without an audio device; [VoiceAudioIO] wires it to flutter_sound.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:lunasea/modules/voice/core/gemini_live_client.dart'
    show kOutputSampleRate;

/// Bytes/second of Gemini's output: 24kHz * 2 bytes (s16le) * 1 channel.
const int _bytesPerSecond = kOutputSampleRate * 2;

int _msToBytes(int ms) {
  // Keep the result even so it never splits a 16-bit sample.
  final b = (_bytesPerSecond * ms) ~/ 1000;
  return b.isEven ? b : b + 1;
}

class PcmPlaybackQueue {
  PcmPlaybackQueue({
    required this.feed,
    int? preRollBytes,
    int? frameBytes,
  })  : preRollBytes = preRollBytes ?? _msToBytes(300),
        frameBytes = frameBytes ?? _msToBytes(100) {
    assert(this.preRollBytes > 0);
    assert(this.frameBytes > 0 && this.frameBytes.isEven,
        'frameBytes must be a positive multiple of the 2-byte sample size');
  }

  /// Back-pressured sink: MUST complete only once the device has accepted the
  /// bytes. In production this is `FlutterSoundPlayer.feedUint8FromStream`.
  final Future<void> Function(Uint8List frame) feed;

  /// Jitter-buffer depth: audio accumulated before the first frame of a turn
  /// plays (default ~300ms). Larger = smoother but more latency.
  final int preRollBytes;

  /// Target size of each frame handed to [feed] (default ~100ms). Kept even so a
  /// frame boundary never falls in the middle of a 16-bit sample.
  final int frameBytes;

  final BytesBuilder _pending = BytesBuilder(copy: false);

  /// True once the pre-roll for the CURRENT turn has been satisfied, so incoming
  /// chunks flow straight through instead of accumulating.
  bool _flowing = false;
  bool _draining = false;
  bool _closed = false;

  /// Bumped on [reset]/[close] so an in-flight drain of an abandoned turn stops
  /// feeding stale audio the instant a barge-in lands.
  int _epoch = 0;

  /// Bytes currently buffered in Dart (not yet handed to the device). Test seam.
  int get bufferedBytes => _pending.length;

  /// Whether the pre-roll for the current turn has been reached. Test seam.
  bool get isFlowing => _flowing;

  /// Append one chunk of Gemini's output PCM. Held until the pre-roll is met,
  /// then drained to the device in order.
  void add(Uint8List chunk) {
    if (_closed || chunk.isEmpty) return;
    _pending.add(chunk);
    if (!_flowing && _pending.length >= preRollBytes) _flowing = true;
    if (_flowing) unawaited(_drain());
  }

  /// The model turn finished: play out whatever is buffered (even a reply
  /// shorter than the pre-roll) and re-arm the pre-roll for the next turn.
  void endTurn() {
    if (_closed) return;
    if (_pending.length > 0) unawaited(_drain());
    // Re-arm: the NEXT turn must re-accumulate the pre-roll cushion. The drain
    // loop is intentionally not gated on `_flowing`, so it still empties.
    _flowing = false;
  }

  /// Barge-in / hard stop: drop everything queued for the abandoned turn and
  /// re-arm the pre-roll. The caller also restarts the native stream to clear
  /// audio already handed to the device.
  void reset() {
    _epoch++;
    _pending.clear();
    _flowing = false;
  }

  void close() {
    _closed = true;
    _epoch++;
    _pending.clear();
    _flowing = false;
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    final myEpoch = _epoch;
    try {
      // Not gated on `_flowing` so endTurn() can flush a sub-pre-roll remainder.
      while (!_closed && _epoch == myEpoch && _pending.length > 0) {
        final bytes = _pending.takeBytes();
        var off = 0;
        while (off < bytes.length && !_closed && _epoch == myEpoch) {
          final end =
              (off + frameBytes < bytes.length) ? off + frameBytes : bytes.length;
          await feed(Uint8List.sublistView(bytes, off, end));
          off = end;
        }
      }
    } catch (_) {
      // A feed failing mid-teardown (player stopped for barge-in / shutdown) is
      // expected; the epoch/closed guards above stop the loop on the next turn.
    } finally {
      _draining = false;
    }
  }
}
