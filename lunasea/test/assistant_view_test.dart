import 'package:flutter_test/flutter_test.dart';

import 'package:lunasea/modules/voice/core/state.dart';
import 'package:lunasea/modules/voice/widgets/assistant_view.dart';

/// Locks the assistant chat's debug-hiding contract: the user sees a normal
/// conversation (their turns + the assistant's replies) and genuine errors —
/// and NEVER the connection/tool telemetry that used to leak into the UI
/// ("Connected as…", "Tools available…", per-tool call traces, status lines).
void main() {
  group('AssistantView.visibleMessages', () {
    test('hides connection + tools telemetry (non-error system lines)', () {
      final visible = AssistantView.visibleMessages([
        VoiceMessage(VoiceRole.system,
            'Connecting to Gemini Live and the Tailarr MCP…'),
        VoiceMessage(VoiceRole.system, 'Connected as: You are Stephen (admin)'),
        VoiceMessage(
            VoiceRole.system, 'Tools available: whoami, search_library'),
        VoiceMessage(VoiceRole.system, 'Listening… speak, and tap the mic.'),
      ]);
      expect(visible, isEmpty);
    });

    test('hides tool-call traces', () {
      final visible = AssistantView.visibleMessages([
        VoiceMessage(VoiceRole.tool, 'calling search_library({q: dune})…'),
        VoiceMessage(VoiceRole.tool, 'search_library({q: dune}) → [Dune]'),
      ]);
      expect(visible, isEmpty);
    });

    test('shows user + assistant turns in order', () {
      final visible = AssistantView.visibleMessages([
        VoiceMessage(VoiceRole.user, 'Do I have Dune?'),
        VoiceMessage(VoiceRole.system, 'Tools available: search_library'),
        VoiceMessage(VoiceRole.tool, 'calling search_library(...)…'),
        VoiceMessage(VoiceRole.assistant, 'Yes, Dune (2021) is in your library.'),
      ]);
      expect(visible.map((m) => m.role).toList(),
          [VoiceRole.user, VoiceRole.assistant]);
      expect(visible.first.text, 'Do I have Dune?');
      expect(visible.last.text, 'Yes, Dune (2021) is in your library.');
    });

    test('surfaces genuine errors (actionable system lines)', () {
      final visible = AssistantView.visibleMessages([
        VoiceMessage(VoiceRole.system,
            'AI access isn\'t enabled — ask your admin.',
            isError: true),
        VoiceMessage(VoiceRole.system, 'Connected as: someone'),
      ]);
      expect(visible, hasLength(1));
      expect(visible.single.isError, isTrue);
      expect(visible.single.text, contains('ask your admin'));
    });
  });
}
