import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/extensions/int/bytes.dart';
import 'package:lunasea/modules/tailarr_server.dart';

class PodBackupsRoute extends StatefulWidget {
  final String pod;

  const PodBackupsRoute({
    Key? key,
    required this.pod,
  }) : super(key: key);

  @override
  State<PodBackupsRoute> createState() => _State();
}

class _State extends State<PodBackupsRoute> with LunaScrollControllerMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();
  Future<List<TailarrServerBackup>>? _backups;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    final api = context.read<TailarrServerState>().api;
    setState(() {
      _backups = api?.getBackups(widget.pod);
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
      title: '${widget.pod}: Backups',
      scrollControllers: [scrollController],
    );
  }

  Widget _bottomActionBar() {
    return LunaBottomActionBar(
      actions: [
        LunaButton.text(
          text: 'Back Up Now',
          icon: Icons.save_rounded,
          onTap: _createBackup,
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
        future: _backups,
        builder: (
          context,
          AsyncSnapshot<List<TailarrServerBackup>> snapshot,
        ) {
          if (snapshot.hasError) {
            return LunaMessage.error(onTap: _refreshKey.currentState!.show);
          }
          if (snapshot.hasData) return _list(snapshot.data!);
          return const LunaLoader();
        },
      ),
    );
  }

  Widget _list(List<TailarrServerBackup> backups) {
    if (backups.isEmpty) {
      return LunaMessage(
        text: 'No Backups Found',
        buttonText: 'Refresh',
        onTap: _refreshKey.currentState!.show,
      );
    }
    return LunaListViewBuilder(
      controller: scrollController,
      itemCount: backups.length,
      itemBuilder: (context, index) => _backupTile(backups[index]),
    );
  }

  Widget _backupTile(TailarrServerBackup backup) {
    final timestamp = backup.timestamp;
    return LunaBlock(
      title: timestamp == null
          ? backup.ts
          : DateFormat('MMMM dd, y — HH:mm').format(timestamp),
      body: [
        TextSpan(text: backup.size.asBytes()),
        if (backup.reason.isNotEmpty) TextSpan(text: backup.reason),
        TextSpan(text: backup.image),
      ],
      trailing: LunaIconButton(
        icon: LunaIcons.DELETE,
        color: LunaColours.red,
        onPressed: () => _deleteBackup(backup),
      ),
      onTap: () => _restoreBackup(backup),
    );
  }

  Future<void> _createBackup() async {
    final state = context.read<TailarrServerState>();
    final confirmed = await TailarrServerDialogs().confirmAction(
      context,
      title: 'Back Up ${widget.pod}',
      message:
          'The pod is stopped, snapshotted, and restarted — expect a brief outage. Continue?',
      buttonText: 'Back Up',
      buttonColor: LunaColours.accent,
    );
    if (!confirmed) return;
    showLunaInfoSnackBar(
      title: 'Backing Up ${widget.pod}',
      message: 'This can take a while…',
    );
    await state.api!.createBackup(widget.pod).then((result) {
      if (result.ok) {
        showLunaSuccessSnackBar(title: 'Backup Created', message: widget.pod);
      } else {
        showLunaErrorSnackBar(
          title: 'Backup Failed',
          message: result.error ?? result.status,
        );
      }
      _fetch();
    }).catchError((error, stack) {
      LunaLogger().error('Backup failed', error, stack);
      showLunaErrorSnackBar(title: 'Backup Failed', error: error);
    });
  }

  Future<void> _restoreBackup(TailarrServerBackup backup) async {
    final state = context.read<TailarrServerState>();
    final confirmed = await TailarrServerDialogs().confirmAction(
      context,
      title: 'Restore Backup',
      message:
          'Restore ${widget.pod} from ${backup.ts}? The pod\'s current data is REPLACED with this snapshot.',
      buttonText: 'Restore',
    );
    if (!confirmed) return;
    showLunaInfoSnackBar(
      title: 'Restoring ${widget.pod}',
      message: 'This can take a while…',
    );
    await state.api!.restoreBackup(widget.pod, backup.ts).then((result) {
      if (result.ok) {
        showLunaSuccessSnackBar(
          title: 'Restore Complete',
          message: widget.pod,
        );
      } else {
        showLunaErrorSnackBar(
          title: 'Restore Failed',
          message: result.error ?? result.status,
        );
      }
      state.resetPods();
    }).catchError((error, stack) {
      LunaLogger().error('Restore failed', error, stack);
      showLunaErrorSnackBar(title: 'Restore Failed', error: error);
    });
  }

  Future<void> _deleteBackup(TailarrServerBackup backup) async {
    final state = context.read<TailarrServerState>();
    final confirmed = await TailarrServerDialogs().confirmAction(
      context,
      title: 'Delete Backup',
      message: 'Delete the ${backup.ts} snapshot of ${widget.pod}?',
      buttonText: 'Delete',
    );
    if (!confirmed) return;
    await state.api!.deleteBackup(widget.pod, backup.ts).then((result) {
      if (result.ok) {
        showLunaSuccessSnackBar(title: 'Backup Deleted', message: backup.ts);
      } else {
        showLunaErrorSnackBar(
          title: 'Delete Failed',
          message: result.error ?? result.status,
        );
      }
      _fetch();
    }).catchError((error, stack) {
      LunaLogger().error('Backup delete failed', error, stack);
      showLunaErrorSnackBar(title: 'Delete Failed', error: error);
    });
  }
}
