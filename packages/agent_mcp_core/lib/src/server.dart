import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'auth.dart';
import 'clipboard_screen_tools.dart';
import 'config.dart';
import 'dashboard_api.dart';
import 'exposure_tools.dart';
import 'file_tools.dart';
import 'logging_utils.dart';
import 'privileged_exec.dart';
import 'process_tools.dart';
import 'sub_mcp.dart';
import 'tool_types.dart';
import 'tunnel.dart';
import 'version.dart';

const String mcpProtocolVersion = '2025-11-25';

const List<String> kSupportedMcpProtocolVersions = <String>[
  '2024-11-05',
  '2025-03-26',
  '2025-06-18',
  '2025-11-25',
  '2026-07-28',
];

String negotiateMcpProtocolVersion(String? clientRequested) {
  final req = (clientRequested ?? '').trim();
  if (req.isEmpty) return mcpProtocolVersion;
  if (kSupportedMcpProtocolVersions.contains(req)) return req;
  return mcpProtocolVersion;
}

class _SseSession {
  final String sessionId;
  final StreamController<List<int>> controller;
  _SseSession(this.sessionId, this.controller);

  void sendEvent(String event, String data) {
    if (controller.isClosed) return;
    controller.add(utf8.encode('event: $event\ndata: $data\n\n'));
  }
}

/// Core Agent MCP Server Engine:
/// - Registers all 20 tools (`list_roots` + 12 file + 3 process + 3 sub-MCP + `manage_expose`)
/// - Enforces per-request `Zone` `AccessPolicy` & `relaxed_command_annotations`
/// - Serves `stdio`, Streamable HTTP (`/mcp`), Legacy SSE (`/sse` + `/messages`),
///   OAuth 2.1, `/health`, and `/dashboard` on a single port!
class McpServerEngine {
  final ServerConfig config;
  final UndoStore undoStore = UndoStore();
  final ProcessManager processManager = ProcessManager();
  final Map<String, McpToolSpec> _tools = {};
  late final String _prefix;

  McpServerEngine(this.config) {
    _prefix = sanitizePrefix(config.toolPrefix);
    _registerAllTools();
  }

  List<McpToolSpec> get tools => _tools.values.toList(growable: false);

  String get instructions {
    final modeDesc = config.readOnly ? 'READ-ONLY' : 'READ-WRITE + EXEC';
    final scopeDesc = config.unrestricted
        ? 'UNRESTRICTED'
        : 'SCOPED (${config.effectiveRoots.length} roots)';
    return "MCP server '${config.serverName}' on host '${Platform.localHostname}' ($modeDesc, $scopeDesc). "
        'Prefer stat_file before reading large files, use edit_file or apply_patch for '
        'surgical changes instead of rewriting whole files, use start_process + '
        'manage_process for long-running builds or servers, use list_sub_mcps / inspect_sub_mcp / call_sub_mcp for nested Sub-MCP servers, '
        'and use manage_expose to share generated videos, files, static websites, or local ports via Tailscale / public links.';
  }

  void _registerAllTools() {
    void registerTool({
      required String name,
      required String description,
      required Map<String, dynamic> inputSchema,
      required ToolAnnotations annotations,
      required ToolHandler handler,
    }) {
      final fullName = _prefix.isEmpty ? name : '$_prefix$name';
      _tools[fullName] = McpToolSpec(
        baseName: name,
        name: fullName,
        description: description,
        inputSchema: inputSchema,
        annotations: annotations,
        handler: handler,
      );
    }

    registerTool(
      name: 'list_roots',
      description:
          'Inspect server access scope, allowed root directories, current working directory, and mode flags.',
      annotations: readOnlyAnn,
      inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
      handler: (_) {
        final policy = getEffectivePolicy(config);
        final info = {
          'server_name': config.serverName,
          'tool_prefix': _prefix,
          'hostname': Platform.localHostname,
          'version': agentMcpVersion,
          'runtime': 'dart-native',
          'os': Platform.operatingSystem,
          'cwd': Directory.current.absolute.path,
          'profile': policy.profileName,
          'access_mode':
              policy.allowAllRoots || policy.effectiveRoots.isEmpty
                  ? 'unrestricted'
                  : 'scoped',
          'allow_all_roots': policy.allowAllRoots,
          'allowed_roots': policy.effectiveRoots,
          'read_only': policy.readOnly,
          'allow_secrets': policy.allowSecrets,
          'allow_commands': policy.allowCommands,
          'allow_processes': policy.allowProcesses,
          'allow_exposures': policy.allowExposures,
          'allow_clipboard_screen': policy.allowClipboardScreen,
          'relaxed_command_annotations': policy.relaxedCommandAnnotations,
          'auth_mode': config.authMode,
          'transport': config.transport,
          if (Platform.isAndroid)
            'privilege': PrivilegedExecutor.instance.publicStatus,
        };
        return const JsonEncoder.withIndent('  ').convert(info);
      },
    );

    registerFileTools(registerTool, config, undoStore);
    registerProcessTools(registerTool, config, processManager);
    registerSubMcpTools(registerTool, config);
    registerExposureTools(registerTool, config);
    registerClipboardAndScreenTools(registerTool, config);
  }

  Map<String, dynamic> buildServerInfoMetadata({String? effectiveBaseUrl}) => {
        'name': sanitizeMcpMachineName(config.serverName),
        'title': config.serverName,
        'version': agentMcpVersion,
        'description':
            'Agent MCP Prism Gateway (${Platform.operatingSystem} · ${_tools.length} built-in tools + Sub-MCP hub)',
        'websiteUrl': 'https://github.com/iamr0s/agent-mcp',
        'icons': buildMcpServerIcons(baseUrl: effectiveBaseUrl),
      };

  Map<String, dynamic> get _serverCapabilities => const {
        'tools': {'listChanged': false},
        'resources': {'listChanged': false, 'subscribe': false},
        'prompts': {'listChanged': false},
        'logging': <String, dynamic>{},
      };

