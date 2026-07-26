import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/api/pairing/quick_connect.dart';
import 'package:lunasea/modules/tailarr_server/core/state.dart';

/// Approve a sign-in (Quick Connect approver leg). A server-badge admin types
/// the 8-char code shown in a browser and approves it over the identity-proven
/// pairing port — no token typed, no admin console. Self-config ("Connect this
/// device") is a separate action added once the token path is verified.
class TailarrServerPairRoute extends StatefulWidget {
  const TailarrServerPairRoute({Key? key}) : super(key: key);

  @override
  State<TailarrServerPairRoute> createState() => _State();
}

class _State extends State<TailarrServerPairRoute>
    with LunaScrollControllerMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _controller = TextEditingController();

  /// Frozen code format: ABCD-1234.
  static final _codeFormat = RegExp(r'^[A-Z0-9]{4}-[0-9]{4}$');

  bool _busy = false;
  String? _success;
  String? _error;

  bool _connecting = false;
  String? _connectMsg;
  bool _connectOk = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      module: LunaModule.TAILARR_SERVER,
      appBar: LunaAppBar(
        title: 'Approve Sign-In',
        scrollControllers: [scrollController],
      ) as PreferredSizeWidget?,
      body: QuickConnect.canApprove(LunaProfile.current)
          ? _body()
          : _noBadge(),
    );
  }

  Widget _noBadge() {
    return LunaMessage(
      text: "This device can't authorize sign-ins (needs server access).",
    );
  }

  Widget _body() {
    return LunaListView(
      controller: scrollController,
      children: [
        ..._connectThisDeviceSection(),
        LunaDivider(),
        const LunaBlock(
          title: 'Approve a browser sign-in',
          body: [
            TextSpan(
              text: 'Enter the code shown in the browser to sign it in as you. '
                  'The code expires in a few minutes.',
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: TextField(
            controller: _controller,
            enabled: !_busy,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            inputFormatters: [
              UpperCaseTextFormatter(),
              FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9-]')),
              LengthLimitingTextInputFormatter(9),
            ],
            decoration: const InputDecoration(
              labelText: 'Code (e.g. ABCD-1234)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (_success != null || _error != null) {
                setState(() {
                  _success = null;
                  _error = null;
                });
              }
            },
            onSubmitted: (_) => _approve(),
          ),
        ),
        if (_success != null)
          LunaBlock(
            title: 'Approved',
            body: [TextSpan(text: _success!)],
            trailing: const Icon(Icons.check_circle_rounded,
                color: LunaColours.accent),
          ),
        if (_error != null)
          LunaBlock(
            title: 'Not Approved',
            body: [TextSpan(text: _error!)],
            trailing:
                const Icon(Icons.error_rounded, color: LunaColours.red),
          ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: LunaButton.text(
            text: _busy ? 'Approving…' : 'Approve',
            icon: Icons.verified_user_rounded,
            onTap: _busy ? null : _approve,
          ),
        ),
      ],
    );
  }

  List<Widget> _connectThisDeviceSection() {
    final connected = LunaProfile.current.serverAdminToken.trim().isNotEmpty;
    return [
      LunaBlock(
        title: connected ? 'This device is connected' : 'Connect this device',
        body: [
          TextSpan(
            text: connected
                ? 'This device can manage your server. Sign out to revoke its '
                    'access on this device.'
                : 'Let this device manage your server (pods, users, updates). '
                    'No code needed — it authorizes itself over your tailnet.',
          ),
        ],
        trailing: connected
            ? const Icon(Icons.dns_rounded, color: LunaColours.accent)
            : null,
      ),
      if (_connectMsg != null)
        LunaBlock(
          title: _connectOk ? 'Connected' : "Couldn't connect",
          body: [TextSpan(text: _connectMsg!)],
          trailing: Icon(
            _connectOk ? Icons.check_circle_rounded : Icons.error_rounded,
            color: _connectOk ? LunaColours.accent : LunaColours.red,
          ),
        ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: LunaButton.text(
          text: _connecting
              ? 'Connecting…'
              : connected
                  ? 'Sign This Device Out'
                  : 'Connect This Device',
          icon: connected ? Icons.logout_rounded : Icons.link_rounded,
          onTap: _connecting
              ? null
              : connected
                  ? _disconnect
                  : _connectThisDevice,
        ),
      ),
    ];
  }

  Future<void> _connectThisDevice() async {
    setState(() {
      _connecting = true;
      _connectMsg = null;
    });
    final result = await QuickConnect.selfConfigure(
      LunaProfile.current,
      deviceLabel: 'Tailarr app',
    );
    if (!mounted) return;
    // Rebuild the Server API with the new bearer.
    context.read<TailarrServerState>().resetProfile();
    setState(() {
      _connecting = false;
      _connectOk = result.ok;
      _connectMsg = result.ok
          ? 'This device can now manage your server.'
          : _friendly(result.error);
    });
  }

  Future<void> _disconnect() async {
    final profile = LunaProfile.current;
    profile.serverAdminToken = '';
    if (profile.isInBox) profile.save();
    context.read<TailarrServerState>().resetProfile();
    setState(() {
      _connectOk = false;
      _connectMsg = 'Signed this device out of server management.';
    });
  }

  Future<void> _approve() async {
    final code = _controller.text.trim().toUpperCase();
    if (!_codeFormat.hasMatch(code)) {
      setState(() {
        _success = null;
        _error = 'Enter the full code in the form ABCD-1234.';
      });
      return;
    }
    final client = QuickConnect.clientFor(LunaProfile.current);
    if (client == null) {
      setState(() => _error = "This device can't authorize sign-ins.");
      return;
    }

    setState(() {
      _busy = true;
      _success = null;
      _error = null;
    });
    try {
      final result = await client.pairApprove(code);
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (result.ok) {
          _success = 'The browser is now signed in'
              '${result.person != null ? ' as ${result.person}' : ''}.';
          _controller.clear();
        } else {
          _error = _friendly(result.error);
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = "Couldn't reach your server. Check the connection and retry.";
      });
    }
  }

  String _friendly(String? error) {
    final e = (error ?? '').toLowerCase();
    if (e.contains('server badge')) {
      return "This device can't authorize sign-ins (needs server access).";
    }
    if (e.contains('live peer')) {
      return 'This device is not connected to your server right now.';
    }
    if (e.contains('not assigned')) {
      return 'This device isn’t linked to your account on the server yet.';
    }
    if (e.contains('expired') || e.contains('bad')) {
      return 'That code is wrong or has expired. Ask for a new one.';
    }
    return error ?? 'The sign-in could not be approved.';
  }
}

/// Forces typed input to upper-case so codes match the frozen ABCD-1234 shape.
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
