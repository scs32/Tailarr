import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/api/jellyfin/models.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/jellyfin/core/dialogs.dart';
import 'package:lunasea/system/gateway/gateway_host.dart';

/// The member's self-service Jellyfin view. Everything here is scoped to the
/// caller's OWN Jellyfin account, brokered by the tailarr-gate (which whois'es
/// the device's tailnet identity). No admin key, no host, no credential is ever
/// entered — Quick Connect authorizes logins, and the app is only the
/// authorizer; playback stays in the official Jellyfin client.
class JellyfinRoute extends StatefulWidget {
  const JellyfinRoute({Key? key}) : super(key: key);

  @override
  State<JellyfinRoute> createState() => _State();
}

class _State extends State<JellyfinRoute> with LunaScrollControllerMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  JellyfinSelf? _self;
  JellyfinDevices? _devices;
  Object? _error;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final client = await gatewayClient();
      final self = await client.selfJellyfin();
      // Only pull sessions when the account is live; a devices failure must not
      // blank the whole screen.
      JellyfinDevices? devices;
      if (self.isAvailable) {
        try {
          devices = await client.selfJellyfinDevices();
        } catch (error, stack) {
          LunaLogger().error('Failed to fetch Jellyfin devices', error, stack);
        }
      }
      if (!mounted) return;
      setState(() {
        _self = self;
        _devices = devices;
        _error = null;
        _loaded = true;
      });
    } catch (error, stack) {
      LunaLogger().error('Failed to fetch Jellyfin account', error, stack);
      if (!mounted) return;
      setState(() {
        _error = error;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      module: LunaModule.JELLYFIN,
      appBar: _appBar() as PreferredSizeWidget?,
      drawer: LunaDrawer(page: LunaModule.JELLYFIN.key),
      body: _body(),
    );
  }

  Widget _appBar() {
    return LunaAppBar(
      title: 'Jellyfin',
      scrollControllers: [scrollController],
    );
  }

  Widget _body() {
    if (!_loaded) return const LunaLoader();
    if (_error != null) {
      // The gateway can briefly stop responding (embedded node rebinding).
      // Present it as transient, not a hard error.
      return LunaMessage(
        text: 'Jellyfin isn\'t responding right now — it may be reconnecting.',
        buttonText: 'Retry',
        onTap: _refresh,
      );
    }
    final self = _self;
    if (self == null) {
      return LunaMessage(text: 'Status Unavailable', buttonText: 'Retry', onTap: _refresh);
    }
    if (!self.isAvailable) return _unavailable(self);

    return LunaRefreshIndicator(
      context: context,
      onRefresh: _refresh,
      child: LunaListView(
        controller: scrollController,
        children: [
          _quickConnectBlock(self),
          _accountCard(self),
          _passwordBlock(self),
          ..._libraries(self),
          ..._devicesSection(),
        ],
      ),
    );
  }

  Widget _unavailable(JellyfinSelf self) {
    // The module is normally hidden in these states; this is the graceful
    // fallback if the screen is reached before the drawer catches up.
    final String text;
    if (self.isUnavailable) {
      text = 'Jellyfin isn\'t available on this server yet.';
    } else if (self.hasNoAccess) {
      text = 'You don\'t have Jellyfin access. Ask your server admin to grant '
          'it, then pull to refresh.';
    } else if (self.isUnassigned) {
      text = 'This device isn\'t assigned to anyone yet. Ask your server admin '
          'to assign it.';
    } else {
      text = self.error ?? 'Jellyfin is unavailable.';
    }
    return LunaMessage(text: text, buttonText: 'Retry', onTap: _refresh);
  }

  Widget _quickConnectBlock(JellyfinSelf self) {
    final enabled = self.quickConnectEnabled;
    return LunaBlock(
      title: 'Sign In a Device',
      body: [
        TextSpan(
          text: enabled
              ? 'Enter a Quick Connect code'
              : 'Quick Connect isn\'t available on this server',
          style: TextStyle(
            color: enabled ? LunaColours.accent : LunaColours.orange,
            fontWeight: LunaUI.FONT_WEIGHT_BOLD,
          ),
        ),
        const TextSpan(
          text: 'Start Quick Connect in the Jellyfin app, then authorize it '
              'here — no password required.',
        ),
      ],
      trailing: LunaIconButton(
        icon: Icons.qr_code_2_rounded,
        color: enabled ? LunaColours.accent : LunaColours.orange,
      ),
      onTap: enabled && !_busy ? _authorize : null,
    );
  }

  Widget _accountCard(JellyfinSelf self) {
    // url:"" means the pod is stopped — keep showing the last known value.
    final url = self.url.isNotEmpty ? self.url : LunaProfile.current.jellyfinUrl;
    return LunaTableCard(
      title: 'Account',
      content: [
        LunaTableContent(title: 'username', body: self.username),
        LunaTableContent(
          title: 'server',
          body: url.isEmpty ? 'Stopped' : url,
        ),
        LunaTableContent(
          title: 'password',
          body: self.hasPassword ? 'Set' : 'Passwordless',
        ),
        LunaTableContent(
          title: 'quick connect',
          body: self.quickConnectEnabled ? 'Enabled' : 'Disabled',
        ),
      ],
    );
  }

  Widget _passwordBlock(JellyfinSelf self) {
    return LunaBlock(
      title: self.hasPassword ? 'Change Password' : 'Set a Password',
      body: [
        TextSpan(
          text: self.hasPassword
              ? 'A password is set. You can change or clear it.'
              : 'Optional — Quick Connect works without one.',
        ),
      ],
      trailing: const LunaIconButton(icon: Icons.password_rounded),
      onTap: _busy ? null : () => _setPassword(self),
    );
  }

  List<Widget> _libraries(JellyfinSelf self) {
    return [
      LunaHeader(
        text: 'Libraries',
        subtitle: self.libraries.isEmpty
            ? 'No libraries granted yet'
            : '${self.libraries.length} available',
      ),
      if (self.libraries.isEmpty)
        LunaBlock(
          title: 'No Libraries',
          body: const [
            TextSpan(
              text: 'Your admin hasn\'t granted any libraries yet.',
            ),
          ],
          trailing: const LunaIconButton(icon: Icons.video_library_outlined),
        ),
      for (final library in self.libraries)
        LunaBlock(
          title: library.name.isEmpty ? library.id : library.name,
          trailing: const LunaIconButton(icon: Icons.video_library_rounded),
        ),
    ];
  }

  List<Widget> _devicesSection() {
    final devices = _devices;
    return [
      LunaHeader(
        text: 'Devices',
        subtitle: (devices == null || devices.devices.isEmpty)
            ? 'No active sessions'
            : '${devices.devices.length} active',
      ),
      if (devices == null)
        LunaBlock(
          title: 'Devices Unavailable',
          body: const [TextSpan(text: 'Pull to refresh to try again.')],
          trailing: const LunaIconButton(icon: Icons.devices_rounded),
        )
      else if (devices.devices.isEmpty)
        LunaBlock(
          title: 'No Active Devices',
          body: const [
            TextSpan(text: 'Sign in a device with Quick Connect above.'),
          ],
          trailing: const LunaIconButton(icon: Icons.devices_rounded),
        )
      else
        for (final device in devices.devices) _deviceBlock(device),
    ];
  }

  Widget _deviceBlock(JellyfinDevice device) {
    final subtitle = [device.client, _lastActiveLabel(device.lastActiveAt)]
        .where((s) => s.isNotEmpty)
        .join(LunaUI.TEXT_BULLET.pad());
    return LunaBlock(
      title: device.name.isEmpty ? (device.client.isEmpty ? 'Device' : device.client) : device.name,
      body: [if (subtitle.isNotEmpty) TextSpan(text: subtitle)],
      trailing: LunaIconButton(
        icon: Icons.logout_rounded,
        color: LunaColours.red,
        onPressed: _busy ? null : () => _signOut(device),
      ),
    );
  }

  /// Relative "2h ago" label from a device's last-active timestamp (matches the
  /// Users page). Empty when the server sent no timestamp.
  String _lastActiveLabel(DateTime? at) {
    if (at == null) return '';
    final diff = DateTime.now().toUtc().difference(at.toUtc());
    if (diff.isNegative || diff.inMinutes < 1) return 'Active now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  Future<void> _authorize() async {
    final result = await JellyfinDialogs().enterQuickConnectCode(context);
    if (!result.item1 || result.item2.isEmpty) return;
    await _runAction(
      () async => (await gatewayClient()).selfJellyfinConnect(result.item2),
      success: 'Device Authorized',
      failure: 'Authorization Failed',
    );
  }

  Future<void> _setPassword(JellyfinSelf self) async {
    final result = await JellyfinDialogs().setPassword(
      context,
      hasPassword: self.hasPassword,
    );
    switch (result.choice) {
      case JellyfinPasswordChoice.cancelled:
        return;
      case JellyfinPasswordChoice.clear:
        await _runAction(
          () async => (await gatewayClient()).selfJellyfinPassword(''),
          success: 'Password Cleared',
          failure: 'Update Failed',
        );
        return;
      case JellyfinPasswordChoice.save:
        await _runAction(
          () async =>
              (await gatewayClient()).selfJellyfinPassword(result.password),
          success: 'Password Updated',
          failure: 'Update Failed',
        );
        return;
    }
  }

  Future<void> _signOut(JellyfinDevice device) async {
    final confirmed = await JellyfinDialogs().confirmAction(
      context,
      title: 'Sign Out Device',
      message: 'Sign out ${device.name.isEmpty ? 'this device' : device.name}? '
          'It will need to sign in again.',
      buttonText: 'Sign Out',
    );
    if (!confirmed) return;
    await _runAction(
      () async => (await gatewayClient()).selfJellyfinSignout(device.id),
      success: 'Device Signed Out',
      failure: 'Sign Out Failed',
    );
  }

  /// Runs a POST action, surfaces {ok,error}, and refreshes on success.
  Future<void> _runAction(
    Future<JellyfinActionResult> Function() action, {
    required String success,
    required String failure,
  }) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await action();
      if (result.ok) {
        showLunaSuccessSnackBar(title: success, message: 'Done');
        await _refresh();
      } else {
        showLunaErrorSnackBar(
          title: failure,
          message: result.error ?? 'Unknown error',
        );
      }
    } catch (error, stack) {
      LunaLogger().error('Jellyfin action failed', error, stack);
      showLunaErrorSnackBar(title: failure, error: error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