  Future<Map<String, dynamic>?> handleJsonRpcMessage(
    Map<String, dynamic> req, {
    String? effectiveBaseUrl,
    String? httpProtocolVersion,
  }) async {
    final method = req['method']?.toString();
    final hasId = req.containsKey('id') && req['id'] != null;
    final id = req['id'];
    final rawParams = req['params'];
    final params = rawParams is Map
        ? Map<String, dynamic>.from(rawParams)
        : const <String, dynamic>{};
    final is2026 = (httpProtocolVersion ?? '').trim() == '2026-07-28';

    if (!hasId) {
      // JSON-RPC Notification (e.g. notifications/initialized, notifications/cancelled)
      return null;
    }

    Map<String, dynamic> ok(Map<String, dynamic> result, {bool add2026Envelope = false}) => {
          'jsonrpc': '2.0',
          'id': id,
          'result': (add2026Envelope && is2026)
              ? <String, dynamic>{'resultType': 'complete', ...result}
              : result,
        };

    Map<String, dynamic> fail(int code, String message) => {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': code, 'message': message},
        };

    switch (method) {
      case 'initialize':
        final clientProto = params['protocolVersion']?.toString();
        final negotiatedProto = negotiateMcpProtocolVersion(clientProto);
        return ok({
          'protocolVersion': negotiatedProto,
          'capabilities': _serverCapabilities,
          'serverInfo':
              buildServerInfoMetadata(effectiveBaseUrl: effectiveBaseUrl),
          'instructions': instructions,
        });

      case 'server/discover':
        final sInfo =
            buildServerInfoMetadata(effectiveBaseUrl: effectiveBaseUrl);
        return ok({
          'resultType': 'complete',
          'supportedVersions': kSupportedMcpProtocolVersions,
          'capabilities': _serverCapabilities,
          'serverInfo': sInfo,
          'instructions': instructions,
          '_meta': {
            'io.modelcontextprotocol/serverInfo': sInfo,
          },
        });

      case 'ping':
      case 'logging/setLevel':
        return ok(const <String, dynamic>{}, add2026Envelope: true);

      case 'completion/complete':
        return ok(
          const {
            'completion': {
              'values': <String>[],
              'total': 0,
              'hasMore': false,
            },
          },
          add2026Envelope: true,
        );

      case 'resources/list':
        final bridged = SubMcpManager.instance.collectBridgedResources();
        return ok(
          {
            'resources': bridged,
            if (is2026) 'ttlMs': 60000,
            if (is2026) 'cacheScope': 'session',
          },
          add2026Envelope: true,
        );

      case 'resources/read':
        final uri = (params['uri'] ?? '').toString().trim();
        if (uri.isEmpty) return fail(-32602, 'Missing required parameter: uri');
        final bridgedRes =
            await SubMcpManager.instance.readBridgedResource(uri);
        if (bridgedRes == null) {
          return fail(-32002, 'Resource not found: $uri');
        }
        return ok(bridgedRes, add2026Envelope: true);

      case 'resources/templates/list':
        return ok(
          const {'resourceTemplates': <dynamic>[]},
          add2026Envelope: true,
        );

      case 'prompts/list':
        final bridgedPrompts = SubMcpManager.instance
            .collectBridgedPrompts()
            .map((p) => <String, dynamic>{
                  'name': p['name'],
                  if (p['description'] != null) 'description': p['description'],
                  if (p['arguments'] != null) 'arguments': p['arguments'],
                })
            .toList();
        return ok(
          {
            'prompts': bridgedPrompts,
            if (is2026) 'ttlMs': 60000,
            if (is2026) 'cacheScope': 'session',
          },
          add2026Envelope: true,
        );

      case 'prompts/get':
        final pName = (params['name'] ?? '').toString().trim();
        if (pName.isEmpty) {
          return fail(-32602, 'Missing required parameter: name');
        }
        final pArgs = params['arguments'] is Map
            ? Map<String, dynamic>.from(params['arguments'] as Map)
            : const <String, dynamic>{};
        final promptRes =
            await SubMcpManager.instance.getBridgedPrompt(pName, pArgs);
        if (promptRes == null) {
          return fail(-32602, "Unknown prompt: '$pName'");
        }
        return ok(promptRes, add2026Envelope: true);

      case 'tools/list':
        final policy = getEffectivePolicy(config);
        final silent = policy.relaxedCommandAnnotations;
        final builtInIcons = buildMcpServerIcons(baseUrl: effectiveBaseUrl);
        final directSpecs =
            await SubMcpManager.instance.resolveDirectMountedToolSpecs(
          globalPrefix: _prefix,
          existingToolNames: _tools.keys.toSet(),
        );
        return ok(
          {
            'tools': [
              ..._tools.values.map(
                (t) => t.toMcpJson(
                  silentAnnotations: silent,
                  defaultIcons: builtInIcons,
                ),
              ),
              ...directSpecs.map(
                (t) => t.toMcpJson(
                  silentAnnotations: silent,
                  defaultIcons: builtInIcons,
                ),
              ),
            ],
            if (is2026) 'ttlMs': 60000,
            if (is2026) 'cacheScope': 'session',
          },
          add2026Envelope: true,
        );

      case 'tools/call':
        final toolName = (params['name'] ?? '').toString();
        final rawArgs = params['arguments'];
        final callArgs = rawArgs is Map
            ? Map<String, dynamic>.from(rawArgs)
            : <String, dynamic>{};
        var spec = _tools[toolName];
        if (spec == null) {
          final directSpecs =
              await SubMcpManager.instance.resolveDirectMountedToolSpecs(
            globalPrefix: _prefix,
            existingToolNames: _tools.keys.toSet(),
          );
          spec = directSpecs.where((t) => t.name == toolName).firstOrNull;
        }
        if (spec == null) {
          return fail(-32602, "Unknown tool: '$toolName'");
        }
        final res = await _executeToolAudited(spec, callArgs);
        return ok(res, add2026Envelope: true);

      default:
        return fail(-32601, 'Method not found: $method');
    }
  }

