import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/modules/voice/core/state.dart';

/// In-app Gemini Live voice assistant screen (Phase 1).
///
/// Text lane is fully wired: type a question → Gemini Live drives the Tailarr
/// MCP (read-only, as the person) → a grounded answer streams back. The mic
/// button is scaffolded for the Phase-1b audio loop (see plan).
class VoiceRoute extends StatefulWidget {
  static const String path = '/voice_assistant';

  const VoiceRoute({super.key});

  @override
  State<VoiceRoute> createState() => _State();
}

class _State extends State<VoiceRoute> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // Connect on open so the first turn is snappy. Fire-and-forget.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<VoiceAssistantState>().ensureConnected();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _submit(String value) {
    if (value.trim().isEmpty) return;
    context.read<VoiceAssistantState>().sendText(value);
    _controller.clear();
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

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
      title: 'Voice Assistant',
      scrollControllers: [_scroll],
    );
  }

  Widget _body() {
    return Consumer<VoiceAssistantState>(
      builder: (context, state, _) {
        _scrollToEnd();
        return Column(
          children: [
            if (state.status == VoiceConnectionStatus.connecting)
              const LinearProgressIndicator(minHeight: 2.0),
            Expanded(child: _transcript(state)),
            _inputRow(state),
          ],
        );
      },
    );
  }

  Widget _transcript(VoiceAssistantState state) {
    if (state.messages.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Text(
            'Ask about your media server.\n'
            'e.g. "How is the server doing?" or "Do I have Dune?"',
            textAlign: TextAlign.center,
            style: TextStyle(color: LunaColours.grey),
          ),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      padding: LunaUI.MARGIN_DEFAULT,
      itemCount: state.messages.length,
      itemBuilder: (context, i) => _bubble(state.messages[i]),
    );
  }

  Widget _bubble(VoiceMessage m) {
    final Color color;
    final Alignment align;
    final String prefix;
    switch (m.role) {
      case VoiceRole.user:
        color = LunaColours.accent;
        align = Alignment.centerRight;
        prefix = '';
        break;
      case VoiceRole.assistant:
        color = LunaColours.primary;
        align = Alignment.centerLeft;
        prefix = '';
        break;
      case VoiceRole.tool:
        color = LunaColours.blueGrey;
        align = Alignment.centerLeft;
        prefix = '🔧 ';
        break;
      case VoiceRole.system:
        color = Colors.transparent;
        align = Alignment.center;
        prefix = '';
        break;
    }
    final textColor = m.isError
        ? LunaColours.red
        : (m.role == VoiceRole.system ? LunaColours.grey : LunaColours.white);
    return Align(
      alignment: align,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4.0),
        padding: m.role == VoiceRole.system
            ? const EdgeInsets.symmetric(vertical: 4.0)
            : const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
        constraints: const BoxConstraints(maxWidth: 320.0),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(LunaUI.BORDER_RADIUS),
        ),
        child: Text(
          '$prefix${m.text.isEmpty ? '…' : m.text}',
          style: TextStyle(
            color: textColor,
            fontSize: m.role == VoiceRole.system
                ? LunaUI.FONT_SIZE_H5
                : LunaUI.FONT_SIZE_H4,
            fontStyle: m.role == VoiceRole.tool
                ? FontStyle.italic
                : FontStyle.normal,
          ),
        ),
      ),
    );
  }

  Widget _inputRow(VoiceAssistantState state) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: LunaTextInputBar.appBarMargin,
        child: Row(
          children: [
            Expanded(
              child: LunaTextInputBar(
                controller: _controller,
                scrollController: _scroll,
                margin: EdgeInsets.zero,
                labelText: 'Ask the server…',
                labelIcon: Icons.forum_rounded,
                action: TextInputAction.send,
                onSubmitted: _submit,
              ),
            ),
            const SizedBox(width: 8.0),
            // Scaffolded mic button — Phase 1b wires mic PCM -> Live -> speaker.
            LunaIconButton(
              icon: Icons.mic_none_rounded,
              color: LunaColours.grey,
              onPressed: () => _showMicNotYet(),
            ),
          ],
        ),
      ),
    );
  }

  void _showMicNotYet() {
    showLunaSnackBar(
      title: 'Voice capture coming soon',
      message: 'Phase 1 ships the text lane; mic + speaker are Phase 1b.',
      type: LunaSnackbarType.INFO,
    );
  }
}
