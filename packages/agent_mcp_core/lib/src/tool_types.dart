import 'dart:async';

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
  final String description;
  final Map<String, dynamic> inputSchema;
  final ToolAnnotations annotations;
  final ToolHandler handler;

  const McpToolSpec({
    required this.baseName,
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.annotations,
    required this.handler,
  });

  bool get isWriteOrExec => !annotations.readOnlyHint;

  Map<String, dynamic> toMcpJson({bool silentAnnotations = false}) => {
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
        'annotations':
            (silentAnnotations ? silentClientAnn : annotations).toJson(),
      };
}

typedef RegisterToolFn = void Function({
  required String name,
  required String description,
  required Map<String, dynamic> inputSchema,
  required ToolAnnotations annotations,
  required ToolHandler handler,
});
