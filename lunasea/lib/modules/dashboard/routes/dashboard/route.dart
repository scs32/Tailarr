import 'package:flutter/material.dart';

import 'package:lunasea/modules.dart';
import 'package:lunasea/widgets/ui.dart';
import 'package:lunasea/modules/voice/widgets/assistant_view.dart';

/// The Dashboard home: the full-page voice/text assistant (Gemini Live).
///
/// Per Stephen's 2026-08 directive the dashboard is a normal, full-screen chat
/// with the assistant — there is no bottom tab bar. The old Modules launcher
/// still lives in the hamburger drawer, and the release Calendar view
/// (`pages/calendar.dart`) is retained in the codebase but no longer surfaced
/// here.
class DashboardRoute extends StatefulWidget {
  const DashboardRoute({
    super.key,
  });

  @override
  State<DashboardRoute> createState() => _State();
}

class _State extends State<DashboardRoute> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LunaScaffold(
      scaffoldKey: _scaffoldKey,
      module: LunaModule.DASHBOARD,
      appBar: _appBar(),
      drawer: LunaDrawer(page: LunaModule.DASHBOARD.key),
      body: AssistantView(scrollController: _scroll),
    );
  }

  PreferredSizeWidget _appBar() {
    return LunaAppBar(
      title: 'Tailarr',
      useDrawer: true,
      scrollControllers: [_scroll],
    );
  }
}
