import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/database/tables/bios.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/system/network/network.dart';
import 'package:lunasea/system/network/platform/network_io.dart'
    if (dart.library.html) 'package:lunasea/system/network/platform/network_html.dart';
import 'package:lunasea/system/platform.dart';

class ConfigurationGeneralRoute extends StatefulWidget {
  const ConfigurationGeneralRoute({
    Key? key,
  }) : super(key: key);

  @override
  State createState() => _State();
}

class _State extends State<ConfigurationGeneralRoute>
    with LunaScrollControllerMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      appBar: _appBar(),
      body: _body(),
    );
  }

  PreferredSizeWidget _appBar() {
    return LunaAppBar(
      title: 'settings.General'.tr(),
      scrollControllers: [scrollController],
    );
  }

  Widget _body() {
    return LunaListView(
      controller: scrollController,
      children: [
        ..._appearance(),
        ..._localization(),
        ..._modules(),
        if (LunaNetwork.isSupported) ..._network(),
        ..._platform(),
      ],
    );
  }

  List<Widget> _appearance() {
    return [
      LunaHeader(text: 'settings.Appearance'.tr()),
      _imageBackgroundOpacity(),
      _amoledTheme(),
      _amoledThemeBorders(),
    ];
  }

  List<Widget> _localization() {
    return [
      LunaHeader(text: 'settings.Localization'.tr()),
      _use24HourTime(),
    ];
  }

  List<Widget> _modules() {
    return [
      LunaHeader(text: 'dashboard.Modules'.tr()),
      _bootModule(),
    ];
  }

  List<Widget> _network() {
    return [
      LunaHeader(text: 'settings.Network'.tr()),
      _useTLSValidation(),
      if (IO.isTailscaleSupported) _useTailscale(),
    ];
  }

  List<Widget> _platform() {
    if (LunaPlatform.isAndroid) {
      return [
        LunaHeader(text: 'settings.Platform'.tr()),
        _openDrawerOnBackAction(),
      ];
    }

    return [];
  }

  Widget _openDrawerOnBackAction() {
    const _db = LunaSeaDatabase.ANDROID_BACK_OPENS_DRAWER;
    return _db.listenableBuilder(
      builder: (context, _) => LunaBlock(
        title: 'settings.OpenDrawerOnBackAction'.tr(),
        body: [
          TextSpan(text: 'settings.OpenDrawerOnBackActionDescription'.tr()),
        ],
        trailing: LunaSwitch(
          value: _db.read(),
          onChanged: _db.update,
        ),
      ),
    );
  }

  Widget _amoledTheme() {
    const _db = LunaSeaDatabase.THEME_AMOLED;
    return _db.listenableBuilder(
      builder: (context, _) => LunaBlock(
        title: 'settings.AmoledTheme'.tr(),
        body: [
          TextSpan(text: 'settings.AmoledThemeDescription'.tr()),
        ],
        trailing: LunaSwitch(
          value: _db.read(),
          onChanged: (value) {
            _db.update(value);
            LunaTheme().initialize();
          },
        ),
      ),
    );
  }

  Widget _amoledThemeBorders() {
    return LunaBox.lunasea.listenableBuilder(
      selectItems: [
        LunaSeaDatabase.THEME_AMOLED_BORDER,
        LunaSeaDatabase.THEME_AMOLED,
      ],
      builder: (context, _) => LunaBlock(
        title: 'settings.AmoledThemeBorders'.tr(),
        body: [
          TextSpan(text: 'settings.AmoledThemeBordersDescription'.tr()),
        ],
        trailing: LunaSwitch(
          value: LunaSeaDatabase.THEME_AMOLED_BORDER.read(),
          onChanged: LunaSeaDatabase.THEME_AMOLED.read()
              ? LunaSeaDatabase.THEME_AMOLED_BORDER.update
              : null,
        ),
      ),
    );
  }

  Widget _imageBackgroundOpacity() {
    const _db = LunaSeaDatabase.THEME_IMAGE_BACKGROUND_OPACITY;
    return _db.listenableBuilder(
      builder: (context, _) => LunaBlock(
        title: 'settings.BackgroundImageOpacity'.tr(),
        body: [
          TextSpan(
            text: _db.read() == 0 ? 'lunasea.Disabled'.tr() : '${_db.read()}%',
          ),
        ],
        trailing: const LunaIconButton.arrow(),
        onTap: () async {
          Tuple2<bool, int> result =
              await SettingsDialogs().changeBackgroundImageOpacity(context);
          if (result.item1) _db.update(result.item2);
        },
      ),
    );
  }

  Widget _useTLSValidation() {
    const _db = LunaSeaDatabase.NETWORKING_TLS_VALIDATION;
    return _db.listenableBuilder(
      builder: (context, _) => LunaBlock(
        title: 'settings.TLSCertificateValidation'.tr(),
        body: [
          TextSpan(text: 'settings.TLSCertificateValidationDescription'.tr()),
        ],
        trailing: LunaSwitch(
          value: _db.read(),
          onChanged: (data) {
            _db.update(data);
            if (LunaNetwork.isSupported) LunaNetwork().initialize();
          },
        ),
      ),
    );
  }

  /// Returns an error message if [key] is recognizably NOT a node auth key,
  /// or null if it looks usable.
  String? _tailscaleKeyTypeError(String key) {
    if (key.startsWith('tskey-api-')) {
      return 'That is an API access token. Generate an "Auth key" instead '
          '(starts with tskey-auth-) at login.tailscale.com under '
          'Settings > Keys.';
    }
    if (key.startsWith('tskey-client-')) {
      return 'That is an OAuth client secret. Generate an "Auth key" instead '
          '(starts with tskey-auth-) at login.tailscale.com under '
          'Settings > Keys.';
    }
    return null;
  }

  /// Translates tsnet/platform errors into something a person can act on.
  String _friendlyTailscaleError(Object error) {
    final raw = error.toString();
    if (raw.contains('cannot be used for node auth')) {
      return 'That key cannot register a device — use an Auth key '
          '(tskey-auth-…) from Settings > Keys. Toggle again to retry.';
    }
    if (raw.contains('invalid key')) {
      return 'The auth key is invalid, expired, or already used. Generate a '
          'new one and toggle again.';
    }
    if (raw.contains('timeout') || raw.contains('deadline')) {
      return 'Timed out reaching Tailscale — check your connection and '
          'toggle again.';
    }
    return 'Could not connect ($raw). Toggle again to retry with a new key.';
  }

  Widget _useTailscale() {
    const _dbEnabled = LunaSeaDatabase.TAILSCALE_ENABLED;
    const _dbAuthKey = LunaSeaDatabase.TAILSCALE_AUTH_KEY;

    return _dbEnabled.listenableBuilder(
      builder: (context, _) => LunaBlock(
        title: 'Use Tailscale',
        body: [
          TextSpan(text: 'Route .ts.net traffic through Tailscale'),
        ],
        trailing: LunaSwitch(
          value: _dbEnabled.read(),
          onChanged: (enabled) async {
            if (enabled) {
              // Check if we have an auth key
              String authKey = _dbAuthKey.read();
              if (authKey.isEmpty) {
                // Show dialog to get auth key
                final result = await SettingsDialogs().editTailscaleAuthKey(context);
                if (!result.item1 || result.item2.isEmpty) {
                  // User cancelled or didn't enter a key
                  return;
                }
                authKey = result.item2.trim();

                // Catch the wrong kind of key before dialing out. Node auth
                // needs an auth key; API tokens and OAuth secrets share the
                // tskey- prefix but cannot register devices.
                final wrongKeyType = _tailscaleKeyTypeError(authKey);
                if (wrongKeyType != null) {
                  showLunaErrorSnackBar(
                    title: 'Wrong Kind of Key',
                    message: wrongKeyType,
                  );
                  return;
                }
                _dbAuthKey.update(authKey);
              }

              // Try to start Tailscale
              try {
                await IO.startTailscale(authKey);
                _dbEnabled.update(true);
                showLunaSuccessSnackBar(
                  title: 'Tailscale Started',
                  message: 'Traffic to .ts.net domains will be routed through Tailscale',
                );
              } catch (e) {
                // Failed to start - show error and prompt for new auth key
                // Clear the auth key so user can try again
                _dbAuthKey.update('');
                showLunaErrorSnackBar(
                  title: 'Failed to Start Tailscale',
                  message: _friendlyTailscaleError(e),
                );
              }
            } else {
              // Stop Tailscale
              try {
                await IO.stopTailscale();
                _dbEnabled.update(false);
                showLunaInfoSnackBar(
                  title: 'Tailscale Stopped',
                  message: 'Traffic routing disabled',
                );
              } catch (e) {
                showLunaErrorSnackBar(
                  title: 'Failed to Stop Tailscale',
                  message: e.toString(),
                );
              }
            }
          },
        ),
      ),
    );
  }

  Widget _use24HourTime() {
    const _db = LunaSeaDatabase.USE_24_HOUR_TIME;
    return _db.listenableBuilder(
      builder: (context, _) => LunaBlock(
        title: 'settings.Use24HourTime'.tr(),
        body: [TextSpan(text: 'settings.Use24HourTimeDescription'.tr())],
        trailing: LunaSwitch(
          value: _db.read(),
          onChanged: _db.update,
        ),
      ),
    );
  }

  Widget _bootModule() {
    const _db = BIOSDatabase.BOOT_MODULE;
    return _db.listenableBuilder(
      builder: (context, _) => LunaBlock(
        title: 'settings.BootModule'.tr(),
        body: [TextSpan(text: _db.read().title)],
        trailing: LunaIconButton(icon: _db.read().icon),
        onTap: () async {
          final result = await SettingsDialogs().selectBootModule();
          if (result.item1) {
            BIOSDatabase.BOOT_MODULE.update(result.item2!);
          }
        },
      ),
    );
  }
}
