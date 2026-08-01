// P1 — the loudest TestFlight beta report: the magicsock "ReceiveIPv4 is not
// running" health warning sticks in the Tailscale Status UI even when peers
// read 8/8 online and traffic flows (only a Tailscale stop/start clears it).
//
// TailscaleHealthView gates that specific warning on observed connectivity: a
// stale magicsock receive warning is suppressed (and does not demote the
// connection to "Attention Needed") when the node is Running and at least one
// peer is online, but a genuine no-connectivity state still warns.
import 'package:flutter_test/flutter_test.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

import 'package:lunasea/modules/settings/routes/configuration_general/pages/tailscale_health.dart';

const _magicsock = 'MagicSock function ReceiveIPv4 is not running';

TailscaleStatus _status({
  bool running = true,
  String backendState = 'Running',
  List<String> health = const [],
  List<TailscaleNode> peers = const [],
}) {
  return TailscaleStatus(
    running: running,
    backendState: backendState,
    health: health,
    peers: peers,
  );
}

TailscaleNode _peer({required bool online}) => TailscaleNode(
      hostName: online ? 'tailarr' : 'truenas-ts',
      dnsName: '',
      ips: const ['100.64.0.2'],
      online: online,
    );

void main() {
  group('TailscaleHealthView magicsock warning matcher', () {
    test('matches the field wording and reworded/lower-cased variants', () {
      expect(TailscaleHealthView.isStaleMagicsockWarning(_magicsock), isTrue);
      expect(
        TailscaleHealthView.isStaleMagicsockWarning(
            'magicsock: ReceiveIPv4 is not running'),
        isTrue,
      );
      expect(
        TailscaleHealthView.isStaleMagicsockWarning(
            'MagicSock function ReceiveIPv6 is not running'),
        isTrue,
      );
    });

    test('does not match unrelated health warnings', () {
      expect(
        TailscaleHealthView.isStaleMagicsockWarning(
            'not connected to home DERP region'),
        isFalse,
      );
      // A magicsock/receive message that is NOT a "not running" state must not
      // be swallowed.
      expect(
        TailscaleHealthView.isStaleMagicsockWarning(
            'magicsock: ReceiveIPv4 socket rebound'),
        isFalse,
      );
    });
  });

  group('stale magicsock warning with peers online (the P1 false alarm)', () {
    final status = _status(
      health: const [_magicsock],
      peers: [_peer(online: true), _peer(online: true)],
    );

    test('is suppressed from the displayed health list', () {
      expect(TailscaleHealthView.effectiveHealth(status), isEmpty);
    });

    test('does not demote the connection — node reads healthy', () {
      expect(TailscaleHealthView.isHealthy(status), isTrue);
    });

    test('other warnings alongside it are still shown', () {
      final mixed = _status(
        health: const [_magicsock, 'not connected to home DERP region'],
        peers: [_peer(online: true)],
      );
      expect(
        TailscaleHealthView.effectiveHealth(mixed),
        ['not connected to home DERP region'],
      );
      expect(TailscaleHealthView.isHealthy(mixed), isFalse);
    });
  });

  group('genuine connectivity failure still warns', () {
    test('magicsock warning with NO peers online is kept', () {
      final status = _status(
        health: const [_magicsock],
        peers: [_peer(online: false)],
      );
      expect(TailscaleHealthView.connectivityProven(status), isFalse);
      expect(TailscaleHealthView.effectiveHealth(status), [_magicsock]);
      expect(TailscaleHealthView.isHealthy(status), isFalse);
    });

    test('magicsock warning with no peers at all is kept (no evidence)', () {
      final status = _status(health: const [_magicsock]);
      expect(TailscaleHealthView.effectiveHealth(status), [_magicsock]);
      expect(TailscaleHealthView.isHealthy(status), isFalse);
    });

    test('non-Running backend keeps the warning even with an online peer', () {
      final status = _status(
        backendState: 'Starting',
        health: const [_magicsock],
        peers: [_peer(online: true)],
      );
      expect(TailscaleHealthView.effectiveHealth(status), [_magicsock]);
      expect(TailscaleHealthView.isHealthy(status), isFalse);
    });
  });

  test('healthy node with no warnings reads healthy', () {
    final status = _status(peers: [_peer(online: true)]);
    expect(TailscaleHealthView.isHealthy(status), isTrue);
    expect(TailscaleHealthView.effectiveHealth(status), isEmpty);
  });
}
