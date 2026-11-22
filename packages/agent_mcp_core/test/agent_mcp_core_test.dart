import 'dart:convert';
import 'dart:io';

import 'package:agent_mcp_core/agent_mcp_core.dart';
import 'package:archive/archive.dart';
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

  test('Linux systemd unit generation, CORS MCP-Protocol-Version, and /health metadata', () async {
    final unitDir = Directory(p.join(tempRoot.path, 'systemd_units'));
    final fakeExe = File(p.join(tempRoot.path, 'agent-mcp'))..writeAsStringSync('#!/bin/sh\n');
    final inst = AutoStartManager.installLinuxSystemdService(
      systemWide: false,
      startNow: false,
      unitDirOverride: unitDir,
      executableOverride: fakeExe.path,
    );
    expect(inst['ok'], isTrue);
    final unitText = File(inst['unit_path'] as String).readAsStringSync();
    expect(unitText, contains('ExecStart="'));
    expect(unitText, contains('AGENT_MCP_HOME='));
    expect(unitText, contains('Restart=on-failure'));

    final uninst = AutoStartManager.uninstallLinuxSystemdService(
      systemWide: false,
      unitDirOverride: unitDir,
    );
    expect(uninst['removed'], isTrue);

    const loopback = '127.0' '.0.1';
    final cfg = ServerConfig(
      serverName: 'meta-mcp',
      transport: 'dual',
      host: loopback,
      port: 0,
      authMode: 'bearer',
      apiKey: 'sk-remote-999',
      roots: [sandboxDir.path],
    );
    final engine = McpServerEngine(cfg);
    final srv = await engine.serveHttp();
    final authority = '${srv.address.address}:${srv.port}';
    try {
      final hResp = await http.get(Uri.http(authority, '/health'));
      final hJson = jsonDecode(hResp.body) as Map<String, dynamic>;
      expect(hJson['os'], equals(Platform.operatingSystem));
      expect(hJson['tools_count'], equals(20));

      final optReq = http.Request('OPTIONS', Uri.http(authority, '/mcp'));
      final optStream = await optReq.send();
      expect(optStream.statusCode, equals(200));
      expect(
        optStream.headers['access-control-allow-headers'] ?? '',
        contains('MCP-Protocol-Version'),
      );
    } finally {
      await srv.close(force: true);
    }
  });

  test('4-mode manage_expose: folder drill-down to single-file preview, zip download, and single HTML site', () async {
    const loopback = '127.0' '.0.1';
    final cfgFile = StoragePaths.instance.defaultConfigFile;
    saveConfigFile(cfgFile, {
      'server_name': 'expose-4mode-mcp',
      'transport': 'dual',
      'host': loopback,
      'port': 0,
      'auth_mode': 'none',
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
      // Create folder with index.html AND nested subfolder + mp4 + markdown
      final courseDir = Directory(p.join(sandboxDir.path, 'physics_pack'))
        ..createSync(recursive: true);
      File(p.join(courseDir.path, 'index.html'))
          .writeAsStringSync('<h1>Interactive Optics Website</h1>');
      File(p.join(courseDir.path, 'guide.md'))
          .writeAsStringSync('# Lens Formula Notes');
      final subDir = Directory(p.join(courseDir.path, '01_videos'))
        ..createSync(recursive: true);
      File(p.join(subDir.path, 'lens_demo.mp4'))
          .writeAsBytesSync(List<int>.generate(64, (i) => i));

      Future<Map<String, dynamic>> openMode(String target, String mode) async {
        final rpc = await engine.handleJsonRpcMessage({
          'jsonrpc': '2.0',
          'id': 201,
          'method': 'tools/call',
          'params': {
            'name': 'manage_expose',
            'arguments': {
              'action': 'open',
              'target': target,
              'mode': mode,
              'scope': 'lan',
            },
          },
        });
        final txt =
            ((rpc!['result'] as Map)['content'] as List).first['text'] as String;
        return (jsonDecode(txt) as Map<String, dynamic>)['exposure']
            as Map<String, dynamic>;
      }

      // 1. Folder mode ALWAYS shows directory listing (even when index.html exists!)
      final folderExp = await openMode(courseDir.path, 'folder');
      expect(folderExp['kind'], equals('folder'));
      final folderId = folderExp['id'] as String;

      final rootListResp = await http.get(
        Uri.http(authority, '/share/$folderId/'),
        headers: {'accept': 'text/html'},
      );
      expect(rootListResp.statusCode, equals(200));
      expect(rootListResp.body, contains('01_videos/'));
      expect(rootListResp.body, contains('guide.md'));

      // Enter subfolder -> lists lens_demo.mp4
      final subListResp = await http.get(
        Uri.http(authority, '/share/$folderId/01_videos/'),
        headers: {'accept': 'text/html'},
      );
      expect(subListResp.statusCode, equals(200));
      expect(subListResp.body, contains('lens_demo.mp4'));

      // Click file inside subfolder -> opens Unified Single-File Preview with Back-to-Folder button!
      final filePreviewResp = await http.get(
        Uri.http(authority, '/share/$folderId/01_videos/lens_demo.mp4'),
        headers: {'accept': 'text/html'},
      );
      expect(filePreviewResp.statusCode, equals(200));
      expect(filePreviewResp.body, contains('<video controls'));
      expect(filePreviewResp.body, contains('返回所在文件夹'));

      // Zip download of subfolder works cleanly
      final zipResp = await http.get(
        Uri.http(authority, '/share/$folderId/01_videos/', {'zip': '1'}),
      );
      expect(zipResp.statusCode, equals(200));
      expect(zipResp.headers['content-type'], equals('application/zip'));
      expect(zipResp.bodyBytes.length, greaterThan(20));

      // 2. Site mode on the exact same directory renders index.html directly!
      final siteDirExp = await openMode(courseDir.path, 'site');
      expect(siteDirExp['kind'], equals('site'));
      final siteDirResp = await http.get(
        Uri.http(authority, '/share/${siteDirExp['id']}/'),
        headers: {'accept': 'text/html'},
      );
      expect(siteDirResp.statusCode, equals(200));
      expect(siteDirResp.body, equals('<h1>Interactive Optics Website</h1>'));

      // 3. Single .html file shared in site mode renders full-screen webpage + sibling CSS!
      final singleHtml = File(p.join(sandboxDir.path, 'standalone_lab.html'))
        ..writeAsStringSync('<!doctype html><link rel="stylesheet" href="lab.css"><h2>Single HTML Lab</h2>');
      File(p.join(sandboxDir.path, 'lab.css')).writeAsStringSync('body { color: #c96442; }');
      final singleSiteExp = await openMode(singleHtml.path, 'site');
      expect(singleSiteExp['kind'], equals('site'));
      final singleHtmlResp = await http.get(
        Uri.http(authority, '/share/${singleSiteExp['id']}/'),
        headers: {'accept': 'text/html'},
      );
      expect(singleHtmlResp.statusCode, equals(200));
      expect(singleHtmlResp.body, contains('Single HTML Lab'));
      final siblingCssResp = await http.get(
        Uri.http(authority, '/share/${singleSiteExp['id']}/lab.css'),
      );
      expect(siblingCssResp.statusCode, equals(200));
      expect(siblingCssResp.body, contains('#c96442'));
    } finally {
      await ExposureManager.instance.closeAllExposures();
      await server.close(force: true);
    }
  });

  test('v2.2 P0-1 & P0-2: symlink escape guard, secret blocklist, Origin DNS-rebinding guard, and deep log redaction', () async {
    const loopback = '127.0' '.0.1';
    final cfgFile = StoragePaths.instance.defaultConfigFile;
    saveConfigFile(cfgFile, {
      'server_name': 'sec-v22-mcp',
      'transport': 'dual',
      'host': loopback,
      'port': 0,
      'auth_mode': 'none',
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
      // 1. Recursive depth-6 credential & Authorization/PIN redaction
      final scrubbed = redactArgs({
        'path': '/tmp/ok.txt',
        'pin_code': '8899',
        'nested': {
          'headers': {
            'Authorization': 'Bearer sk-super-secret-token-999',
            'X-Custom': 'visible-val',
          },
          'env': {
            'OPENAI_API_KEY': 'sk-proj-abc123456',
          },
        },
      });
      expect(scrubbed['pin_code'], equals('***'));
      final nested = scrubbed['nested'] as Map<String, dynamic>;
      expect((nested['headers'] as Map)['Authorization'], equals('***'));
      expect((nested['headers'] as Map)['X-Custom'], equals('visible-val'));
      expect((nested['env'] as Map)['OPENAI_API_KEY'], equals('***'));

      // 2. Anti-DNS-Rebinding Origin guard on /mcp and /dashboard/api/*
      final evilMcpResp = await http.post(
        Uri.http(authority, '/mcp'),
        headers: {
          'content-type': 'application/json',
          'origin': 'https://evil-rebinding.attacker.example',
        },
        body: jsonEncode({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}),
      );
      expect(evilMcpResp.statusCode, equals(403));

      final evilDashResp = await http.post(
        Uri.http(authority, '/dashboard/api/config'),
        headers: {
          'content-type': 'application/json',
          'origin': 'https://evil-rebinding.attacker.example',
        },
        body: jsonEncode({'server_name': 'hijacked'}),
      );
      expect(evilDashResp.statusCode, equals(403));

      // Non-browser SDK clients (no Origin header) & same-host localhost Origin succeed
      final sdkResp = await http.post(
        Uri.http(authority, '/mcp'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'}),
      );
      expect(sdkResp.statusCode, equals(200));

      final localOriginResp = await http.post(
        Uri.http(authority, '/mcp'),
        headers: {
          'content-type': 'application/json',
          'origin': 'http://$authority',
        },
        body: jsonEncode({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'}),
      );
      expect(localOriginResp.statusCode, equals(200));

      // 3. Symlink escape & unified secret blocklist in /share/<id> and streaming ?zip=1
      final outsideSecret = File(p.join(tempRoot.path, 'outside_host_secret.txt'))
        ..writeAsStringSync('TOP_SECRET_OUTSIDE_SHARE_ROOT');
      final sharedDir = Directory(p.join(sandboxDir.path, 'public_bundle'))
        ..createSync(recursive: true);
      File(p.join(sharedDir.path, 'readme.txt')).writeAsStringSync('Safe public content');
      File(p.join(sharedDir.path, '.env')).writeAsStringSync('DB_PASSWORD=123');
      final sshDir = Directory(p.join(sharedDir.path, '.ssh'))..createSync();
      File(p.join(sshDir.path, 'id_ed25519')).writeAsStringSync('PRIVATE_KEY');
      Link(p.join(sharedDir.path, 'escape_link.txt')).createSync(outsideSecret.path);

      final rpc = await engine.handleJsonRpcMessage({
        'jsonrpc': '2.0',
        'id': 301,
        'method': 'tools/call',
        'params': {
          'name': 'manage_expose',
          'arguments': {
            'action': 'open',
            'target': sharedDir.path,
            'mode': 'folder',
            'scope': 'lan',
          },
        },
      });
      final shareId = ((jsonDecode(
        ((rpc!['result'] as Map)['content'] as List).first['text'] as String,
      ) as Map)['exposure'] as Map)['id'] as String;

      final escapeResp = await http.get(
        Uri.http(authority, '/share/$shareId/escape_link.txt'),
      );
      expect(escapeResp.statusCode, equals(403));

      final envResp = await http.get(
        Uri.http(authority, '/share/$shareId/.env'),
      );
      expect(envResp.statusCode, equals(403));

      final sshResp = await http.get(
        Uri.http(authority, '/share/$shareId/.ssh/id_ed25519'),
      );
      expect(sshResp.statusCode, equals(403));

      // Streaming PKZIP (?zip=1) decodes cleanly and omits symlinks & blocked secrets
      final zipResp = await http.get(
        Uri.http(authority, '/share/$shareId/', {'zip': '1'}),
      );
      expect(zipResp.statusCode, equals(200));
      final archive = ZipDecoder().decodeBytes(zipResp.bodyBytes);
      final entryNames = archive.files.map((f) => f.name).toList();
      expect(entryNames, contains('readme.txt'));
      expect(entryNames.any((n) => n.contains('escape_link')), isFalse);
      expect(entryNames.any((n) => n.contains('.env')), isFalse);
      expect(entryNames.any((n) => n.contains('id_ed25519')), isFalse);
    } finally {
      await ExposureManager.instance.closeAllExposures();
      await server.close(force: true);
    }
  });

  test('v2.2 P0-3: SubMcpManager warm stdio session pool reuses child PID across calls and evicts cleanly', () async {
    final mockSubMcpScript = File(p.join(tempRoot.path, 'mock_warm_submcp.dart'));
    mockSubMcpScript.writeAsStringSync(r"""
import 'dart:convert';
import 'dart:io';

void main() {
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
    if (line.trim().isEmpty) return;
    final msg = jsonDecode(line) as Map<String, dynamic>;
    final method = (msg['method'] ?? '').toString();
    final id = msg['id'];
    if (id == null) return;
    if (method == 'initialize') {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'protocolVersion': '2024-11-05',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'mock-warm', 'version': '1.0.0'},
        },
      }));
    } else if (method == 'tools/list') {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'tools': [
            {
              'name': 'get_worker_pid',
              'description': 'Returns current worker OS PID',
              'inputSchema': {'type': 'object', 'properties': {}},
            },
          ],
        },
      }));
    } else if (method == 'tools/call') {
      stdout.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'content': [
            {'type': 'text', 'text': 'PID=$pid'},
          ],
        },
      }));
    }
  });
}
""");

    SubMcpManager.instance.upsertEntry({
      'name': 'warm-pid-check',
      'enabled': true,
      'transport': 'stdio',
      'command': Platform.resolvedExecutable,
      'args': ['run', mockSubMcpScript.path],
      'timeout': 20,
    });

    try {
      final out1 = await SubMcpManager.instance.callTool('warm-pid-check', 'get_worker_pid', arguments: const {});
      final out2 = await SubMcpManager.instance.callTool('warm-pid-check', 'get_worker_pid', arguments: const {});
      final out3 = await SubMcpManager.instance.callTool('warm-pid-check', 'get_worker_pid', arguments: const {});
      expect(out1, startsWith('PID='));
      expect(out2, equals(out1), reason: '2nd call must reuse warm stdio child process');
      expect(out3, equals(out1), reason: '3rd call must reuse warm stdio child process');

      // Evict warm pool and verify a fresh child PID is spawned cleanly on next call
      await SubMcpManager.instance.closeAllSessions();
      final outAfterEvict =
          await SubMcpManager.instance.callTool('warm-pid-check', 'get_worker_pid', arguments: const {});
      expect(outAfterEvict, startsWith('PID='));
      expect(outAfterEvict, isNot(equals(out1)));
    } finally {
      SubMcpManager.instance.deleteEntry('warm-pid-check');
      await SubMcpManager.instance.closeAllSessions();
    }
  });

  test('v2.2 P0-4, P1-1 & P1-2: full-duplex WebSocket port proxy, folder sibling nav, PIN lock, and burn-after-download', () async {
    const loopback = '127.0' '.0.1';
    final cfgFile = StoragePaths.instance.defaultConfigFile;
    saveConfigFile(cfgFile, {
      'server_name': 'ws-pin-mcp',
      'transport': 'dual',
      'host': loopback,
      'port': 0,
      'auth_mode': 'none',
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

    // Spin up a local upstream HTTP + WebSocket HMR echo server
    final upstream = await HttpServer.bind(loopback, 0);
    upstream.listen((HttpRequest req) async {
      if (WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((msg) {
          ws.add('hmr-echo:$msg');
        });
      } else {
        req.response
          ..statusCode = 200
          ..write('upstream-http-ok');
        await req.response.close();
      }
    });

    try {
      Future<Map<String, dynamic>> openShare(Map<String, dynamic> args) async {
        final rpc = await engine.handleJsonRpcMessage({
          'jsonrpc': '2.0',
          'id': 401,
          'method': 'tools/call',
          'params': {
            'name': 'manage_expose',
            'arguments': {'action': 'open', 'scope': 'lan', ...args},
          },
        });
        final txt =
            ((rpc!['result'] as Map)['content'] as List).first['text'] as String;
        return (jsonDecode(txt) as Map<String, dynamic>)['exposure']
            as Map<String, dynamic>;
      }

      // 1. P0-4: Full-duplex WebSocket upgrade tunneling over /share/<id>/ws
      final portExp = await openShare({'target': '${upstream.port}', 'mode': 'port'});
      final portId = portExp['id'] as String;
      final ws = await WebSocket.connect('ws://$authority/share/$portId/vite-hmr');
      final received = <String>[];
      final done = ws.listen((data) => received.add(data.toString()));
      ws.add('ping-1');
      ws.add('ping-2');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(received, equals(['hmr-echo:ping-1', 'hmr-echo:ping-2']));
      await done.cancel();
      await ws.close();

      // 2. P1-1: Folder subfolder -> single-file preview breadcrumbs + prev/next sibling links
      final albumDir = Directory(p.join(sandboxDir.path, 'media_pack', '02_clips'))
        ..createSync(recursive: true);
      for (final name in ['01_intro.mp4', '02_main.mp4', '03_outro.mp4']) {
        File(p.join(albumDir.path, name)).writeAsBytesSync([1, 2, 3, 4]);
      }
      final folderExp = await openShare({
        'target': p.join(sandboxDir.path, 'media_pack'),
        'mode': 'folder',
      });
      final folderId = folderExp['id'] as String;
      final midPreview = await http.get(
        Uri.http(authority, '/share/$folderId/02_clips/02_main.mp4'),
        headers: {'accept': 'text/html'},
      );
      expect(midPreview.statusCode, equals(200));
      expect(midPreview.body, contains('返回所在文件夹 (02_clips)'));
      expect(midPreview.body, contains('上一文件'));
      expect(midPreview.body, contains('01_intro.mp4'));
      expect(midPreview.body, contains('下一文件'));
      expect(midPreview.body, contains('03_outro.mp4'));
      expect(midPreview.body, contains('stage-loader'));

      // 2b. v2.8 Architectural code-sheet preview (pinned line-number gutter + 2D horizontal scroll)
      final dartDemo = File(p.join(albumDir.path, '04_sample.dart'))
        ..writeAsStringSync("import 'package:flutter/material.dart';\nvoid main() => runApp(const SizedBox());\n");
      expect(dartDemo.existsSync(), isTrue);
      final codePreview = await http.get(
        Uri.http(authority, '/share/$folderId/02_clips/04_sample.dart'),
        headers: {'accept': 'text/html'},
      );
      expect(codePreview.statusCode, equals(200));
      expect(codePreview.body, contains('code-sheet'));
      expect(codePreview.body, contains('code-scroll'));
      expect(codePreview.body, contains('c-ln'));
      expect(codePreview.body, contains('左右滑动'));

      // 3. P1-2: Optional PIN code + max_downloads=1 burn-after-download
      final oneTimeFile = File(p.join(sandboxDir.path, 'burn_secret.txt'))
        ..writeAsStringSync('One-time confidential delivery');
      final pinExp = await openShare({
        'target': oneTimeFile.path,
        'mode': 'file',
        'pin_code': '2580',
        'max_downloads': 1,
      });
      final pinId = pinExp['id'] as String;
      expect(pinExp['has_pin'], isTrue);
      expect(pinExp['max_downloads'], equals(1));

      // Without PIN -> 401 unlock prompt
      final lockedHtml = await http.get(
        Uri.http(authority, '/share/$pinId'),
        headers: {'accept': 'text/html'},
      );
      expect(lockedHtml.statusCode, equals(401));
      expect(lockedHtml.body, contains('输入提取码'));

      final lockedRaw = await http.get(
        Uri.http(authority, '/share/$pinId/burn_secret.txt'),
      );
      expect(lockedRaw.statusCode, equals(401));

      // Unlock with X-Share-Pin -> 200 payload on 1st download, then auto-closed (404 on 2nd)
      final unlockedRaw = await http.get(
        Uri.http(authority, '/share/$pinId/burn_secret.txt'),
        headers: {'x-share-pin': '2580'},
      );
      expect(unlockedRaw.statusCode, equals(200));
      expect(unlockedRaw.body, equals('One-time confidential delivery'));

      await Future<void>.delayed(const Duration(milliseconds: 50));
      final secondTry = await http.get(
        Uri.http(authority, '/share/$pinId/burn_secret.txt'),
        headers: {'x-share-pin': '2580'},
      );
      expect(secondTry.statusCode, equals(404));
    } finally {
      await upstream.close(force: true);
      await ExposureManager.instance.closeAllExposures();
      await server.close(force: true);
    }
  });

  test('v2.2 P0-5: concurrent edit_file mutex, CRLF/whitespace-tolerant matching, and UndoStore byte budget', () async {
    final cfg = ServerConfig(
      serverName: 'concurrency-mcp',
      roots: [sandboxDir.path],
      readOnly: false,
    );
    final engine = McpServerEngine(cfg);

    final sharedFile = File(p.join(sandboxDir.path, 'concurrent.txt'))
      ..writeAsStringSync('lineA = 1\r\nlineB = 2   \r\nlineC = 3\r\n');

    Future<String> editCall(int id, String oldStr, String newStr) async {
      final resp = await engine.handleJsonRpcMessage({
        'jsonrpc': '2.0',
        'id': id,
        'method': 'tools/call',
        'params': {
          'name': 'edit_file',
          'arguments': {
            'path': sharedFile.path,
            'edits': [
              {'old_str': oldStr, 'new_str': newStr},
            ],
          },
        },
      });
      return (((resp!['result'] as Map)['content'] as List).first as Map)['text']
          as String;
    }

    // Fire 3 concurrent edits (including LF old_str against CRLF + trailing spaces!)
    final results = await Future.wait([
      editCall(1, 'lineA = 1', 'lineA = 100'),
      editCall(2, 'lineB = 2\nlineC = 3', 'lineB = 200\nlineC = 300'),
      editCall(3, 'lineA = 100', 'lineA = 999'),
    ]);
    for (final r in results) {
      expect(r, contains('Successfully applied'));
    }
    final finalRaw = sharedFile.readAsStringSync();
    expect(finalRaw, equals('lineA = 999\r\nlineB = 200\r\nlineC = 300\r\n'));

    // Verify UndoStore global byte cap evicts oldest snapshots cleanly
    final fA = File(p.join(sandboxDir.path, 'u_a.bin'))..writeAsBytesSync(List<int>.filled(20, 1));
    final fB = File(p.join(sandboxDir.path, 'u_b.bin'))..writeAsBytesSync(List<int>.filled(20, 2));
    final fC = File(p.join(sandboxDir.path, 'u_c.bin'))..writeAsBytesSync(List<int>.filled(20, 3));
    final smallUndo = UndoStore(maxPerFile: 10, maxTotalBytes: 40);
    smallUndo.save(fA, 'edit-1');
    smallUndo.save(fB, 'edit-2');
    expect(smallUndo.totalBytes, equals(40));
    smallUndo.save(fC, 'edit-3');
    expect(smallUndo.totalBytes, lessThanOrEqualTo(40));
    expect(smallUndo.pop(fA), isNull, reason: 'Oldest entry evicted to stay under byte budget');
    expect(smallUndo.pop(fC), isNotNull);
  });
}
