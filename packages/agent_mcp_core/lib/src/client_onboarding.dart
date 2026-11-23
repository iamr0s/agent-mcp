import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'auth.dart';
import 'config.dart';
import 'sub_mcp.dart';
import 'version.dart';

/// Supported AI Client definitions for 1-click `mcpServers` / `servers` onboarding.
class AiClientTarget {
  final String id;
  final String label;
  final String rootKey; // 'mcpServers' | 'servers'
  final String configPath;
  final bool installed;

  const AiClientTarget({
    required this.id,
    required this.label,
    required this.rootKey,
    required this.configPath,
    required this.installed,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'root_key': rootKey,
        'config_path': configPath,
        'installed': installed,
      };
}

class ClientOnboardingManager {
  static String _userHome() =>
      Platform.environment['USERPROFILE'] ??
      Platform.environment['HOME'] ??
      Directory.current.path;

  static List<AiClientTarget> detectTargets() {
    final home = _userHome();
    final appData = Platform.environment['APPDATA'] ??
        p.join(home, 'AppData', 'Roaming');

    String claudeDesktopPath;
    String vscodePath;
    if (Platform.isWindows) {
      claudeDesktopPath = p.join(appData, 'Claude', 'claude_desktop_config.json');
      vscodePath = p.join(appData, 'Code', 'User', 'mcp.json');
    } else if (Platform.isMacOS) {
      claudeDesktopPath = p.join(
        home,
        'Library',
        'Application Support',
        'Claude',
        'claude_desktop_config.json',
      );
      vscodePath = p.join(
        home,
        'Library',
        'Application Support',
        'Code',
        'User',
        'mcp.json',
      );
    } else {
      final xdg = Platform.environment['XDG_CONFIG_HOME'] ?? p.join(home, '.config');
      claudeDesktopPath = p.join(xdg, 'Claude', 'claude_desktop_config.json');
      vscodePath = p.join(xdg, 'Code', 'User', 'mcp.json');
    }

    final cursorPath = p.join(home, '.cursor', 'mcp.json');
    final windsurfPath = p.join(home, '.codeium', 'windsurf', 'mcp_config.json');
    final claudeCodePath = p.join(home, '.claude.json');

    bool parentOrFileExists(String filePath) {
      final f = File(filePath);
      return f.existsSync() || f.parent.existsSync();
    }

    return [
      AiClientTarget(
        id: 'claude_desktop',
        label: 'Claude Desktop',
        rootKey: 'mcpServers',
        configPath: claudeDesktopPath,
        installed: parentOrFileExists(claudeDesktopPath),
      ),
      AiClientTarget(
        id: 'cursor',
        label: 'Cursor',
        rootKey: 'mcpServers',
        configPath: cursorPath,
        installed: parentOrFileExists(cursorPath),
      ),
      AiClientTarget(
        id: 'vscode',
        label: 'VS Code (Copilot MCP)',
        rootKey: 'servers',
        configPath: vscodePath,
        installed: parentOrFileExists(vscodePath),
      ),
      AiClientTarget(
        id: 'windsurf',
        label: 'Windsurf',
        rootKey: 'mcpServers',
        configPath: windsurfPath,
        installed: parentOrFileExists(windsurfPath),
      ),
      AiClientTarget(
        id: 'claude_code',
        label: 'Claude Code CLI (~/.claude.json)',
        rootKey: 'mcpServers',
        configPath: claudeCodePath,
        installed: File(claudeCodePath).existsSync(),
      ),
    ];
  }

