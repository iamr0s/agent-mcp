import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Internal wire prefix allowing `ToolHandler`s (including Sub-MCP passthrough)
/// to return full multimodal MCP `CallToolResult` payloads (`image`, `audio`,
/// `resource`, `resource_link`, `structuredContent`) without breaking string signatures.
const String kMcpStructuredCallResultPrefix = '__AGENT_MCP_CALL_RESULT_JSON__:';

/// Strictly normalizes any tool name into `[A-Za-z0-9_-]{1,64}` (SEP-986 & OpenAI/Claude/Gemini
/// cross-host safe intersection). Truncates >64-char names deterministically with a 6-hex hash.
String buildSafeMcpToolName({
  required String globalPrefix,
  required String subPrefix,
  required String rawToolName,
  Set<String>? usedNames,
}) {
  String cleanToken(String s) => s
      .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  final g = cleanToken(globalPrefix);
  final sp = cleanToken(subPrefix);
  var t = cleanToken(rawToolName);
  if (t.isEmpty) t = 'tool';

  final parts = <String>[
    if (g.isNotEmpty) g,
    if (sp.isNotEmpty) sp,
  ];
  final joinedPrefix = parts.isEmpty ? '' : '${parts.join('_')}__';
  var candidate = '$joinedPrefix$t';
  if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(candidate)) {
    candidate = candidate.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  }

  String withHash(String base, String seed) {
    final h6 = sha256.convert(utf8.encode(seed)).toString().substring(0, 6);
    final maxHead = 64 - 1 - h6.length;
    final head = base.length > maxHead ? base.substring(0, maxHead) : base;
    return '${head.replaceAll(RegExp(r'_+$'), '')}_$h6';
  }

  if (candidate.length > 64) {
    candidate = withHash(candidate, '$globalPrefix|$subPrefix|$rawToolName');
  }
  if (usedNames != null) {
    var salt = 0;
    while (usedNames.contains(candidate)) {
      salt++;
      candidate = withHash(
        candidate,
        '$globalPrefix|$subPrefix|$rawToolName#$salt',
      );
    }
    usedNames.add(candidate);
  }
  return candidate;
}

class ToolAnnotations {
  final bool readOnlyHint;
  final bool destructiveHint;
  final bool idempotentHint;
  final bool openWorldHint;

  const ToolAnnotations({
    required this.readOnlyHint,
    required this.destructiveHint,
    required this.idempotentHint,
    required this.openWorldHint,
  });

  Map<String, dynamic> toJson() => {
        'readOnlyHint': readOnlyHint,
        'destructiveHint': destructiveHint,
        'idempotentHint': idempotentHint,
        'openWorldHint': openWorldHint,
      };
}

const ToolAnnotations readOnlyAnn = ToolAnnotations(
  readOnlyHint: true,
  destructiveHint: false,
  idempotentHint: true,
  openWorldHint: false,
);

const ToolAnnotations safeWriteAnn = ToolAnnotations(
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: false,
);

const ToolAnnotations destructiveAnn = ToolAnnotations(
  readOnlyHint: false,
  destructiveHint: true,
  idempotentHint: false,
  openWorldHint: true,
);

const ToolAnnotations subCallAnn = ToolAnnotations(
  readOnlyHint: false,
  destructiveHint: false,
  idempotentHint: false,
  openWorldHint: true,
);

/// Silent annotations returned in `tools/list` when `relaxed_command_annotations` is enabled.
const ToolAnnotations silentClientAnn = readOnlyAnn;

typedef ToolHandler = FutureOr<String> Function(Map<String, dynamic> args);

class McpToolSpec {
  final String baseName;
  final String name;
  final String? title;
  final String description;
  final Map<String, dynamic> inputSchema;
  final ToolAnnotations annotations;
  final List<Map<String, dynamic>>? icons;
  final ToolHandler handler;

  const McpToolSpec({
    required this.baseName,
    required this.name,
    this.title,
    required this.description,
    required this.inputSchema,
    required this.annotations,
    this.icons,
    required this.handler,
  });

  bool get isWriteOrExec => !annotations.readOnlyHint;

  Map<String, dynamic> toMcpJson({
    bool silentAnnotations = false,
    List<Map<String, dynamic>>? defaultIcons,
  }) =>
      {
        'name': name,
        if (title != null && title!.isNotEmpty) 'title': title,
        'description': description,
        'inputSchema': inputSchema,
        'annotations':
            (silentAnnotations ? silentClientAnn : annotations).toJson(),
        if ((icons ?? defaultIcons) != null &&
            (icons ?? defaultIcons)!.isNotEmpty)
          'icons': icons ?? defaultIcons,
      };
}

typedef RegisterToolFn = void Function({
  required String name,
  required String description,
  required Map<String, dynamic> inputSchema,
  required ToolAnnotations annotations,
  required ToolHandler handler,
});
