import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/lidarr.dart';
import 'package:lunasea/modules/nzbget.dart';
import 'package:lunasea/modules/radarr.dart';
import 'package:lunasea/modules/sabnzbd.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/modules/sonarr.dart';
import 'package:lunasea/modules/tailarr_server.dart';
import 'package:lunasea/modules/tautulli.dart';
import 'package:lunasea/system/gateway/gateway_services.dart';
import 'package:lunasea/system/network/platform/network_io.dart'
    if (dart.library.html) 'package:lunasea/system/network/platform/network_html.dart';
import 'package:lunasea/system/notifications/notifications.dart';
import 'package:lunasea/utils/profile_tools.dart';
import 'package:tailscale_embed/tailscale_embed.dart';

/// Landing screen for shared-configuration deep links
/// (https://tailarr.com/import#payload and tailarr:///import#payload).
///
/// Shows the shared connection details, lets the recipient Test Connection
/// against the UNSAVED payload values, and only writes to the profile on an
/// explicit save — with a warning dialog when the module is already
/// configured.
class ImportConfigurationRoute extends StatefulWidget {
  final String encoded;

  const ImportConfigurationRoute({
    Key? key,
    required this.encoded,
  }) : super(key: key);

  @override
  State<ImportConfigurationRoute> createState() => _State();
}