  Future<Map<String, dynamic>> _executeToolAudited(
    McpToolSpec spec,
    Map<String, dynamic> args,
  ) async {
    final callId = randomHex(5);
    final policy = getEffectivePolicy(config);
    final argSummary = formatCallArgs(args);
    final safeArgs = redactArgs(args);

    McpLogger.instance.info(
      '[TOOL CALL] [${policy.profileName}] ${spec.name}($argSummary)',
    );
    StructuredEventBus.instance.emit({
      'call_id': callId,
      'status': 'running',
      'kind': 'call',
      'badge': '执行中',
      'level': 'INFO',
      'tool': spec.name,
      'source': policy.profileName,
      'source_host': policy.host,
      'args': safeArgs,
      'summary': argSummary.isEmpty ? '(无参数)' : argSummary,
    });

    if (spec.isWriteOrExec && policy.readOnly) {
      final denyMsg =
          "Error: Read-only mode is enabled for profile '${policy.profileName}'.";
      McpLogger.instance
          .warning('[TOOL ERR] [${policy.profileName}] ${spec.name} -> $denyMsg');
      StructuredEventBus.instance.emit({
        'call_id': callId,
        'status': 'error',
        'kind': 'err',
        'badge': '拒绝',
        'level': 'WARNING',
        'tool': spec.name,
        'source': policy.profileName,
        'source_host': policy.host,
        'ms': 0.0,
        'args': safeArgs,
        'result': denyMsg,
        'summary': denyMsg,
      });
      return {
        'content': [
          {'type': 'text', 'text': denyMsg},
        ],
        'isError': true,
      };
    }

    final sw = Stopwatch()..start();
    try {
      final resultText = await spec.handler(args);
      sw.stop();
      final elapsedMs =
          double.parse((sw.elapsedMicroseconds / 1000.0).toStringAsFixed(1));
      if (resultText.startsWith(kMcpStructuredImagePrefix)) {
        final rawJson = resultText.substring(kMcpStructuredImagePrefix.length);
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        final savedPath = decoded['saved_path']?.toString();
        final summaryText =
            'Captured screen #${decoded['display_index'] ?? 0} (${decoded['bytes'] ?? 0} bytes PNG${savedPath != null ? ', saved to $savedPath' : ''}).';
        McpLogger.instance.info(
          '[TOOL OK] [${policy.profileName}] ${spec.name} (${elapsedMs}ms) -> $summaryText',
        );
        StructuredEventBus.instance.emit({
          'call_id': callId,
          'status': 'done',
          'kind': 'ok',
          'badge': '完成',
          'level': 'INFO',
          'tool': spec.name,
          'source': policy.profileName,
          'source_host': policy.host,
          'ms': elapsedMs,
          'args': safeArgs,
          'result': summaryText,
          'summary': summaryText,
        });
        return {
          'content': [
            {
              'type': 'image',
              'data': (decoded['data'] ?? '').toString(),
              'mimeType': (decoded['mimeType'] ?? 'image/png').toString(),
            },
            {
              'type': 'text',
              'text': summaryText,
            },
          ],
          'isError': false,
        };
      }
      if (resultText.startsWith(kMcpStructuredCallResultPrefix)) {
        final rawJson =
            resultText.substring(kMcpStructuredCallResultPrefix.length);
        final decoded = jsonDecode(rawJson) as Map<String, dynamic>;
        final blocks = ((decoded['content'] as List?) ?? const [])
            .whereType<Map>()
            .map((b) => Map<String, dynamic>.from(b))
            .toList();
        final summaryText =
            'Multimodal Sub-MCP response (${blocks.length} content blocks).';
        McpLogger.instance.info(
          '[TOOL OK] [${policy.profileName}] ${spec.name} (${elapsedMs}ms) -> $summaryText',
        );
        StructuredEventBus.instance.emit({
          'call_id': callId,
          'status': 'done',
          'kind': 'ok',
          'badge': '完成',
          'level': 'INFO',
          'tool': spec.name,
          'source': policy.profileName,
          'source_host': policy.host,
          'ms': elapsedMs,
          'args': safeArgs,
          'result': summaryText,
          'summary': summaryText,
        });
        return <String, dynamic>{
          'content': blocks,
          if (decoded['structuredContent'] != null)
            'structuredContent': decoded['structuredContent'],
          'isError': decoded['isError'] == true,
        };
      }
      var preview = resultText.replaceAll('\r', '').replaceAll('\n', ' ');
      if (preview.length > 360) {
        preview =
            '${preview.substring(0, 360)}... (total ${resultText.length} chars)';
      }
      final isErr = resultText.startsWith('Error:');
      if (isErr) {
        McpLogger.instance.warning(
          '[TOOL ERR] [${policy.profileName}] ${spec.name} (${elapsedMs}ms) -> $preview',
        );
      } else {
        McpLogger.instance.info(
          '[TOOL OK] [${policy.profileName}] ${spec.name} (${elapsedMs}ms) -> $preview',
        );
      }
      StructuredEventBus.instance.emit({
        'call_id': callId,
        'status': isErr ? 'error' : 'done',
        'kind': isErr ? 'err' : 'ok',
        'badge': isErr ? '失败' : '完成',
        'level': isErr ? 'WARNING' : 'INFO',
        'tool': spec.name,
        'source': policy.profileName,
        'source_host': policy.host,
        'ms': elapsedMs,
        'args': safeArgs,
        'result': resultText.length > 4000
            ? '${resultText.substring(0, 4000)}\n... (total ${resultText.length} chars)'
            : resultText,
        'summary': preview,
      });
      return {
        'content': [
          {'type': 'text', 'text': resultText},
        ],
        'isError': isErr,
      };
    } catch (e, st) {
      sw.stop();
      final elapsedMs =
          double.parse((sw.elapsedMicroseconds / 1000.0).toStringAsFixed(1));
      McpLogger.instance.error(
        '[TOOL CRASH] [${policy.profileName}] ${spec.name} (${elapsedMs}ms)',
        e,
        st,
      );
      final errStr = 'Error: Unexpected exception in ${spec.name}: $e';
      StructuredEventBus.instance.emit({
        'call_id': callId,
        'status': 'error',
        'kind': 'err',
        'badge': '异常',
        'level': 'ERROR',
        'tool': spec.name,
        'source': policy.profileName,
        'source_host': policy.host,
        'ms': elapsedMs,
        'args': safeArgs,
        'result': '$e',
        'summary': '$e',
      });
      return {
        'content': [
          {'type': 'text', 'text': errStr},
        ],
        'isError': true,
      };
    }
  }

  /// Runs the MCP server over `stdin` / `stdout` (stdio transport).
  Future<void> serveStdio() async {
    McpLogger.instance.info(
      "Agent MCP '${config.serverName}' v$agentMcpVersion ready on stdio (${_tools.length} tools).",
    );
    await for (final rawLine
        in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      dynamic decoded;
      try {
        decoded = jsonDecode(line);
      } catch (_) {
        stdout.writeln(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': null,
            'error': {'code': -32700, 'message': 'Parse error'},
          }),
        );
        continue;
      }

