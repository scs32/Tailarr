import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/modules/voice/core/state.dart';
import 'package:lunasea/modules/voice/widgets/assistant_orb.dart';

/// The voice-assistant surface: a mesh-decorated pulsing [AssistantOrb] you talk
/// to, with the conversation transcript and a text lane beneath it.
///
/// Shared by the Dashboard's home tab (the orb *is* the dashboard) and the
/// standalone [VoiceRoute] reached from the drawer, so there is a single
/// assistant UI. Connection is lazy — nothing dials Gemini/MCP until the user
/// actually sends a turn (see [VoiceAssistantState.sendText]), so landing on the
/// dashboard never opens a socket or fires an unconfigured-error on launch.
///
/// Increment 1: text lane only. The mic button is scaffolded for the audio
/// increment.
class AssistantView extends StatefulWidget {
  const AssistantView({
    super.key,
    required this.scrollController,
  });

  /// Scroll controller for the transcript, shared with the host app bar so
  /// tap-to-scroll-top keeps working.
  final ScrollController scrollController;

  @override
  State<AssistantView> createState() => _AssistantViewState();
}

class _AssistantViewState extends State<AssistantView> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _submit(String value) {
    if (value.trim().isEmpty) return;
    context.read<VoiceAssistantState>().sendText(value);
    _input.clear();
    _scrollToEnd();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.scrollController.hasClients) {
        widget.scrollController.animateTo(
          widget.scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<VoiceAssistantState>(
      builder: (context, state, _) {
        final bool hasConversation = state.messages
            .any((m) => m.role != VoiceRole.system || m.isError);
        if (hasConversation) _scrollToEnd();
        return Column(
          children: [
            if (state.status == VoiceConnectionStatus.connecting)
              const LinearProgressIndicator(minHeight: 2.0),
            _orbHeader(state, compact: hasConversation),
            Expanded(child: _transcript(state, hasConversation)),
            _inputRow(state),
          ],
        );
      },
    );
  }

  Widget _orbHeader(VoiceAssistantState state, {required bool compact}) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 12.0 : 28.0),
      child: AssistantOrb(
        size: compact ? 108.0 : 208.0,
        intensity: _intensityFor(state),
        label: compact ? null : _labelFor(state),
      ),
    );
  }

  double _intensityFor(VoiceAssistantState state) {
    // Live-voice lane drives the orb through its idle->listening->thinking->
    // speaking states (public [AssistantOrb.intensity] API only — the mesh
    // worker owns the paint).
    if (state.voiceActive) {
      switch (state.activity) {
        case VoiceActivity.speaking:
          return 1.0;
        case VoiceActivity.thinking:
          return 0.9;
        case VoiceActivity.listening:
          return 0.7;
        case VoiceActivity.idle:
          return 0.4;
      }
    }
    if (state.turnInProgress) return 1.0;
    switch (state.status) {
      case VoiceConnectionStatus.connecting:
        return 0.6;
      case VoiceConnectionStatus.ready:
        return 0.2;
      case VoiceConnectionStatus.idle:
      case VoiceConnectionStatus.error:
        return 0.0;
    }
  }

  String _labelFor(VoiceAssistantState state) {
    if (state.voiceActive) {
      switch (state.activity) {
        case VoiceActivity.speaking:
          return 'Speaking…';
        case VoiceActivity.thinking:
          return 'Thinking…';
        case VoiceActivity.listening:
          return 'Listening…';
        case VoiceActivity.idle:
          return 'Starting…';
      }
    }
    if (state.turnInProgress) return 'Thinking…';
    switch (state.status) {
      case VoiceConnectionStatus.connecting:
        return 'Connecting…';
      case VoiceConnectionStatus.ready:
        return 'Ask me about your server';
      case VoiceConnectionStatus.error:
        return 'Tap to try again';
      case VoiceConnectionStatus.idle:
        return 'Talk to your media server';
    }
  }

  Widget _transcript(VoiceAssistantState state, bool hasConversation) {
    if (!hasConversation) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 32.0),
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
      controller: widget.scrollController,
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
            fontStyle:
                m.role == VoiceRole.tool ? FontStyle.italic : FontStyle.normal,
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
                controller: _input,
                scrollController: widget.scrollController,
                margin: EdgeInsets.zero,
                labelText: 'Ask the server…',
                labelIcon: Icons.forum_rounded,
                action: TextInputAction.send,
                onSubmitted: _submit,
              ),
            ),
            const SizedBox(width: 8.0),
            // Live-voice toggle: opens the mic + speaker duplex loop (16kHz in /
            // 24kHz out) to Gemini Live. Tap again to stop.
            LunaIconButton(
              icon: state.voiceActive
                  ? Icons.stop_circle_rounded
                  : Icons.mic_none_rounded,
              color: state.voiceActive ? LunaColours.accent : LunaColours.grey,
              onPressed: () => context.read<VoiceAssistantState>().toggleVoice(),
            ),
          ],
        ),
      ),
    );
  }
}
