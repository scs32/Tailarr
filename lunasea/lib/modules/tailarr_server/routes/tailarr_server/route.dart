import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/tailarr_server.dart';
import 'package:lunasea/router/routes/tailarr_server.dart';

class TailarrServerRoute extends StatefulWidget {
  const TailarrServerRoute({
    Key? key,
  }) : super(key: key);

  @override
  State<TailarrServerRoute> createState() => _State();
}

class _State extends State<TailarrServerRoute>
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
      drawer: LunaDrawer(page: LunaModule.TAILARR_SERVER.key),
      body: _body(),
      bottomNavigationBar: _bottomActionBar(),
    );
  }

  Widget _appBar() {
    return LunaAppBar(
      useDrawer: true,
      title: LunaModule.TAILARR_SERVER.title,
      scrollControllers: [scrollController],
      actions: [
        LunaIconButton(
          icon: Icons.people_alt_rounded,
          onPressed: TailarrServerRoutes.USERS.go,
        ),
        LunaIconButton(
          icon: Icons.system_update_alt_rounded,
          onPressed: TailarrServerRoutes.UPDATES.go,
        ),
      ],
    );
  }

  Widget _bottomActionBar() {
    return LunaBottomActionBar(
      actions: [
        LunaButton.text(
          text: 'Start All',
          icon: Icons.play_arrow_rounded,
          onTap: () => _fleetAction('start'),
        ),
        LunaButton.text(
          text: 'Restart All',
          icon: Icons.restart_alt_rounded,
          onTap: () => _fleetAction('restart'),
        ),
      ],
    );
  }

  Future<void> _fleetAction(String action) async {
    final state = context.read<TailarrServerState>();
    final confirmed = await TailarrServerDialogs().confirmAction(
      context,
      title: '${action.toTitleCase()} All Pods',
      message:
          'Are you sure you want to $action every pod? The controller pod is never touched.',
      buttonText: action.toTitleCase(),
      buttonColor: LunaColours.accent,
    );
    if (!confirmed) return;
    showLunaInfoSnackBar(
      title: '${action.asProgressLabel()} Fleet',
      message: 'This can take a while…',
    );
    await state.api!.fleetAction(action).then((result) {
      if (result.ok) {
        showLunaSuccessSnackBar(
          title: 'Fleet ${action.toTitleCase()} Complete',
          message: '${result.results.length} pods processed',
        );
      } else {
        showLunaErrorSnackBar(
          title: 'Fleet ${action.toTitleCase()} Failed',
          message: result.error ?? result.status,
        );
      }
      state.resetPods();
    }).catchError((error, stack) {
      LunaLogger().error('Fleet action failed', error, stack);
      showLunaErrorSnackBar(title: 'Fleet Action Failed', error: error);
    });
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
              if (snapshot.connectionState != ConnectionState.waiting)
                LunaLogger().error(
                  'Unable to fetch Tailarr Server pods',
                  snapshot.error,
                  snapshot.stackTrace,
                );
              return LunaMessage.error(onTap: _refreshKey.currentState!.show);
            }
            if (snapshot.hasData) return _list(snapshot.data);
            return const LunaLoader();
          },
        ),
      ),
    );
  }

  Widget _list(List<TailarrServerPod>? pods) {
    if ((pods?.length ?? 0) == 0)
      return LunaMessage(
        text: 'No Pods Found',
        buttonText: 'Refresh',
        onTap: _refreshKey.currentState!.show,
      );
    return LunaListViewBuilder(
      controller: scrollController,
      itemCount: pods!.length,
      itemBuilder: (context, index) => _podTile(pods[index]),
    );
  }

  Widget _podTile(TailarrServerPod pod) {
    return LunaBlock(
      title: pod.name,
      body: [
        TextSpan(
          text: pod.state.isEmpty ? 'stopped' : pod.state,
          style: TextStyle(
            color: pod.isRunning ? LunaColours.accent : LunaColours.red,
            fontWeight: LunaUI.FONT_WEIGHT_BOLD,
          ),
        ),
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
        TextSpan(text: pod.image),
      ],
      trailing: LunaIconButton(
        icon: pod.controller ? Icons.shield_rounded : Icons.dns_rounded,
        color: pod.updateAvailable
            ? LunaColours.orange
            : pod.isRunning
                ? LunaColours.accent
                : LunaColours.red,
      ),
      onTap: () => TailarrServerRoutes.POD_DETAILS.go(
        params: {'pod': pod.name},
      ),
    );
  }
}
