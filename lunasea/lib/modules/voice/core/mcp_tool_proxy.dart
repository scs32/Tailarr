/// Tailarr MCP funnel client for the in-app Gemini Live voice assistant.
///
/// Dart port of `spikes/gemini-live-mcp/mcp_client.py`. Talks to the Tailarr
/// MCP over the public Tailscale Funnel plane (Streamable-HTTP JSON-RPC,
/// `POST /mcp`) using a PERSON's `tailarr-mcp-` bearer token. It:
///
///   - lists the MCP tool catalog (`tools/list`),
///   - filters it to a READ-ONLY allowlist (voice must never mutate anything),
///   - converts each tool's JSON-Schema into a Gemini FunctionDeclaration, and
///   - proxies a Gemini function-call to the MCP (`tools/call`), returning the
///     one-line `summary` PLUS the full `structuredContent` envelope (Gemini
///     reads titles from `structuredContent`, not just the summary).
///
/// Auth model (see handoff/voice-mcp-feature-scope.md): the token is per-person
/// and badge-scoped; the server re-derives scopes from live badges every call,
/// so this client acts *as the person* and the person's scopes gate which tools
/// succeed. Gemini never sees the token or the tailnet.
///
/// Deliberately depends ONLY on dart:io + dart:convert (no Flutter, no Dio) so
/// the exact shipped code is exercised by the standalone proof harness
/// (`tool/voice_smoke.dart`). In the Flutter app the split-tunnel HttpOverrides
/// installed by `tailscale_embed` route the funnel host (`*.ts.net`) through the
/// embedded node automatically; from a laptop the funnel origin is publicly
/// reachable over HTTPS (DIRECT), which is how the Python spike ran.
library;

import 'dart:convert';
import 'dart:io';

/// READ-ONLY allowlist. The write tools (`preview_request`/`submit_request`/
/// `cancel_request`) and `list_requests` are deliberately excluded so voice can
/// never submit or mutate a request. Belt-and-suspenders: the person token also
/// lacks `request.write` server-side.
const Set<String> kReadonlyTools = {
  'whoami',
  'search_library',
  'get_media_status',
  'get_download_status',
  'search_catalog',
  'get_service_status',
  'get_system_health',
  'get_storage_overview',
  'list_people',
  'explain_setup',
};

class McpError implements Exception {
  McpError(this.message);
  final String message;
  @override
  String toString() => 'McpError: $message';
}

/// Result of a proxied tool call. `summary` is the one-line voice-friendly text;
/// `structured` is the full envelope Gemini uses to read structured detail.
class McpToolResult {
  McpToolResult({required this.summary, this.structured, this.isError = false});
  final String summary;
  final Object? structured;
  final bool isError;
}

/// A read-only MCP tool exposed to Gemini as a function declaration.
class McpTool {
  McpTool({required this.name, required this.description, this.inputSchema});
  final String name;
  final String description;
  final Map<String, dynamic>? inputSchema;
}

class TailarrMcp {
  TailarrMcp({
    required this.url,
    required this.token,
    this.timeout = const Duration(seconds: 30),
  });

  /// Funnel-plane endpoint, e.g. `https://tailarr-mcp.<tn>.ts.net/mcp`.
  final String url;

  /// A person's `tailarr-mcp-...` bearer.
  final String token;
  final Duration timeout;

  int _id = 0;
  final HttpClient _http = HttpClient()..connectionTimeout = const Duration(seconds: 15);

