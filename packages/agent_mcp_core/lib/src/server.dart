import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'auth.dart';
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

const String mcpProtocolVersion = '2025-03-26';

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
        : 'SCOPED (${config.roots.length} roots)';
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
          'access_mode': policy.roots.isEmpty ? 'unrestricted' : 'scoped',
          'allowed_roots': policy.roots,
          'read_only': policy.readOnly,
          'allow_secrets': policy.allowSecrets,
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
  }

  Future<Map<String, dynamic>?> handleJsonRpcMessage(
    Map<String, dynamic> req,
  ) async {
    final method = req['method']?.toString();
    final hasId = req.containsKey('id') && req['id'] != null;
    final id = req['id'];
    final rawParams = req['params'];
    final params = rawParams is Map
        ? Map<String, dynamic>.from(rawParams)
        : const <String, dynamic>{};

    if (!hasId) {
      // JSON-RPC Notification (e.g. notifications/initialized, notifications/cancelled)
      return null;
    }

    Map<String, dynamic> ok(Map<String, dynamic> result) => {
          'jsonrpc': '2.0',
          'id': id,
          'result': result,
        };

    Map<String, dynamic> fail(int code, String message) => {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': code, 'message': message},
        };

    switch (method) {
      case 'initialize':
        final clientProto = params['protocolVersion']?.toString();
        final negotiatedProto =
            (clientProto != null && clientProto.isNotEmpty)
                ? clientProto
                : mcpProtocolVersion;
        return ok({
          'protocolVersion': negotiatedProto,
          'capabilities': {
            'tools': {'listChanged': false},
          },
          'serverInfo': {
            'name': config.serverName,
            'version': agentMcpVersion,
            'icons': [
              {'src': appIconDataUri, 'mimeType': 'image/svg+xml'},
            ],
          },
          'instructions': instructions,
        });

      case 'ping':
        return ok(const <String, dynamic>{});

      case 'resources/list':
        return ok(const {'resources': <dynamic>[]});

      case 'resources/templates/list':
        return ok(const {'resourceTemplates': <dynamic>[]});

      case 'prompts/list':
        return ok(const {'prompts': <dynamic>[]});

      case 'tools/list':
        final policy = getEffectivePolicy(config);
        final silent = policy.relaxedCommandAnnotations;
        return ok({
          'tools': _tools.values
              .map((t) => t.toMcpJson(silentAnnotations: silent))
              .toList(),
        });

      case 'tools/call':
        final toolName = (params['name'] ?? '').toString();
        final rawArgs = params['arguments'];
        final callArgs = rawArgs is Map
            ? Map<String, dynamic>.from(rawArgs)
            : <String, dynamic>{};
        final spec = _tools[toolName];
        if (spec == null) {
          return fail(-32602, "Unknown tool: '$toolName'");
        }
        final res = await _executeToolAudited(spec, callArgs);
        return ok(res);

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
                'Authorization, X-API-Key, Content-Type, Accept, Mcp-Session-Id, MCP-Protocol-Version, Last-Event-ID, X-Filename',
            'access-control-expose-headers': 'Mcp-Session-Id, MCP-Protocol-Version',
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

      if (bearerTok.isNotEmpty && st.apiKeyMap.containsKey(bearerTok)) {
        matchedProfile = st.apiKeyMap[bearerTok];
        tokenAuthenticated = true;
      } else if (bearerTok.isNotEmpty) {
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

      final policy = matchedProfile != null
          ? st.policyFromProfile(matchedProfile, rawHost)
          : st.defaultPolicy(rawHost);

      // 6. Execute MCP Transport inside isolated Dart Zone carrying `policy`
      return runWithPolicy(policy, () async {
        final allowHttp = config.transport == 'dual' || config.transport == 'http';
        final allowSse = config.transport == 'dual' || config.transport == 'sse';

        if (allowHttp && path == '/mcp') {
          return _withCors(await _handleStreamableHttp(request));
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

  Future<Response> _handleStreamableHttp(Request request) async {
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
          'mcp-protocol-version': mcpProtocolVersion,
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
          final r = await handleJsonRpcMessage(Map<String, dynamic>.from(item));
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
          'mcp-protocol-version': mcpProtocolVersion,
        },
      );
    }

    if (decoded is Map) {
      final resp =
          await handleJsonRpcMessage(Map<String, dynamic>.from(decoded));
      if (resp == null) {
        return Response(202, headers: {'mcp-session-id': sid});
      }
      return Response.ok(
        jsonEncode(resp),
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'mcp-session-id': sid,
          'mcp-protocol-version': mcpProtocolVersion,
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
    final gRoots = saved['roots'] is List
        ? (saved['roots'] as List)
            .map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .map(expandAndResolvePath)
            .toList()
        : List<String>.from(config.roots);

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
        roots: globalRoots,
      );
    }
    final customRoots = ((prof['roots'] as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .map(expandAndResolvePath)
        .toList();
    return AccessPolicy(
      profileId: (prof['id'] ?? 'default').toString(),
      profileName: (prof['name'] ?? '主入口').toString(),
      host: hostStr,
      readOnly: prof['read_only'] == true,
      allowSecrets: prof['allow_secrets'] == true,
      relaxedCommandAnnotations: prof['relaxed_command_annotations'] == true,
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
      roots: globalRoots,
    );
  }
}

Response _withCors(Response r) {
  return r.change(
    headers: const {
      'access-control-allow-origin': '*',
      'access-control-expose-headers': 'Mcp-Session-Id, MCP-Protocol-Version',
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
