import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/extensions/string/links.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/tailarr_server.dart';
import 'package:lunasea/router/routes/tailarr_server.dart';

class PodDetailsRoute extends StatefulWidget {
  final String pod;

  const PodDetailsRoute({
    Key? key,
    required this.pod,
  }) : super(key: key);

  @override
  State<PodDetailsRoute> createState() => _State();
}

class _State extends State<PodDetailsRoute>
    with LunaScrollControllerMixin, LunaLoadCallbackMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();

  @override
  Future<void> loadCallback() async {
    context.read<TailarrServerState>().resetPods();
    await context.read<TailarrServerState>().pods;
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
      title: widget.pod,
      scrollControllers: [scrollController],
    );
  }

  Widget _body() {
    return LunaRefreshIndicator(
      context: context,
      key: _refreshKey,
      onRefresh: loadCallback,
      child: Selector<TailarrServerState, Future<List<TailarrServerPod>>?>(
        selector: (_, state) => state.pods,
        builder: (context, pods, _) => FutureBuilder(
          future: pods,
          builder: (context, AsyncSnapshot<List<TailarrServerPod>> snapshot) {
            if (snapshot.hasError) {
              return LunaMessage.error(onTap: _refreshKey.currentState!.show);
            }
            if (snapshot.hasData) {
              final pod = snapshot.data!
                  .where((p) => p.name == widget.pod)
                  .cast<TailarrServerPod?>()
                  .firstWhere((_) => true, orElse: () => null);
              if (pod == null) {
                return LunaMessage(
                  text: 'Pod Not Found',
                  buttonText: 'Refresh',
                  onTap: _refreshKey.currentState!.show,
                );
              }
              return _list(pod);
            }
            return const LunaLoader();
          },
        ),
      ),
    );
  }

  Widget _list(TailarrServerPod pod) {
    return LunaListView(
      controller: scrollController,
      children: [
        _statusBlock(pod),
        _urlBlock(pod),
        _publicAccessBlock(pod),
        LunaDivider(),
        if (!pod.controller) ..._actionBlocks(pod),
        _logsBlock(),
        if (!pod.controller) _backupsBlock(),
      ],
    );
  }

  Widget _statusBlock(TailarrServerPod pod) {
    return LunaBlock(
      title: pod.state.isEmpty ? 'stopped' : pod.state.toTitleCase(),
      body: [
        TextSpan(text: pod.image),
        if (pod.isBusy)
          TextSpan(
            text: '${pod.busy} in progress…',
            style: const TextStyle(
              color: LunaColours.orange,
              fontWeight: LunaUI.FONT_WEIGHT_BOLD,
            ),
          ),
        if (pod.identityMissing)
          const TextSpan(
            text: 'Identity tag missing — user access is blocked',
            style: TextStyle(
              color: LunaColours.red,
              fontWeight: LunaUI.FONT_WEIGHT_BOLD,
            ),
          ),
        if (pod.updateAvailable)
          const TextSpan(
            text: 'Image update available',
            style: TextStyle(
              color: LunaColours.orange,
              fontWeight: LunaUI.FONT_WEIGHT_BOLD,
            ),
          ),
        if (pod.controller) const TextSpan(text: 'Controller pod'),
      ],
      trailing: LunaIconButton(
        icon: pod.controller ? Icons.shield_rounded : Icons.dns_rounded,
        color: pod.isRunning ? LunaColours.accent : LunaColours.red,
      ),
    );
  }

  /// The tailnet URL comes from `/api/network`, which is slower than the
  /// pods list (the server shells into each sidecar) — render it lazily.
  Widget _urlBlock(TailarrServerPod pod) {
    return Selector<TailarrServerState,
        Future<List<TailarrServerNetworkEntry>>?>(
      selector: (_, state) => state.network,
      builder: (context, network, _) => FutureBuilder(
        future: network,
        builder: (
          context,
          AsyncSnapshot<List<TailarrServerNetworkEntry>> snapshot,
        ) {
          String url = '';
          if (snapshot.hasData) {
            final entry = snapshot.data!
                .where((e) => e.name == widget.pod)
                .cast<TailarrServerNetworkEntry?>()
                .firstWhere((_) => true, orElse: () => null);
            url = entry?.serviceUrl ?? '';
          }
          if (snapshot.hasError || (snapshot.hasData && url.isEmpty)) {
            return const SizedBox(height: 0, width: double.infinity);
          }
          return LunaBlock(
            title: 'Open Service',
            body: [
              TextSpan(text: url.isEmpty ? 'Resolving tailnet address…' : url),
            ],
            trailing: const LunaIconButton(icon: Icons.open_in_new_rounded),
            onTap: url.isEmpty ? null : url.openLink,
          );
        },
      ),
    );
  }

  /// Tailscale Funnel toggle — expose the pod's HTTPS serve to the public
  /// internet, or make it tailnet-only again. Live flip, no restart.
  Widget _publicAccessBlock(TailarrServerPod pod) {
    return Selector<TailarrServerState,
        Future<List<TailarrServerNetworkEntry>>?>(
      selector: (_, state) => state.network,
      builder: (context, network, _) => FutureBuilder(
        future: network,
        builder: (
          context,
          AsyncSnapshot<List<TailarrServerNetworkEntry>> snapshot,
        ) {
          if (!snapshot.hasData) {
            return const SizedBox(height: 0, width: double.infinity);
          }
          final entry = snapshot.data!
              .where((e) => e.name == widget.pod)
              .cast<TailarrServerNetworkEntry?>()
              .firstWhere((_) => true, orElse: () => null);
          if (entry == null || !entry.canTogglePublic) {
            return const SizedBox(height: 0, width: double.infinity);
          }
          final busy = entry.busy == 'funnel' || _funnelPending;
          return LunaBlock(
            title: 'Public Access',
            body: [
              TextSpan(
                text: entry.funnel
                    ? 'PUBLIC — reachable from the internet'
                    : 'Private — tailnet only',
                style: TextStyle(
                  color:
                      entry.funnel ? LunaColours.orange : LunaColours.accent,
                  fontWeight: LunaUI.FONT_WEIGHT_BOLD,
                ),
              ),
              const TextSpan(
                text: 'Tailscale Funnel — flips live, no restart',
              ),
            ],
            trailing: LunaSwitch(
              value: entry.funnel,
              onChanged: busy ? null : (v) => _setFunnel(entry, v),
            ),
          );
        },
      ),
    );
  }

  bool _funnelPending = false;

  Future<void> _setFunnel(TailarrServerNetworkEntry entry, bool enable) async {
    final state = context.read<TailarrServerState>();
    if (enable) {
      // Mirrors the web UI: confirm on expose, not on making private.
      final confirmed = await TailarrServerDialogs().confirmAction(
        context,
        title: 'Make ${entry.name} Public',
        message:
            'Expose ${entry.name} to the ENTIRE internet via Tailscale Funnel? Anyone with the URL can reach it — the service\'s own login becomes the only protection.',
        buttonText: 'Make Public',
        buttonColor: LunaColours.orange,
      );
      if (!confirmed) return;
    }
    setState(() => _funnelPending = true);
    try {
      final result = await state.api!.setFunnel(entry.name, enable);
      if (result.ok) {
        showLunaSuccessSnackBar(
          title: enable ? 'Now Public' : 'Now Private',
          message: enable
              ? 'https://${entry.dnsName} is reachable from the internet'
              : '${entry.name} is tailnet-only again',
        );
      } else {
        final detail = result.error ?? result.status;
        showLunaErrorSnackBar(
          title: 'Funnel Change Failed',
          message: result.status == 'funnel refused'
              ? '$detail\n${result.output.split('\n').take(3).join('\n')}'
              : detail,
        );
      }
    } catch (error, stack) {
      LunaLogger().error('Funnel toggle failed', error, stack);
      showLunaErrorSnackBar(title: 'Funnel Change Failed', error: error);
    } finally {
      if (mounted) setState(() => _funnelPending = false);
      state.resetPods();
    }
  }

  List<Widget> _actionBlocks(TailarrServerPod pod) {
    return [
      if (!pod.isRunning)
        LunaBlock(
          title: 'Start',
          body: const [TextSpan(text: 'Start the pod')],
          trailing: const LunaIconButton(
            icon: Icons.play_arrow_rounded,
            color: LunaColours.accent,
          ),
          onTap: () => _runAction(pod, 'start'),
        ),
      if (pod.isRunning)
        LunaBlock(
          title: 'Stop',
          body: const [TextSpan(text: 'Stop the pod and its sidecar')],
          trailing: const LunaIconButton(
            icon: Icons.stop_rounded,
            color: LunaColours.red,
          ),
          onTap: () => _runAction(pod, 'stop', confirm: true),
        ),
      LunaBlock(
        title: 'Update',
        body: const [
          TextSpan(text: 'Pull the latest image and recreate the pod'),
        ],
        trailing: const LunaIconButton(
          icon: Icons.download_rounded,
          color: LunaColours.orange,
        ),
        onTap: () => _runAction(pod, 'update', confirm: true),
      ),
    ];
  }

  Widget _logsBlock() {
    return LunaBlock(
      title: 'Logs',
      body: const [TextSpan(text: 'View the most recent log output')],
      trailing: const LunaIconButton(icon: Icons.developer_mode_rounded),
      onTap: () => TailarrServerRoutes.POD_LOGS.go(
        params: {'pod': widget.pod},
      ),
    );
  }

  Widget _backupsBlock() {
    return LunaBlock(
      title: 'Backups',
      body: const [TextSpan(text: 'Create, restore, and manage snapshots')],
      trailing: const LunaIconButton(icon: Icons.settings_backup_restore_rounded),
      onTap: () => TailarrServerRoutes.POD_BACKUPS.go(
        params: {'pod': widget.pod},
      ),
    );
  }

  Future<void> _runAction(
    TailarrServerPod pod,
    String action, {
    bool confirm = false,
  }) async {
    final state = context.read<TailarrServerState>();
    if (confirm) {
      final confirmed = await TailarrServerDialogs().confirmAction(
        context,
        title: '${action.toTitleCase()} ${pod.name}',
        message: 'Are you sure you want to $action ${pod.name}?',
        buttonText: action.toTitleCase(),
      );
      if (!confirmed) return;
    }
    showLunaInfoSnackBar(
      title: '${action.toTitleCase()}ing ${pod.name}',
      message: 'This can take a while…',
    );
    await state.api!.podAction(pod.name, action).then((result) {
      if (result.ok) {
        showLunaSuccessSnackBar(
          title: '${action.toTitleCase()} Complete',
          message: pod.name,
        );
      } else {
        showLunaErrorSnackBar(
          title: '${action.toTitleCase()} Failed',
          message: result.error ?? result.status,
        );
      }
      state.resetPods();
    }).catchError((error, stack) {
      LunaLogger().error('Pod action failed', error, stack);
      showLunaErrorSnackBar(title: 'Action Failed', error: error);
    });
  }
}
