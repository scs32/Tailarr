import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/extensions/datetime.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/modules/tailarr_server.dart';
import 'package:share_plus/share_plus.dart';

class PersonDetailsRoute extends StatefulWidget {
  final String id;

  const PersonDetailsRoute({
    Key? key,
    required this.id,
  }) : super(key: key);

  @override
  State<PersonDetailsRoute> createState() => _State();
}

class _State extends State<PersonDetailsRoute> with LunaScrollControllerMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();
  Future<TailarrServerUsers>? _users;

  /// Services with a grant/revoke call in flight (switches disabled).
  final Set<String> _pending = {};

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    final api = context.read<TailarrServerState>().api;
    setState(() {
      _users = api?.getUsers();
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
      title: 'User',
      scrollControllers: [scrollController],
    );
  }

  Widget _bottomActionBar() {
    return LunaBottomActionBar(
      actions: [
        LunaButton.text(
          text: 'Reissue Key',
          icon: Icons.key_rounded,
          onTap: _reissueKey,
        ),
        LunaButton.text(
          text: 'Delete',
          icon: Icons.person_remove_rounded,
          color: LunaColours.red,
          onTap: _delete,
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
          if (snapshot.hasData) {
            final person = snapshot.data!.people
                .where((p) => p.id == widget.id)
                .cast<TailarrServerPerson?>()
                .firstWhere((_) => true, orElse: () => null);
            if (person == null) {
              return LunaMessage(
                text: 'User Not Found',
                buttonText: 'Refresh',
                onTap: _refreshKey.currentState!.show,
              );
            }
            return _content(person, snapshot.data!);
          }
          return const LunaLoader();
        },
      ),
    );
  }

  Widget _content(TailarrServerPerson person, TailarrServerUsers users) {
    return LunaListView(
      controller: scrollController,
      children: [
        _nameBlock(person),
        if (users.ntfy) _notificationsBlock(person),
        const LunaHeader(text: 'Access'),
        if (users.services.isEmpty)
          const LunaBlock(
            title: 'No Services Deployed',
            body: [TextSpan(text: 'Install services to grant access to them')],
          ),
        for (final service in users.services) _serviceBlock(person, service),
        LunaHeader(
          text: 'Devices',
          subtitle: person.devices.isEmpty
              ? 'No devices yet — share an enrollment key'
              : 'Access applies to all of them',
        ),
        for (final device in person.devices) _deviceBlock(device),
      ],
    );
  }

  Widget _nameBlock(TailarrServerPerson person) {
    return LunaBlock(
      title: person.name,
      body: [
        TextSpan(
          text: '${person.devices.length} '
              'device${person.devices.length == 1 ? '' : 's'}',
        ),
        if (person.createdAt != null)
          TextSpan(text: 'Added ${person.createdAt!.asDateOnly()}'),
      ],
      trailing: const LunaIconButton(icon: Icons.edit_rounded),
      onTap: () async {
        final values = await LunaDialogs().editText(
          context,
          'Name',
          prefill: person.name,
        );
        if (!values.item1 || values.item2.trim().isEmpty) return;
        final api = context.read<TailarrServerState>().api;
        await api!.renamePerson(person.id, values.item2.trim()).then((result) {
          if (!result.ok) {
            showLunaErrorSnackBar(
              title: 'Rename Failed',
              message: result.error ?? 'Unknown error',
            );
          }
          _fetch();
        }).catchError((error, stack) {
          LunaLogger().error('Person rename failed', error, stack);
          showLunaErrorSnackBar(title: 'Rename Failed', error: error);
        });
      },
    );
  }

  Widget _serviceBlock(TailarrServerPerson person, String service) {
    final granted = person.badges.contains(service);
    final pending = _pending.contains(service);
    final isServer = service == 'server';
    return LunaBlock(
      title: service,
      body: [
        TextSpan(
          text: granted
              ? (isServer ? 'Full admin access' : 'Access granted')
              : 'No access',
          style: TextStyle(
            color: granted
                ? (isServer ? LunaColours.orange : LunaColours.accent)
                : LunaColours.grey,
            fontWeight: LunaUI.FONT_WEIGHT_BOLD,
          ),
        ),
      ],
      trailing: LunaSwitch(
        value: granted,
        onChanged:
            pending ? null : (allow) => _setAccess(person, service, allow),
      ),
    );
  }

  Future<void> _setAccess(
    TailarrServerPerson person,
    String service,
    bool allow,
  ) async {
    if (service == 'server' && allow) {
      final confirmed = await TailarrServerDialogs().confirmAction(
        context,
        title: 'Grant Server Access',
        message:
            'Adding this gives full admin rights to ALL of ${person.name}\'s devices.',
        buttonText: 'Grant',
        buttonColor: LunaColours.orange,
      );
      if (!confirmed) return;
    }
    final api = context.read<TailarrServerState>().api;
    setState(() => _pending.add(service));
    try {
      final result = await api!.setPersonAccess(person.id, service, allow);
      if (result.ok) {
        showLunaSuccessSnackBar(
          title: allow ? 'Access Granted' : 'Access Revoked',
          message: '${person.name} ${allow ? '→' : '⇸'} $service',
        );
      } else {
        showLunaErrorSnackBar(
          title: 'Access Change Failed',
          message: result.error ?? 'Unknown error',
        );
      }
    } catch (error, stack) {
      LunaLogger().error('Access change failed', error, stack);
      showLunaErrorSnackBar(title: 'Access Change Failed', error: error);
    } finally {
      _pending.remove(service);
      _fetch();
    }
  }

  String _lastSeenLabel(TailarrServerUserDevice device) {
    if (device.isOnline) return 'Online';
    final seen = device.lastSeen;
    if (seen == null) return 'Never seen';
    final diff = DateTime.now().toUtc().difference(seen.toUtc());
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Widget _deviceBlock(TailarrServerUserDevice device) {
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
        icon: device.isOnline
            ? Icons.smartphone_rounded
            : Icons.mobile_off_rounded,
        color: device.isOnline ? LunaColours.accent : LunaColours.grey,
      ),
    );
  }

  Widget _notificationsBlock(TailarrServerPerson person) {
    return LunaBlock(
      title: 'Notifications',
      body: const [
        TextSpan(
          text: 'Issue ntfy credentials — topics mirror their access',
        ),
      ],
      trailing: const LunaIconButton(icon: Icons.notifications_rounded),
      onTap: () async {
        final api = context.read<TailarrServerState>().api;
        try {
          final creds = await api!.getPersonNotifications(person.id);
          if (!creds.ok) {
            showLunaErrorSnackBar(
              title: 'Notifications Setup Failed',
              message: creds.error ?? 'Unknown error',
            );
            return;
          }
          _showNotificationsSheet(person, creds);
        } catch (error, stack) {
          LunaLogger().error('Notification credentials failed', error, stack);
          showLunaErrorSnackBar(
            title: 'Notifications Setup Failed',
            error: error,
          );
        }
      },
    );
  }

  void _showNotificationsSheet(
    TailarrServerPerson person,
    TailarrServerNotificationCredentials creds,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${person.name} — Notifications',
                style: const TextStyle(
                  fontSize: LunaUI.FONT_SIZE_H1,
                  fontWeight: LunaUI.FONT_WEIGHT_BOLD,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Tailarr-app devices configure themselves automatically '
                'from the server — this handout is for the official ntfy '
                'app or manual setups. In the ntfy app, add the server '
                'with the username and password (it wants basic auth, not '
                'the token), then subscribe to the topics.',
              ),
              const SizedBox(height: 12),
              SelectableText(
                'Server:   ${creds.url}\n'
                'Username: ${creds.user}\n'
                'Password: ${creds.password}\n'
                'Token:    ${creds.token}\n'
                'Topics:   ${creds.topics.join(', ')}',
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: LunaButton.text(
                      text: 'Copy All',
                      icon: Icons.copy_rounded,
                      onTap: () async =>
                          ('${creds.url}\n${creds.user}\n${creds.password}\n'
                                  '${creds.token}\n${creds.topics.join(',')}')
                              .copyToClipboard(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: LunaButton.text(
                      text: 'Share Config',
                      icon: Icons.ios_share_rounded,
                      // Tailarr-app devices self-configure — this handout
                      // is for the official ntfy app.
                      onTap: () async => Share.share(
                        'Your Tailarr notification config for the ntfy '
                        'app (Tailarr itself configures automatically):\n\n'
                        '${creds.subscriptionJson}',
                        sharePositionOrigin:
                            SharedModuleConfiguration.shareOriginOf(context),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _reissueKey() async {
    final api = context.read<TailarrServerState>().api;
    final confirmed = await TailarrServerDialogs().confirmAction(
      context,
      title: 'Reissue Enrollment Key',
      message:
          'Mint a fresh single-use key (24h expiry) for this user? A device that enrolls with it automatically belongs to them and inherits their access.',
      buttonText: 'Generate Key',
      buttonColor: LunaColours.accent,
    );
    if (!confirmed) return;
    await api!.reissuePersonKey(widget.id).then((result) {
      if (result.ok && result.key.isNotEmpty) {
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
              'Single-use, expires in 24 hours. A device that joins with it automatically belongs to this user, with their access — modules configure themselves.',
          shareMessage:
              'Your Tailarr invite — open this link on your phone (it walks you through install if needed). Expires in 24h:',
        );
      } else {
        showLunaErrorSnackBar(
          title: 'Key Generation Failed',
          message: result.error ?? 'Unknown error',
        );
      }
    }).catchError((error, stack) {
      LunaLogger().error('Key reissue failed', error, stack);
      showLunaErrorSnackBar(title: 'Key Generation Failed', error: error);
    });
  }

  Future<void> _delete() async {
    final api = context.read<TailarrServerState>().api;
    final confirmed = await TailarrServerDialogs().confirmAction(
      context,
      title: 'Delete User',
      message:
          'Delete this user? Their devices stay enrolled but lose all access.',
      buttonText: 'Delete',
    );
    if (!confirmed) return;
    await api!.deletePerson(widget.id).then((result) {
      if (result.ok) {
        showLunaSuccessSnackBar(title: 'User Deleted', message: '');
        Navigator.of(context).pop();
      } else {
        showLunaErrorSnackBar(
          title: 'Delete Failed',
          message: result.error ?? 'Unknown error',
        );
      }
    }).catchError((error, stack) {
      LunaLogger().error('Person delete failed', error, stack);
      showLunaErrorSnackBar(title: 'Delete Failed', error: error);
    });
  }
}
