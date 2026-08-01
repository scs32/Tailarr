import 'package:flutter/material.dart';

import 'package:lunasea/core.dart';
import 'package:lunasea/modules/voice/core/state.dart';
import 'package:lunasea/modules/voice/widgets/assistant_orb.dart';

/// The voice-assistant surface: a plain, conventional chat window you talk or
/// type to (Gemini Live). Message bubbles + scrollback + a text input with a
/// mic button; nothing else.
///
/// Shared by the Dashboard (the assistant *is* the dashboard home) and the
/// standalone [VoiceRoute] reached from the drawer, so there is a single
/// assistant UI. Connection is lazy — nothing dials Gemini/MCP until the user
/// actually sends a turn (see [VoiceAssistantState.sendText]), so landing on the
/// dashboard never opens a socket or fires an unconfigured-error on launch.
///
/// This surface is intentionally free of telemetry: the "Connected as…",
/// "Tools available…", per-tool call traces, and connection/status readouts are
/// deliberately NOT shown to the user. Only real, actionable errors (e.g. "AI
/// isn't enabled — ask your admin", mic-permission denied) surface, as a quiet
/// centered notice. The mesh orb appears only while a live-voice session is
/// active, as a listening/speaking indicator — not as a dashboard.
class AssistantView extends StatefulWidget {
  const AssistantView({
    super.key,
    required this.scrollController,
  });

  /// Scroll controller for the transcript, shared with the host app bar so
  /// tap-to-scroll-top keeps working.
  final ScrollController scrollController;

  /// The conversation as the USER sees it: their turns and the assistant's
  /// replies, plus any real error notice. Debug telemetry — the system status
  /// lines ("Connected as…", "Tools available…", "Connecting…") and the
  /// per-tool call traces — is filtered out entirely.
  ///
  /// Kept as a pure static so the debug-hiding contract can be unit-tested
  /// without a full widget bootstrap.
  static List<VoiceMessage> visibleMessages(Iterable<VoiceMessage> messages) {
    final list = messages.toList();
    final result = <VoiceMessage>[];
    for (var i = 0; i < list.length; i++) {
      final m = list[i];
      final bool isLast = i == list.length - 1;
      switch (m.role) {
        case VoiceRole.user:
          result.add(m);
          break;
        case VoiceRole.assistant:
          // The turn pre-creates an empty assistant bubble that the streamed
          // reply fills in. When a tool call lands first, the real reply becomes
          // a LATER assistant bubble, orphaning that placeholder — which would
          // otherwise render as a stray "…". Drop an empty assistant line once
          // it's been superseded; keep it only while it's the latest line (the
          // live "thinking" placeholder).
          if (m.text.isEmpty && !isLast) break;
          result.add(m);
          break;
        case VoiceRole.tool:
          // Tool-call traces are debug telemetry — never shown. A FAILED tool
          // call is surfaced (as a generic notice, no internals) so a silent
          // failure the model doesn't verbalize isn't invisible to the user.
          if (m.isError) result.add(m);
          break;
        case VoiceRole.system:
          // Only surface real, actionable errors; hide status/telemetry lines.
          if (m.isError) result.add(m);
          break;
      }
    }
    return result;
  }

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
        final visible = AssistantView.visibleMessages(state.messages);
        if (visible.isNotEmpty) _scrollToEnd();
        return Column(
          children: [
            // A plain progress bar (not telemetry) so the first typed turn's
            // Gemini + MCP dial isn't silent dead air.
            if (state.status == VoiceConnectionStatus.connecting)
              const LinearProgressIndicator(minHeight: 2.0),
            Expanded(child: _transcript(visible)),
            if (state.voiceActive) _voiceIndicator(state),
            _inputRow(state),
          ],
        );
      },
    );
  }

  /// A small, quiet orb shown only while the live-voice lane is active, as a
  /// listening/thinking/speaking indicator. Not a dashboard, not a status
  /// readout — just visual feedback that the mic is live.
  Widget _voiceIndicator(VoiceAssistantState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: AssistantOrb(
        size: 72.0,
        intensity: _intensityFor(state),
      ),
    );
  }

  double _intensityFor(VoiceAssistantState state) {
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

  Widget _transcript(List<VoiceMessage> visible) {
    if (visible.isEmpty) {
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
      itemCount: visible.length,
      itemBuilder: (context, i) => _bubble(visible[i]),
    );
  }

  Widget _bubble(VoiceMessage m) {
    // Errors render as a quiet centered notice; conversation turns render as
    // left/right chat bubbles. Only errors reach here for system/tool roles
    // (see [visibleMessages]); a failed tool call shows a generic message
    // rather than its raw name/args.
    if (m.role == VoiceRole.system || m.role == VoiceRole.tool) {
      final text = m.role == VoiceRole.tool
          ? 'Something went wrong. Please try again.'
          : m.text;
      return Align(
        alignment: Alignment.center,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6.0),
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: LunaColours.red,
              fontSize: LunaUI.FONT_SIZE_H5,
            ),
          ),
        ),
      );
    }

    final bool isUser = m.role == VoiceRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4.0),
        padding: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 10.0),
        constraints: const BoxConstraints(maxWidth: 320.0),
        decoration: BoxDecoration(
          color: isUser ? LunaColours.accent : LunaColours.primary,
          borderRadius: BorderRadius.circular(LunaUI.BORDER_RADIUS),
        ),
        child: Text(
          m.text.isEmpty ? '…' : m.text,
          style: const TextStyle(
            color: LunaColours.white,
            fontSize: LunaUI.FONT_SIZE_H4,
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