      if (decoded is List) {
        final responses = <Map<String, dynamic>>[];
        for (final item in decoded) {
          if (item is Map) {
            final r = await handleJsonRpcMessage(
              Map<String, dynamic>.from(item),
            );
            if (r != null) responses.add(r);
          }
        }
        if (responses.isNotEmpty) {
          stdout.writeln(jsonEncode(responses));
        }
      } else if (decoded is Map) {
        final r = await handleJsonRpcMessage(
          Map<String, dynamic>.from(decoded),
        );
        if (r != null) {
          stdout.writeln(jsonEncode(r));
        }
      }
    }
  }

  /// Builds the unified Shelf HTTP handler mounting:
  /// - `/health`
  /// - `/dashboard` & `/dashboard/api/*`
  /// - OAuth 2.1 (`/.well-known/*`, `/register`, `/authorize`, `/local-login`, `/token`, `/revoke`)
  /// - Hot-reloading `ProfileRouter`
  /// - Streamable HTTP (`/mcp`) & Legacy SSE (`/sse` + `/messages`)
  Handler buildHttpHandler({
    bool Function()? isServiceRunning,
    Future<void> Function()? onStartService,
    Future<void> Function()? onStopService,
    Future<void> Function()? onRestartService,
    String? localLaunchTicket,
  }) {
    final oauthProvider = buildOAuthProvider(config);
    final dashboard = DashboardHandler(
      config: config,
      isServiceRunning: isServiceRunning,
      onStartService: onStartService,
      onStopService: onStopService,
      onRestartService: onRestartService,
      localLaunchTicket: localLaunchTicket,
    );
    final sseSessions = <String, _SseSession>{};

    var cachedConfigMtime = -1;
    var cachedTunnelMtime = -1;
    late _LiveRoutingState liveState;

    int fileMtime(File f) {
      try {
        return f.existsSync() ? f.lastModifiedSync().microsecondsSinceEpoch : 0;
      } catch (_) {
        return 0;
      }
    }

    _LiveRoutingState getLiveState() {
      final cm = fileMtime(config.configFile);
      final tm = fileMtime(StoragePaths.instance.tunnelStateFile);
      if (cm != cachedConfigMtime || tm != cachedTunnelMtime) {
        final saved = loadSavedConfig(config.configFile);
        final profs = saved.isNotEmpty
            ? ensureProfilesInConfig(saved)
            : List<Map<String, dynamic>>.from(config.profiles);
        if (saved.isNotEmpty) {
          oauthProvider.syncFromConfig(saved, profs);
        }
        liveState = _LiveRoutingState.build(
          config: config,
          saved: saved,
          profiles: profs,
          tunnelDiskState: TunnelManager.instance.loadDiskState(),
        );
        cachedConfigMtime = cm;
        cachedTunnelMtime = tm;
      }
      return liveState;
    }

    // Initialize liveState immediately
    getLiveState();

    return (Request request) async {
      // CORS preflight support
      if (request.method == 'OPTIONS') {
        return Response.ok(
          '',
          headers: const {
            'access-control-allow-origin': '*',
            'access-control-allow-methods': 'GET, POST, DELETE, OPTIONS',
            'access-control-allow-headers':
                'Authorization, X-API-Key, Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version, Mcp-Method, Mcp-Name, Last-Event-ID, X-Filename',
            'access-control-expose-headers': 'Mcp-Session-Id, MCP-Protocol-Version, Mcp-Method, Mcp-Name',
          },
        );
      }

      final path = '/${request.url.path}';

      // 1. Health check (unauthenticated)
      if (path == '/health' && request.method == 'GET') {
        return Response.ok(
          jsonEncode({
            'status': 'ok',
            'server_name': config.serverName,
            'version': agentMcpVersion,
            'runtime': 'dart-native',
            'os': Platform.operatingSystem,
            'hostname': Platform.localHostname,
            'tools_count': _tools.length,
            'auth_mode': config.authMode,
            'read_only': config.readOnly,
          }),
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }

      // 1b. Public / Tailscale capability-token share links (/share/<id>/...)
      final shareResp = await ExposureManager.instance.tryHandleShareRequest(request, config: config);
      if (shareResp != null) return shareResp;

      // 2. Password-protected Web Dashboard
      final dashResp = await dashboard.tryHandle(request);
      if (dashResp != null) return dashResp;

      // 3. Hot-reload routing state & resolve caller Host / Base URL
      final st = getLiveState();
      final rawHost = (request.headers['x-forwarded-host'] ??
              request.headers['host'] ??
              '')
          .split(',')
          .first
          .trim()
          .toLowerCase();
      final hostNoPort = rawHost.split(':').first;
      final fwdProto = (request.headers['x-forwarded-proto'] ?? '')
          .split(',')
          .first
          .trim()
          .toLowerCase();
      final scheme = fwdProto.isNotEmpty
          ? fwdProto
          : (rawHost.endsWith('.trycloudflare.com') ? 'https' : request.requestedUri.scheme);
      final inferredBase = rawHost.isNotEmpty
          ? '$scheme://$rawHost'
          : 'http://${config.host}:${config.port}';
      final effectiveBaseUrl = st.hostBaseMap[rawHost] ??
          st.hostBaseMap[hostNoPort] ??
          inferredBase;
      final hostProfile =
          st.hostProfileMap[rawHost] ?? st.hostProfileMap[hostNoPort];

      // 3b. Unauthenticated Same-Origin Brand Icons, Root Favicon Link & MCP Server Cards
      //     (Per MCP `icons` security guidance: clients fetch icons from same origin WITHOUT credentials!)
      final unauthDiscoveryResp = _tryServePublicIconOrServerCard(
        request,
        path: path,
        effectiveBaseUrl: effectiveBaseUrl,
      );
      if (unauthDiscoveryResp != null) return _withCors(unauthDiscoveryResp);

      // 4. OAuth 2.1 Discovery & Authorization routes
      if (oauthProvider.isOAuthRoute(path)) {
        final oauthResp = await oauthProvider.tryHandle(
          request,
          effectiveBaseUrl: effectiveBaseUrl,
          targetProfileId: hostProfile?['id']?.toString(),
        );
        if (oauthResp != null) return _withCors(oauthResp);
      }

      // 5. Authenticate & match Profile -> AccessPolicy
      final authHdr = request.headers['authorization'] ?? '';
      final xKey = request.headers['x-api-key'] ?? '';
      final bearerTok = authHdr.toLowerCase().startsWith('bearer ')
          ? authHdr.substring(7).trim()
          : xKey.trim();

      Map<String, dynamic>? matchedProfile;
      var tokenAuthenticated = false;

      if (bearerTok.isNotEmpty && st.apiKeyMap.isNotEmpty) {
        Map<String, dynamic>? hit;
        for (final entry in st.apiKeyMap.entries) {
          if (constantTimeEquals(bearerTok, entry.key)) {
            hit = entry.value;
          }
        }
        if (hit != null) {
          matchedProfile = hit;
          tokenAuthenticated = true;
        }
      }
      if (!tokenAuthenticated && bearerTok.isNotEmpty) {
        final cid = oauthProvider.resolveTokenClientId(bearerTok);
        if (cid != null) {
          tokenAuthenticated = true;
          final tokenPid = oauthProvider.resolveTokenProfileId(bearerTok);
          matchedProfile = st.clientIdMap[cid] ??
              (tokenPid != null ? st.profileIdMap[tokenPid] : null);
        }
      }

      matchedProfile ??= hostProfile;

      final requiredAuth = matchedProfile != null
          ? (matchedProfile['auth_mode'] ?? 'none').toString()
          : st.globalAuthMode;

      if (requiredAuth == 'bearer' && !tokenAuthenticated) {
        McpLogger.instance
            .warning('[AUTH 401] Rejected Bearer ${request.method} $path');
        return _withCors(
          Response(
            401,
            body: jsonEncode({
              'error': 'Unauthorized: invalid or missing Bearer token / API key',
            }),
            headers: const {
              'content-type': 'application/json; charset=utf-8',
              'www-authenticate': 'Bearer',
            },
          ),
        );
      }

      if (requiredAuth == 'oauth-local' && !tokenAuthenticated) {
        McpLogger.instance
            .warning('[AUTH 401] Triggering OAuth discovery on ${request.method} $path');
        return _withCors(
          Response(
            401,
            body: jsonEncode({'error': 'invalid_token'}),
            headers: {
              'content-type': 'application/json; charset=utf-8',
              'www-authenticate':
                  'Bearer resource_metadata="$effectiveBaseUrl/.well-known/oauth-protected-resource"',
            },
          ),
        );
      }

      // 5b. MCP Streamable HTTP Origin & DNS Rebinding Guard (MCP 2025-11-25 Spec)
      if (!tokenAuthenticated) {
        final savedCfg = loadSavedConfig(config.configFile);
        final allowedOrigins = ((savedCfg['allowed_origins'] as List?) ?? const [])
            .map((e) => e.toString().trim().toLowerCase())
            .where((s) => s.isNotEmpty)
            .toSet();
        final guardErr = _checkMcpDnsRebindingAndOrigin(
          request: request,
          rawHost: rawHost,
          hostNoPort: hostNoPort,
          routingState: st,
          allowedOrigins: allowedOrigins,
        );
        if (guardErr != null) {
          McpLogger.instance
              .warning('[SECURITY 403] $guardErr (${request.method} $path)');
          return _withCors(
            Response.forbidden(
              jsonEncode({'error': guardErr}),
              headers: const {'content-type': 'application/json; charset=utf-8'},
            ),
          );
        }
      }

      final policy = matchedProfile != null
          ? st.policyFromProfile(matchedProfile, rawHost)
          : st.defaultPolicy(rawHost);

      // 6. Execute MCP Transport inside isolated Dart Zone carrying `policy`
      return runWithPolicy(policy, () async {
        final allowHttp = config.transport == 'dual' || config.transport == 'http';
        final allowSse = config.transport == 'dual' || config.transport == 'sse';

        if (allowHttp && path == '/mcp') {
          return _withCors(
            await _handleStreamableHttp(
              request,
              effectiveBaseUrl: effectiveBaseUrl,
            ),
          );
        }

        if (allowSse && path == '/sse' && request.method == 'GET') {
          return _withCors(_handleSseConnect(request, sseSessions));
        }

        if (allowSse && path == '/messages' && request.method == 'POST') {
          return _withCors(await _handleSseMessage(request, sseSessions));
        }

        return _withCors(
          Response.notFound(
            jsonEncode({'error': 'Not Found', 'path': path}),
            headers: const {'content-type': 'application/json; charset=utf-8'},
          ),
        );
      });
    };
  }

  String _resolveStreamableSessionId(Request request) {
    final incoming = request.headers['mcp-session-id']?.trim();
    if (incoming != null && incoming.isNotEmpty) {
      return incoming;
    }
    final auth = request.headers['authorization'] ?? '';
    final ua = request.headers['user-agent'] ?? '';
    final seed = auth.isNotEmpty ? auth : 'anon|$ua|${config.serverName}';
    final digest =
        sha256.convert(utf8.encode(seed)).toString().substring(0, 16);
    return 'sess-$digest';
  }

  Uint8List _resolveRasterIconBytes(int preferredSize) {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final relCandidates = preferredSize >= 512
        ? const [
            'web_dashboard/icons/Icon-512.png',
            'apps/agent_mcp_app/web/icons/Icon-512.png',
          ]
        : (preferredSize >= 192
            ? const [
                'web_dashboard/icons/Icon-192.png',
                'apps/agent_mcp_app/web/icons/Icon-192.png',
              ]
            : const [
                'web_dashboard/favicon.png',
                'apps/agent_mcp_app/web/favicon.png',
              ]);
    for (final base in [exeDir, Directory.current.path]) {
      for (final rel in relCandidates) {
        final f = File('$base/$rel');
        if (f.existsSync()) {
          try {
            return f.readAsBytesSync();
          } catch (_) {}
        }
      }
    }
    return appIconPng64Bytes;
  }

  Uint8List? _resolveIcoFileBytes() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    for (final pth in [
      '$exeDir/app_icon.ico',
      '${Directory.current.path}/apps/agent_mcp_app/assets/app_icon.ico',
    ]) {
      final f = File(pth);
      if (f.existsSync()) {
        try {
          return f.readAsBytesSync();
        } catch (_) {}
      }
    }
    return null;
  }

  Response? _tryServePublicIconOrServerCard(
    Request request, {
    required String path,
    required String effectiveBaseUrl,
  }) {
    if (request.method != 'GET' && request.method != 'HEAD') return null;
    final cleanBase = effectiveBaseUrl.replaceAll(RegExp(r'/+$'), '');
    const cacheHdr = 'public, max-age=86400';

    if (path == '/favicon.ico') {
      final ico = _resolveIcoFileBytes();
      if (ico != null) {
        return Response.ok(
          ico,
          headers: const {
            'content-type': 'image/x-icon',
            'cache-control': cacheHdr,
          },
        );
      }
      return Response.ok(
        appIconPng64Bytes,
        headers: const {
          'content-type': 'image/png',
          'cache-control': cacheHdr,
        },
      );
    }

    if (path == '/favicon.png' || path == '/icon.png' || path == '/icon-64.png') {
      return Response.ok(
        _resolveRasterIconBytes(64),
        headers: const {
          'content-type': 'image/png',
          'cache-control': cacheHdr,
        },
      );
    }

    if (path == '/icon-192.png' ||
        path == '/apple-touch-icon.png' ||
        path == '/apple-touch-icon-precomposed.png') {
      return Response.ok(
        _resolveRasterIconBytes(192),
        headers: const {
          'content-type': 'image/png',
          'cache-control': cacheHdr,
        },
      );
    }

    if (path == '/icon-512.png') {
      return Response.ok(
        _resolveRasterIconBytes(512),
        headers: const {
          'content-type': 'image/png',
          'cache-control': cacheHdr,
        },
      );
    }

    if (path == '/icon.svg' || path == '/favicon.svg') {
      return Response.ok(
        appIconSvg,
        headers: const {
          'content-type': 'image/svg+xml; charset=utf-8',
          'cache-control': cacheHdr,
        },
      );
    }

    if (path == '/.well-known/mcp.json' ||
        path == '/.well-known/mcp/server-card.json' ||
        path == '/mcp/server-card') {
      final info = buildServerInfoMetadata(effectiveBaseUrl: cleanBase);
      return Response.ok(
        jsonEncode({
          ...info,
          'supportedVersions': kSupportedMcpProtocolVersions,
          'endpoints': {
            'streamableHttp': '$cleanBase/mcp',
            'sse': '$cleanBase/sse',
          },
          'capabilities': _serverCapabilities,
        }),
        headers: const {
          'content-type': 'application/json; charset=utf-8',
          'cache-control': 'public, max-age=300',
        },
      );
    }

    if (path == '/') {
      final safeTitle = const HtmlEscape().convert(config.serverName);
      final html = '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>$safeTitle · Agent MCP v$agentMcpVersion</title>
<link rel="icon" type="image/png" sizes="192x192" href="/icon-192.png">
<link rel="icon" type="image/png" sizes="64x64" href="/favicon.png">
<link rel="icon" type="image/svg+xml" href="/icon.svg">
<link rel="apple-touch-icon" sizes="192x192" href="/apple-touch-icon.png">
<link rel="mcp-server-card" type="application/json" href="/.well-known/mcp.json">
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;background:#0A0A0C;color:#FAFAFA;padding:20px}.card{max-width:420px;width:100%;background:#121216;border:1px solid #24242C;border-radius:26px;padding:28px 26px;text-align:center;box-shadow:0 20px 46px -12px rgba(0,0,0,.72)}img{width:56px;height:56px;border-radius:14px}h1{font-size:19px;margin:14px 0 6px}p{margin:0;color:#8E8E98;font-size:13.5px;line-height:1.6}code{background:#1B1B22;padding:2px 7px;border-radius:6px;font-size:12.5px;color:#C7D2FE}</style>
</head><body><div class="card"><img src="/icon-192.png" alt="$safeTitle"><h1>$safeTitle</h1><p>Agent MCP Gateway v$agentMcpVersion · Streamable HTTP endpoint <code>/mcp</code></p></div></body></html>''';
      return Response.ok(
        html,
        headers: const {'content-type': 'text/html; charset=utf-8'},
      );
    }

    return null;
  }

  Future<Response> _handleStreamableHttp(
    Request request, {
    String? effectiveBaseUrl,
  }) async {
    final reqProtoHdr = request.headers['mcp-protocol-version']?.trim();
    final effProto = negotiateMcpProtocolVersion(reqProtoHdr);

    if (request.method == 'DELETE') {
      return Response(202);
    }

    if (request.method == 'GET') {
      final sid = _resolveStreamableSessionId(request);
      final ctrl = StreamController<List<int>>();
      Timer? keepAlive;
      ctrl.onCancel = () {
        keepAlive?.cancel();
        if (!ctrl.isClosed) ctrl.close();
      };
      keepAlive = Timer.periodic(const Duration(seconds: 20), (_) {
        if (!ctrl.isClosed) ctrl.add(utf8.encode(': ping\n\n'));
      });
      ctrl.add(utf8.encode(': streamable-http-ready\n\n'));
      return Response.ok(
        ctrl.stream,
        headers: {
          'content-type': 'text/event-stream; charset=utf-8',
          'cache-control': 'no-cache',
          'mcp-session-id': sid,
          'mcp-protocol-version': effProto,
        },
        context: const {'shelf.io.buffer_output': false},
      );
    }

    if (request.method != 'POST') {
      return Response(405, body: 'Method Not Allowed');
    }

    final sid = _resolveStreamableSessionId(request);
    final rawBody = await request.readAsString();
    dynamic decoded;
    try {
      decoded = jsonDecode(rawBody);
    } catch (_) {
      return Response(
        400,
        body: jsonEncode({
          'jsonrpc': '2.0',
          'id': null,
          'error': {'code': -32700, 'message': 'Parse error'},
        }),
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }

    if (decoded is List) {
      final out = <Map<String, dynamic>>[];
      for (final item in decoded) {
        if (item is Map) {
          final r = await handleJsonRpcMessage(
            Map<String, dynamic>.from(item),
            effectiveBaseUrl: effectiveBaseUrl,
            httpProtocolVersion: reqProtoHdr,
          );
          if (r != null) out.add(r);
        }
      }
      if (out.isEmpty) {
        return Response(202, headers: {'mcp-session-id': sid});
      }
      return Response.ok(
        jsonEncode(out),
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'mcp-session-id': sid,
          'mcp-protocol-version': effProto,
        },
      );
    }

    if (decoded is Map) {
      final resp = await handleJsonRpcMessage(
        Map<String, dynamic>.from(decoded),
        effectiveBaseUrl: effectiveBaseUrl,
        httpProtocolVersion: reqProtoHdr,
      );
      if (resp == null) {
        return Response(202, headers: {'mcp-session-id': sid});
      }
      final negotiatedFromInit = (resp['result'] is Map &&
              (resp['result'] as Map)['protocolVersion'] is String)
          ? (resp['result'] as Map)['protocolVersion'] as String
          : effProto;
      final isMethodNotFound2026 = reqProtoHdr == '2026-07-28' &&
          resp['error'] is Map &&
          (resp['error'] as Map)['code'] == -32601;
      return Response(
        isMethodNotFound2026 ? 404 : 200,
        body: jsonEncode(resp),
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'mcp-session-id': sid,
          'mcp-protocol-version': negotiatedFromInit,
        },
      );
    }

    return Response(400, body: 'Invalid JSON-RPC payload');
  }

  Response _handleSseConnect(
    Request request,
    Map<String, _SseSession> sessions,
  ) {
    final sid = randomHex(12);
    final ctrl = StreamController<List<int>>();
    final session = _SseSession(sid, ctrl);
    sessions[sid] = session;

    Timer? keepAlive;
    ctrl.onCancel = () {
      keepAlive?.cancel();
      sessions.remove(sid);
      if (!ctrl.isClosed) ctrl.close();
    };
    keepAlive = Timer.periodic(const Duration(seconds: 18), (_) {
      if (!ctrl.isClosed) ctrl.add(utf8.encode(': ping\n\n'));
    });

    session.sendEvent('endpoint', '/messages?session_id=$sid');

    return Response.ok(
      ctrl.stream,
      headers: const {
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache',
        'connection': 'keep-alive',
        'x-accel-buffering': 'no',
      },
      context: const {'shelf.io.buffer_output': false},
    );
  }

  Future<Response> _handleSseMessage(
    Request request,
    Map<String, _SseSession> sessions,
  ) async {
    final sid = request.url.queryParameters['session_id'] ??
        request.url.queryParameters['sessionId'] ??
        '';
    final session = sessions[sid];
    if (session == null) {
      return Response(
        404,
        body: jsonEncode({'error': 'Unknown or expired SSE session_id'}),
        headers: const {'content-type': 'application/json; charset=utf-8'},
      );
    }

    final rawBody = await request.readAsString();
    dynamic decoded;
    try {
      decoded = jsonDecode(rawBody);
    } catch (_) {
      return Response(400, body: 'Invalid JSON');
    }

    if (decoded is List) {
      for (final item in decoded) {
        if (item is Map) {
          final r = await handleJsonRpcMessage(Map<String, dynamic>.from(item));
          if (r != null) session.sendEvent('message', jsonEncode(r));
        }
      }
    } else if (decoded is Map) {
      final r = await handleJsonRpcMessage(Map<String, dynamic>.from(decoded));
      if (r != null) session.sendEvent('message', jsonEncode(r));
    }

    return Response(202, body: 'Accepted');
  }

  Future<HttpServer> serveHttp({
    bool Function()? isServiceRunning,
    Future<void> Function()? onStartService,
    Future<void> Function()? onStopService,
    Future<void> Function()? onRestartService,
    String? localLaunchTicket,
  }) async {
    final handler = buildHttpHandler(
      isServiceRunning: isServiceRunning,
      onStartService: onStartService,
      onStopService: onStopService,
      onRestartService: onRestartService,
      localLaunchTicket: localLaunchTicket,
    );
    final server = await shelf_io.serve(
      handler,
      config.host,
      config.port,
      shared: false,
    );
    server.autoCompress = false; // Crucial: never GZip-buffer SSE streams!
    McpLogger.instance.info(
      'Agent MCP ready on http://${config.host}:${config.port} -> /mcp (Streamable HTTP), /sse (SSE), /dashboard (Web UI)',
    );
    return server;
  }

  Future<List<HttpServer>> serveHttpMulti({
    bool Function()? isServiceRunning,
    Future<void> Function()? onStartService,
    Future<void> Function()? onStopService,
    Future<void> Function()? onRestartService,
    String? localLaunchTicket,
  }) async {
    final handler = buildHttpHandler(
      isServiceRunning: isServiceRunning,
      onStartService: onStartService,
      onStopService: onStopService,
      onRestartService: onRestartService,
      localLaunchTicket: localLaunchTicket,
    );
    final targets = config.hosts.isEmpty ? <String>[config.host] : config.hosts;
    final servers = <HttpServer>[];
    Object? lastErr;

    for (final bindHost in targets) {
      try {
        final srv = await shelf_io.serve(
          handler,
          bindHost,
          config.port,
          shared: false,
        );
        srv.autoCompress = false; // Crucial: never GZip-buffer SSE streams!
        servers.add(srv);
      } catch (e) {
        lastErr = e;
        McpLogger.instance.warning(
          'Failed to bind $bindHost:${config.port}: $e',
        );
        StructuredEventBus.instance.emit({
          'kind': 'err',
          'badge': '监听',
          'level': 'WARNING',
          'summary': '网卡地址 $bindHost:${config.port} 监听失败: $e',
        });
      }
    }

    if (servers.isEmpty && lastErr != null) {
      throw lastErr;
    }

    final boundDesc = servers
        .map((s) => 'http://${s.address.host}:${s.port}')
        .join(', ');
    McpLogger.instance.info(
      'Agent MCP ready on $boundDesc -> /mcp (Streamable HTTP), /sse (SSE), /dashboard (Web UI)',
    );
    return servers;
  }
}

class _LiveRoutingState {
  final List<Map<String, dynamic>> enabledProfiles;
  final Map<String, Map<String, dynamic>> profileIdMap;
  final Map<String, Map<String, dynamic>> clientIdMap;
  final Map<String, Map<String, dynamic>> apiKeyMap;
  final Map<String, Map<String, dynamic>> hostProfileMap;
  final Map<String, String> hostBaseMap;
  final String globalAuthMode;
  final bool globalReadOnly;
  final bool globalAllowSecrets;
  final bool globalRelaxedCmd;
  final bool globalAllowAllRoots;
  final bool globalAllowCommands;
  final bool globalAllowProcesses;
  final bool globalAllowExposures;
  final bool globalAllowClipboardScreen;
  final List<String> globalRoots;

  const _LiveRoutingState({
    required this.enabledProfiles,
    required this.profileIdMap,
    required this.clientIdMap,
    required this.apiKeyMap,
    required this.hostProfileMap,
    required this.hostBaseMap,
    required this.globalAuthMode,
    required this.globalReadOnly,
    required this.globalAllowSecrets,
    required this.globalRelaxedCmd,
    required this.globalAllowAllRoots,
    required this.globalAllowCommands,
    required this.globalAllowProcesses,
    required this.globalAllowExposures,
    required this.globalAllowClipboardScreen,
    required this.globalRoots,
  });

  factory _LiveRoutingState.build({
    required ServerConfig config,
    required Map<String, dynamic> saved,
    required List<Map<String, dynamic>> profiles,
    required Map<String, dynamic> tunnelDiskState,
  }) {
    final activeTunnelIds =
        tunnelDiskState.keys.map((e) => e.toString()).toSet();
    final enabled = profiles.where((p) => p['enabled'] != false).toList();
    final pidMap = <String, Map<String, dynamic>>{};
    final cidMap = <String, Map<String, dynamic>>{};
    final keyMap = <String, Map<String, dynamic>>{};
    final hpMap = <String, Map<String, dynamic>>{};
    final hbMap = <String, String>{};

    final globalAuth =
        (saved['auth_mode'] ?? config.authMode).toString().toLowerCase();
    final globalKey = (saved['api_key'] ?? config.apiKey ?? '').toString().trim();
    final gRo = saved.containsKey('read_only')
        ? saved['read_only'] == true
        : config.readOnly;
    final gSec = saved.containsKey('allow_secrets')
        ? saved['allow_secrets'] == true
        : config.allowSecrets;
    final gRelaxed = saved.containsKey('relaxed_command_annotations')
        ? saved['relaxed_command_annotations'] == true
        : config.relaxedCommandAnnotations;
    final gAllowCmd = saved.containsKey('allow_commands')
        ? saved['allow_commands'] != false
        : config.allowCommands;
    final gAllowProc = saved.containsKey('allow_processes')
        ? saved['allow_processes'] != false
        : config.allowProcesses;
    final gAllowExp = saved.containsKey('allow_exposures')
        ? saved['allow_exposures'] != false
        : config.allowExposures;
    final gAllowClip = saved.containsKey('allow_clipboard_screen')
        ? saved['allow_clipboard_screen'] != false
        : config.allowClipboardScreen;
    final gRoots = saved['roots'] is List
        ? (saved['roots'] as List)
            .map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .map((s) => containsPathWildcard(s) ? s : expandAndResolvePath(s))
            .toList()
        : List<String>.from(config.roots);
    final gAllowAllRoots = saved.containsKey('allow_all_roots')
        ? saved['allow_all_roots'] != false
        : (saved['roots'] is List && gRoots.isNotEmpty
            ? false
            : config.allowAllRoots);

    void registerBase(String rawUrl, [Map<String, dynamic>? prof]) {
      final clean = rawUrl.trim().replaceAll(RegExp(r'/+$'), '');
      if (clean.isEmpty) return;
      try {
        final uri = Uri.parse(clean);
        if (uri.host.isNotEmpty) {
          final hostLower = uri.host.toLowerCase();
          final authorityLower = uri.authority.toLowerCase();
          hbMap[authorityLower] = clean;
          hbMap.putIfAbsent(hostLower, () => clean);
          if (prof != null) {
            hpMap[authorityLower] = prof;
            hpMap.putIfAbsent(hostLower, () => prof);
          }
        }
      } catch (_) {}
    }

    for (final p in enabled) {
      final pid = (p['id'] ?? '').toString();
      if (pid.isNotEmpty) pidMap[pid] = p;
      final tmode = (p['tunnel_mode'] ?? 'none').toString().toLowerCase();
      if ((tmode == 'quick' || tmode == 'token') &&
          !activeTunnelIds.contains(pid)) {
        continue;
      }
      final cid = (p['oauth_client_id'] ?? '').toString().trim();
      if (cid.isNotEmpty) cidMap[cid] = p;
      if (p['auth_mode'] == 'bearer') {
        final k = (p['api_key'] ?? '').toString().trim();
        if (k.isNotEmpty) keyMap[k] = p;
      }
      final livePort = int.tryParse('${saved['port'] ?? config.port}') ?? config.port;
      registerBase((p['base_url'] ?? '').toString(), p);
      final rawBases = p['base_urls'];
      if (rawBases is List) {
        for (final u in rawBases) {
          registerBase(u.toString(), p);
        }
      }
      final rawDirectIps = p['direct_ips'];
      if (rawDirectIps is List) {
        for (final ip in rawDirectIps) {
          final s = ip.toString().trim();
          if (s.isNotEmpty) registerBase('http://$s:$livePort', p);
        }
      }
      final rawManual = p['manual_urls'];
      if (rawManual is List) {
        for (final u in rawManual) {
          registerBase(u.toString(), p);
        }
      }
      final tInfo = tunnelDiskState[pid];
      if (tInfo is Map) {
        final liveUrl = (tInfo['live_url'] ?? '').toString().trim();
        if (liveUrl.isNotEmpty) registerBase(liveUrl, p);
      }
    }

    if (globalAuth == 'bearer' &&
        globalKey.isNotEmpty &&
        !keyMap.containsKey(globalKey)) {
      keyMap[globalKey] = {
        'id': 'global-bearer',
        'name': '主入口 (Bearer)',
        'auth_mode': 'bearer',
        'inherit_permissions': true,
      };
    }

    return _LiveRoutingState(
      enabledProfiles: enabled,
      profileIdMap: pidMap,
      clientIdMap: cidMap,
      apiKeyMap: keyMap,
      hostProfileMap: hpMap,
      hostBaseMap: hbMap,
      globalAuthMode: globalAuth,
      globalReadOnly: gRo,
      globalAllowSecrets: gSec,
      globalRelaxedCmd: gRelaxed,
      globalAllowAllRoots: gAllowAllRoots,
      globalAllowCommands: gAllowCmd,
      globalAllowProcesses: gAllowProc,
      globalAllowExposures: gAllowExp,
      globalAllowClipboardScreen: gAllowClip,
      globalRoots: gRoots,
    );
  }

  AccessPolicy policyFromProfile(Map<String, dynamic> prof, String hostStr) {
    if (prof['inherit_permissions'] != false) {
      return AccessPolicy(
        profileId: (prof['id'] ?? 'default').toString(),
        profileName: (prof['name'] ?? '主入口').toString(),
        host: hostStr,
        readOnly: globalReadOnly,
        allowSecrets: globalAllowSecrets,
        relaxedCommandAnnotations: globalRelaxedCmd,
        allowAllRoots: globalAllowAllRoots,
        allowCommands: globalAllowCommands,
        allowProcesses: globalAllowProcesses,
        allowExposures: globalAllowExposures,
        allowClipboardScreen: globalAllowClipboardScreen,
        roots: globalRoots,
      );
    }
    final customRoots = ((prof['roots'] as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .map((s) => containsPathWildcard(s) ? s : expandAndResolvePath(s))
        .toList();
    final pAllowAllRoots = prof.containsKey('allow_all_roots')
        ? prof['allow_all_roots'] != false
        : customRoots.isEmpty;
    return AccessPolicy(
      profileId: (prof['id'] ?? 'default').toString(),
      profileName: (prof['name'] ?? '主入口').toString(),
      host: hostStr,
      readOnly: prof['read_only'] == true,
      allowSecrets: prof['allow_secrets'] == true,
      relaxedCommandAnnotations: prof['relaxed_command_annotations'] == true,
      allowAllRoots: pAllowAllRoots,
      allowCommands: prof['allow_commands'] != false,
      allowProcesses: prof['allow_processes'] != false,
      allowExposures: prof['allow_exposures'] != false,
      allowClipboardScreen: prof['allow_clipboard_screen'] != false,
      roots: customRoots,
    );
  }

  AccessPolicy defaultPolicy(String hostStr) {
    final defaultName = enabledProfiles.isNotEmpty
        ? (enabledProfiles.first['name'] ?? '默认入口').toString()
        : '默认入口';
    return AccessPolicy(
      profileId: 'default',
      profileName: defaultName,
      host: hostStr,
      readOnly: globalReadOnly,
      allowSecrets: globalAllowSecrets,
      relaxedCommandAnnotations: globalRelaxedCmd,
      allowAllRoots: globalAllowAllRoots,
      allowCommands: globalAllowCommands,
      allowProcesses: globalAllowProcesses,
      allowExposures: globalAllowExposures,
      allowClipboardScreen: globalAllowClipboardScreen,
      roots: globalRoots,
    );
  }
}

bool _isTrustedLocalOrConfiguredHost(
  String rawHost,
  String hostNoPort,
  _LiveRoutingState st,
) {
  if (hostNoPort.isEmpty ||
      hostNoPort == 'localhost' ||
      hostNoPort == '127.0.0.1' ||
      hostNoPort == '::1' ||
      hostNoPort == '[::1]') {
    return true;
  }
  if (InternetAddress.tryParse(hostNoPort) != null) {
    return true;
  }
  if (hostNoPort.endsWith('.ts.net') ||
      hostNoPort.endsWith('.trycloudflare.com') ||
      hostNoPort == Platform.localHostname.toLowerCase()) {
    return true;
  }
  if (st.hostBaseMap.containsKey(rawHost) ||
      st.hostBaseMap.containsKey(hostNoPort) ||
      st.hostProfileMap.containsKey(rawHost) ||
      st.hostProfileMap.containsKey(hostNoPort)) {
    return true;
  }
  return false;
}

bool _isLoopbackHostName(String h) =>
    h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';

String? _checkMcpDnsRebindingAndOrigin({
  required Request request,
  required String rawHost,
  required String hostNoPort,
  required _LiveRoutingState routingState,
  required Set<String> allowedOrigins,
}) {
  if (!_isTrustedLocalOrConfiguredHost(rawHost, hostNoPort, routingState)) {
    return "Blocked untrusted Host '$rawHost' (MCP DNS rebinding protection).";
  }

  final rawOrigin = (request.headers['origin'] ?? '').trim();
  if (rawOrigin.isEmpty) {
    return null;
  }

  final originLower = rawOrigin.toLowerCase().replaceAll(RegExp(r'/+$'), '');
  if (allowedOrigins.contains('*') || allowedOrigins.contains(originLower)) {
    return null;
  }

  final originUri = Uri.tryParse(rawOrigin);
  if (originUri == null || originUri.host.isEmpty) {
    return "Blocked malformed Origin header '$rawOrigin'.";
  }

  final originHost = originUri.host.toLowerCase();
  final sameHost = originHost == hostNoPort ||
      (_isLoopbackHostName(originHost) && _isLoopbackHostName(hostNoPort));
  if (!sameHost) {
    return "Cross-origin browser request from '$rawOrigin' to unauthenticated MCP endpoint blocked (Origin guard).";
  }
  return null;
}

Response _withCors(Response r) {
  return r.change(
    headers: const {
      'access-control-allow-origin': '*',
      'access-control-expose-headers': 'Mcp-Session-Id, MCP-Protocol-Version, Mcp-Method, Mcp-Name',
    },
  );
}

/// In-process lifecycle controller used by both Flutter Desktop and CLI.
class McpServiceController {
  final File configFile;
  final String localLaunchTicket = randomTokenUrlSafe(24);
  McpServerEngine? _engine;
  final List<HttpServer> _httpServers = [];
  final StreamController<bool> _runningStateCtrl =
      StreamController<bool>.broadcast();

  McpServiceController([File? configFile])
      : configFile = configFile ?? StoragePaths.instance.defaultConfigFile;

  bool get isRunning => _httpServers.isNotEmpty;
  Stream<bool> get runningStream => _runningStateCtrl.stream;
  McpServerEngine? get engine => _engine;

  ServerConfig loadCurrentServerConfig() {
    final saved = loadSavedConfig(configFile);
    return ServerConfig.fromSavedMap(saved, configFile: configFile);
  }

  Future<void> start() async {
    if (_httpServers.isNotEmpty) return;
    final cfg = loadCurrentServerConfig();
    if (cfg.transport == 'stdio') {
      cfg.transport = 'dual';
    }
    McpLogger.instance.configure(
      name: cfg.serverName,
      levelName: cfg.logLevel,
      logFilePath: cfg.logFile,
      noColor: cfg.noColor,
    );
    final eng = McpServerEngine(cfg);
    final srvs = await eng.serveHttpMulti(
      isServiceRunning: () => isRunning,
      onStartService: start,
      onStopService: stop,
      onRestartService: restart,
      localLaunchTicket: localLaunchTicket,
    );
    _engine = eng;
    _httpServers
      ..clear()
      ..addAll(srvs);
    _runningStateCtrl.add(true);
    final urlsDesc = srvs
        .map((s) => 'http://${s.address.host}:${s.port}')
        .join(', ');
    StructuredEventBus.instance.emit({
      'kind': 'info',
      'badge': '系统',
      'level': 'INFO',
      'summary': 'MCP 服务已启动: $urlsDesc (${eng.tools.length} 个工具)',
    });
    await TunnelManager.instance.startAutoTunnels(cfg.profiles, cfg.port);
  }

  Future<void> stop() async {
    await TunnelManager.instance.stopAll();
    final eng = _engine;
    final srvs = List<HttpServer>.from(_httpServers);
    _engine = null;
    _httpServers.clear();
    if (eng != null) {
      await eng.processManager.stopAll();
    }
    await SubMcpManager.instance.closeAllSessions();
    if (srvs.isNotEmpty) {
      for (final srv in srvs) {
        await srv.close(force: true);
      }
      _runningStateCtrl.add(false);
      StructuredEventBus.instance.emit({
        'kind': 'info',
        'badge': '系统',
        'level': 'INFO',
        'summary': 'MCP 服务已停止',
      });
    }
  }

  Future<void> restart() async {
    await stop();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    await start();
  }

  Future<void> dispose() async {
    await stop();
    if (!_runningStateCtrl.isClosed) {
      await _runningStateCtrl.close();
    }
  }
}
