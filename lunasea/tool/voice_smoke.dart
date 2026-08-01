/// Standalone proof harness for the in-app voice loop.
///
/// Exercises the EXACT shipped Dart classes (VoiceSession -> GeminiLiveClient +
/// TailarrMcp) against the real Gemini Live API and the real Tailarr MCP funnel,
/// with no Flutter/iOS in the loop. This proves the core in-app networking code
/// end-to-end; the Flutter screen is a thin ChangeNotifier over the same
/// VoiceSession.
///
/// Secrets come from the environment (never committed / never hardcoded):
///   GEMINI_API_KEY   AI Studio key (Phase 1 only; Phase 2 uses an ephemeral token)
///   TAILARR_MCP_URL  the funnel MCP endpoint (…ts.net/mcp)
///   TAILARR_MCP_TOKEN a person's tailarr-mcp-... bearer
///
/// Run:
///   set -a; source ../../tailarr-ops/spikes/gemini-live-mcp/.env; set +a
///   dart run tool/voice_smoke.dart "How is the server doing?" "Do I have Dune?"
library;

import 'dart:io';

import 'package:lunasea/modules/voice/core/voice_session.dart';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final apiKey = env['GEMINI_API_KEY'] ?? '';
  final mcpUrl = env['TAILARR_MCP_URL'] ?? '';
  final mcpToken = env['TAILARR_MCP_TOKEN'] ?? '';
  final model = env['GEMINI_LIVE_MODEL'] ?? kDefaultLiveModel;

  if (apiKey.isEmpty || mcpUrl.isEmpty || mcpToken.isEmpty) {
    stderr.writeln('BLOCKED: set GEMINI_API_KEY, TAILARR_MCP_URL, TAILARR_MCP_TOKEN');
    exit(2);
  }

  final queries = args.isNotEmpty
      ? args
      : ['How is the server doing?', 'Do I have Dune?'];

  final session = VoiceSession(
    apiKey: apiKey,
    mcpUrl: mcpUrl,
    mcpToken: mcpToken,
    model: model,
  );

  session.toolActivity.listen((a) {
    if (a.result == null) {
      stdout.writeln('  [tool-call] ${a.name}(${a.args})');
    } else {
      stdout.writeln('  [tool-result] ${a.isError ? 'ERROR ' : ''}${a.result}');
    }
  });

  stdout.writeln('[connecting] model=$model');
  final whoami = await session.start();
  stdout.writeln('[mcp] connected as: $whoami');
  stdout.writeln('[gemini] exposing ${session.exposedTools.length} read-only '
      'tools: ${session.exposedTools.join(', ')}');

  for (final q in queries) {
    stdout.writeln('\n[you] $q');
    final answer = await session.driveTextTurn(q);
    stdout.writeln('[spoken] $answer');
  }

  await session.close();
  stdout.writeln('\n[done]');
  exit(0);
}
