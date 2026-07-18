import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/extensions/string/string.dart';
import 'package:lunasea/modules/tailarr_server.dart';

class PodLogsRoute extends StatefulWidget {
  final String pod;

  const PodLogsRoute({
    Key? key,
    required this.pod,
  }) : super(key: key);

  @override
  State<PodLogsRoute> createState() => _State();
}

class _State extends State<PodLogsRoute> with LunaScrollControllerMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();
  Future<TailarrServerActionResult>? _logs;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    final api = context.read<TailarrServerState>().api;
    setState(() => _logs = api?.getLogs(widget.pod));
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
      title: '${widget.pod}: Logs',
      scrollControllers: [scrollController],
    );
  }

  Widget _body() {
    return LunaRefreshIndicator(
      context: context,
      key: _refreshKey,
      onRefresh: () async => _fetch(),
      child: FutureBuilder(
        future: _logs,
        builder: (
          context,
          AsyncSnapshot<TailarrServerActionResult> snapshot,
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

  Widget _list(TailarrServerActionResult result) {
    final lines = result.output
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) {
      return LunaMessage(
        text: 'No Logs Found',
        buttonText: 'Refresh',
        onTap: _refreshKey.currentState!.show,
      );
    }
    return LunaListViewBuilder(
      controller: scrollController,
      itemCount: lines.length,
      itemBuilder: (context, index) => LunaBlock(
        title: lines[index],
        onTap: () async => lines[index].copyToClipboard(),
      ),
    );
  }
}
