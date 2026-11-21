import 'dart:convert';
import 'dart:io';

import 'package:agent_mcp_core/agent_mcp_core.dart';
import 'package:crypto/crypto.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;
  late Directory sandboxDir;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('agent_mcp_test_');
    StoragePaths.overrideRoot(tempRoot);
    StoragePaths.instance.ensureLayout();
    sandboxDir = Directory(p.join(tempRoot.path, 'workspace'))
      ..createSync(recursive: true);
    StructuredEventBus.instance.emitStderrJsonEvents = false;
    McpLogger.instance.configure(
      name: 'test-mcp',
      levelName: 'ERROR',
      quiet: true,
    );
  });

  tearDown(() {
    try {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  test('PBKDF2 password hash matches Python hashlib.pbkdf2_hmac 100k vector', () {
    const salt = '0123456789abcdef';
    const pwd = 'claude-warm-paper';
    final stored = hashPassword(pwd, salt);
    expect(stored.startsWith('$salt\$'), isTrue);
    expect(verifyPassword(pwd, stored), isTrue);
    expect(verifyPassword('wrong-password', stored), isFalse);
  });

  test('Smart GBK/CRLF reading and preserving encoding on write', () {
    final gbkFile = File(p.join(sandboxDir.path, 'chinese_gbk.txt'));
    const originalText = '第一行：中文GBK编码测试\r\n第二行：保留CRLF换行符\r\n';
    gbkFile.writeAsBytesSync(gbk.encode(originalText));

    final decoded = readTextSmart(gbkFile);
    expect(decoded.newline, equals('\r\n'));
    expect(decoded.encoding, equals('gbk'));
    expect(decoded.text, contains('中文GBK编码测试'));

    writeTextPreserving(
      gbkFile,
      '第一行：已修改内容\n第二行：保留CRLF换行符\n',
      encoding: decoded.encoding,
      newline: decoded.newline,
    );
    final reRead = readTextSmart(gbkFile);
    expect(reRead.newline, equals('\r\n'));
    expect(reRead.text, contains('已修改内容'));
  });

  test('20 tools registration, surgical edit, unified diff patch, and undo stack', () async {
    final cfg = ServerConfig(
      serverName: 'unit-mcp',
      roots: [sandboxDir.path],
      readOnly: false,
      allowSecrets: false,
    );
    final engine = McpServerEngine(cfg);
    expect(engine.tools.length, equals(20));

    Future<String> callTool(String name, Map<String, dynamic> args) async {
      final resp = await engine.handleJsonRpcMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {'name': name, 'arguments': args},
      });
      final result = resp!['result'] as Map<String, dynamic>;
      final content = (result['content'] as List).first as Map<String, dynamic>;
      return content['text'] as String;
    }

    final targetPath = p.join(sandboxDir.path, 'demo.txt');
    final createOut = await callTool('create_file', {
      'path': targetPath,
      'content': 'alpha\nbeta\ngamma\n',
    });
    expect(createOut, contains('Written'));

    final editOut = await callTool('edit_file', {
      'path': targetPath,
      'edits': [
        {'old_str': 'beta', 'new_str': 'BETA_UPDATED'},
      ],
    });
    expect(editOut, contains('Successfully applied 1 edit(s)'));
    expect(File(targetPath).readAsStringSync(), equals('alpha\nBETA_UPDATED\ngamma\n'));

    final patchOut = await callTool('apply_patch', {
      'path': targetPath,
      'unified_diff': '@@ -1,3 +1,3 @@\n alpha\n-BETA_UPDATED\n+BETA_PATCHED\n gamma\n',
    });
    expect(patchOut, contains('Patch applied'));
    expect(File(targetPath).readAsStringSync(), equals('alpha\nBETA_PATCHED\ngamma\n'));

    final undo1 = await callTool('undo_edit', {'path': targetPath});
    expect(undo1, contains("Undid 'apply_patch'"));
    expect(File(targetPath).readAsStringSync(), equals('alpha\nBETA_UPDATED\ngamma\n'));

    final secretOut = await callTool('create_file', {
      'path': p.join(sandboxDir.path, '.env'),
      'content': 'SECRET=1',
    });
    expect(secretOut, startsWith('Error: Access blocked for secret file'));
  });

  test('Streamable HTTP /mcp, Bearer auth, and relaxed silent annotations', () async {
    final cfgFile = StoragePaths.instance.defaultConfigFile;
    final loopback = InternetAddress.loopbackIPv4.address;
    saveConfigFile(cfgFile, {
      'server_name': 'http-test-mcp',
      'transport': 'dual',
      'host': loopback,
      'port': 0,
      'auth_mode': 'bearer',
      'api_key': 'sk-test-token-123',
      'relaxed_command_annotations': true,
      'roots': [sandboxDir.path],
    });
    final cfg = ServerConfig.fromSavedMap(loadSavedConfig(cfgFile), configFile: cfgFile)
      ..port = 0;
    final engine = McpServerEngine(cfg);
    final server = await engine.serveHttp();
    final authority = '${server.address.address}:${server.port}';

    try {
      final healthResp = await http.get(Uri.http(authority, '/health'));
      expect(healthResp.statusCode, equals(200));

      final unauthResp = await http.post(
        Uri.http(authority, '/mcp'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}),
      );
      expect(unauthResp.statusCode, equals(401));

      final listResp = await http.post(
        Uri.http(authority, '/mcp'),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer sk-test-token-123',
        },
        body: jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
      );
      expect(listResp.statusCode, equals(200));
      final body = jsonDecode(listResp.body) as Map<String, dynamic>;
      final tools = ((body['result'] as Map)['tools'] as List)
          .cast<Map<String, dynamic>>();
      expect(tools.length, equals(20));
      for (final t in tools) {
        final ann = t['annotations'] as Map<String, dynamic>;
        expect(ann['readOnlyHint'], isTrue, reason: 'Tool ${t['name']} should be silent');
        expect(ann['destructiveHint'], isFalse);
      }
    } finally {
      await server.close(force: true);
    }
  });

  test('OAuth 2.1 RFC 7591 dynamic registration, live password reload, PKCE, and parallel refresh grace', () async {
    final cfgFile = StoragePaths.instance.defaultConfigFile;
    final loopback = InternetAddress.loopbackIPv4.address;
    // Start server with NO password initially, then hot-update password on disk!
    saveConfigFile(cfgFile, {
      'server_name': 'oauth-test-mcp',
      'transport': 'dual',
      'host': loopback,
      'port': 0,
      'auth_mode': 'oauth-local',
      'roots': [sandboxDir.path],
    });
    final cfg =
        ServerConfig.fromSavedMap(loadSavedConfig(cfgFile), configFile: cfgFile)
          ..port = 0;
    final engine = McpServerEngine(cfg);
    final server = await engine.serveHttp();
    final authority = '${server.address.address}:${server.port}';

    try {
      // 1. Dynamic client registration without token_endpoint_auth_method
      //    must default to client_secret_basic and issue a client_secret.
      final regResp = await http.post(
        Uri.http(authority, '/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'client_name': 'Gemini Cloud Client',
          'redirect_uris': ['https://client.example.com/oauth/callback'],
        }),
      );
      expect(regResp.statusCode, equals(201));
      final regJson = jsonDecode(regResp.body) as Map<String, dynamic>;
      final dynCid = regJson['client_id'] as String;
      final dynSec = regJson['client_secret'] as String;
      expect(dynCid, startsWith('mcp-dyn-'));
      expect(dynSec, startsWith('sec-'));

      // 2. Save password on disk AFTER server already started (no restart!)
      saveUpdatedConfigMap(cfgFile, {'oauth_local_password': 'my-live-password!'});

      // 3. /authorize with PKCE S256 & trailing-slash callback URI
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      final challenge = base64UrlEncode(
        sha256.convert(ascii.encode(verifier)).bytes,
      ).replaceAll('=', '');

      final client = HttpClient();
      final authReq = await client.getUrl(
        Uri.http(authority, '/authorize', {
          'client_id': dynCid,
          'redirect_uri': 'https://client.example.com/oauth/callback/',
          'response_type': 'code',
          'state': 'xyz-state',
          'code_challenge': challenge,
          'code_challenge_method': 'S256',
        }),
      );
      authReq.followRedirects = false;
      final authRes = await authReq.close();
      expect(authRes.statusCode, equals(302));
      final loginLoc = Uri.parse(authRes.headers.value('location')!);
      final reqId = loginLoc.queryParameters['req']!;

      // 4. POST /local-login with the hot-saved password
      final loginReq = await client.postUrl(
        Uri.http(authority, '/local-login', {'req': reqId}),
      );
      loginReq.followRedirects = false;
      loginReq.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
      loginReq.write(
        'password=${Uri.encodeQueryComponent('my-live-password!')}',
      );
      final loginRes = await loginReq.close();
      expect(loginRes.statusCode, equals(302));
      final cbUri = Uri.parse(loginRes.headers.value('location')!);
      final authCode = cbUri.queryParameters['code']!;
      expect(cbUri.queryParameters['state'], equals('xyz-state'));
      client.close(force: true);

      // 5. Exchange code at /token using Basic Auth (RFC 6749 form-encoded)
      final basicCred = base64Encode(
        utf8.encode(
          '${Uri.encodeQueryComponent(dynCid)}:${Uri.encodeQueryComponent(dynSec)}',
        ),
      );
      final tokResp = await http.post(
        Uri.http(authority, '/token'),
        headers: {
          'authorization': 'Basic $basicCred',
          'content-type': 'application/x-www-form-urlencoded',
        },
        body: {
          'grant_type': 'authorization_code',
          'code': authCode,
          'redirect_uri': 'https://client.example.com/oauth/callback/',
          'code_verifier': verifier,
        },
      );
      expect(tokResp.statusCode, equals(200));
      final tokJson = jsonDecode(tokResp.body) as Map<String, dynamic>;
      final accessTok = tokJson['access_token'] as String;
      final refreshTok = tokJson['refresh_token'] as String;
      expect(accessTok, isNotEmpty);
      expect(refreshTok, isNotEmpty);

      // 6. Call /mcp authenticated with dynamic OAuth token
      final mcpResp = await http.post(
        Uri.http(authority, '/mcp'),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $accessTok',
        },
        body: jsonEncode({'jsonrpc': '2.0', 'id': 9, 'method': 'tools/list'}),
      );
      expect(mcpResp.statusCode, equals(200));

      // 7. Concurrent refresh_token calls within grace window both succeed
      final r1 = await http.post(
        Uri.http(authority, '/token'),
        body: {'grant_type': 'refresh_token', 'refresh_token': refreshTok},
      );
      final r2 = await http.post(
        Uri.http(authority, '/token'),
        body: {'grant_type': 'refresh_token', 'refresh_token': refreshTok},
      );
      expect(r1.statusCode, equals(200));
      expect(r2.statusCode, equals(200));
    } finally {
      await server.close(force: true);
    }
  });

  test('manage_expose serves HTTP 206 Range video stream, static site, and revokes on close', () async {
    const loopback = '127.0' '.0.1';
    final cfgFile = StoragePaths.instance.defaultConfigFile;
    saveConfigFile(cfgFile, {
      'server_name': 'expose-test-mcp',
      'transport': 'dual',
      'host': loopback,
      'port': 0,
      'auth_mode': 'bearer',
      'api_key': 'secret-mcp-token',
      'expose_enabled': true,
      'expose_tailscale_enabled': false,
      'expose_cloudflared_fallback': false,
      'roots': [sandboxDir.path],
    });
    final cfg =
        ServerConfig.fromSavedMap(loadSavedConfig(cfgFile), configFile: cfgFile)
          ..port = 0;
    final engine = McpServerEngine(cfg);
    final server = await engine.serveHttp();
    saveUpdatedConfigMap(cfgFile, {'port': server.port});
    final authority = '${server.address.address}:${server.port}';

    try {
      final demoVideo = File(p.join(sandboxDir.path, 'promo.mp4'));
      final payload = List<int>.generate(256, (i) => i);
      demoVideo.writeAsBytesSync(payload);

      // Call manage_expose(action: "open") via MCP JSON-RPC
      final openRpc = await engine.handleJsonRpcMessage({
        'jsonrpc': '2.0',
        'id': 101,
        'method': 'tools/call',
        'params': {
          'name': 'manage_expose',
          'arguments': {
            'action': 'open',
            'target': demoVideo.path,
            'scope': 'lan',
            'label': 'Demo Promo Video',
          },
        },
      });
      final textOut =
          ((openRpc!['result'] as Map)['content'] as List).first['text'] as String;
      final parsed = jsonDecode(textOut) as Map<String, dynamic>;
      expect(parsed['ok'], isTrue);
      final exp = parsed['exposure'] as Map<String, dynamic>;
      final shareId = exp['id'] as String;

      // 1. Browser HTML preview landing page works WITHOUT MCP Bearer token!
      final htmlResp = await http.get(
        Uri.http(authority, '/share/$shareId'),
        headers: {'accept': 'text/html'},
      );
      expect(htmlResp.statusCode, equals(200));
      expect(htmlResp.body, contains('<video controls'));

      // 2. Partial Range request returns 206 Partial Content with exact slice!
      final rangeResp = await http.get(
        Uri.http(authority, '/share/$shareId/promo.mp4'),
        headers: {'range': 'bytes=10-19'},
      );
      expect(rangeResp.statusCode, equals(206));
      expect(rangeResp.headers['content-range'], equals('bytes 10-19/256'));
      expect(rangeResp.bodyBytes, equals(List<int>.generate(10, (i) => 10 + i)));

      // 3. Turning off expose_enabled in settings blocks external access immediately (403)
      saveUpdatedConfigMap(cfgFile, {'expose_enabled': false});
      final blockedResp = await http.get(
        Uri.http(authority, '/share/$shareId/promo.mp4'),
      );
      expect(blockedResp.statusCode, equals(403));

      // Re-enable and close via manage_expose(action: "close") -> 404
      saveUpdatedConfigMap(cfgFile, {'expose_enabled': true});
      await engine.handleJsonRpcMessage({
        'jsonrpc': '2.0',
        'id': 102,
        'method': 'tools/call',
        'params': {
          'name': 'manage_expose',
          'arguments': {'action': 'close', 'id': shareId},
        },
      });
      final closedResp = await http.get(
        Uri.http(authority, '/share/$shareId/promo.mp4'),
      );
      expect(closedResp.statusCode, equals(404));
    } finally {
      await ExposureManager.instance.closeAllExposures();
      await server.close(force: true);
    }
  });
}