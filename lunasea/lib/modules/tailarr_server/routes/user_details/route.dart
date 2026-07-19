import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/modules/tailarr_server.dart';

class UserDetailsRoute extends StatefulWidget {
  final String id;

  const UserDetailsRoute({
    Key? key,
    required this.id,
  }) : super(key: key);

  @override
  State<UserDetailsRoute> createState() => _State();
}

class _State extends State<UserDetailsRoute> with LunaScrollControllerMixin {
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
    );
  }

  Widget _appBar() {
    return LunaAppBar(
      title: 'User Access',
      scrollControllers: [scrollController],
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
            final user = snapshot.data!.users
                .where((u) => u.id == widget.id)
                .cast<TailarrServerUserDevice?>()
                .firstWhere((_) => true, orElse: () => null);
            if (user == null) {
              return LunaMessage(
                text: 'Device Not Found',
                buttonText: 'Refresh',
                onTap: _refreshKey.currentState!.show,
              );
            }
            return _content(user, snapshot.data!.services);
          }
          return const LunaLoader();
        },
      ),
    );
  }

  Widget _content(TailarrServerUserDevice user, List<String> services) {
    return LunaListView(
      controller: scrollController,
      children: [
        _nicknameBlock(user),
        _deviceBlock(user),
        LunaDivider(),
        if (services.isEmpty)
          const LunaBlock(
            title: 'No Services Deployed',
            body: [TextSpan(text: 'Install services to grant access to them')],
          ),
        for (final service in services) _serviceBlock(user, service),
      ],
    );
  }

  Widget _nicknameBlock(TailarrServerUserDevice user) {
    return LunaBlock(
      title: user.displayName,
      body: [
        TextSpan(
          text: user.nickname.isEmpty
              ? 'Tap to set a nickname'
              : user.hostname,
        ),
      ],
      trailing: const LunaIconButton(icon: Icons.edit_rounded),
      onTap: () async {
        final values = await LunaDialogs().editText(
          context,
          'Nickname',
          prefill: user.nickname,
        );
        if (!values.item1) return;
        final api = context.read<TailarrServerState>().api;
        await api!
            .setUserNickname(user.id, values.item2.trim())
            .then((_) => _fetch())
            .catchError((error, stack) {
          LunaLogger().error('Nickname update failed', error, stack);
          showLunaErrorSnackBar(title: 'Update Failed', error: error);
        });
      },
    );
  }

  Widget _deviceBlock(TailarrServerUserDevice user) {
    return LunaBlock(
      title: 'Device',
      body: [
        if (user.os.isNotEmpty) TextSpan(text: user.os),
        if (user.ip.isNotEmpty) TextSpan(text: user.ip),
        TextSpan(text: user.id),
      ],
      trailing: LunaIconButton(
        icon: user.isOnline
            ? Icons.smartphone_rounded
            : Icons.mobile_off_rounded,
        color: user.isOnline ? LunaColours.accent : LunaColours.grey,
      ),
    );
  }

  Widget _serviceBlock(TailarrServerUserDevice user, String service) {
    final granted = user.can.contains(service);
    final pending = _pending.contains(service);
    return LunaBlock(
      title: service,
      body: [
        TextSpan(
          text: granted ? 'Access granted' : 'No access',
          style: TextStyle(
            color: granted ? LunaColours.accent : LunaColours.grey,
            fontWeight: LunaUI.FONT_WEIGHT_BOLD,
          ),
        ),
      ],
      trailing: LunaSwitch(
        value: granted,
        onChanged: pending ? null : (allow) => _setAccess(user, service, allow),
      ),
    );
  }

  Future<void> _setAccess(
    TailarrServerUserDevice user,
    String service,
    bool allow,
  ) async {
    final api = context.read<TailarrServerState>().api;
    setState(() => _pending.add(service));
    try {
      final result = await api!.setUserAccess(user.id, service, allow);
      if (result.ok) {
        showLunaSuccessSnackBar(
          title: allow ? 'Access Granted' : 'Access Revoked',
          message: '${user.displayName} ${allow ? '→' : '⇸'} $service',
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
}