  Future<Map<String, dynamic>> _rpc(String method, Map<String, dynamic> params) async {
    _id += 1;
    final bodyBytes = utf8.encode(jsonEncode({
      'jsonrpc': '2.0',
      'id': _id,
      'method': method,
      'params': params,
    }));
    final uri = Uri.parse(url);
    final req = await _http.postUrl(uri).timeout(timeout);
    req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    // The Tailarr MCP is application/json only; also advertise SSE per spec.
    req.headers.set(HttpHeaders.acceptHeader, 'application/json, text/event-stream');
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    // Set an explicit Content-Length so HttpClient sends a plain (non-chunked)
    // body — the funnel/server returns an empty body for chunked POSTs.
    req.contentLength = bodyBytes.length;
    req.add(bodyBytes);
    final resp = await req.close().timeout(timeout);
    final text = await resp.transform(utf8.decoder).join().timeout(timeout);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw McpError('HTTP ${resp.statusCode}: $text');
    }
    final payload = _decodeMcpBody(text);
    if (payload.containsKey('error')) {
      throw McpError(jsonEncode(payload['error']));
    }
    return (payload['result'] as Map).cast<String, dynamic>();
  }

  /// The Tailarr MCP replies `application/json`, but be tolerant of an
  /// `text/event-stream` framing (`data: {...}`) too, matching the spec.
  Map<String, dynamic> _decodeMcpBody(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{')) {
      return (jsonDecode(trimmed) as Map).cast<String, dynamic>();
    }
    for (final line in const LineSplitter().convert(text)) {
      if (line.startsWith('data:')) {
        final data = line.substring(5).trim();
        if (data.isNotEmpty && data != '[DONE]') {
          return (jsonDecode(data) as Map).cast<String, dynamic>();
        }
      }
    }
    throw McpError('Unparseable MCP response: $text');
  }

  Future<Map<String, dynamic>> initialize() {
    return _rpc('initialize', {
      'protocolVersion': '2025-06-18',
      'capabilities': {},
      'clientInfo': {'name': 'tailarr-app-voice', 'version': '0'},
    });
  }

  /// Fetch the catalog, filtered to the read-only allowlist by default.
  Future<List<McpTool>> listTools({bool readonlyOnly = true}) async {
    final result = await _rpc('tools/list', {});
    final raw = (result['tools'] as List?) ?? const [];
    final tools = <McpTool>[];
    for (final t in raw) {
      final m = (t as Map).cast<String, dynamic>();
      final name = m['name'] as String;
      if (readonlyOnly && !kReadonlyTools.contains(name)) continue;
      tools.add(McpTool(
        name: name,
        description: (m['description'] as String?) ?? '',
        inputSchema: (m['inputSchema'] as Map?)?.cast<String, dynamic>(),
      ));
    }
    return tools;
  }

  /// Proxy a Gemini function-call to the MCP. Hard-guards the read-only
  /// allowlist even if the model hallucinates a write tool.
  Future<McpToolResult> callTool(String name, Map<String, dynamic> arguments) async {
    if (!kReadonlyTools.contains(name)) {
      return McpToolResult(
        summary: "Tool '$name' is not permitted in this assistant.",
        structured: {'ok': false, 'error': 'tool not permitted'},
        isError: true,
      );
    }
    final result = await _rpc('tools/call', {'name': name, 'arguments': arguments});
    final content = (result['content'] as List?) ?? const [];
    var summary = '';
    for (final c in content) {
      final m = (c as Map).cast<String, dynamic>();
      if (m['type'] == 'text') {
        summary = (m['text'] as String?) ?? '';
        break;
      }
    }
    return McpToolResult(
      summary: summary,
      structured: result['structuredContent'],
      isError: result['isError'] == true,
    );
  }

  void close() => _http.close(force: true);
}

// ---- JSON-Schema -> Gemini Schema conversion -------------------------------

const Set<String> _kAllowedSchemaKeys = {
  'type',
  'description',
  'enum',
  'properties',
  'items',
  'required',
  'nullable',
};

/// Strip keys Gemini's Schema type rejects (e.g. `additionalProperties`) and
/// recurse. MCP inputSchemas use closed-world `additionalProperties:false`,
/// which the Gemini function-declaration schema does not accept.
Map<String, dynamic> sanitizeSchema(Map<String, dynamic> schema) {
  final out = <String, dynamic>{};
  schema.forEach((k, v) {
    if (!_kAllowedSchemaKeys.contains(k)) return;
    if (k == 'properties' && v is Map) {
      out[k] = <String, dynamic>{
        for (final e in v.entries)
          e.key as String: sanitizeSchema((e.value as Map).cast<String, dynamic>()),
      };
    } else if (k == 'items' && v is Map) {
      out[k] = sanitizeSchema(v.cast<String, dynamic>());
    } else {
      out[k] = v;
    }
  });
  return out;
}

/// Return a Gemini FunctionDeclaration JSON for an MCP tool. Omits `parameters`
/// entirely for no-arg tools (Gemini rejects an empty object schema for some
/// models).
Map<String, dynamic> toFunctionDeclaration(McpTool tool) {
  final decl = <String, dynamic>{
    'name': tool.name,
    'description': tool.description,
  };
  final params = sanitizeSchema(tool.inputSchema ?? const {});
  final props = params['properties'];
  if (props is Map && props.isNotEmpty) {
    decl['parameters'] = params;
  }
  return decl;
}
