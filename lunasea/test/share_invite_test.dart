// The suite-invite extension of the share-config payload: enroll key
// round-trip, backwards compatibility with plain module shares.
import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules.dart';
import 'package:lunasea/modules/settings/core/share_configuration.dart';

void main() {
  test('invite payload round-trips through encode/decode', () {
    final invite = SharedModuleConfiguration.invite(
      serverHost: 'https://tailarr.tail95fc29.ts.net',
      enrollKey: 'tskey-auth-kFAKEFAKE-fakefakefakefakefakefakefake',
    );
    expect(invite.isInvite, isTrue);
    expect(invite.link, startsWith('https://tailarr.com/import#'));

    final decoded = SharedModuleConfiguration.decode(
      invite.link.split('#').last,
    );
    expect(decoded, isNotNull);
    expect(decoded!.isInvite, isTrue);
    expect(decoded.module, LunaModule.TAILARR_SERVER);
    expect(decoded.host, 'https://tailarr.tail95fc29.ts.net');
    expect(
      decoded.enrollKey,
      'tskey-auth-kFAKEFAKE-fakefakefakefakefakefakefake',
    );
  });

  test('plain module shares still decode without an enroll key', () {
    const share = SharedModuleConfiguration(
      module: LunaModule.SONARR,
      host: 'https://sonarr.tailXXXX.ts.net',
      key: 'abc123',
    );
    final decoded =
        SharedModuleConfiguration.decode(share.link.split('#').last);
    expect(decoded, isNotNull);
    expect(decoded!.isInvite, isFalse);
    expect(decoded.enrollKey, isEmpty);
    expect(decoded.key, 'abc123');
  });

  test('a payload with a malformed enroll block is not an invite', () {
    // Forward-compat: enroll must be a map with a key to count.
    const share = SharedModuleConfiguration(
      module: LunaModule.TAILARR_SERVER,
      host: 'https://tailarr.tailXXXX.ts.net',
    );
    final decoded =
        SharedModuleConfiguration.decode(share.link.split('#').last);
    expect(decoded!.isInvite, isFalse);
  });
}
