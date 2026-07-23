import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/modules/tailarr_server.dart';
import 'package:lunasea/router/routes/tailarr_server.dart';

class UsersRoute extends StatefulWidget {
  const UsersRoute({
    Key? key,
  }) : super(key: key);

  @override
  State<UsersRoute> createState() => _State();
}

class _State extends State<UsersRoute> with LunaScrollControllerMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();
  Future<TailarrServerUsers>? _users;
  Timer? _pollTimer;

  /// Last successful snapshot — decides whether Add User creates a person
  /// (server v0.19.0+) or mints an anonymous key (older servers).
  TailarrServerUsers? _latest;

  @override
  void initState() {
    super.initState();
    _fetch();
    // Mirror the web UI: newly-enrolled devices appear on their own.
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) => _fetch());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _fetch() {
    final api = context.read<TailarrServerState>().api;
    setState(() {
      _users = api?.getUsers().then((users) {
        _latest = users;
        return users;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      module: LunaModule.TAILARR_SERVER,
      appBar: _appBar() as PreferredSizeWidget?,
      body: _body(),
      bottomNavigationBar: _bottomActionBar(),
    );
  }

  Widget _appBar() {
    return LunaAppBar(
      title: 'Users',
      scrollControllers: [scrollController],
    );
  }

  Widget _bottomActionBar() {
    return LunaBottomActionBar(
      actions: [
        LunaButton.text(
          text: 'Add User',
          icon: Icons.person_add_rounded,
          onTap: _addUser,
        ),
        LunaButton.text(
          text: 'Adopt by ID',
          icon: Icons.badge_rounded,
          onTap: _adoptById,
        ),
      ],
    );
  }

  Widget _body() {
    return LunaRefreshIndicator(
      context: context,
      key: _refreshKey,
      onRefresh: () async => _fetch(),
      child: FutureBuilder(
        future: _users,
        builder: (context, AsyncSnapshot<TailarrServerUsers> snapshot) {
          if (snapshot.hasError) {
            return LunaMessage.error(onTap: _refreshKey.currentState!.show);
          }
          if (snapshot.hasData) return _content(snapshot.data!);
          return const LunaLoader();
        },
      ),
    );
  }

  Widget _content(TailarrServerUsers users) {
    if (!users.configured) return _notConfigured();
    if (users.error != null) {
      return LunaMessage(
        text: users.error!,
        buttonText: 'Refresh',
        onTap: _refreshKey.currentState!.show,
      );
    }
    // Pre-0.19.0 servers: the flat machine list is the whole model.
    if (!users.hasPeople) return _legacyContent(users);

    if (users.people.isEmpty && users.users.isEmpty) {
      return LunaListView(
        controller: scrollController,
        children: [
          LunaMessage.inList(text: 'No Users Found'),
          _queriedHostBlock(),
        ],
      );
    }
    return LunaListView(
      controller: scrollController,
      children: [
        for (final person in users.people) _personTile(person, users),
        if (users.users.isNotEmpty) ...[
          const LunaHeader(
            text: 'Unassigned Devices',
            subtitle: 'Enrolled with an old anonymous key — '
                'assign each to a user',
          ),
          for (final device in users.users) _unassignedTile(device, users),
        ],
      ],
    );
  }

  Widget _legacyContent(TailarrServerUsers users) {
    // The fallback being active must be VISIBLE: an empty legacy list is
    // otherwise indistinguishable from a broken people view. Always name
    // the host that was queried and why the old model is rendering.
    return LunaListView(
      controller: scrollController,
      children: [
        _legacyModelBlock(),
        if (users.users.isEmpty)
          LunaMessage.inList(text: 'No User Devices Found'),
        for (final user in users.users)
          _machineTile(user, users.services.length),
      ],
    );
  }

  Widget _legacyModelBlock() {
    return LunaBlock(
      title: 'Legacy User Model',
      body: [
        const TextSpan(
          text:
              'This server did not report people (pre-v0.19) — showing the flat device list. Queried:',
        ),
        TextSpan(text: context.read<TailarrServerState>().host),
      ],
      trailing: const LunaIconButton(icon: Icons.history_rounded),
    );
  }

  Widget _queriedHostBlock() {
    return LunaBlock(
      title: 'Server',
      body: [TextSpan(text: context.read<TailarrServerState>().host)],
      trailing: const LunaIconButton(icon: Icons.dns_rounded),
    );
  }

  Widget _notConfigured() {
    return LunaListView(
      controller: scrollController,
      children: [
        LunaMessage.inList(
          text: 'Tailscale API Credentials Required',
        ),
        const LunaBlock(
          title: 'Set Up in the Web UI',
          body: [
            TextSpan(
              text:
                  'User management flips tailnet access tags, which needs a Tailscale API credential on the server. Open the Tailarr Server web UI > Settings and complete the credential wizard once — then this page lights up.',
            ),
          ],
          trailing: LunaIconButton(icon: Icons.vpn_key_off_rounded),
        ),
      ],
    );
  }

  Widget _personTile(TailarrServerPerson person, TailarrServerUsers users) {
    final online = person.devices.any((d) => d.isOnline);
    return LunaBlock(
      title: person.name,
      body: [
        TextSpan(
          text: '${person.devices.length} '
              'device${person.devices.length == 1 ? '' : 's'}',
          style: TextStyle(
            color: online ? LunaColours.accent : LunaColours.grey,
            fontWeight: LunaUI.FONT_WEIGHT_BOLD,
          ),
        ),
        TextSpan(
          text: person.badges.isEmpty
              ? 'No access granted'
              : person.badges.join(LunaUI.TEXT_BULLET.pad()),
          style: person.badges.contains('server')
              ? const TextStyle(color: LunaColours.orange)
              : null,
        ),
      ],
      trailing: LunaIconButton(
        icon: person.badges.contains('server')
            ? Icons.shield_rounded
            : Icons.person_rounded,
        color: person.badges.contains('server')
            ? LunaColours.orange
            : (online ? LunaColours.accent : LunaColours.grey),
      ),
      onTap: () => TailarrServerRoutes.PERSON_DETAILS.go(
        params: {'id': person.id},
      ),
    );
  }

  String _lastSeenLabel(TailarrServerUserDevice user) {
    if (user.isOnline) return 'Online';
    final seen = user.lastSeen;
    if (seen == null) return 'Never seen';
    final diff = DateTime.now().toUtc().difference(seen.toUtc());
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Widget _unassignedTile(
    TailarrServerUserDevice device,
    TailarrServerUsers users,
  ) {
    return LunaBlock(
      title: device.displayName,
      body: [
        TextSpan(
          text: _lastSeenLabel(device),
          style: TextStyle(
            color: device.isOnline ? LunaColours.accent : LunaColours.grey,
            fontWeight: LunaUI.FONT_WEIGHT_BOLD,
          ),
        ),
        TextSpan(
          text: [device.os, device.ip]
              .where((s) => s.isNotEmpty)
              .join(LunaUI.TEXT_BULLET.pad()),
        ),
      ],
      trailing: LunaIconButton(
        icon: Icons.person_add_alt_rounded,
        onPressed: () => _assignDevice(device, users.people),
      ),
      // Per-device access toggles still work through the legacy endpoint.
      onTap: () => TailarrServerRoutes.USER_DETAILS.go(
        params: {'id': device.id},
      ),
    );
  }

  Widget _machineTile(TailarrServerUserDevice user, int serviceCount) {
    return LunaBlock(
      title: user.displayName,
      body: [
        TextSpan(
          text: _lastSeenLabel(user),
          style: TextStyle(
            color: user.isOnline ? LunaColours.accent : LunaColours.grey,
            fontWeight: LunaUI.FONT_WEIGHT_BOLD,
          ),
        ),
        TextSpan(
          text: '${user.can.length} of $serviceCount services',
        ),
        TextSpan(
          text: [user.os, user.ip]
              .where((s) => s.isNotEmpty)
              .join(LunaUI.TEXT_BULLET),
        ),
      ],
      trailing: LunaIconButton(
        icon: user.isOnline
            ? Icons.smartphone_rounded
            : Icons.mobile_off_rounded,
        color: user.isOnline ? LunaColours.accent : LunaColours.grey,
      ),
      onTap: () => TailarrServerRoutes.USER_DETAILS.go(
        params: {'id': user.id},
      ),
    );
  }

  Future<void> _assignDevice(
    TailarrServerUserDevice device,
    List<TailarrServerPerson> people,
  ) async {
    if (people.isEmpty) {
      showLunaErrorSnackBar(
        title: 'No Users Yet',
        message: 'Add a user first, then assign this device to them',
      );
      return;
    }
    bool flag = false;
    TailarrServerPerson? selected;
    await LunaDialog.dialog(
      context: context,
      title: 'Assign ${device.displayName}',
      content: List.generate(
        people.length,
        (index) => LunaDialog.tile(
          icon: Icons.person_rounded,
          iconColor: LunaColours().byListIndex(index),
          text: people[index].name,
          onTap: () {
            flag = true;
            selected = people[index];
            Navigator.of(context).pop();
          },
        ),
      ),
      contentPadding: LunaDialog.listDialogContentPadding(),
    );
    if (!flag || selected == null) return;

    final api = context.read<TailarrServerState>().api;
    await api!.assignDevice(selected!.id, device.id).then((result) {
      if (result.ok) {
        showLunaSuccessSnackBar(
          title: 'Device Assigned',
          message: '${device.displayName} → ${selected!.name}',
        );
      } else {
        showLunaErrorSnackBar(
          title: 'Assignment Failed',
          message: result.error ?? 'Unknown error',
        );
      }
      _fetch();
    }).catchError((error, stack) {
      LunaLogger().error('Device assignment failed', error, stack);
      showLunaErrorSnackBar(title: 'Assignment Failed', error: error);
    });
  }

  Future<void> _addUser() async {
    final api = context.read<TailarrServerState>().api;
    // Minting enrollment keys needs the tag-owning OAuth client — a static
    // API token acts as a personal credential and can't reliably mint
    // tagged keys, so the whole path is gated on oauth mode.
    try {
      final info = await api!.getInfo();
      if (info.tsapiMode != 'oauth') {
        await TailarrServerDialogs().confirmAction(
          context,
          title: 'OAuth Client Required',
          message: info.tsapiMode == 'token'
              ? 'The server is using a static API token, which cannot mint enrollment keys reliably. Open the Tailarr Server web UI > Settings and switch the credential to an OAuth client, then try again.'
              : 'Adding users mints tailnet enrollment keys, which requires an OAuth client credential on the server. Open the Tailarr Server web UI > Settings and complete the credential wizard, then try again.',
          buttonText: 'OK',
          buttonColor: LunaColours.accent,
        );
        return;
      }
    } catch (error, stack) {
      LunaLogger().error('Fetching server info failed', error, stack);
      showLunaErrorSnackBar(title: 'Add User Failed', error: error);
      return;
    }

    if (_latest?.hasPeople ?? false) {
      return _addPerson(api);
    }
    return _addLegacyKey(api);
  }

  Future<void> _addPerson(TailarrServerAPI api) async {
    final values = await LunaDialogs().editText(context, 'User Name');
    if (!values.item1 || values.item2.trim().isEmpty) return;
    final name = values.item2.trim();
    await api.addPerson(name).then((result) {
      if (result.ok && result.key.isNotEmpty) {
        _fetch();
        final profile = LunaProfile.current;
        TailarrServerKeySheet.show(
          context,
          enrollmentKey: result.key,
          inviteLink: profile.tailarrServerHost.isEmpty
              ? null
              : SharedModuleConfiguration.invite(
                  serverHost: profile.tailarrServerHost,
                  enrollKey: result.key,
                  headers: Map<String, String>.from(
                    profile.tailarrServerHeaders,
                  ),
                ).link,
          message:
              'Send this to $name. Their device enrolls already belonging to them, with no access until you grant services. Single-use, expires in 24 hours.',
          shareMessage:
              'Your Tailarr invite — open this link on your phone (it walks you through install if needed). Expires in 24h:',
        );
      } else {
        showLunaErrorSnackBar(
          title: 'Add User Failed',
          message: result.error ?? 'Unknown error',
        );
      }
    }).catchError((error, stack) {
      LunaLogger().error('Add person failed', error, stack);
      showLunaErrorSnackBar(title: 'Add User Failed', error: error);
    });
  }

  Future<void> _addLegacyKey(TailarrServerAPI api) async {
    final confirmed = await TailarrServerDialogs().confirmAction(
      context,
      title: 'Add User',
      message:
          'Generate a one-time enrollment key for a new user device? The key is single-use, expires in 24 hours, and the device starts with no service access.',
      buttonText: 'Generate Key',
      buttonColor: LunaColours.accent,
    );
    if (!confirmed) return;
    await api.createUserKey().then((result) {
      if (result.ok && result.key.isNotEmpty) {
        TailarrServerKeySheet.show(
          context,
          enrollmentKey: result.key,
          message:
              'Send this to the new user. They install Tailscale on their device and sign in with this key — the device then appears here with no access until you grant services. Single-use, expires in 24 hours.',
          shareMessage:
              'Your Tailarr access key (install Tailscale, then sign in with this key — expires in 24h):',
        );
      } else {
        showLunaErrorSnackBar(
          title: 'Key Generation Failed',
          message: result.error ?? 'Unknown error',
        );
      }
    }).catchError((error, stack) {
      LunaLogger().error('User key generation failed', error, stack);
      showLunaErrorSnackBar(title: 'Key Generation Failed', error: error);
    });
  }

  Future<void> _adoptById() async {
    final api = context.read<TailarrServerState>().api;
    final values = await LunaDialogs().editText(
      context,
      'Adopt Device by Node ID',
    );
    if (!values.item1 || values.item2.isEmpty) return;
    await api!.adoptUser(values.item2.trim()).then((result) {
      if (result.ok) {
        showLunaSuccessSnackBar(
          title: 'Device Adopted',
          message: result.hostname,
        );
        _fetch();
      } else {
        showLunaErrorSnackBar(
          title: 'Adoption Failed',
          message: result.error ?? 'Unknown error',
        );
      }
    }).catchError((error, stack) {
      LunaLogger().error('Device adoption failed', error, stack);
      showLunaErrorSnackBar(title: 'Adoption Failed', error: error);
    });
  }
}
