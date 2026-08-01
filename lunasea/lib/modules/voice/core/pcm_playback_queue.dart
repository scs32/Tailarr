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
///   * **Pre-roll** — accumulate [preRollBytes] of audio (bounded by a wall-clock
///     [maxPreRoll] so a short reply / short prefix still plays promptly) before
///     the FIRST frame of a turn is played, so playback starts with a cushion
///     that absorbs the bursty, slower-than-realtime cadence.
///   * **Serialized, awaited, INTERRUPTIBLE feeding** — hand audio to the device
///     one frame at a time through an async [feed] sink that only completes once
///     the bytes are accepted (flutter_sound's `feedUint8FromStream`), so nothing
///     is dropped and we never overrun the native buffer. Each await is raced
///     against a cancel signal so a barge-in teardown can never wedge the drain.
///   * **Per-turn boundary** — [endTurn] flushes exactly this turn's buffered
///     tail (even a reply shorter than the pre-roll) and re-arms the pre-roll so
///     the NEXT turn buffers afresh; audio that arrives after the boundary is not
///     swept into the flush.
///   * **Barge-in** — [reset] drops everything still queued for an abandoned
///     turn and re-arms the pre-roll.
///   * **Bounded memory** — a hard [maxBufferedBytes] cap is the safety net if
///     production ever wildly outpaces playback (only reachable if the device
///     feed stalls); excess is dropped with an [onOverflow] notification rather
///     than growing without bound.
///
/// Pure Dart (no Flutter, no plugins) so the buffering/scheduling logic is unit
/// testable without an audio device; [VoiceAudioIO] wires it to flutter_sound.
library;

