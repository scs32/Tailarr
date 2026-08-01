import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/modules/voice/widgets/assistant_view.dart';

/// Standalone in-app voice-assistant screen (Gemini Live), reached from the
/// drawer and the deep link `tailarr:///voice_assistant`.
///
/// The same chat surface is also the Dashboard home (see
/// `dashboard/routes/dashboard/route.dart`); both render the shared
/// [AssistantView], so there is a single assistant UI. Connection is lazy — the
/// first sent turn dials Gemini + the Tailarr MCP.
class VoiceRoute extends StatefulWidget {
  static const String path = '/voice_assistant';

  const VoiceRoute({super.key});

  @override
  State<VoiceRoute> createState() => _State();
}

class _State extends State<VoiceRoute> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
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
      appBar: LunaAppBar(
        title: 'Voice Assistant',
        scrollControllers: [_scroll],
      ),
      body: AssistantView(scrollController: _scroll),
    );
  }
}