  /// Safely merges an HTTP/SSE MCP server entry into the chosen client's JSON file
  /// while preserving all existing user settings and writing a `.bak` backup.
  static Map<String, dynamic> applyClientOnboarding({
    required String clientId,
    required String serverKey,
    required String mcpUrl,
    String transport = 'http',
    String? bearerToken,
    String? customConfigPath,
  }) {
    final cleanKey = sanitizeSubName(serverKey.isEmpty ? 'agent-mcp' : serverKey);
    final cleanUrl = mcpUrl.trim();
    if (cleanUrl.isEmpty) {
      throw const FormatException('MCP 接入地址 (mcpUrl) 不能为空。');
    }

    final target = detectTargets().where((t) => t.id == clientId).firstOrNull;
    final targetPath = (customConfigPath != null && customConfigPath.trim().isNotEmpty)
        ? customConfigPath.trim()
        : (target?.configPath ?? '');
    if (targetPath.isEmpty) {
      throw FormatException('未知的客户端标识: $clientId');
    }
    final rootKey = target?.rootKey ?? 'mcpServers';
    final file = File(targetPath);

    Map<String, dynamic> doc = <String, dynamic>{};
    String? backupPath;
    if (file.existsSync()) {
      final rawText = file.readAsStringSync();
      if (rawText.trim().isNotEmpty) {
        final decoded = jsonDecode(rawText);
        if (decoded is! Map) {
          throw FormatException('目标配置文件顶层不是 JSON 对象: $targetPath');
        }
        doc = Map<String, dynamic>.from(decoded);
        backupPath = '$targetPath.bak';
        File(backupPath).writeAsStringSync(rawText, flush: true);
      }
    }

    final existingServers = doc[rootKey] is Map
        ? Map<String, dynamic>.from(doc[rootKey] as Map)
        : <String, dynamic>{};

    final isSse = transport == 'sse' || cleanUrl.endsWith('/sse');
    final entry = <String, dynamic>{
      if (rootKey == 'servers') 'type': isSse ? 'sse' : 'http',
      'url': cleanUrl,
      if (bearerToken != null && bearerToken.trim().isNotEmpty)
        'headers': {'Authorization': 'Bearer ${bearerToken.trim()}'},
    };

    existingServers[cleanKey] = entry;
    doc[rootKey] = existingServers;

    file.parent.createSync(recursive: true);
    const enc = JsonEncoder.withIndent('  ');
    file.writeAsStringSync('${enc.convert(doc)}\n', flush: true);

    final cliCmd = bearerToken != null && bearerToken.trim().isNotEmpty
        ? 'claude mcp add --transport ${isSse ? "sse" : "http"} $cleanKey "$cleanUrl" --header "Authorization: Bearer ${bearerToken.trim()}"'
        : 'claude mcp add --transport ${isSse ? "sse" : "http"} $cleanKey "$cleanUrl"';

    return {
      'ok': true,
      'client_id': clientId,
      'server_key': cleanKey,
      'config_path': file.path,
      if (backupPath != null) 'backup_path': backupPath,
      'entry': entry,
      'cli_command': cliCmd,
    };
  }
}

/// Exports and restores full or sanitized configuration snapshots (`.amcp.json`),
/// with optional password-based authenticated encryption (PBKDF2-HMAC-SHA256 + XOR-CTR + HMAC).
class ConfigSnapshotManager {
  static Uint8List _deriveKey(String password, List<int> salt, int length) {
    final pwdBytes = utf8.encode(password);
    final hmacSha = Hmac(sha256, pwdBytes);
    final blocks = (length + 31) ~/ 32;
    final out = BytesBuilder();
    for (var blockNum = 1; blockNum <= blocks; blockNum++) {
      final initMsg = <int>[
        ...salt,
        (blockNum >> 24) & 0xFF,
        (blockNum >> 16) & 0xFF,
        (blockNum >> 8) & 0xFF,
        blockNum & 0xFF,
      ];
      var u = hmacSha.convert(initMsg).bytes;
      final acc = List<int>.from(u);
      for (var iter = 1; iter < 60000; iter++) {
        u = hmacSha.convert(u).bytes;
        for (var j = 0; j < 32; j++) {
          acc[j] ^= u[j];
        }
      }
      out.add(acc);
    }
    return Uint8List.fromList(out.takeBytes().sublist(0, length));
  }

  static Uint8List _streamXor(Uint8List data, Uint8List encKey, Uint8List iv) {
    final out = Uint8List(data.length);
    var counter = 0;
    var offset = 0;
    while (offset < data.length) {
      final ctrBlock = <int>[
        ...iv,
        (counter >> 24) & 0xFF,
        (counter >> 16) & 0xFF,
        (counter >> 8) & 0xFF,
        counter & 0xFF,
      ];
      final keystream = Hmac(sha256, encKey).convert(ctrBlock).bytes;
      final n = min(32, data.length - offset);
      for (var i = 0; i < n; i++) {
        out[offset + i] = data[offset + i] ^ keystream[i];
      }
      offset += n;
      counter++;
    }
    return out;
  }