import 'dart:async';
import 'dart:collection';
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
    int? maxBufferedBytes,
    this.maxPreRoll = const Duration(milliseconds: 400),
    this.feedRetryDelay = const Duration(milliseconds: 200),
    this.onDrained,
    this.onOverflow,
    this.onFeedError,
  })  : preRollBytes = preRollBytes ?? _msToBytes(300),
        frameBytes = frameBytes ?? _msToBytes(100),
        maxBufferedBytes = maxBufferedBytes ?? _bytesPerSecond * 10 {
    assert(this.preRollBytes > 0);
    assert(this.frameBytes > 0 && this.frameBytes.isEven,
        'frameBytes must be a positive multiple of the 2-byte sample size');
    assert(this.maxBufferedBytes >= this.preRollBytes);
  }

  /// Back-pressured sink: MUST complete only once the device has accepted the
  /// bytes. In production this is `FlutterSoundPlayer.feedUint8FromStream`.
  final Future<void> Function(Uint8List frame) feed;

  /// Jitter-buffer depth: audio accumulated before the first frame of a turn
  /// plays (default ~300ms). Larger = smoother but more latency.
  final int preRollBytes;

  /// Wall-clock ceiling on the pre-roll wait. If the byte threshold is not met
  /// within this window (a short reply, or a short prefix before a long
  /// generation/tool-call pause), playback starts anyway so audio is never held
  /// silent until turnComplete.
  final Duration maxPreRoll;

  /// Target size of each frame handed to [feed] (default ~100ms). Kept even so a
  /// frame boundary never falls in the middle of a 16-bit sample.
  final int frameBytes;

  /// How long to wait before re-kicking the drain after a genuine [feed] failure,
  /// so the turn's LAST frame (which has no later add() to re-kick it) still
  /// plays instead of leaving the tail stuck.
  final Duration feedRetryDelay;

  /// Hard upper bound on retained-but-unfed audio (default ~10s). Safety net for
  /// a stalled device feed; excess incoming audio is dropped, not buffered.
  final int maxBufferedBytes;

  /// Fired (once per turn) when the turn's audio has all been handed to the
  /// device after [endTurn] — the closest signal available in pure Dart to
  /// "finished speaking" (true audible completion is device-only).
  final void Function()? onDrained;

  /// Fired when [maxBufferedBytes] forces incoming audio to be dropped.
  final void Function(int droppedBytes)? onOverflow;

  /// Fired when a [feed] call fails for a reason other than teardown/barge-in.
  final void Function()? onFeedError;

  /// FIFO of un-fed PCM chunks. Frames are taken from the FRONT one at a time and
  /// only removed as they are built into a frame — a failing [feed] re-queues its
  /// frame, so an exception can never drop the rest of the tail.
  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _bufferedBytes = 0;

  /// True once the pre-roll for the CURRENT turn is satisfied, so incoming chunks
  /// flow straight through instead of accumulating.
  bool _flowing = false;

  /// One-shot allowance (bytes) that [endTurn] may feed even though [_flowing] is
  /// false — the boundary that keeps a turn's tail from re-prerolling while the
  /// NEXT turn's audio is held back.
  int _flushBytes = 0;

  /// Size of the frame currently awaiting device acceptance (0 when none). It has
  /// left [_chunks]/[_bufferedBytes] but is still our responsibility (it may be
  /// re-queued on failure), so both the memory cap and the drained-signal
  /// accounting must include it.
  int _inFlightBytes = 0;

  /// Monotonic count of bytes the device has ACCEPTED this session. Paired with
  /// [_drainTarget] it makes the "turn finished playing" signal a cumulative
  /// checkpoint — immune to NEXT-turn audio that arrives before this turn drains.
  int _acceptedBytes = 0;

  /// The [_acceptedBytes] value at which the current turn's audio has all reached
  /// the device (set by [endTurn]).
  int _drainTarget = 0;

  /// Bytes of the current turn that will never be fed (a lone odd carry-byte),
  /// dropped from the front when the turn's boundary is signalled.
  int _turnLeftover = 0;

  bool _draining = false;
  bool _closed = false;
  bool _turnEndPending = false;

  /// Bumped on [reset]/[close] so an in-flight drain of an abandoned turn stops
  /// feeding stale audio the instant a barge-in lands.
  int _epoch = 0;

  /// Completed by [reset]/[close] to unpark a drain awaiting a [feed] that may
  /// never return (flutter_sound's `_stop()` nulls its needSomeFood completer
  /// without completing it — a parked await would otherwise wedge the drain).
  Completer<void> _cancel = Completer<void>();

  Timer? _preRollTimer;
  Timer? _retryTimer;

  /// Bytes currently buffered in Dart (not yet handed to the device). Test seam.
  int get bufferedBytes => _bufferedBytes;

  /// Whether the pre-roll for the current turn has been reached. Test seam.
  bool get isFlowing => _flowing;

  /// Append one chunk of Gemini's output PCM. Held until the pre-roll is met (by
  /// bytes or the wall-clock ceiling), then drained to the device in order.
  void add(Uint8List chunk) {
    if (_closed || chunk.isEmpty) return;
    // HARD cap: compare against remaining capacity (incl. the in-flight frame),
    // so a large chunk can't blow past the cap just because we weren't AT it yet.
    final remaining = maxBufferedBytes - _bufferedBytes - _inFlightBytes;
    if (remaining <= 0) {
      onOverflow?.call(chunk.length);
      return;
    }
    var toAdd = chunk;
    if (chunk.length > remaining) {
      // Accept an even-aligned prefix (keep 16-bit sample alignment); drop the
      // rest. Better graceful degradation than dropping the whole chunk.
      final keep = remaining.isEven ? remaining : remaining - 1;
      if (keep <= 0) {
        onOverflow?.call(chunk.length);
        return;
      }
      toAdd = Uint8List.sublistView(chunk, 0, keep);
      onOverflow?.call(chunk.length - keep);
    }
    _chunks.add(toAdd);
    _bufferedBytes += toAdd.length;
    if (!_flowing && _flushBytes == 0) {
      if (_bufferedBytes >= preRollBytes) {
        _flowing = true;
        _cancelPreRollTimer();
      } else {
        _startPreRollTimer();
      }
    }
    if (_flowing || _flushBytes > 0) unawaited(_drain());
  }

  /// The model turn finished: flush exactly this turn's buffered tail (incl. a
  /// reply shorter than the pre-roll) and re-arm the pre-roll for the next turn.
  void endTurn() {
    if (_closed) return;
    _cancelPreRollTimer();
    // This turn's still-unplayed audio = what's buffered + the in-flight frame.
    // Target the cumulative accepted-byte count at which it will all have reached
    // the device, so the boundary signal is independent of any NEXT-turn audio
    // that arrives before this turn finishes draining (codex#4).
    var pending = _bufferedBytes + _inFlightBytes;
    _turnLeftover = pending.isOdd ? 1 : 0; // a lone carry-byte is never fed
    pending -= _turnLeftover;
    _drainTarget = _acceptedBytes + pending;
    _flushBytes = _bufferedBytes; // feed-gating boundary for the !flowing path
    _flowing = false; // the next turn must re-accumulate the pre-roll
    _turnEndPending = true;
    if (_bufferedBytes > 0) {
      unawaited(_drain());
    }
    _maybeSignalDrained();
  }

  /// Barge-in / hard stop: drop everything queued for the abandoned turn and
  /// re-arm the pre-roll. The caller also restarts the native stream to clear
  /// audio already handed to the device.
  void reset() {
    _epoch++;
    _signalCancel();
    _cancelPreRollTimer();
    _cancelRetryTimer();
    _chunks.clear();
    _bufferedBytes = 0;
    _flowing = false;
    _flushBytes = 0;
    _inFlightBytes = 0;
    _acceptedBytes = 0;
    _drainTarget = 0;
    _turnLeftover = 0;
    _turnEndPending = false;
  }

  void close() {
    _closed = true;
    _epoch++;
    _signalCancel();
    _cancelPreRollTimer();
    _cancelRetryTimer();
    _chunks.clear();
    _bufferedBytes = 0;
    _flowing = false;
    _flushBytes = 0;
    _inFlightBytes = 0;
    _acceptedBytes = 0;
    _drainTarget = 0;
    _turnLeftover = 0;
    _turnEndPending = false;
  }

  void _signalCancel() {
    if (!_cancel.isCompleted) _cancel.complete();
    _cancel = Completer<void>();
  }

  void _startPreRollTimer() {
    _preRollTimer ??= Timer(maxPreRoll, () {
      _preRollTimer = null;
      if (_closed || _flowing || _flushBytes > 0) return;
      if (_bufferedBytes > 0) {
        _flowing = true; // force playback of a short reply / prefix
        unawaited(_drain());
      }
    });
  }

  void _cancelPreRollTimer() {
    _preRollTimer?.cancel();
    _preRollTimer = null;
  }

  /// Re-kick the drain shortly after a feed failure (epoch-guarded) so the turn's
  /// last frame is retried even when no further add() is coming.
  void _scheduleRetry(int forEpoch) {
    _retryTimer?.cancel();
    _retryTimer = Timer(feedRetryDelay, () {
      _retryTimer = null;
      if (_closed || _epoch != forEpoch) return;
      if (_bufferedBytes > 0 && (_flowing || _flushBytes > 0)) {
        unawaited(_drain());
      }
    });
  }

  void _cancelRetryTimer() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    final myEpoch = _epoch;
    final cancel = _cancel;
    try {
      while (!_closed && _epoch == myEpoch) {
        // Re-arm flowing once the flush boundary clears and the pre-roll is met.
        if (!_flowing && _flushBytes == 0 && _bufferedBytes >= preRollBytes) {
          _flowing = true;
          _cancelPreRollTimer();
        }
        final int allowance = _flowing
            ? _bufferedBytes
            : (_flushBytes > 0
                ? (_flushBytes < _bufferedBytes ? _flushBytes : _bufferedBytes)
                : 0);
        if (allowance <= 0 || _bufferedBytes == 0) break;

        final take = allowance < frameBytes ? allowance : frameBytes;
        final frame = _takeFront(take);
        if (frame.isEmpty) break; // only an odd trailing byte remains
        // The frame has left the buffer but is still ours until accepted.
        _inFlightBytes = frame.length;

        final f = feed(frame);
        // A post-cancel throw lands on this abandoned future; swallow it so it
        // never becomes an unhandled async error.
        unawaited(f.catchError((_) {}));
        try {
          await Future.any<void>([f, cancel.future]);
        } catch (_) {
          _inFlightBytes = 0;
          // A genuine feed failure (NOT teardown/barge-in): preserve the frame
          // so the tail is not silently dropped, then stop. Only reachable when
          // the epoch is unchanged.
          if (!_closed && _epoch == myEpoch) {
            _requeueFront(frame);
            onFeedError?.call();
            // A later add() would normally re-kick the drain, but the turn's LAST
            // frame (post-endTurn) has no more adds coming — schedule an
            // epoch-guarded retry so the tail still plays and onDrained fires.
            _scheduleRetry(myEpoch);
          }
          return;
        }
        if (_closed || _epoch != myEpoch) {
          _inFlightBytes = 0; // barge-in / close won the race; frame abandoned
          return;
        }
        // Frame accepted by the device. Decrement the flush allowance (feed
        // gating) and advance the cumulative accepted count (drained signal).
        if (!_flowing) {
          _flushBytes -= frame.length;
          if (_flushBytes < 0) _flushBytes = 0;
        }
        _acceptedBytes += frame.length;
        _inFlightBytes = 0;
        _maybeSignalDrained();
      }
    } finally {
      _draining = false;
    }
    _maybeSignalDrained();
  }

  /// Take up to [n] bytes from the FRONT, splitting a straddling chunk and never
  /// returning an odd-length frame (flutter_sound rejects odd frames — the
  /// trailing byte is carried back to merge with the next chunk).
  Uint8List _takeFront(int n) {
    final out = BytesBuilder(copy: false);
    var need = n;
    while (need > 0 && _chunks.isNotEmpty) {
      final head = _chunks.first;
      if (head.length <= need) {
        out.add(head);
        _chunks.removeFirst();
        _bufferedBytes -= head.length;
        need -= head.length;
      } else {
        out.add(Uint8List.sublistView(head, 0, need));
        _chunks.removeFirst();
        _chunks.addFirst(Uint8List.sublistView(head, need));
        _bufferedBytes -= need;
        need = 0;
      }
    }
    var bytes = out.takeBytes();
    if (bytes.length.isOdd) {
      final last = bytes[bytes.length - 1];
      _chunks.addFirst(Uint8List.fromList([last]));
      _bufferedBytes += 1;
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    return bytes;
  }

  void _requeueFront(Uint8List frame) {
    if (frame.isEmpty) return;
    _chunks.addFirst(frame);
    _bufferedBytes += frame.length;
    // Note: [_flushBytes] is only decremented once a frame is ACCEPTED, so a
    // failed frame's allowance was never consumed — nothing to restore here.
  }

  /// Drop up to [n] bytes from the FRONT (splitting a straddling chunk).
  void _dropFront(int n) {
    var need = n;
    while (need > 0 && _chunks.isNotEmpty) {
      final head = _chunks.first;
      if (head.length <= need) {
        _chunks.removeFirst();
        _bufferedBytes -= head.length;
        need -= head.length;
      } else {
        _chunks.removeFirst();
        _chunks.addFirst(Uint8List.sublistView(head, need));
        _bufferedBytes -= need;
        need = 0;
      }
    }
  }

  void _maybeSignalDrained() {
    // Never signal with a frame still in flight — its bytes are not yet accepted.
    if (!_turnEndPending || _closed || _inFlightBytes > 0) return;
    // Boundary reached when the device has ACCEPTED all of this turn's bytes — a
    // cumulative checkpoint, so NEXT-turn audio already buffered/draining cannot
    // suppress this signal or fire it early (codex#4).
    if (_acceptedBytes >= _drainTarget) {
      // Drop this turn's lone odd carry-byte (excluded from the target) so it
      // can't prepend as a stale sample onto the next turn.
      if (_turnLeftover > 0) {
        _dropFront(_turnLeftover);
        _turnLeftover = 0;
      }
      // Zero the flush allowance too: an ODD-total turn otherwise leaves it stuck
      // at 1, which would make the NEXT turn skip its pre-roll branch forever.
      _flushBytes = 0;
      _turnEndPending = false;
      onDrained?.call();
    }
  }
}
