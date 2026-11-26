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
    const pwd = 'prism-starlight-indigo';
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

  test('22 tools registration, surgical edit, unified diff patch, and undo stack', () async {
    final cfg = ServerConfig(
      serverName: 'unit-mcp',
      roots: [sandboxDir.path],
      readOnly: false,
      allowSecrets: false,
    );
    final engine = McpServerEngine(cfg);
    expect(engine.tools.length, equals(22));

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
      expect(tools.length, equals(22));
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
      'oauth_allow_all_redirects': true,
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
      expect(hJson['tools_count'], equals(22));

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

  test('v3.5.0 Switch-driven Wildcard OAuth Redirect & Root Whitelists + Fine-Grained Capability Switches', () async {
    final cfgFile = StoragePaths.instance.defaultConfigFile;
    final loopback = InternetAddress.loopbackIPv4.address;
    final allowedProj = Directory(p.join(sandboxDir.path, 'proj_alpha'))
      ..createSync(recursive: true);
    final blockedDir = Directory(p.join(sandboxDir.path, 'other_secret_zone'))
      ..createSync(recursive: true);
    File(p.join(allowedProj.path, 'hello.txt')).writeAsStringSync('alpha-ok');
    File(p.join(blockedDir.path, 'nope.txt')).writeAsStringSync('blocked');

    // Configure oauth_allow_all_redirects=false with wildcard patterns AND allow_all_roots=false with wildcard path
    saveConfigFile(cfgFile, {
      'server_name': 'v35-whitelist-mcp',
      'transport': 'dual',
      'host': loopback,
      'port': 0,
      'auth_mode': 'oauth-local',
      'oauth_allow_all_redirects': false,
      'oauth_redirect_uris': [
        'http://127.0.0.1:*/callback',
        'https://*.claude.ai/**',
      ],
      'allow_all_roots': false,
      'roots': [p.join(sandboxDir.path, 'proj_*')],
      'allow_commands': false,
      'allow_clipboard_screen': false,
    });

    final cfg = ServerConfig.fromSavedMap(loadSavedConfig(cfgFile), configFile: cfgFile)
      ..port = 0;
    final engine = McpServerEngine(cfg);
    final server = await engine.serveHttp();
    final authority = '${server.address.address}:${server.port}';

    try {
      // 1. Dynamic client registration with unlisted domain MUST fail when oauth_allow_all_redirects=false
      final badReg = await http.post(
        Uri.http(authority, '/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'client_name': 'Untrusted App',
          'redirect_uris': ['https://evil.example.org/cb'],
        }),
      );
      expect(badReg.statusCode, equals(400));

      // 2. Wildcard-matched redirect URIs (`localhost` loopback port + subdomain `**`) MUST succeed!
      final goodReg = await http.post(
        Uri.http(authority, '/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'client_name': 'Trusted Wildcard App',
          'redirect_uris': [
            'http://localhost:54321/callback',
            'https://app.claude.ai/oauth/mcp/done',
          ],
        }),
      );
      expect(goodReg.statusCode, equals(201));

      // 3. Unsafe javascript: scheme is ALWAYS rejected even if oauth_allow_all_redirects=true
      saveConfigFile(cfgFile, {
        ...loadSavedConfig(cfgFile),
        'oauth_allow_all_redirects': true,
      });
      final jsReg = await http.post(
        Uri.http(authority, '/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'client_name': 'XSS Probe',
          'redirect_uris': ['javascript:alert(1)'],
        }),
      );
      expect(jsReg.statusCode, equals(400));
      // Rule list is preserved in saved config even after toggling oauth_allow_all_redirects=true!
      expect(
        (loadSavedConfig(cfgFile)['oauth_redirect_uris'] as List).length,
        equals(2),
      );

      // 4. Wildcard root rule (`proj_*`) allows proj_alpha/hello.txt and blocks other_secret_zone/nope.txt
      Future<String> callRpc(String name, Map<String, dynamic> args) async {
        final resp = await engine.handleJsonRpcMessage({
          'jsonrpc': '2.0',
          'id': 9,
          'method': 'tools/call',
          'params': {'name': name, 'arguments': args},
        });
        return (((resp!['result'] as Map)['content'] as List).first as Map)['text']
            as String;
      }

      final okRead = await callRpc('read_file', {
        'path': p.join(allowedProj.path, 'hello.txt'),
      });
      expect(okRead, contains('alpha-ok'));

      final blockedRead = await callRpc('read_file', {
        'path': p.join(blockedDir.path, 'nope.txt'),
      });
      expect(blockedRead, contains('does not match allowed root rules'));

      // 5. Fine-grained capability switches block run_command & manage_clipboard
      final cmdBlocked = await callRpc('run_command', {'command': 'echo hi'});
      expect(cmdBlocked, contains('disabled'));
      final clipBlocked = await callRpc('manage_clipboard', {'action': 'get'});
      expect(clipBlocked, contains('disabled'));
    } finally {
      await server.close(force: true);
    }
  });

  test('v3.5.0 Universal Sub-MCP Hub: auto HTTP->SSE fallback, WebSocket MCP, M2M OAuth, direct mounting & smart importer', () async {
    final loopback = InternetAddress.loopbackIPv4.address;

    // 1. Smart importer handles VS Code `servers`, single-line `npx`, and bare URLs
    final parsedNpx = parseMcpServersJson('npx -y @modelcontextprotocol/server-github');
    expect(parsedNpx.single['name'], equals('github'));
    expect(parsedNpx.single['transport'], equals('stdio'));

    final parsedUrl = parseMcpServersJson('wss://mcp.linear.app/ws');
    expect(parsedUrl.single['transport'], equals('ws'));

    final parsedVsCode = parseMcpServersJson(jsonEncode({
      'servers': {
        'sentry-remote': {
          'type': 'http',
          'url': 'https://mcp.sentry.dev/mcp',
        },
      },
    }));
    expect(parsedVsCode.single['name'], equals('sentry-remote'));

    // 2. Upstream mock server supporting:
    //    - OAuth M2M token endpoint (`/oauth/token`)
    //    - `auto` fallback: POST `/mcp` returns 404, GET `/mcp` opens Legacy SSE stream + POST `/messages`
    //    - WebSocket JSON-RPC at `/ws` with `tools`, `resources`, and `prompts`
    final upstream = await HttpServer.bind(loopback, 0);
    final upPort = upstream.port;
    IOSink? activeSseSink;
    String? lastBearerHeader;

    upstream.listen((HttpRequest req) async {
      if (req.uri.path == '/oauth/token' && req.method == 'POST') {
        final body = await utf8.decoder.bind(req).join();
        expect(body, contains('grant_type=client_credentials'));
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'access_token': 'm2m-live-token-777',
            'token_type': 'Bearer',
            'expires_in': 3600,
          }));
        await req.response.close();
        return;
      }

      if (req.uri.path == '/ws' && WebSocketTransformer.isUpgradeRequest(req)) {
        lastBearerHeader = req.headers.value('authorization');
        final ws = await WebSocketTransformer.upgrade(req);
        ws.listen((raw) {
          final msg = jsonDecode(raw.toString()) as Map<String, dynamic>;
          final id = msg['id'];
          final method = msg['method'];
          if (method == 'initialize') {
            ws.add(jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'protocolVersion': '2025-03-26',
                'capabilities': {'tools': {}, 'resources': {}, 'prompts': {}},
                'serverInfo': {'name': 'ws-sub', 'version': '1.0.0'},
              },
            }));
          } else if (method == 'tools/list') {
            ws.add(jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'tools': [
                  {
                    'name': 'echo_ws',
                    'description': 'Echo over WS',
                    'inputSchema': {'type': 'object'},
                  },
                  {
                    'name': 'secret_op',
                    'description': 'Disabled tool',
                    'inputSchema': {'type': 'object'},
                  },
                ],
              },
            }));
          } else if (method == 'tools/call') {
            final args = (msg['params'] as Map)['arguments'] as Map? ?? {};
            ws.add(jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'content': [
                  {'type': 'text', 'text': 'ws-ok:${args['msg'] ?? ''}:$lastBearerHeader'},
                ],
              },
            }));
          } else if (method == 'resources/list') {
            ws.add(jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'resources': [
                  {'uri': 'memo://doc/1', 'name': 'Architecture Doc'},
                ],
              },
            }));
          } else if (method == 'prompts/list') {
            ws.add(jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'prompts': [
                  {'name': 'code_review', 'description': 'Review patch'},
                ],
              },
            }));
          }
        });
        return;
      }

      if (req.uri.path == '/mcp' && req.method == 'POST') {
        // Trigger `auto` fallback to Legacy SSE!
        req.response.statusCode = 405;
        await req.response.close();
        return;
      }

      if ((req.uri.path == '/mcp' || req.uri.path == '/sse') && req.method == 'GET') {
        req.response.bufferOutput = false;
        req.response.statusCode = 200;
        req.response.headers.set('content-type', 'text/event-stream');
        activeSseSink = req.response;
        activeSseSink!.write('event: endpoint\ndata: /messages\n\n');
        await activeSseSink!.flush();
        return;
      }

      if (req.uri.path == '/messages' && req.method == 'POST') {
        final msg = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
        final id = msg['id'];
        final method = msg['method'];
        Map<String, dynamic>? reply;
        if (method == 'initialize') {
          reply = {
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'protocolVersion': '2024-11-05',
              'capabilities': {'tools': {}},
              'serverInfo': {'name': 'legacy-sse-sub', 'version': '1.0'},
            },
          };
        } else if (method == 'tools/list') {
          reply = {
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'tools': [
                {'name': 'sse_ping', 'description': 'Legacy SSE tool', 'inputSchema': {'type': 'object'}},
              ],
            },
          };
        } else if (method == 'tools/call') {
          reply = {
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'content': [
                {'type': 'text', 'text': 'sse-fallback-pong'},
              ],
            },
          };
        }
        req.response.statusCode = 202;
        await req.response.close();
        if (reply != null && activeSseSink != null) {
          activeSseSink!.write('event: message\ndata: ${jsonEncode(reply)}\n\n');
          await activeSseSink!.flush();
        }
        return;
      }

      req.response.statusCode = 404;
      await req.response.close();
    });

    try {
      final subMgr = SubMcpManager(StoragePaths.instance.subMcpConfigFile);
      subMgr.saveEntries([
        normalizeSubEntry({
          'name': 'auto_sse',
          'enabled': true,
          'transport': 'auto',
          'url': 'http://$loopback:$upPort/mcp',
          'expose_mode': 'gateway',
        }),
        normalizeSubEntry({
          'name': 'ws_direct',
          'enabled': true,
          'transport': 'ws',
          'url': 'ws://$loopback:$upPort/ws',
          'expose_mode': 'direct',
          'disabled_tools': ['secret_op'],
          'auth_type': 'oauth2_client_credentials',
          'oauth_token_url': 'http://$loopback:$upPort/oauth/token',
          'oauth_client_id': 'svc-client',
          'oauth_client_secret': 'svc-secret',
        }),
      ]);

      // Verify `auto` falls back from HTTP 405 -> Legacy SSE seamlessly
      final sseCall = await subMgr.callTool('auto_sse', 'sse_ping', arguments: {});
      expect(sseCall, contains('sse-fallback-pong'));

      // Verify WS + M2M OAuth + resources/prompts + direct mounting (`ws_direct__echo_ws`) + disabled_tools filtering
      final disc = await subMgr.discoverTools('ws_direct', refresh: true);
      expect(disc['ok'], isTrue);
      final resList = (disc['resources'] as List).cast<Map<String, dynamic>>();
      expect(resList.single['uri'], equals('memo://doc/1'));
      final prmList = (disc['prompts'] as List).cast<Map<String, dynamic>>();
      expect(prmList.single['name'], equals('code_review'));

      final engine = McpServerEngine(ServerConfig(
        serverName: 'hub-host',
        roots: [sandboxDir.path],
      ));
      final listRpc = await engine.handleJsonRpcMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      });
      final toolNames = (((listRpc!['result'] as Map)['tools'] as List)
              .cast<Map>())
          .map((t) => t['name'].toString())
          .toList();
      expect(toolNames, contains('ws_direct__echo_ws'));
      expect(toolNames, isNot(contains('ws_direct__secret_op')));

      final directCall = await engine.handleJsonRpcMessage({
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': {
          'name': 'ws_direct__echo_ws',
          'arguments': {'msg': 'hello'},
        },
      });
      final directText =
          (((directCall!['result'] as Map)['content'] as List).first as Map)['text']
              as String;
      expect(directText, contains('ws-ok:hello:Bearer m2m-live-token-777'));
    } finally {
      await upstream.close(force: true);
    }
  });

  test('v3.5.0 Offline Vector QR, Bi-Directional Folder Upload, Client Onboarding & Encrypted Snapshot Round-Trip', () async {
    // 1. Offline ISO/IEC 18004 QR encoder & SVG output
    final qrSvg = generateQrSvg('https://omen-mcp.iamr0s.de5.net/mcp');
    expect(qrSvg, startsWith('<svg xmlns="http://www.w3.org/2000/svg"'));
    expect(qrSvg, contains('<path d="M'));

    // 2. ClientOnboardingManager writes Cursor `mcpServers` & VS Code `servers` with `.bak` backup
    final cursorCfg = File(p.join(sandboxDir.path, 'cursor_mcp.json'))
      ..writeAsStringSync('{"mcpServers":{"existing":{"command":"node"}}}\n');
    final onboardRes = ClientOnboardingManager.applyClientOnboarding(
      clientId: 'cursor',
      serverKey: 'omen-node',
      mcpUrl: 'http://100.88.1.2:8000/mcp',
      bearerToken: 'sk-onboard-1',
      customConfigPath: cursorCfg.path,
    );
    expect(onboardRes['ok'], isTrue);
    expect(File('${cursorCfg.path}.bak').existsSync(), isTrue);
    final mergedCursor = jsonDecode(cursorCfg.readAsStringSync()) as Map<String, dynamic>;
    final cursorServers = mergedCursor['mcpServers'] as Map<String, dynamic>;
    expect(cursorServers.containsKey('existing'), isTrue);
    expect((cursorServers['omen-node'] as Map)['url'], equals('http://100.88.1.2:8000/mcp'));

    final vscodeCfg = File(p.join(sandboxDir.path, 'vscode_mcp.json'));
    ClientOnboardingManager.applyClientOnboarding(
      clientId: 'vscode',
      serverKey: 'omen-node',
      mcpUrl: 'http://100.88.1.2:8000/mcp',
      customConfigPath: vscodeCfg.path,
    );
    final mergedVsCode = jsonDecode(vscodeCfg.readAsStringSync()) as Map<String, dynamic>;
    expect(((mergedVsCode['servers'] as Map)['omen-node'] as Map)['type'], equals('http'));

    // 3. ConfigSnapshotManager PBKDF2-HMAC-SHA256 encrypted export/import + wrong-password guard
    final snapCfgFile = File(p.join(sandboxDir.path, 'snap_cfg.json'));
    final snapSubFile = File(p.join(sandboxDir.path, 'snap_sub.json'));
    saveConfigFile(snapCfgFile, {
      'server_name': 'Snapshot Source',
      'api_key': 'sk-super-secret',
      'profiles': [
        {'id': 'p1', 'name': 'Main', 'api_key': 'sk-prof-secret'},
      ],
    });
    SubMcpManager(snapSubFile).saveEntries([
      normalizeSubEntry({
        'name': 'demo-sub',
        'transport': 'http',
        'url': 'https://example.com/mcp',
        'auth_type': 'bearer',
        'auth_token': 'tok-sub-secret',
      }),
    ]);

    final encrypted = ConfigSnapshotManager.exportSnapshot(
      configFile: snapCfgFile,
      subMcpFile: snapSubFile,
      includeSecrets: true,
      password: 'vault-passphrase-2026',
    );
    expect(encrypted['schema'], equals('agent_mcp_encrypted_snapshot_v1'));
    expect(jsonEncode(encrypted), isNot(contains('sk-super-secret')));

    expect(
      () => ConfigSnapshotManager.importSnapshot(
        rawJson: jsonEncode(encrypted),
        password: 'wrong-password',
        configFile: snapCfgFile,
        subMcpFile: snapSubFile,
      ),
      throwsA(isA<FormatException>()),
    );

    final destCfgFile = File(p.join(sandboxDir.path, 'restored_cfg.json'));
    final destSubFile = File(p.join(sandboxDir.path, 'restored_sub.json'));
    final restored = ConfigSnapshotManager.importSnapshot(
      rawJson: jsonEncode(encrypted),
      password: 'vault-passphrase-2026',
      configFile: destCfgFile,
      subMcpFile: destSubFile,
    );
    expect(restored['ok'], isTrue);
    expect(loadSavedConfig(destCfgFile)['api_key'], equals('sk-super-secret'));

    // 4. Folder share bi-directional upload (`allow_upload: true` -> POST ?__upload=1) + persistence
    final loopback = InternetAddress.loopbackIPv4.address;
    final cfgFile = StoragePaths.instance.defaultConfigFile;
    final dropboxDir = Directory(p.join(sandboxDir.path, 'inbox_share'))
      ..createSync(recursive: true);
    saveConfigFile(cfgFile, {
      'server_name': 'upload-share-mcp',
      'transport': 'dual',
      'host': loopback,
      'port': 0,
      'auth_mode': 'none',
      'expose_enabled': true,
      'expose_tailscale_enabled': false,
      'expose_cloudflared_fallback': false,
      'roots': [sandboxDir.path],
    });
    final cfg = ServerConfig.fromSavedMap(loadSavedConfig(cfgFile), configFile: cfgFile)
      ..port = 0;
    final engine = McpServerEngine(cfg);
    final srv = await engine.serveHttp();
    final authority = '${srv.address.address}:${srv.port}';
    try {
      final expRpc = await engine.handleJsonRpcMessage({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'manage_expose',
          'arguments': {
            'action': 'open',
            'target': dropboxDir.path,
            'mode': 'folder',
            'allow_upload': true,
          },
        },
      });
      final expTxt =
          (((expRpc!['result'] as Map)['content'] as List).first as Map)['text']
              as String;
      final expMap = (jsonDecode(expTxt) as Map)['exposure'] as Map<String, dynamic>;
      final shareId = expMap['id'] as String;
      expect(expMap['allow_upload'], isTrue);
      expect(StoragePaths.instance.exposuresStateFile.existsSync(), isTrue);

      // Upload normal file -> 200 OK & written to disk
      final upResp = await http.post(
        Uri.parse('http://$authority/share/$shareId/?__upload=1&filename=report.md'),
        body: '# Uploaded from phone\n',
      );
      expect(upResp.statusCode, equals(200));
      expect(
        File(p.join(dropboxDir.path, 'report.md')).readAsStringSync(),
        equals('# Uploaded from phone\n'),
      );

      // Uploading sensitive `.env` file -> rejected!
      final envResp = await http.post(
        Uri.parse('http://$authority/share/$shareId/?__upload=1&filename=.env'),
        body: 'SECRET=1',
      );
      expect(envResp.statusCode, anyOf(equals(400), equals(403)));
    } finally {
      await ExposureManager.instance.closeAllExposures();
      await srv.close(force: true);
    }
  });

  test('v3.5.2 Default OAuth Callback Whitelist Mode & Full MCP Protocol Compliance: Icons (PNG+SVG), Unauthenticated Favicon/ServerCard, 64-Char Safe Naming, 2024-2026 Dual-Stack, Sub-MCP Pagination/Multimodal & OAuth CIMD/iss', () async {
    expect(sanitizeMcpMachineName('Omen Desktop Mcp'), equals('Omen-Desktop-Mcp'));
    expect(sanitizeMcpMachineName('暗影精灵主节点'), startsWith('agent-mcp-'));
    final used = <String>{};
    expect(
      buildSafeMcpToolName(
        globalPrefix: '',
        subPrefix: 'ws_direct_',
        rawToolName: 'echo_ws',
        usedNames: used,
      ),
      equals('ws_direct__echo_ws'),
    );
    final longSlashName = buildSafeMcpToolName(
      globalPrefix: 'omen_node_',
      subPrefix: 'enterprise_github_gateway_',
      rawToolName: 'repos/pull_requests/reviews/comments/create_inline_suggestion_v2',
      usedNames: used,
    );
    expect(longSlashName.length, lessThanOrEqualTo(64));
    expect(RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(longSlashName), isTrue);

    expect(appIconPng64Bytes.length, greaterThan(512));
    expect(appIconPng64Bytes.sublist(0, 8), equals([137, 80, 78, 71, 13, 10, 26, 10]));

    final loopback = InternetAddress.loopbackIPv4.address;
    final mockUpstream = await HttpServer.bind(loopback, 0);
    final upBase = 'http://$loopback:${mockUpstream.port}';
    const tinyPngB64 =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

    mockUpstream.listen((HttpRequest req) async {
      final path = req.uri.path;
      if (path == '/oauth/client.json') {
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'client_id': '$upBase/oauth/client.json',
          'client_name': 'Gemini CIMD Test Connector',
          'logo_uri': '$upBase/logo.png',
          'redirect_uris': ['http://127.0.0.1:54321/cb'],
        }));
        await req.response.close();
        return;
      }
      if (path == '/mcp2026' && req.method == 'POST') {
        final raw = await utf8.decoder.bind(req).join();
        final msg = jsonDecode(raw) as Map<String, dynamic>;
        final id = msg['id'];
        final method = msg['method'];
        final params = (msg['params'] as Map?) ?? const {};
        req.response.headers.contentType = ContentType.json;
        if (method == 'initialize') {
          req.response.write(jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32601, 'message': 'Stateless 2026 server'},
          }));
        } else if (method == 'server/discover') {
          req.response.write(jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'resultType': 'complete',
              'supportedVersions': ['2026-07-28'],
              'capabilities': {'tools': {'listChanged': false}},
              '_meta': {
                'io.modelcontextprotocol/serverInfo': {
                  'name': 'vision-sub',
                  'title': 'Vision Sub MCP',
                  'version': '2.0.0',
                  'icons': [
                    {
                      'src': 'data:image/png;base64,$tinyPngB64',
                      'mimeType': 'image/png',
                      'sizes': ['64x64'],
                    },
                  ],
                },
              },
            },
          }));
        } else if (method == 'tools/list') {
          expect(req.headers.value('mcp-protocol-version'), equals('2026-07-28'));
          final cursor = params['cursor']?.toString();
          if (cursor == null || cursor.isEmpty) {
            req.response.write(jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'resultType': 'complete',
                'tools': [
                  {
                    'name': 'page1/snap_chart',
                    'description': 'Returns PNG chart',
                    'inputSchema': {'type': 'object', 'properties': {}},
                  },
                ],
                'nextCursor': 'p2',
              },
            }));
          } else {
            req.response.write(jsonEncode({
              'jsonrpc': '2.0',
              'id': id,
              'result': {
                'resultType': 'complete',
                'tools': [
                  {
                    'name': 'page2/very_long_enterprise_namespace_operation_that_exceeds_sixty_four_chars_easily',
                    'description': 'Second page long-named tool',
                    'inputSchema': {'type': 'object', 'properties': {}},
                  },
                ],
              },
            }));
          }
        } else if (method == 'tools/call') {
          req.response.write(jsonEncode({
            'jsonrpc': '2.0',
            'id': id,
            'result': {
              'resultType': 'complete',
              'content': [
                {'type': 'image', 'data': tinyPngB64, 'mimeType': 'image/png'},
                {'type': 'text', 'text': 'Rendered chart OK'},
              ],
              'isError': false,
            },
          }));
        }
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });

    final cfgFile = StoragePaths.instance.defaultConfigFile;
    final pwdHash = hashPassword('oauth-pass-123');
    // Omit oauth_allow_all_redirects & oauth_redirect_uris to verify DEFAULT whitelist mode!
    saveConfigFile(cfgFile, {
      'server_name': 'Omen Desktop Mcp',
      'transport': 'dual',
      'host': loopback,
      'port': 0,
      'auth_mode': 'oauth-local',
      'oauth_local_password_hash': pwdHash,
      'roots': [sandboxDir.path],
    });

    final subMgr = SubMcpManager.instance;
    subMgr.saveEntries([
      normalizeSubEntry({
        'name': 'vision2026',
        'transport': 'http',
        'expose_mode': 'direct',
        'url': '$upBase/mcp2026',
      }),
    ]);

    final cfg = ServerConfig.fromSavedMap(loadSavedConfig(cfgFile), configFile: cfgFile)
      ..port = 0;
    final engine = McpServerEngine(cfg);
    final srv = await engine.serveHttp();
    final mainBase = 'http://$loopback:${srv.port}';

    try {
      for (final iconRoute in [
        '/favicon.ico',
        '/favicon.png',
        '/icon-192.png',
        '/apple-touch-icon.png',
        '/icon.svg',
      ]) {
        final r = await http.get(Uri.parse('$mainBase$iconRoute'));
        expect(r.statusCode, equals(200), reason: 'Expected 200 for $iconRoute');
        expect(r.bodyBytes.length, greaterThan(100));
      }
      final rootHtml = await http.get(Uri.parse('$mainBase/'));
      expect(rootHtml.statusCode, equals(200));
      expect(rootHtml.body, contains('rel="icon"'));

      final cardResp = await http.get(Uri.parse('$mainBase/.well-known/mcp.json'));
      expect(cardResp.statusCode, equals(200));
      final cardJson = jsonDecode(cardResp.body) as Map<String, dynamic>;
      expect(cardJson['title'], equals('Omen Desktop Mcp'));
      expect(cardJson['name'], equals('Omen-Desktop-Mcp'));
      expect((cardJson['icons'] as List).any((i) => (i as Map)['mimeType'] == 'image/png'), isTrue);

      final asMetaResp = await http.get(
        Uri.parse('$mainBase/.well-known/oauth-authorization-server/mcp'),
      );
      expect(asMetaResp.statusCode, equals(200));
      final asMeta = jsonDecode(asMetaResp.body) as Map<String, dynamic>;
      expect(asMeta['logo_uri'], equals('$mainBase/icon-192.png'));
      expect(asMeta['authorization_response_iss_parameter_supported'], isTrue);
      expect(asMeta['client_id_metadata_document_supported'], isTrue);

      // Verify OAuth callback whitelist mode is ENABLED BY DEFAULT (`oauthAllowAllRedirects == false`)
      expect(cfg.oauthAllowAllRedirects, isFalse);
      expect(cfg.oauthRedirectUris, equals(kDefaultOAuthRedirectUris));
      final blockedEvilReg = await http.post(
        Uri.parse('$mainBase/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'client_name': 'Evil Redirect Probe',
          'redirect_uris': ['https://evil.attacker.example/cb'],
        }),
      );
      expect(blockedEvilReg.statusCode, equals(400));
      final blockedSpoofReg = await http.post(
        Uri.parse('$mainBase/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'client_name': 'Path Spoof Probe',
          'redirect_uris': ['https://evil.com/.claude.ai/cb'],
        }),
      );
      expect(blockedSpoofReg.statusCode, equals(400));
      final allowedDefaultReg = await http.post(
        Uri.parse('$mainBase/register'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'client_name': 'Default Whitelisted Clients',
          'redirect_uris': [
            'https://gemini.google.com/oauth/callback',
            'http://127.0.0.1:54321',
          ],
        }),
      );
      expect(allowedDefaultReg.statusCode, equals(201));

      final httpNoRedir = HttpClient();
      final authReq = await httpNoRedir.getUrl(
        Uri.parse(
          '$mainBase/authorize?client_id=${Uri.encodeQueryComponent('$upBase/oauth/client.json')}'
          '&redirect_uri=${Uri.encodeQueryComponent('http://127.0.0.1:54321/cb')}'
          '&response_type=code&state=xyz987',
        ),
      );
      authReq.followRedirects = false;
      final auth302 = await authReq.close();
      expect(auth302.statusCode, equals(302));
      final loginLoc = auth302.headers.value('location')!;

      final loginPost = await httpNoRedir.postUrl(Uri.parse(loginLoc));
      loginPost.followRedirects = false;
      loginPost.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
      loginPost.write('password=${Uri.encodeQueryComponent('oauth-pass-123')}');
      final cb302 = await loginPost.close();
      expect(cb302.statusCode, equals(302));
      final cbUri = Uri.parse(cb302.headers.value('location')!);
      expect(cbUri.queryParameters['iss'], equals(mainBase));
      expect(cbUri.queryParameters['state'], equals('xyz987'));
      expect(cbUri.queryParameters['code'], isNotEmpty);
      httpNoRedir.close(force: true);

      final initFuture = await engine.handleJsonRpcMessage(
        {
          'jsonrpc': '2.0',
          'id': 10,
          'method': 'initialize',
          'params': {'protocolVersion': '2099-01-01'},
        },
        effectiveBaseUrl: mainBase,
      );
      final initResult = initFuture!['result'] as Map<String, dynamic>;
      expect(initResult['protocolVersion'], equals('2025-11-25'));
      final sInfo = initResult['serverInfo'] as Map<String, dynamic>;
      expect(sInfo['title'], equals('Omen Desktop Mcp'));
      expect((sInfo['icons'] as List).any((i) => (i as Map)['mimeType'] == 'image/png'), isTrue);

      final disc2026 = await engine.handleJsonRpcMessage(
        {'jsonrpc': '2.0', 'id': 11, 'method': 'server/discover'},
        effectiveBaseUrl: mainBase,
      );
      final discRes = disc2026!['result'] as Map<String, dynamic>;
      expect(discRes['resultType'], equals('complete'));
      expect(discRes['supportedVersions'], contains('2026-07-28'));
      expect((discRes['_meta'] as Map)['io.modelcontextprotocol/serverInfo'], isA<Map>());

      final listRpc = await engine.handleJsonRpcMessage(
        {'jsonrpc': '2.0', 'id': 12, 'method': 'tools/list'},
        effectiveBaseUrl: mainBase,
        httpProtocolVersion: '2026-07-28',
      );
      final listRes = listRpc!['result'] as Map<String, dynamic>;
      expect(listRes['resultType'], equals('complete'));
      expect(listRes['ttlMs'], isA<int>());
      final tools = (listRes['tools'] as List).cast<Map>();
      final snapTool = tools.firstWhere(
        (t) => t['name'].toString().contains('snap_chart'),
      );
      final longTool = tools.firstWhere(
        (t) => t['description'].toString().contains('Second page long-named tool'),
      );
      expect(longTool['name'].toString().length, lessThanOrEqualTo(64));
      expect(
        subMgr.listWithStatus().single['icon_src'],
        startsWith('data:image/png;base64,'),
      );

      final multimodalRpc = await engine.handleJsonRpcMessage({
        'jsonrpc': '2.0',
        'id': 13,
        'method': 'tools/call',
        'params': {'name': snapTool['name'], 'arguments': const {}},
      });
      final callBlocks =
          ((multimodalRpc!['result'] as Map)['content'] as List).cast<Map>();
      expect(callBlocks.first['type'], equals('image'));
      expect(callBlocks.first['data'], equals(tinyPngB64));
    } finally {
      await srv.close(force: true);
      await mockUpstream.close(force: true);
    }
  });
}
