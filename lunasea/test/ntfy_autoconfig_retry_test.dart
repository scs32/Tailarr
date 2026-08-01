// B27: Automatic Setup for push/notifications must survive the gate-settling
// window instead of latching a terminal "not set up" on the first transient.
//
// The gateway handshake (`GET http://tailarr-gate/self/notifications`) can, on a
// cold start, either fail to dial (the embedded Tailscale node isn't up yet:
// "Failed host lookup" / receiveTimeout) OR succeed but hand back an INCOMPLETE
// handout while the gate is still warming up its whois/roster. Both are
// transient. The pre-B27 loop retried only dial failures and treated an
// incomplete handout as terminal, so a single settling-window blip stuck the
// device "Not set up" until a manual retry happened to land.
//
// These tests drive the pure, injected retry policy (no Hive, no network, no
// real clock) and prove: a transient failure — dial OR incomplete handout — is
// retried and recovers, while a SUSTAINED failure still ends unresolved (the
// caller then persists "not set up / tap to retry").
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/api/ntfy/models.dart';
// The io platform impl directly (not the conditional `notifications.dart`
// barrel): the retry policy under test lives on the io-backed LunaNtfy, and
// tests run on the VM where dart:io is available.
import 'package:lunasea/system/notifications/platform/ntfy_io.dart';

NtfyGatewayCredentials _creds({
  required bool ok,
  String? error,
  String url = '',
  String token = '',
  List<String> topics = const [],
}) =>
    NtfyGatewayCredentials(
      ok: ok,
      error: error,
      url: url,
      user: '',
      password: '',
      token: token,
      topics: topics,
    );

/// A complete, usable handout.
final _complete = _creds(
  ok: true,
  url: 'https://ntfy.example.ts.net',
  token: 'tk_abc',
  topics: const ['alerts-abc'],
);

/// ok=true but the subscription is unusable — the classic "incomplete handout".
final _incompleteOkNoUrl = _creds(ok: true, topics: const ['alerts-abc']);
final _incompleteOkNoTopics =
    _creds(ok: true, url: 'https://ntfy.example.ts.net', token: 'tk');

/// ok=false, but NOT the device-unassigned refusal — still worth retrying.
final _incompleteNotOk = _creds(ok: false, error: 'notifications not ready');

/// The definitive admin-action refusal — a retry cannot fix it.
final _unassigned =
    _creds(ok: false, error: 'this device is not assigned to a user');

Future<void> _noSleep(Duration _) async {}

void main() {
  group('classifyAutoConfigure', () {
    test('a complete handout is configured (stop)', () {
      expect(LunaNtfy.classifyAutoConfigure(_complete),
          NtfyAutoConfigOutcome.configured);
    });

    test('device-unassigned is terminal (stop — needs an admin action)', () {
      expect(LunaNtfy.classifyAutoConfigure(_unassigned),
          NtfyAutoConfigOutcome.terminal);
    });

    test('a null result is terminal (nothing to do)', () {
      expect(LunaNtfy.classifyAutoConfigure(null),
          NtfyAutoConfigOutcome.terminal);
    });

    test('ok=true but missing url is an incomplete handout (retry)', () {
      expect(LunaNtfy.classifyAutoConfigure(_incompleteOkNoUrl),
          NtfyAutoConfigOutcome.incompleteHandout);
    });

    test('ok=true but missing topics is an incomplete handout (retry)', () {
      expect(LunaNtfy.classifyAutoConfigure(_incompleteOkNoTopics),
          NtfyAutoConfigOutcome.incompleteHandout);
    });

    test('ok=false for a non-terminal reason is an incomplete handout (retry)',
        () {
      expect(LunaNtfy.classifyAutoConfigure(_incompleteNotOk),
          NtfyAutoConfigOutcome.incompleteHandout);
    });
  });

  group('runAutoConfigureRetry', () {
    test('recovers when a transport failure clears within the window',
        () async {
      var calls = 0;
      final outcome = await LunaNtfy.runAutoConfigureRetry(
        () async {
          calls++;
          if (calls < 3) throw Exception('Failed host lookup: tailarr-gate');
          return NtfyAutoConfigOutcome.configured;
        },
        sleep: _noSleep,
      );
      expect(outcome, NtfyAutoConfigOutcome.configured);
      expect(calls, 3); // 2 transient dial failures, then success
    });

    test('recovers when an INCOMPLETE HANDOUT resolves within the window',
        () async {
      // The B27 heart: pre-fix this returned on the first incomplete handout
      // and never recovered. The gate settles by attempt 4 and we apply it.
      var calls = 0;
      final outcome = await LunaNtfy.runAutoConfigureRetry(
        () async {
          calls++;
          return calls < 4
              ? NtfyAutoConfigOutcome.incompleteHandout
              : NtfyAutoConfigOutcome.configured;
        },
        sleep: _noSleep,
      );
      expect(outcome, NtfyAutoConfigOutcome.configured);
      expect(calls, 4); // 3 incomplete handouts retried, then complete
    });

    test('a SUSTAINED transport failure ends unresolved after the bound',
        () async {
      var calls = 0;
      final outcome = await LunaNtfy.runAutoConfigureRetry(
        () async {
          calls++;
          throw Exception('receiveTimeout');
        },
        maxAttempts: 5,
        sleep: _noSleep,
      );
      // Bounded give-up — the caller persists "not set up / tap to retry".
      expect(outcome, NtfyAutoConfigOutcome.transientError);
      expect(calls, 5);
    });

    test('a SUSTAINED incomplete handout ends unresolved after the bound',
        () async {
      var calls = 0;
      final outcome = await LunaNtfy.runAutoConfigureRetry(
        () async {
          calls++;
          return NtfyAutoConfigOutcome.incompleteHandout;
        },
        maxAttempts: 4,
        sleep: _noSleep,
      );
      // Still bounded — a truly-misconfigured server correctly lands terminal.
      expect(outcome, NtfyAutoConfigOutcome.incompleteHandout);
      expect(calls, 4);
    });

    test('a definitive refusal stops immediately — no wasted retries',
        () async {
      var calls = 0;
      var sleeps = 0;
      final outcome = await LunaNtfy.runAutoConfigureRetry(
        () async {
          calls++;
          return NtfyAutoConfigOutcome.terminal;
        },
        sleep: (_) async => sleeps++,
      );
      expect(outcome, NtfyAutoConfigOutcome.terminal);
      expect(calls, 1);
      expect(sleeps, 0); // no backoff before a stop
    });

    test('a complete handout on the first try stops immediately', () async {
      var calls = 0;
      final outcome = await LunaNtfy.runAutoConfigureRetry(
        () async {
          calls++;
          return NtfyAutoConfigOutcome.configured;
        },
        sleep: _noSleep,
      );
      expect(outcome, NtfyAutoConfigOutcome.configured);
      expect(calls, 1);
    });

    test('backs off once per gap — never after the final attempt', () async {
      var sleeps = 0;
      await LunaNtfy.runAutoConfigureRetry(
        () async => NtfyAutoConfigOutcome.transientError,
        maxAttempts: 3,
        sleep: (_) async => sleeps++,
      );
      expect(sleeps, 2); // 3 attempts → 2 inter-attempt gaps
    });
  });
}
