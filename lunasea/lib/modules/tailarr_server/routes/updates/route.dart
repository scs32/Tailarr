import 'package:flutter/material.dart';
import 'package:lunasea/core.dart';
import 'package:lunasea/modules/tailarr_server.dart';

class UpdatesRoute extends StatefulWidget {
  const UpdatesRoute({
    Key? key,
  }) : super(key: key);

  @override
  State<UpdatesRoute> createState() => _State();
}

class _State extends State<UpdatesRoute>
    with LunaScrollControllerMixin, LunaLoadCallbackMixin {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _refreshKey = GlobalKey<RefreshIndicatorState>();

  @override
  Future<void> loadCallback() async {
    context.read<TailarrServerState>().resetUpdates();
    await context.read<TailarrServerState>().updates;
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
      title: 'Image Updates',
      scrollControllers: [scrollController],
    );
  }

  Widget _bottomActionBar() {
    return LunaBottomActionBar(
      actions: [
        LunaButton.text(
          text: 'Check Now',
          icon: LunaIcons.REFRESH,
          onTap: () async {
            final state = context.read<TailarrServerState>();
            await state.api!.refreshUpdates();
            showLunaInfoSnackBar(
              title: 'Checking for Updates',
              message: 'Refresh in a moment to see results',
            );
          },
        ),
      ],
    );
  }

  Widget _body() {
    return LunaRefreshIndicator(
      context: context,
      key: _refreshKey,
      onRefresh: loadCallback,
      child: Selector<TailarrServerState, Future<TailarrServerUpdates>?>(
        selector: (_, state) => state.updates,
        builder: (context, updates, _) => FutureBuilder(
          future: updates,
          builder: (context, AsyncSnapshot<TailarrServerUpdates> snapshot) {
            if (snapshot.hasError) {
              return LunaMessage.error(onTap: _refreshKey.currentState!.show);
            }
            if (snapshot.hasData) return _list(snapshot.data!);
            return const LunaLoader();
          },
        ),
      ),
    );
  }

  Widget _list(TailarrServerUpdates updates) {
    if (updates.images.isEmpty) {
      return LunaMessage(
        text: updates.checking
            ? 'Checking for Updates…'
            : 'No Image Data Found',
        buttonText: 'Refresh',
        onTap: _refreshKey.currentState!.show,
      );
    }
    final images = [...updates.images]..sort((a, b) {
        if (a.updateAvailable != b.updateAvailable) {
          return a.updateAvailable ? -1 : 1;
        }
        return a.image.compareTo(b.image);
      });
    return LunaListViewBuilder(
      controller: scrollController,
      itemCount: images.length,
      itemBuilder: (context, index) => _imageTile(images[index]),
    );
  }

  Widget _imageTile(TailarrServerImageUpdate image) {
    return LunaBlock(
      title: image.image,
      body: [
        TextSpan(
          text: image.updateAvailable ? 'Update available' : 'Up to date',
          style: TextStyle(
            color: image.updateAvailable
                ? LunaColours.orange
                : LunaColours.accent,
            fontWeight: LunaUI.FONT_WEIGHT_BOLD,
          ),
        ),
      ],
      trailing: LunaIconButton(
        icon: image.updateAvailable
            ? Icons.download_rounded
            : Icons.check_circle_rounded,
        color:
            image.updateAvailable ? LunaColours.orange : LunaColours.accent,
      ),
    );
  }
}
