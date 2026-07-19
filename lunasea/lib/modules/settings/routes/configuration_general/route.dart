import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/database/tables/bios.dart';
import 'package:lunasea/modules/settings.dart';
import 'package:lunasea/system/network/network.dart';
import 'package:tailscale_embed/tailscale_embed.dart';
import 'package:lunasea/system/network/platform/network_io.dart'
    if (dart.library.html) 'package:lunasea/system/network/platform/network_html.dart';
import 'package:lunasea/system/platform.dart';
import 'package:lunasea/utils/profile_tools.dart';

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
      if (IO.isTailscaleSupported) _tailscaleAuthKey(),
      if (IO.isTailscaleSupported) _tailscaleForgetNode(),
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

  Widget _useTailscale() {
    return LunaBox.profiles.listenableBuilder(
      builder: (context, _) => LunaBlock(
        title: 'Use Tailscale',
        body: const [
          TextSpan(text: 'Route .ts.net traffic through Tailscale'),
        ],
        trailing: LunaSwitch(
          value: LunaProfile.current.tailscaleEnabled,
          onChanged: _toggleTailscale,
        ),
      ),
    );
  }

  Future<void> _toggleTailscale(bool enabled) async {
    final profile = LunaProfile.current;

    if (!enabled) {
      try {
        await IO.stopTailscale();
        profile.tailscaleEnabled = false;
        profile.save();
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
      return;
    }

    // Each profile owns one node identity, generated exactly once.
    if (profile.tailscaleIdentity.isEmpty) {
      profile.tailscaleIdentity = LunaProfileTools.generateTailscaleIdentity(
        LunaSeaDatabase.ENABLED_PROFILE.read(),
      );
      profile.save();
    }

    // An existing node identity starts without any key, so only prompt
    // when a start attempt actually fails.
    var promptedForKey = false;
    while (true) {
      try {
        await IO.startTailscale(profile.tailscaleAuthKey);
        profile.tailscaleEnabled = true;
        profile.save();
        showLunaSuccessSnackBar(
          title: 'Tailscale Started',
          message:
              'Traffic to .ts.net domains will be routed through Tailscale',
        );
        return;
      } catch (e) {
        if (promptedForKey) {
          showLunaErrorSnackBar(
            title: 'Failed to Start Tailscale',
            message: TailscaleAuthKeys.friendlyError(e),
          );
          return;
        }
        promptedForKey = true;

        final result = await SettingsDialogs().editTailscaleAuthKey(
          context,
          prefill: profile.tailscaleAuthKey,
        );
        if (!result.item1 || result.item2.trim().isEmpty) {
          showLunaErrorSnackBar(
            title: 'Failed to Start Tailscale',
            message: TailscaleAuthKeys.friendlyError(e),
          );
          return;
        }
        final authKey = result.item2.trim();

        // Catch the wrong kind of key before dialing out. Node auth
        // needs an auth key; API tokens and OAuth secrets share the
        // tskey- prefix but cannot register devices.
        final wrongKeyType = TailscaleAuthKeys.typeError(authKey);
        if (wrongKeyType != null) {
          showLunaErrorSnackBar(
            title: 'Wrong Kind of Key',
            message: wrongKeyType,
          );
          return;
        }
        profile.tailscaleAuthKey = authKey;
        profile.save();
      }
    }
  }

  Widget _tailscaleAuthKey() {
    return LunaBox.profiles.listenableBuilder(
      builder: (context, _) {
        final profile = LunaProfile.current;
        final String body;
        if (profile.tailscaleAuthKey.isNotEmpty) {
          body = LunaUI.TEXT_OBFUSCATED_PASSWORD;
        } else if (profile.tailscaleEnabled) {
          body = 'Consumed — node identity saved';
        } else {
          body = 'lunasea.NotSet'.tr();
        }
        return LunaBlock(
          title: 'Tailscale Auth Key',
          body: [TextSpan(text: body)],
          trailing: const LunaIconButton(icon: Icons.vpn_key_rounded),
          onTap: () async {
            final result = await SettingsDialogs().editTailscaleAuthKey(
              context,
              prefill: profile.tailscaleAuthKey,
            );
            if (!result.item1) return;
            final authKey = result.item2.trim();
            if (authKey.isEmpty) {
              profile.tailscaleAuthKey = '';
              profile.save();
              showLunaInfoSnackBar(
                title: 'Auth Key Removed',
                message: 'The saved key was deleted',
              );
              return;
            }
            final wrongKeyType = TailscaleAuthKeys.typeError(authKey);
            if (wrongKeyType != null) {
              showLunaErrorSnackBar(
                title: 'Wrong Kind of Key',
                message: wrongKeyType,
              );
              return;
            }
            profile.tailscaleAuthKey = authKey;
            profile.save();
            showLunaSuccessSnackBar(
              title: 'Auth Key Saved',
              message: 'Used at the next enrollment',
            );
          },
        );
      },
    );
  }

  Widget _tailscaleForgetNode() {
    return LunaBox.profiles.listenableBuilder(
      builder: (context, _) => LunaBlock(
        title: 'Forget Tailscale Node',
        body: const [
          TextSpan(
            text: 'Delete this profile\'s node identity to re-enroll fresh',
          ),
        ],
        trailing: const LunaIconButton(icon: Icons.link_off_rounded),
        onTap: _forgetTailscaleNode,
      ),
    );
  }

  Future<void> _forgetTailscaleNode() async {
    final profile = LunaProfile.current;
    final identity = profile.tailscaleIdentity.isEmpty
        ? 'default'
        : profile.tailscaleIdentity;

    bool confirmed = false;
    await LunaDialog.dialog(
      context: context,
      title: 'Forget Tailscale Node?',
      buttons: [
        LunaDialog.button(
          text: 'Forget',
          textColor: LunaColours.red,
          onPressed: () {
            confirmed = true;
            Navigator.of(context, rootNavigator: true).pop();
          },
        ),
      ],
      content: [
        LunaDialog.textContent(
          text: 'This stops Tailscale and deletes this profile\'s node '
              'identity and saved auth key. Re-enabling enrolls a brand-new '
              'node, which needs a fresh auth key. Remove the old node in '
              'the Tailscale admin console afterwards.',
        ),
      ],
      contentPadding: LunaDialog.textDialogContentPadding(),
    );
    if (!confirmed) return;

    try {
      await IO.forgetTailscaleNode(identity);
      profile.tailscaleEnabled = false;
      profile.tailscaleAuthKey = '';
      profile.save();
      showLunaSuccessSnackBar(
        title: 'Node Forgotten',
        message: 'Set a new auth key and re-enable to enroll again',
      );
    } catch (e) {
      showLunaErrorSnackBar(title: 'Failed to Forget Node', error: e);
    }
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