class _State extends State<ImportConfigurationRoute>
    with LunaScrollControllerMixin {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  SharedModuleConfiguration? _config;

  /// The invite join sequence in flight — '' when idle, otherwise the
  /// current step label shown in place of the action bar.
  String _joiningStep = '';

  @override
  void initState() {
    super.initState();
    _config = SharedModuleConfiguration.decode(widget.encoded);
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      appBar: LunaAppBar(
        title: config?.isInvite == true ? 'Tailarr Invite' : 'Import Configuration',
        scrollControllers: [scrollController],
      ),
      body: config == null
          ? _invalid()
          : config.isInvite
              ? _inviteBody(config)
              : _body(config),
      bottomNavigationBar: config == null
          ? null
          : config.isInvite
              ? _inviteActionBar(config)
              : _bottomActionBar(config),
    );
  }

  Widget _inviteBody(SharedModuleConfiguration config) {
    return LunaListView(
      controller: scrollController,
      children: [
        const LunaBlock(
          title: 'You\'ve been invited',
          body: [
            TextSpan(text: 'One tap joins this server\'s private network'),
            TextSpan(text: 'Your services set themselves up — no typing'),
          ],
          trailing: LunaIconButton(
            icon: Icons.qr_code_rounded,
            color: LunaColours.accent,
          ),
        ),
        LunaBlock(
          title: 'Server',
          body: [TextSpan(text: config.host)],
        ),
        const LunaBlock(
          title: 'Enrollment Key',
          body: [
            TextSpan(text: LunaUI.TEXT_OBFUSCATED_PASSWORD),
            TextSpan(text: 'Single-use, expires 24h after it was issued'),
          ],
        ),
        if (LunaProfile.current.tailscaleEnabled)
          const LunaBlock(
            title: 'Heads Up',
            body: [
              TextSpan(
                text: 'This profile already has a Tailscale node. If it '
                    'belongs to a different network, use Settings > General > '
                    'Forget Tailscale Node first, then tap the invite again.',
                style: TextStyle(color: LunaColours.orange),
              ),
            ],
          ),
      ],
    );
  }

  Widget _inviteActionBar(SharedModuleConfiguration config) {
    if (_joiningStep.isNotEmpty) {
      return LunaBottomActionBar(
        actions: [
          LunaButton.text(
            text: _joiningStep,
            icon: Icons.downloading_rounded,
            onTap: () async {},
          ),
        ],
      );
    }
    return LunaBottomActionBar(
      actions: [
        LunaButton.text(
          text: 'Join & Set Up',
          icon: Icons.rocket_launch_rounded,
          color: LunaColours.accent,
          onTap: () => _joinAndSetup(config),
        ),
      ],
    );
  }

  /// The whole invite in one tap: save the server module + enroll key,
  /// bring the embedded node up, then let the tailarr-gate self-config
  /// endpoints materialize notifications and every badged service.
  Future<void> _joinAndSetup(SharedModuleConfiguration config) async {
    if (!IO.isTailscaleSupported) {
      showLunaErrorSnackBar(
        title: 'Not Supported',
        message: 'Joining a tailnet is not supported on this platform',
      );
      return;
    }

    setState(() => _joiningStep = 'Joining network…');
    try {
      // Every server-driven thing this join creates lands on a profile the
      // SERVER owns (name locked, config server-managed), created fresh or
      // reused per server host — the user's own profiles are never touched.
      final profileName =
          await LunaProfileTools().enterServerOwnedProfile(config.host);
      final profile = LunaProfile.current;
      config.applyToProfile();
      // Invite-joined = server-managed from birth (not a manual import).
      if (!profile.gatewayManagedModules.contains('tailarr')) {
        profile.gatewayManagedModules = [
          ...profile.gatewayManagedModules,
          'tailarr',
        ];
      }
      profile.serverOwned = true;
      profile.tailscaleAuthKey = config.enrollKey;
      profile.tailscaleEnabled = true;
      if (profile.tailscaleIdentity.isEmpty) {
        profile.tailscaleIdentity =
            LunaProfileTools.generateTailscaleIdentity(profileName);
      }
      profile.save();

      try {
        await IO.startTailscale(profile.tailscaleAuthKey);
      } catch (error) {
        setState(() => _joiningStep = '');
        showLunaErrorSnackBar(
          title: 'Could Not Join',
          message: TailscaleAuthKeys.friendlyError(error),
        );
        return;
      }

      setState(() => _joiningStep = 'Setting up your services…');
      // Best-effort: the node is enrolled either way, and both re-attempt
      // opportunistically later (module open / stream reconnect).
      try {
        await LunaNtfy().autoConfigure();
      } catch (_) {}
      GatewayServicesResult? services;
      try {
        services = (await GatewayServicesSync.sync()).result;
      } catch (_) {}

      if (!mounted) return;
      context.read<TailarrServerState>().reset();
      final summary = [
        ...?services?.configured.map((t) => t.toTitleCase()),
        if ((services?.bookmarked ?? []).isNotEmpty)
          '${services!.bookmarked.length} bookmark(s)',
      ].join(', ');
      showLunaSuccessSnackBar(
        title: 'You\'re In',
        message: summary.isEmpty
            ? 'Connected — services appear once the server grants access'
            : summary,
      );
      LunaModule.DASHBOARD.launch();
    } finally {
      if (mounted) setState(() => _joiningStep = '');
    }
  }

  Widget _invalid() {
    return LunaMessage.goBack(
      context: context,
      text: 'This link does not contain a valid shared configuration.',
    );
  }

  Widget _body(SharedModuleConfiguration config) {
    return LunaListView(
      controller: scrollController,
      children: [
        LunaBlock(
          title: config.module.title,
          body: const [
            TextSpan(
              text: 'Shared connection settings — nothing is saved until '
                  'you accept. Test the connection first.',
            ),
          ],
          trailing: LunaIconButton(icon: config.module.icon),
        ),
        LunaBlock(
          title: 'settings.Host'.tr(),
          body: [TextSpan(text: config.host)],
        ),
        if (config.key.isNotEmpty)
          LunaBlock(
            title: 'settings.ApiKey'.tr(),
            body: const [TextSpan(text: LunaUI.TEXT_OBFUSCATED_PASSWORD)],
          ),
        if (config.user.isNotEmpty)
          LunaBlock(
            title: 'Username',
            body: [TextSpan(text: config.user)],
          ),
        if (config.pass.isNotEmpty)
          LunaBlock(
            title: 'Password',
            body: const [TextSpan(text: LunaUI.TEXT_OBFUSCATED_PASSWORD)],
          ),
        if (config.headers.isNotEmpty)
          LunaBlock(
            title: 'settings.CustomHeaders'.tr(),
            body: [
              TextSpan(text: config.headers.keys.join(LunaUI.TEXT_BULLET)),
            ],
          ),
      ],
    );
  }

  Widget _bottomActionBar(SharedModuleConfiguration config) {
    return LunaBottomActionBar(
      actions: [
        LunaButton.text(
          text: 'settings.TestConnection'.tr(),
          icon: LunaIcons.CONNECTION_TEST,
          onTap: () => _testConnection(config),
        ),
        LunaButton.text(
          text: 'Save',
          icon: Icons.save_rounded,
          color: LunaColours.accent,
          onTap: () => _save(config),
        ),
      ],
    );
  }

  /// Tests use ONLY the payload values — never the recipient's saved profile.
  Future<void> _testConnection(SharedModuleConfiguration config) async {
    Future<void> test;
    switch (config.module) {
      case LunaModule.SONARR:
        test = SonarrAPI(
          host: config.host,
          apiKey: config.key,
          headers: Map<String, dynamic>.from(config.headers),
        ).system.getStatus();
        break;
      case LunaModule.RADARR:
        test = RadarrAPI(
          host: config.host,
          apiKey: config.key,
          headers: Map<String, dynamic>.from(config.headers),
        ).system.status();
        break;
      case LunaModule.LIDARR:
        test = LidarrAPI.from(config.toScratchProfile()).testConnection();
        break;
      case LunaModule.SABNZBD:
        test = SABnzbdAPI.from(config.toScratchProfile()).testConnection();
        break;
      case LunaModule.NZBGET:
        test = NZBGetAPI.from(config.toScratchProfile()).testConnection();
        break;
      case LunaModule.TAUTULLI:
        test = TautulliAPI(
          host: config.host,
          apiKey: config.key,
          headers: Map<String, dynamic>.from(config.headers),
        ).miscellaneous.arnold();
        break;
      case LunaModule.TAILARR_SERVER:
        test = TailarrServerAPI(
          host: config.host,
          headers: Map<String, dynamic>.from(config.headers),
        ).getInfo().then((info) {
          if (info.apiVersion < 1) {
            throw Exception('Server does not report a compatible API version');
          }
        });
        break;
      default:
        return;
    }
    await test.then((_) {
      showLunaSuccessSnackBar(
        title: 'settings.ConnectedSuccessfully'.tr(),
        message: 'settings.ConnectedSuccessfullyMessage'
            .tr(args: [config.module.title]),
      );
    }).catchError((error, trace) {
      LunaLogger().error('Connection Test Failed', error, trace);
      showLunaErrorSnackBar(
        title: 'settings.ConnectionTestFailed'.tr(),
        error: error,
      );
    });
  }

  Future<void> _save(SharedModuleConfiguration config) async {
    if (config.conflictsWithProfile) {
      final accepted = await _confirmOverwrite(config);
      if (!accepted) return;
    }
    config.applyToProfile();
    _resetModuleState(config.module);
    showLunaSuccessSnackBar(
      title: 'Configuration Imported',
      message: '${config.module.title} is ready to use',
    );
    config.module.launch();
  }

  Future<bool> _confirmOverwrite(SharedModuleConfiguration config) async {
    bool flag = false;

    void setValues(bool value) {
      flag = value;
      Navigator.of(context, rootNavigator: true).pop();
    }

    await LunaDialog.dialog(
      context: context,
      title: 'Replace Existing Configuration?',
      buttons: [
        LunaDialog.button(
          text: 'Replace',
          textColor: LunaColours.red,
          onPressed: () => setValues(true),
        ),
      ],
      content: [
        LunaDialog.textContent(
          text: '${config.module.title} is already configured on this '
              'profile. Saving replaces your current connection settings '
              'with the shared ones.',
        ),
      ],
      contentPadding: LunaDialog.textDialogContentPadding(),
    );
    return flag;
  }

  void _resetModuleState(LunaModule module) {
    switch (module) {
      case LunaModule.SONARR:
        context.read<SonarrState>().reset();
        break;
      case LunaModule.RADARR:
        context.read<RadarrState>().reset();
        break;
      case LunaModule.LIDARR:
        context.read<LidarrState>().reset();
        break;
      case LunaModule.SABNZBD:
        context.read<SABnzbdState>().reset();
        break;
      case LunaModule.NZBGET:
        context.read<NZBGetState>().reset();
        break;
      case LunaModule.TAUTULLI:
        context.read<TautulliState>().reset();
        break;
      case LunaModule.TAILARR_SERVER:
        context.read<TailarrServerState>().reset();
        break;
      default:
        break;
    }
  }
}
