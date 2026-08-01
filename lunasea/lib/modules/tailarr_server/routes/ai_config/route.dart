import 'package:flutter/material.dart';
import 'package:lunasea/api/pairing/quick_connect.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/modules/tailarr_server.dart';

/// Mirrors the server's `AI_DEFAULT_MODEL` (web/app.py). Used to prefill the
/// model field when the server hasn't reported one yet.
const String _kAIDefaultModel = 'gemini-3.1-flash-live-preview';

/// Admin-only config for the voice-AI provider key ("under identities"). Wires
/// to the admin-gated `/api/ai`:
///   GET  → { ok, error, configured, provider, model, key_set, providers }
///   POST { do:'set', provider, api_key, model } | { do:'clear' }
/// The raw key is WRITE-ONLY: the server never returns it and the app never
/// stores it — the key field is cleared the moment a save succeeds.
class AIConfigRoute extends StatefulWidget {
  const AIConfigRoute({super.key});

  @override
  State<AIConfigRoute> createState() => _State();
}

class _State extends State<AIConfigRoute> with LunaScrollControllerMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();

  // Write-only key entry — never seeded from the server (it can't be), and
  // wiped on a successful save so a raw key is never retained in the widget.
  final _keyController = TextEditingController();
  final _modelController = TextEditingController();

  Future<TailarrServerAIConfig>? _config;
  String? _provider;
  bool _saving = false;
  bool _prefilled = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  void _fetch() {
    final api = context.read<TailarrServerState>().api;
    setState(() {
      _config = api?.getAIConfig().then((config) {
        // Seed the editable fields once from the server's current config; don't
        // clobber in-progress edits on later refreshes.
        if (!_prefilled) {
          _prefilled = true;
          _provider = config.provider.isNotEmpty
              ? config.provider
              : (config.providers.isNotEmpty ? config.providers.first : 'gemini');
          _modelController.text =
              config.model.isNotEmpty ? config.model : _kAIDefaultModel;
        }
        return config;
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
      title: 'AI Provider',
      scrollControllers: [scrollController],
    );
  }

  Widget? _bottomActionBar() {
    // Only offer actions once the config is reachable and the caller is an
    // admin (has the server grant). Non-admins never see the buttons.
    if (!QuickConnect.canApprove(LunaProfile.current)) return null;
    return LunaBottomActionBar(
      actions: [
        LunaButton.text(
          text: _saving ? 'Saving…' : 'Save Key',
          icon: Icons.save_rounded,
          onTap: _saving ? null : _save,
          loadingState: _saving ? LunaLoadingState.ACTIVE : null,
        ),
      ],
    );
  }

  Widget _body() {
    // UI-side admin gate: without the server grant this identity can never use
    // the admin-only endpoint, so don't even show the form.
    if (!QuickConnect.canApprove(LunaProfile.current)) {
      return LunaMessage(
        text: "This device can't manage AI settings (needs server access).",
      );
    }
    return LunaRefreshIndicator(
      context: context,
      key: _refreshKey,
      onRefresh: () async => _fetch(),
      child: FutureBuilder(
        future: _config,
        builder: (context, AsyncSnapshot<TailarrServerAIConfig> snapshot) {
          if (snapshot.hasError) {
            if (isServerAuthRequired(snapshot.error)) {
              return LunaMessage(
                text: 'You need admin access to manage AI settings, and this '
                    'device must be connected to the server.',
              );
            }
            return LunaMessage.error(onTap: _refreshKey.currentState!.show);
          }
          if (snapshot.hasData) return _content(snapshot.data!);
          return const LunaLoader();
        },
      ),
    );
  }

  Widget _content(TailarrServerAIConfig config) {
    return LunaListView(
      controller: scrollController,
      children: [
        const LunaHeader(
          text: 'Status',
          subtitle: 'The voice assistant\'s AI provider',
        ),
        _statusBlock(config),
        const LunaHeader(
          text: 'Configuration',
          subtitle: 'Set the provider, API key, and model',
        ),
        _providerBlock(config),
        _keyField(config),
        _modelField(),
        if (config.keySet) _removeBlock(),
      ],
    );
  }

  Widget _statusBlock(TailarrServerAIConfig config) {
    final keySet = config.keySet;
    return LunaBlock(
      title: config.provider.isEmpty ? 'Not Configured' : config.provider,
      body: [
        TextSpan(
          text: keySet ? 'API key set ✓' : 'No API key set',
          style: TextStyle(
            color: keySet ? LunaColours.accent : LunaColours.red,
            fontWeight: LunaUI.FONT_WEIGHT_BOLD,
          ),
        ),
        TextSpan(
          text: config.model.isEmpty ? 'No model set' : config.model,
        ),
      ],
      trailing: LunaIconButton(
        icon: keySet ? Icons.check_circle_rounded : Icons.key_off_rounded,
        color: keySet ? LunaColours.accent : LunaColours.red,
      ),
    );
  }

  Widget _providerBlock(TailarrServerAIConfig config) {
    final providers = config.providers;
    return LunaBlock(
      title: 'Provider',
      body: [TextSpan(text: _provider ?? 'gemini')],
      trailing: const LunaIconButton(icon: Icons.expand_more_rounded),
      // Provider-abstracted: a picker even when Gemini is the only option today.
      onTap: () => _pickProvider(providers),
    );
  }

  Future<void> _pickProvider(List<String> providers) async {
    if (providers.length <= 1) {
      // Nothing to choose — keep the single supported provider selected.
      setState(() => _provider = providers.isNotEmpty ? providers.first : 'gemini');
      return;
    }
    await LunaDialog.dialog(
      context: context,
      title: 'AI Provider',
      content: List.generate(
        providers.length,
        (index) => LunaDialog.tile(
          icon: Icons.auto_awesome_rounded,
          iconColor: LunaColours().byListIndex(index),
          text: providers[index],
          onTap: () {
            setState(() => _provider = providers[index]);
            Navigator.of(context).pop();
          },
        ),
      ),
      contentPadding: LunaDialog.listDialogContentPadding(),
    );
  }

  Widget _keyField(TailarrServerAIConfig config) {
    return LunaTextInputBar(
      controller: _keyController,
      isFormField: true,
      obscureText: true,
      labelText: config.keySet
          ? 'New API Key (leave blank to keep current)'
          : 'API Key',
      labelIcon: Icons.vpn_key_rounded,
      action: TextInputAction.next,
      margin: LunaUI.MARGIN_DEFAULT,
    );
  }

  Widget _modelField() {
    return LunaTextInputBar(
      controller: _modelController,
      isFormField: true,
      labelText: 'Model',
      labelIcon: Icons.smart_toy_rounded,
      action: TextInputAction.done,
      onSubmitted: (_) => _save(),
      margin: LunaUI.MARGIN_DEFAULT,
    );
  }

  Widget _removeBlock() {
    return LunaBlock(
      title: 'Remove API Key',
      body: const [
        TextSpan(text: 'Forget the provider config and delete the stored key'),
      ],
      trailing: const LunaIconButton(
        icon: Icons.delete_forever_rounded,
        color: LunaColours.red,
      ),
      onTap: _remove,
    );
  }

  Future<void> _save() async {
    final api = context.read<TailarrServerState>().api;
    if (api == null) return;
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      showLunaErrorSnackBar(
        title: 'API Key Required',
        message: 'Enter the provider API key to save.',
      );
      return;
    }
    final provider = _provider ?? 'gemini';
    final model = _modelController.text.trim().isEmpty
        ? _kAIDefaultModel
        : _modelController.text.trim();

    setState(() => _saving = true);
    try {
      final result = await api.setAIConfig(
        provider: provider,
        apiKey: key,
        model: model,
      );
      if (!mounted) return;
      if (result.ok) {
        // Wipe the write-only key from the widget the instant it's stored.
        _keyController.clear();
        if (result.config != null && result.config!.model.isNotEmpty) {
          _modelController.text = result.config!.model;
        }
        showLunaSuccessSnackBar(
          title: 'AI Provider Saved',
          message: 'API key set ✓',
        );
        _fetch();
      } else {
        showLunaErrorSnackBar(
          title: 'Save Failed',
          message: result.error ?? 'Unknown error',
        );
      }
    } catch (error, stack) {
      LunaLogger().error('Saving AI provider config failed', error, stack);
      if (mounted) showLunaErrorSnackBar(title: 'Save Failed', error: error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove() async {
    final api = context.read<TailarrServerState>().api;
    if (api == null) return;
    final confirmed = await TailarrServerDialogs().confirmAction(
      context,
      title: 'Remove API Key',
      message:
          'Delete the stored AI provider key from the server? The voice assistant '
          'will stop working until a new key is set.',
      buttonText: 'Remove',
      buttonColor: LunaColours.red,
    );
    if (!confirmed) return;
    try {
      final result = await api.clearAIConfig();
      if (!mounted) return;
      if (result.ok) {
        _keyController.clear();
        showLunaSuccessSnackBar(
          title: 'API Key Removed',
          message: 'The AI provider config was cleared.',
        );
        _fetch();
      } else {
        showLunaErrorSnackBar(
          title: 'Remove Failed',
          message: result.error ?? 'Unknown error',
        );
      }
    } catch (error, stack) {
      LunaLogger().error('Clearing AI provider config failed', error, stack);
      if (mounted) showLunaErrorSnackBar(title: 'Remove Failed', error: error);
    }
  }
}