  static Map<String, dynamic> exportSnapshot({
    File? configFile,
    File? subMcpFile,
    bool includeSecrets = false,
    String? password,
  }) {
    final cfgFile = configFile ?? StoragePaths.instance.defaultConfigFile;
    final subFile = subMcpFile ?? StoragePaths.instance.subMcpConfigFile;
    final cfg = Map<String, dynamic>.from(loadSavedConfig(cfgFile));
    final subs = SubMcpManager(subFile).loadEntries();

    if (!includeSecrets) {
      cfg.remove('oauth_local_password_hash');
      cfg.remove('api_key');
      cfg.remove('oauth_client_secret');
      cfg.remove('tunnel_token');
      if (cfg['profiles'] is List) {
        cfg['profiles'] = (cfg['profiles'] as List).whereType<Map>().map((p) {
          final m = Map<String, dynamic>.from(p);
          m.remove('api_key');
          m.remove('oauth_client_secret');
          m.remove('tunnel_token');
          return m;
        }).toList();
      }
      for (final s in subs) {
        s.remove('auth_token');
        s.remove('api_key');
        s.remove('basic_password');
        s.remove('oauth_client_secret');
      }
    }

    final inner = <String, dynamic>{
      'schema': 'agent_mcp_snapshot_v1',
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'app_version': agentMcpVersion,
      'include_secrets': includeSecrets,
      'config': cfg,
      'sub_mcps': subs,
    };

    final cleanPwd = (password ?? '').trim();
    if (cleanPwd.isEmpty) {
      return inner;
    }

    final rng = Random.secure();
    final salt = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
    final iv = Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256)));
    final keyMaterial = _deriveKey(cleanPwd, salt, 64);
    final encKey = Uint8List.sublistView(keyMaterial, 0, 32);
    final macKey = Uint8List.sublistView(keyMaterial, 32, 64);

    final plainBytes = Uint8List.fromList(utf8.encode(jsonEncode(inner)));
    final cipherBytes = _streamXor(plainBytes, encKey, iv);
    final tag = Hmac(sha256, macKey).convert([...salt, ...iv, ...cipherBytes]).bytes;

    return {
      'schema': 'agent_mcp_encrypted_snapshot_v1',
      'exported_at': inner['exported_at'],
      'app_version': agentMcpVersion,
      'kdf': 'pbkdf2-hmac-sha256-60000',
      'salt': base64Encode(salt),
      'iv': base64Encode(iv),
      'ciphertext': base64Encode(cipherBytes),
      'mac': base64Encode(tag),
    };
  }

  static Map<String, dynamic> importSnapshot({
    required String rawJson,
    String? password,
    File? configFile,
    File? subMcpFile,
  }) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) {
      throw const FormatException('无效的快照文件格式。');
    }
    var payload = Map<String, dynamic>.from(decoded);
    if (payload['schema'] == 'agent_mcp_encrypted_snapshot_v1') {
      final cleanPwd = (password ?? '').trim();
      if (cleanPwd.isEmpty) {
        throw const FormatException('该配置快照已加密，请输入解密口令。');
      }
      final salt = base64Decode(payload['salt'].toString());
      final iv = base64Decode(payload['iv'].toString());
      final cipherBytes = base64Decode(payload['ciphertext'].toString());
      final expectedMac = base64Decode(payload['mac'].toString());

      final keyMaterial = _deriveKey(cleanPwd, salt, 64);
      final encKey = Uint8List.sublistView(keyMaterial, 0, 32);
      final macKey = Uint8List.sublistView(keyMaterial, 32, 64);
      final actualMac =
          Hmac(sha256, macKey).convert([...salt, ...iv, ...cipherBytes]).bytes;
      if (!constantTimeEquals(base64Encode(actualMac), base64Encode(expectedMac))) {
        throw const FormatException('解密失败：快照口令不正确或文件已损坏。');
      }
      final plainBytes = _streamXor(Uint8List.fromList(cipherBytes), encKey, Uint8List.fromList(iv));
      payload = Map<String, dynamic>.from(jsonDecode(utf8.decode(plainBytes)) as Map);
    }

    if (payload['schema'] != 'agent_mcp_snapshot_v1') {
      throw FormatException("不支持的快照版本: ${payload['schema']}");
    }

    final cfgFile = configFile ?? StoragePaths.instance.defaultConfigFile;
    final subFile = subMcpFile ?? StoragePaths.instance.subMcpConfigFile;

    var restoredProfiles = 0;
    if (payload['config'] is Map) {
      final cur = loadSavedConfig(cfgFile);
      final incoming = Map<String, dynamic>.from(payload['config'] as Map);
      // Preserve local password hash if incoming snapshot excluded secrets
      if (!incoming.containsKey('oauth_local_password_hash') &&
          cur.containsKey('oauth_local_password_hash')) {
        incoming['oauth_local_password_hash'] = cur['oauth_local_password_hash'];
      }
      saveConfigFile(cfgFile, incoming);
      restoredProfiles = (incoming['profiles'] is List)
          ? (incoming['profiles'] as List).length
          : 1;
    }

    var restoredSubs = 0;
    if (payload['sub_mcps'] is List) {
      final mgr = SubMcpManager(subFile);
      final valid = <Map<String, dynamic>>[];
      for (final raw in payload['sub_mcps'] as List) {
        if (raw is Map) {
          try {
            valid.add(normalizeSubEntry(Map<String, dynamic>.from(raw)));
          } catch (_) {}
        }
      }
      mgr.saveEntries(valid);
      restoredSubs = valid.length;
    }

    return {
      'ok': true,
      'profiles_count': restoredProfiles,
      'sub_mcps_count': restoredSubs,
    };
  }
}
