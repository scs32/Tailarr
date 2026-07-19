import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/tailarr_server.dart';
import 'package:lunasea/router/routes/tailarr_server.dart';
import 'package:share_plus/share_plus.dart';

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
    if (users.users.isEmpty) {
      return LunaMessage(
        text: 'No User Devices Found',
        buttonText: 'Refresh',
        onTap: _refreshKey.currentState!.show,
      );
    }
    return LunaListViewBuilder(
      controller: scrollController,
      itemCount: users.users.length,
      itemBuilder: (context, index) => _userTile(
        users.users[index],
        users.services.length,
      ),
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

  String _lastSeenLabel(TailarrServerUserDevice user) {
    if (user.isOnline) return 'Online';
    final seen = user.lastSeen;
    if (seen == null) return 'Never seen';
    final diff = DateTime.now().toUtc().difference(seen.toUtc());
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Widget _userTile(TailarrServerUserDevice user, int serviceCount) {
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
        TextSpan(text: [user.os, user.ip].where((s) => s.isNotEmpty).join(LunaUI.TEXT_BULLET)),
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

  Future<void> _addUser() async {
    final api = context.read<TailarrServerState>().api;
    final confirmed = await TailarrServerDialogs().confirmAction(
      context,
      title: 'Add User',
      message:
          'Generate a one-time enrollment key for a new user device? The key is single-use, expires in 24 hours, and the device starts with no service access.',
      buttonText: 'Generate Key',
      buttonColor: LunaColours.accent,
    );
    if (!confirmed) return;
    await api!.createUserKey().then((result) {
      if (result.ok && result.key.isNotEmpty) {
        _showKeySheet(result.key);
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

  void _showKeySheet(String key) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Enrollment Key',
                style: TextStyle(
                  fontSize: LunaUI.FONT_SIZE_H1,
                  fontWeight: LunaUI.FONT_WEIGHT_BOLD,
                ),
              ),
              const SizedBox(height: 12),
              SelectableText(
                key,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
              const SizedBox(height: 12),
              const Text(
                'Send this to the new user. They install Tailscale on their device and sign in with this key — the device then appears here with no access until you grant services. Single-use, expires in 24 hours.',
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: LunaButton.text(
                      text: 'Copy',
                      icon: Icons.copy_rounded,
                      onTap: () async => key.copyToClipboard(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: LunaButton.text(
                      text: 'Share',
                      icon: Icons.ios_share_rounded,
                      onTap: () async => Share.share(
                        'Your Tailarr access key (install Tailscale, then sign in with this key — expires in 24h):\n\n$key',
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
