import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:agent_mcp_core/agent_mcp_core.dart';
import 'package:agent_mcp_core/src/win32_tray.dart';
import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

bool _useAnsiColor = true;

void _initConsoleUtf8AndColor(List<String> rawArgs) {
  if (Platform.isWindows) {
    try {
      final kernel32 = ffi.DynamicLibrary.open('kernel32.dll');
      final setOutCp = kernel32
          .lookupFunction<ffi.Int32 Function(ffi.Uint32), int Function(int)>(
            'SetConsoleOutputCP',
          );
      final setInCp = kernel32
          .lookupFunction<ffi.Int32 Function(ffi.Uint32), int Function(int)>(
            'SetConsoleCP',
          );
      setOutCp(65001);
      setInCp(65001);
    } catch (_) {}
  }
  final noColorEnv = (Platform.environment['NO_COLOR'] ?? '').isNotEmpty;
  final noColorArg = rawArgs.contains('--no-color');
  _useAnsiColor = !noColorEnv && !noColorArg && stdout.hasTerminal;
}

String _cClay(String s) => _useAnsiColor ? '\x1B[38;5;173m$s\x1B[0m' : s;
String _cSage(String s) => _useAnsiColor ? '\x1B[38;5;108m$s\x1B[0m' : s;
String _cMuted(String s) => _useAnsiColor ? '\x1B[38;5;245m$s\x1B[0m' : s;
String _cBold(String s) => _useAnsiColor ? '\x1B[1m$s\x1B[0m' : s;

final RegExp _ansiStripRe = RegExp(r'\x1B\[[0-9;]*m');

int _displayWidth(String raw) {
  final plain = raw.replaceAll(_ansiStripRe, '');
  var width = 0;
  for (final rune in plain.runes) {
    if (_isWideRune(rune)) {
      width += 2;
    } else if (rune >= 32) {
      width += 1;
    }
  }
  return width;
}

bool _isWideRune(int r) {
  return (r >= 0x1100 && r <= 0x115F) ||
      r == 0x2329 ||
      r == 0x232A ||
      (r >= 0x2E80 && r <= 0xA4CF && r != 0x303F) ||
      (r >= 0xAC00 && r <= 0xD7A3) ||
      (r >= 0xF900 && r <= 0xFAFF) ||
      (r >= 0xFE10 && r <= 0xFE19) ||
      (r >= 0xFE30 && r <= 0xFE6F) ||
      (r >= 0xFF00 && r <= 0xFF60) ||
      (r >= 0xFFE0 && r <= 0xFFE6);
}

String _padDisplay(String s, int targetCols) {
  final w = _displayWidth(s);
  if (w >= targetCols) return s;
  return '$s${' ' * (targetCols - w)}';
}

void _printBox(String title, List<String> bodyLines, {bool toStderr = false}) {
  var innerWidth = _displayWidth(title) + 4;
  for (final l in bodyLines) {
    final lw = _displayWidth(l) + 2;
    if (lw > innerWidth) innerWidth = lw;
  }
  innerWidth = innerWidth.clamp(56, 88);

  final out = toStderr ? stderr : stdout;
  out.writeln('╭${'─' * innerWidth}╮');
  out.writeln('│ ${_padDisplay(title, innerWidth - 2)} │');
  if (bodyLines.isNotEmpty) {
    out.writeln('├${'─' * innerWidth}┤');
    for (final line in bodyLines) {
      out.writeln('│ ${_padDisplay(line, innerWidth - 2)} │');
    }
  }
  out.writeln('╰${'─' * innerWidth}╯');
}

Future<void> main(List<String> rawArgs) async {
  _initConsoleUtf8AndColor(rawArgs);
  StoragePaths.instance.ensureLayout();

  if (rawArgs.isEmpty) {
    _printHelp();
    return;
  }

  final first = rawArgs.first.trim();
  if (first == '-v' || first == '--version' || first == 'version') {
    stdout.writeln('Agent MCP v$agentMcpVersion (Dart Native)');
    return;
  }
  if (first == '-h' || first == '--help' || first == 'help') {
    _printHelp();
    return;
  }

  switch (first) {
    case 'run':
      await _cmdRun(rawArgs.sublist(1));
    case 'gui':
      await _cmdGui(rawArgs.sublist(1));
    case 'init':
      await _cmdInit(rawArgs.sublist(1));
    case 'service':
      _cmdService(rawArgs.sublist(1));
    case 'remote':
      await _cmdRemote(rawArgs.sublist(1));
    case 'status':
    case 'doctor':
      await _cmdDoctor(rawArgs.sublist(1));
    case 'tools':
      _cmdTools(rawArgs.sublist(1));
    case 'snippet':
      _cmdSnippet(rawArgs.sublist(1));
    case 'setup':
    case 'set':
      await _cmdSetup();
    case 'config':
      _cmdConfig(rawArgs.sublist(1));
    case 'profile':
      _cmdProfile(rawArgs.sublist(1));
    case 'sub':
      await _cmdSub(rawArgs.sublist(1));
    case 'tunnel':
      await _cmdTunnel(rawArgs.sublist(1));
    default:
      if (first.startsWith('-')) {
        await _cmdRun(rawArgs);
      } else {
        stderr.writeln('${_cClay("未知子命令")}: $first\n');
        _printHelp();
        exitCode = 1;
      }
  }
}

void _printHelp() {
  _printBox(
    '${_cClay("✦")} ${_cBold("Agent MCP v$agentMcpVersion")} · Cross-Device Remote Execution Node & CLI',
    [
      _cMuted('部署于 Linux 服务器 · Windows 主机 · Android 手机，供任意电脑 AI 或 SDK 远程调用'),
    ],
  );
  stdout.writeln('''
${_cBold("核心运行与无头服务器部署:")}
  init [options]          非交互一行初始化节点配置（适合 SSH 云服务器 / Docker 部署）
  service <subcmd>        注册后台常驻守护服务 (install | uninstall | status, 支持 Linux systemd)
  run [options]           按配置或参数启动多网卡 MCP 节点与 Web 管理面板 (/mcp + /dashboard/)
  gui [--silent]          启动原生桌面控制台（无 GUI 二进制时自动挂载 Web 面板模式）
  doctor [--json]         全面体检：探测在线状态、本机网卡 / Tailscale IP、隧道与外网分享

${_cBold("跨设备连接与程序化调用:")}
  snippet [target]        生成远程连接与程序调用代码 (remote | python | ts | curl | claude | cursor | gemini | codex)
  remote <url> [action]   从终端直接测试或调用远端服务器 / 手机节点 (ping | tools | call)
  tools [--json]          查看内置 20 项原子工具矩阵与权限分级

${_cBold("配置与网关运维 (实时热加载):")}
  setup                   交互式终端分步配置向导
  config [--json]         查看生效配置与接入入口（全部密钥自动脱敏）
  profile <subcmd>        管理多入口 (list | enable | disable | add-ip | remove-ip | add-url)
  sub <subcmd>            管理嵌套子 MCP 网关 (list | inspect | enable | disable)
  tunnel <subcmd>         管理 Cloudflared 隧道 (status | start | stop | stop-all | install)

${_cBold("init / run 常用参数:")}
  -t, --transport <mode>  传输协议: dual (默认 HTTP+SSE) | http | sse | stdio
      --host <addr>       监听网卡地址 (支持多次传入或逗号分隔，如 0.0.0.0 或 127.0.0.1,100.x.y.z)
  -p, --port <port>       监听端口 (默认 8778 / 8000)
      --auth <mode>       鉴权模式: bearer | oauth-local | none
      --api-key <token>   指定 Bearer API Key（init 可传 --generate-key 自动生成高强密钥）
  -r, --root <dir>        限定可访问根目录（可多次传入）
      --allow-cwd         将当前工作目录加入白名单
      --read-only         纯只读安全审计模式（禁止一切写入、删除与命令执行）
      --allow-secrets     允许读取 .env / 密钥等敏感文件
      --relaxed-cmd       开启客户端免弹窗声明（tools/list 静默注解）
  -c, --config <file>     指定配置文件路径
      --log-level <lvl>   DEBUG | INFO | WARNING | ERROR
      --no-color          禁用彩色输出
''');
}

ServerConfig _resolveCliServerConfig(List<String> args) {
  final parser = ArgParser()
    ..addOption('config', abbr: 'c')
    ..addOption('name')
    ..addOption('prefix')
    ..addOption('transport', abbr: 't')
    ..addMultiOption('host')
    ..addOption('port', abbr: 'p')
    ..addOption('auth')
    ..addOption('api-key')
    ..addOption('oauth-base-url')
    ..addOption('oauth-client-id')
    ..addOption('oauth-client-secret')
    ..addMultiOption('root', abbr: 'r')
    ..addFlag('allow-cwd', negatable: false)
    ..addFlag('read-only', negatable: false)
    ..addFlag('allow-secrets', negatable: false)
    ..addFlag('relaxed-cmd', negatable: false)
    ..addFlag('silent', negatable: false)
    ..addOption('log-level')
    ..addOption('log-file')
    ..addFlag('no-color', negatable: false);

  final res = parser.parse(args);
  final cfgPath = res['config']?.toString();
  final cfgFile = cfgPath != null && cfgPath.trim().isNotEmpty
      ? File(expandAndResolvePath(cfgPath))
      : StoragePaths.instance.defaultConfigFile;

  final saved = loadSavedConfig(cfgFile);
  final env = Platform.environment;
  final cfg = ServerConfig.fromSavedMap(saved, configFile: cfgFile);

  if ((env['MCP_NAME'] ?? '').isNotEmpty) cfg.serverName = env['MCP_NAME']!;
  if ((env['MCP_TOOL_PREFIX'] ?? '').isNotEmpty) {
    cfg.toolPrefix = env['MCP_TOOL_PREFIX']!;
  }
  if ((env['MCP_TRANSPORT'] ?? '').isNotEmpty) {
    cfg.transport = env['MCP_TRANSPORT']!.toLowerCase();
  }
  if ((env['MCP_HOST'] ?? '').isNotEmpty) {
    final parsed = parseBindHosts(env['MCP_HOST']);
    cfg.hosts = parsed;
    cfg.host = parsed.first;
  }
  if ((env['MCP_PORT'] ?? '').isNotEmpty) {
    cfg.port = int.tryParse(env['MCP_PORT']!) ?? cfg.port;
  }
  if ((env['MCP_AUTH_MODE'] ?? '').isNotEmpty) {
    cfg.authMode = env['MCP_AUTH_MODE']!.toLowerCase();
  }
  if ((env['MCP_API_KEY'] ?? '').isNotEmpty) cfg.apiKey = env['MCP_API_KEY'];
  if ((env['MCP_OAUTH_BASE_URL'] ?? '').isNotEmpty) {
    cfg.oauthBaseUrl = env['MCP_OAUTH_BASE_URL'];
  }
  if ((env['MCP_OAUTH_CLIENT_ID'] ?? '').isNotEmpty) {
    cfg.oauthClientId = env['MCP_OAUTH_CLIENT_ID'];
  }
  if ((env['MCP_OAUTH_CLIENT_SECRET'] ?? '').isNotEmpty) {
    cfg.oauthClientSecret = env['MCP_OAUTH_CLIENT_SECRET'];
  }
  if ((env['MCP_LOG_LEVEL'] ?? '').isNotEmpty) {
    cfg.logLevel = env['MCP_LOG_LEVEL']!.toUpperCase();
  }
  if ((env['MCP_LOG_FILE'] ?? '').isNotEmpty) cfg.logFile = env['MCP_LOG_FILE'];

  if (res.wasParsed('name')) cfg.serverName = res['name'].toString();
  if (res.wasParsed('prefix')) cfg.toolPrefix = res['prefix'].toString();
  if (res.wasParsed('transport')) {
    var tr = res['transport'].toString().toLowerCase();
    if (tr == 'streamable-http') tr = 'http';
    cfg.transport = tr;
  }
  if (res.wasParsed('host')) {
    final hostList = parseBindHosts(res['host'] as List<String>);
    cfg.hosts = hostList;
    cfg.host = hostList.first;
  }
  if (res.wasParsed('port')) {
    cfg.port = int.tryParse(res['port'].toString()) ?? cfg.port;
  }
  if (res.wasParsed('auth')) {
    cfg.authMode = res['auth'].toString().toLowerCase();
  }
  if (res.wasParsed('api-key')) cfg.apiKey = res['api-key'].toString();
  if (res.wasParsed('oauth-base-url')) {
    cfg.oauthBaseUrl = res['oauth-base-url'].toString();
  }
  if (res.wasParsed('oauth-client-id')) {
    cfg.oauthClientId = res['oauth-client-id'].toString();
  }
  if (res.wasParsed('oauth-client-secret')) {
    cfg.oauthClientSecret = res['oauth-client-secret'].toString();
  }

  final cliRoots = (res['root'] as List<String>)
      .map((e) => e.trim())
      .where((s) => s.isNotEmpty)
      .map(expandAndResolvePath)
      .toList();
  if (cliRoots.isNotEmpty) {
    cfg.roots
      ..clear()
      ..addAll(cliRoots);
  }
  if (res['allow-cwd'] == true) {
    final cwd = Directory.current.absolute.path;
    if (!cfg.roots.contains(cwd)) cfg.roots.add(cwd);
  }
  if (res['read-only'] == true) cfg.readOnly = true;
  if (res['allow-secrets'] == true) cfg.allowSecrets = true;
  if (res['relaxed-cmd'] == true) cfg.relaxedCommandAnnotations = true;
  if (res.wasParsed('log-level')) {
    cfg.logLevel = res['log-level'].toString().toUpperCase();
  }
  if (res.wasParsed('log-file')) cfg.logFile = res['log-file'].toString();
  if (res['no-color'] == true) cfg.noColor = true;

  return cfg;
}

Future<void> _cmdInit(List<String> args) async {
  final parser = ArgParser()
    ..addOption('config', abbr: 'c')
    ..addOption('name')
    ..addOption('prefix')
    ..addMultiOption('host')
    ..addOption('port', abbr: 'p')
    ..addOption('auth')
    ..addOption('api-key')
    ..addFlag('generate-key', negatable: false)
    ..addFlag('password-stdin', negatable: false)
    ..addMultiOption('root', abbr: 'r')
    ..addFlag('read-only', negatable: false)
    ..addFlag('relaxed-cmd', defaultsTo: true)
    ..addFlag('json', negatable: false)
    ..addFlag('no-color', negatable: false);

  final res = parser.parse(args);
  final cfgPath = res['config']?.toString();
  final cfgFile = cfgPath != null && cfgPath.trim().isNotEmpty
      ? File(expandAndResolvePath(cfgPath))
      : StoragePaths.instance.defaultConfigFile;

  final data = loadSavedConfig(cfgFile);
  final serverName = (res.wasParsed('name')
          ? res['name']
          : (data['server_name'] ?? 'mcp-${Platform.localHostname}'))
      .toString()
      .trim();
  data['server_name'] = serverName;
  if (res.wasParsed('prefix')) {
    data['tool_prefix'] = sanitizePrefix(res['prefix'].toString())
        .replaceAll(RegExp(r'_+$'), '');
  }
  data['transport'] = 'dual';

  final bindHosts = res.wasParsed('host')
      ? parseBindHosts(res['host'] as List<String>)
      : parseBindHosts(data['hosts'], data['host'] ?? '0.0.0.0');
  data['hosts'] = bindHosts;
  data['host'] = bindHosts.first;

  final port = res.wasParsed('port')
      ? (int.tryParse(res['port'].toString()) ?? 8778)
      : (int.tryParse('${data['port'] ?? 8778}') ?? 8778);
  data['port'] = port;

  final authMode = (res.wasParsed('auth')
          ? res['auth']
          : (data['auth_mode'] ?? 'bearer'))
      .toString()
      .toLowerCase();
  data['auth_mode'] =
      {'bearer', 'oauth-local', 'none'}.contains(authMode) ? authMode : 'bearer';

  String? issuedKey;
  String? issuedPassword;

  if (data['auth_mode'] == 'bearer') {
    var key = res.wasParsed('api-key')
        ? res['api-key'].toString().trim()
        : (data['api_key'] ?? '').toString().trim();
    if (res['generate-key'] == true || key.isEmpty) {
      key = 'sk-mcp-${randomTokenUrlSafe(24)}';
    }
    data['api_key'] = key;
    issuedKey = key;
  }

  var adminPwd = (Platform.environment['AGENT_MCP_PASSWORD'] ?? '').trim();
  if (res['password-stdin'] == true) {
    adminPwd = stdin.readLineSync()?.trim() ?? '';
  }
  if (adminPwd.isNotEmpty) {
    data['oauth_local_password_hash'] = hashPassword(adminPwd);
    issuedPassword = '<configured-from-env-or-stdin>';
  } else if ((data['oauth_local_password_hash'] ?? '').toString().isEmpty) {
    final autoPwd = randomTokenUrlSafe(12);
    data['oauth_local_password_hash'] = hashPassword(autoPwd);
    issuedPassword = autoPwd;
  }

  final cliRoots = (res['root'] as List<String>)
      .map((e) => e.trim())
      .where((s) => s.isNotEmpty)
      .map(expandAndResolvePath)
      .toList();
  if (cliRoots.isNotEmpty) {
    data['roots'] = cliRoots;
  }
  if (res.wasParsed('read-only')) {
    data['read_only'] = res['read-only'] == true;
  }
  data['relaxed_command_annotations'] = res['relaxed-cmd'] == true;

  final ifaces = await listHostNetworkInterfaces();
  final detectedIps = ifaces
      .map((m) => (m['ip'] ?? '').trim())
      .where((ip) => ip.isNotEmpty && ip != '127.0.0.1' && ip != '::1')
      .toList();

  final profs = ensureProfilesInConfig(data);
  if (profs.isNotEmpty) {
    final mainProf = profs.first;
    mainProf['auth_mode'] = data['auth_mode'];
    if (issuedKey != null) {
      mainProf['api_key'] = issuedKey;
    }
    if (bindHosts.contains('0.0.0.0') && detectedIps.isNotEmpty) {
      mainProf['direct_ips'] = detectedIps;
    }
  }
  data['profiles'] = profs;
  saveConfigFile(cfgFile, data);

  final primaryIp = detectedIps.firstWhere(
    (ip) => ip.startsWith('100.'),
    orElse: () => detectedIps.isNotEmpty
        ? detectedIps.first
        : (bindHosts.first == '0.0.0.0' ? '127.0.0.1' : bindHosts.first),
  );
  final mcpEndpoint = 'http://$primaryIp:$port/mcp';
  final dashUrl = 'http://$primaryIp:$port/dashboard/';

  if (res['json'] == true) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'ok': true,
        'config_file': cfgFile.path,
        'server_name': serverName,
        'bind_hosts': bindHosts,
        'port': port,
        'auth_mode': data['auth_mode'],
        if (issuedKey != null) 'api_key': issuedKey,
        if (issuedPassword != null) 'dashboard_password': issuedPassword,
        'mcp_endpoint': mcpEndpoint,
        'dashboard_url': dashUrl,
        'detected_ips': detectedIps,
      }),
    );
    return;
  }

  _printBox('${_cClay("✦")} ${_cBold("节点初始化完成 ($serverName)")}', [
    '配置文件   : ${cfgFile.path}',
    '监听地址   : ${bindHosts.join(", ")} : $port',
    '远程入口   : ${_cSage(mcpEndpoint)}',
    'Web 管理台 : $dashUrl',
    if (issuedKey != null) 'Bearer Key : $issuedKey',
    if (issuedPassword != null) '管理台密码 : $issuedPassword',
  ]);
  stdout.writeln('\n下一步启动或注册常驻守护服务:');
  stdout.writeln('  前台运行 : agent-mcp run');
  if (Platform.isLinux) {
    stdout.writeln('  常驻守护 : agent-mcp service install');
  }
  stdout.writeln('  调用代码 : agent-mcp snippet python');
}

void _cmdService(List<String> args) {
  final sub = args.isEmpty ? 'status' : args.first.toLowerCase();
  final systemWide = args.contains('--system');
  final startNow = !args.contains('--no-start');
  final asJson = args.contains('--json');

  if (Platform.isLinux) {
    Map<String, dynamic> out;
    if (sub == 'install') {
      out = AutoStartManager.installLinuxSystemdService(
        systemWide: systemWide,
        startNow: startNow,
      );
    } else if (sub == 'uninstall' || sub == 'remove') {
      out = AutoStartManager.uninstallLinuxSystemdService(
        systemWide: systemWide,
      );
    } else if (sub == 'status') {
      out = AutoStartManager.queryLinuxSystemdStatus(systemWide: systemWide);
    } else {
      stderr.writeln('用法: agent-mcp service <install|uninstall|status> [--user|--system] [--no-start]');
      exitCode = 1;
      return;
    }

    if (asJson) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(out));
      return;
    }

    if (sub == 'install') {
      if (out['ok'] != true) {
        stderr.writeln('${_cClay("✗")} ${out['error']}');
        exitCode = 1;
        return;
      }
      _printBox('${_cClay("✦")} ${_cBold("Linux systemd 守护服务已写入")}', [
        '运行级别 : ${out['mode'] == 'system' ? '系统级 (/etc/systemd/system)' : '用户级 (~/.config/systemd/user)'}',
        '单元文件 : ${out['unit_path']}',
        '工作目录 : ${out['working_directory']}',
        '启动状态 : ${out['systemctl_started'] == true ? _cSage("已启用并启动") : _cMuted("单元已生成 (${out['note'] ?? '请手动执行 systemctl 启用'})")}',
      ]);
      return;
    }
    if (sub == 'uninstall' || sub == 'remove') {
      stdout.writeln('${_cSage("✓")} 已移除 systemd 服务单元: ${out['unit_path']}');
      return;
    }
    _printBox('${_cClay("✦")} ${_cBold("Linux systemd 服务状态")}', [
      '单元文件 : ${out['unit_path']} (${out['unit_exists'] == true ? "已安装" : "未安装"})',
      '激活状态 : ${out['active_state']}',
      '自启状态 : ${out['enabled_state']}',
    ]);
    return;
  }

  if (sub == 'install') {
    final res = AutoStartManager.syncWithOs(enabled: true, silentStart: true);
    if (asJson) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(res));
      return;
    }
    stdout.writeln(
      res['ok'] == true
          ? '${_cSage("✓")} 已注册开机静默自启动: ${res['exe']}'
          : '${_cClay("!")} ${res['warning'] ?? res['error']}',
    );
  } else if (sub == 'uninstall' || sub == 'remove') {
    final res = AutoStartManager.syncWithOs(enabled: false, silentStart: false);
    if (asJson) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(res));
      return;
    }
    stdout.writeln('${_cSage("✓")} 已取消开机自启动。');
  } else {
    final reg = AutoStartManager.isOsRegistered();
    if (asJson) {
      stdout.writeln(jsonEncode({'os': Platform.operatingSystem, 'registered': reg}));
      return;
    }
    stdout.writeln('开机自启注册状态 (${Platform.operatingSystem}): ${reg ? _cSage("已启用") : _cMuted("未启用")}');
  }
}

Future<void> _cmdRemote(List<String> args) async {
  final parser = ArgParser()
    ..addOption('api-key', abbr: 'k')
    ..addFlag('json', negatable: false)
    ..addFlag('no-color', negatable: false);
  final res = parser.parse(args);
  final rest = res.rest;
  if (rest.isEmpty) {
    stderr.writeln(
      '用法:\n'
      '  agent-mcp remote <http://host:port> ping\n'
      '  agent-mcp remote <http://host:port> tools [-k <api_key>]\n'
      '  agent-mcp remote <http://host:port> call <tool_name> [json_args] [-k <api_key>]',
    );
    exitCode = 1;
    return;
  }

  var rawBase = rest.first.trim().replaceAll(RegExp(r'/+$'), '');
  if (!rawBase.startsWith('http://') && !rawBase.startsWith('https://')) {
    rawBase = 'http://$rawBase';
  }
  if (rawBase.endsWith('/mcp')) {
    rawBase = rawBase.substring(0, rawBase.length - 4);
  }
  final action = rest.length >= 2 ? rest[1].toLowerCase() : 'ping';
  final apiKey = (res['api-key'] ?? Platform.environment['MCP_API_KEY'] ?? '')
      .toString()
      .trim();
  final asJson = res['json'] == true;

  Map<String, String> buildHeaders() => {
        'content-type': 'application/json',
        'accept': 'application/json, text/event-stream',
        'mcp-protocol-version': mcpProtocolVersion,
        if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
      };

  if (action == 'ping' || action == 'health') {
    final sw = Stopwatch()..start();
    try {
      final resp = await http
          .get(Uri.parse('$rawBase/health'))
          .timeout(const Duration(seconds: 6));
      sw.stop();
      if (resp.statusCode != 200) {
        stderr.writeln('远端返回 HTTP ${resp.statusCode}: ${resp.body}');
        exitCode = 1;
        return;
      }
      final info = jsonDecode(resp.body) as Map<String, dynamic>;
      info['latency_ms'] = sw.elapsedMilliseconds;
      info['mcp_endpoint'] = '$rawBase/mcp';
      if (asJson) {
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(info));
        return;
      }
      _printBox('${_cClay("✦")} ${_cBold("远端节点在线 (${info['server_name']})")}', [
        'MCP 地址 : ${_cSage("$rawBase/mcp")}',
        '主机信息 : ${info['hostname'] ?? '-'} (${info['os'] ?? 'unknown'} · v${info['version'] ?? '-'})',
        '工具数量 : ${info['tools_count'] ?? '-'} 项 · 鉴权=${info['auth_mode']} · 延迟=${sw.elapsedMilliseconds}ms',
      ]);
    } catch (e) {
      stderr.writeln('无法连接远端节点 $rawBase: $e');
      exitCode = 1;
    }
    return;
  }

  Future<Map<String, dynamic>> rpcPost(
    String method,
    Map<String, dynamic> params, {
    String? sessionId,
  }) async {
    final hdrs = buildHeaders();
    if (sessionId != null && sessionId.isNotEmpty) {
      hdrs['mcp-session-id'] = sessionId;
    }
    final r = await http
        .post(
          Uri.parse('$rawBase/mcp'),
          headers: hdrs,
          body: jsonEncode({
            'jsonrpc': '2.0',
            'id': 1,
            'method': method,
            'params': params,
          }),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw HttpException('HTTP ${r.statusCode}: ${r.body}');
    }
    final decoded = jsonDecode(r.body) as Map<String, dynamic>;
    final sid = r.headers['mcp-session-id'];
    if (sid != null) decoded['_session_id'] = sid;
    return decoded;
  }

  try {
    final initResp = await rpcPost('initialize', {
      'protocolVersion': mcpProtocolVersion,
      'capabilities': const <String, dynamic>{},
      'clientInfo': {'name': 'agent-mcp-cli', 'version': agentMcpVersion},
    });
    final sid = initResp['_session_id']?.toString();

    if (action == 'tools') {
      final listResp =
          await rpcPost('tools/list', const <String, dynamic>{}, sessionId: sid);
      final tools = (((listResp['result'] as Map?)?['tools'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      if (asJson) {
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(tools));
        return;
      }
      stdout.writeln('${_cBold("远端节点共开放 ${tools.length} 项工具")} ($rawBase/mcp):');
      for (final t in tools) {
        final name = '${t['name']}'.padRight(20);
        stdout.writeln('  • ${_cSage(name)} ${_cMuted('${t['description'] ?? ''}')}');
      }
      return;
    }

    if (action == 'call' && rest.length >= 3) {
      final toolName = rest[2];
      final rawArgsJson = rest.length >= 4 ? rest[3] : '{}';
      final parsedArgs = Map<String, dynamic>.from(jsonDecode(rawArgsJson) as Map);
      final callResp = await rpcPost(
        'tools/call',
        {'name': toolName, 'arguments': parsedArgs},
        sessionId: sid,
      );
      if (asJson) {
        stdout.writeln(const JsonEncoder.withIndent('  ').convert(callResp));
        return;
      }
      if (callResp['error'] != null) {
        stderr.writeln('调用错误: ${jsonEncode(callResp['error'])}');
        exitCode = 1;
        return;
      }
      final content = ((callResp['result'] as Map?)?['content'] as List?) ?? const [];
      for (final item in content) {
        if (item is Map && item['text'] != null) {
          stdout.writeln(item['text']);
        }
      }
      return;
    }

    stderr.writeln('未知 remote 动作: $action (支持 ping | tools | call)');
    exitCode = 1;
  } catch (e) {
    stderr.writeln('远程调用失败: $e');
    exitCode = 1;
  }
}

Future<void> _cmdRun(List<String> args) async {
  final cfg = _resolveCliServerConfig(args);
  McpLogger.instance.configure(
    name: cfg.serverName,
    levelName: cfg.logLevel,
    logFilePath: cfg.logFile,
    noColor: cfg.noColor,
  );

  final engine = McpServerEngine(cfg);

  if (cfg.transport == 'stdio') {
    await engine.serveStdio();
    return;
  }

  final servers = await engine.serveHttpMulti();
  _printStartupCard(cfg, engine.tools.length, servers);
  await TunnelManager.instance.startAutoTunnels(cfg.profiles, cfg.port);

  final stopSignal = Completer<void>();
  void handleSig(ProcessSignal _) {
    if (!stopSignal.isCompleted) stopSignal.complete();
  }

  final sigIntSub = ProcessSignal.sigint.watch().listen(handleSig);
  StreamSubscription<ProcessSignal>? sigTermSub;
  if (!Platform.isWindows) {
    sigTermSub = ProcessSignal.sigterm.watch().listen(handleSig);
  }

  await stopSignal.future;
  McpLogger.instance.info('正在优雅关闭 Agent MCP 服务与后台子进程...');
  await sigIntSub.cancel();
  await sigTermSub?.cancel();
  await ExposureManager.instance.closeAllExposures();
  await TunnelManager.instance.stopAll();
  await engine.processManager.stopAll();
  for (final s in servers) {
    await s.close(force: true);
  }
}

File? _findNativeGuiBinary() {
  if (!Platform.isWindows) return null;
  final root = StoragePaths.instance.rootDir.path;
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final candidates = <String>[
    p.join(exeDir, 'agent_mcp_app.exe'),
    p.join(p.dirname(exeDir), 'agent_mcp_app.exe'),
    p.join(
      root,
      'apps',
      'agent_mcp_app',
      'build',
      'windows',
      'x64',
      'runner',
      'Release',
      'agent_mcp_app.exe',
    ),
    p.join(root, 'dist', 'windows', 'agent_mcp_app.exe'),
  ];
  for (final c in candidates) {
    final f = File(c);
    if (f.existsSync()) return f;
  }
  return null;
}

Future<void> _cmdGui(List<String> args) async {
  final nativeApp = _findNativeGuiBinary();
  if (nativeApp != null && !args.contains('--web-only')) {
    final passArgs = <String>[
      if (args.contains('--silent')) '--silent',
    ];
    await Process.start(
      nativeApp.path,
      passArgs,
      workingDirectory: nativeApp.parent.path,
      mode: ProcessStartMode.detached,
    );
    stdout.writeln(
      '${_cSage("✓")} 已拉起原生桌面控制台: ${nativeApp.path}${passArgs.isNotEmpty ? " (${passArgs.join(" ")})" : ""}',
    );
    return;
  }

  final cfg0 = _resolveCliServerConfig(args);
  final saved = loadSavedConfig(cfg0.configFile);
  if ((saved['oauth_local_password_hash'] ?? '').toString().isEmpty &&
      (saved['api_key'] ?? '').toString().isEmpty) {
    final initPwd = randomTokenUrlSafe(10);
    saved['oauth_local_password_hash'] = hashPassword(initPwd);
    saved['server_name'] ??= cfg0.serverName;
    saved['host'] ??= '127.0.0.1';
    saved['hosts'] ??= ['127.0.0.1'];
    saved['port'] ??= 8778;
    saved['transport'] ??= 'dual';
    saved['auto_start'] ??= true;
    saveConfigFile(cfg0.configFile, saved);
    stderr.writeln('已初始化本地控制台授权密码: $initPwd');
  }

  final ctrl = McpServiceController(cfg0.configFile);
  await ctrl.start();
  final activeCfg = ctrl.loadCurrentServerConfig();
  final localHost = (activeCfg.host == '0.0.0.0' || activeCfg.host == '::')
      ? '127.0.0.1'
      : activeCfg.host;
  final launchUrl =
      'http://$localHost:${activeCfg.port}/dashboard/?ticket=${Uri.encodeComponent(ctrl.localLaunchTicket)}';

  final tray = Win32TrayManager();
  final quitCompleter = Completer<void>();

  final trayOk = await tray.start(
    tooltip: '${activeCfg.serverName} Console (v$agentMcpVersion)',
    onAction: (act) async {
      switch (act) {
        case TrayAction.openConsole:
          await launchConsoleWindow(launchUrl);
        case TrayAction.startService:
          await ctrl.start();
        case TrayAction.stopService:
          await ctrl.stop();
        case TrayAction.quitApp:
          if (!quitCompleter.isCompleted) quitCompleter.complete();
      }
    },
  );

  stderr.writeln(
    'Agent MCP Console running at http://$localHost:${activeCfg.port}/dashboard/ (System Tray: ${trayOk ? "ON" : "OFF"})',
  );
  if (!args.contains('--silent')) {
    await launchConsoleWindow(launchUrl);
  }

  final sigSub = ProcessSignal.sigint.watch().listen((_) {
    if (!quitCompleter.isCompleted) quitCompleter.complete();
  });

  await quitCompleter.future;
  await sigSub.cancel();
  await tray.stop();
  await ctrl.dispose();
  exit(0);
}

void _printStartupCard(
  ServerConfig cfg,
  int toolCount,
  List<HttpServer> servers,
) {
  final scope =
      cfg.unrestricted ? '全盘 (Unrestricted)' : '${cfg.roots.length} 个限定目录';
  final perm = cfg.readOnly ? '只读 (Read-Only)' : '读写 + 命令执行';
  final boundStr = servers.isNotEmpty
      ? servers.map((s) => '${s.address.host}:${s.port}').join(', ')
      : '${cfg.host}:${cfg.port}';
  final hostDisp =
      (cfg.host == '0.0.0.0' || cfg.host == '::') ? '127.0.0.1' : cfg.host;

  _printBox(
    '${_cClay("✦")} ${_cBold(cfg.serverName)} · v$agentMcpVersion (Dart Native)',
    [
      '监听网卡   : $boundStr (${cfg.transport.toUpperCase()})',
      'Streamable : ${_cSage("http://$hostDisp:${cfg.port}/mcp")}',
      'Legacy SSE : http://$hostDisp:${cfg.port}/sse',
      '管理面板   : http://$hostDisp:${cfg.port}/dashboard/',
      '权限边界   : $perm · $scope · $toolCount 项工具',
    ],
    toStderr: true,
  );
}

Future<void> _cmdDoctor(List<String> args) async {
  final cfgFile = StoragePaths.instance.defaultConfigFile;
  final saved = loadSavedConfig(cfgFile);
  final profs = ensureProfilesInConfig(saved);
  final bindHosts = parseBindHosts(saved['hosts'], saved['host']);
  final port = int.tryParse('${saved['port'] ?? 8000}') ?? 8000;
  final probeHost =
      (bindHosts.first == '0.0.0.0' || bindHosts.first == '::')
          ? '127.0.0.1'
          : bindHosts.first;

  var serviceLive = false;
  int? latencyMs;
  String? liveServerName;
  String? liveVersion;
  final sw = Stopwatch()..start();
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = const Duration(milliseconds: 1500);
  try {
    final req = await client
        .getUrl(Uri.parse('http://$probeHost:$port/health'))
        .timeout(const Duration(milliseconds: 1800));
    final res = await req.close().timeout(const Duration(milliseconds: 1800));
    final body = await utf8.decodeStream(res);
    sw.stop();
    if (res.statusCode == 200) {
      serviceLive = true;
      latencyMs = sw.elapsedMilliseconds;
      final parsed = jsonDecode(body);
      if (parsed is Map) {
        liveServerName = parsed['server_name']?.toString();
        liveVersion = parsed['version']?.toString();
      }
    }
  } catch (_) {
    sw.stop();
  } finally {
    client.close(force: true);
  }

  final netIfaces = await listHostNetworkInterfaces();
  final tunStatus = TunnelManager.instance.getStatuses();
  final subServers = SubMcpManager.instance.listWithStatus();

  if (args.contains('--json')) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'version': agentMcpVersion,
        'os': Platform.operatingSystem,
        'hostname': Platform.localHostname,
        'config_file': cfgFile.path,
        'service_online': serviceLive,
        'latency_ms': latencyMs,
        'live_server_name': liveServerName,
        'live_version': liveVersion,
        'bind_hosts': bindHosts,
        'port': port,
        'network_interfaces': netIfaces,
        'cloudflared_installed': tunStatus['installed'] == true,
        'cloudflared_version': tunStatus['version'],
        'profiles_count': profs.length,
        'sub_mcps_count': subServers.length,
      }),
    );
    return;
  }

  final statusLine = serviceLive
      ? '${_cSage("● 运行中")} (${liveServerName ?? saved['server_name'] ?? 'Agent MCP'} v${liveVersion ?? agentMcpVersion}, ${latencyMs}ms)'
      : '${_cClay("○ 未在本地监听")} (可执行 agent-mcp init / run 或 agent-mcp gui 启动)';

  final cfInstalled = tunStatus['installed'] == true;
  final cfLine = cfInstalled
      ? '${_cSage("已就绪")} ${tunStatus['version'] ?? ""}'.trim()
      : _cMuted('未安装 (需要公网穿透可执行 agent-mcp tunnel install)');

  _printBox('${_cClay("✦")} ${_cBold("Agent MCP 节点环境与连通性体检")}', [
    '运行状态 : $statusLine',
    '当前主机 : ${Platform.localHostname} (${Platform.operatingSystem})',
    '配置文件 : ${cfgFile.path}',
    '监听配置 : ${bindHosts.join(", ")} : $port',
    '隧道组件 : $cfLine',
    '子网关数 : 已配置 ${subServers.length} 个嵌套子 MCP 服务',
    '外网分享 : ${ExposureManager.isExposureEnabledInSaved(saved) ? _cSage('已开启 (Tailscale + /share)') : _cMuted('已关闭')}',
  ]);

  stdout.writeln('\n${_cBold("本机网络接口:")}');
  for (final nif in netIfaces) {
    final ip = (nif['ip'] ?? '').padRight(16);
    final kindLbl = nif['label'] ?? '';
    final iface = nif['iface'] ?? '';
    final tag = '[$kindLbl${iface.isNotEmpty ? " · $iface" : ""}]';
    stdout.writeln('  • $ip ${_cMuted(tag)}');
  }

  stdout.writeln('\n${_cBold("接入入口 (Profiles):")}');
  for (final p in profs) {
    final en = p['enabled'] != false ? _cSage('ON ') : _cMuted('OFF');
    final urls = resolveProfileBaseUrls(p, port: port, fallbackHost: probeHost);
    final tr = (p['transport'] ?? 'dual').toString().toLowerCase();
    final suf = tr == 'sse' ? '/sse' : '/mcp';
    final pName = _cBold('${p['name']}');
    stdout.writeln(
      '  [$en] $pName (${p['id']}) · ${p['auth_mode']} · tunnel=${p['tunnel_mode']}',
    );
    for (final u in urls) {
      stdout.writeln('        -> ${_cSage("$u$suf")}');
    }
  }
}

void _cmdTools(List<String> args) {
  final engine = McpServerEngine(ServerConfig(readOnly: false));
  final specs = engine.tools;
  if (args.contains('--json')) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(
        specs.map((t) => t.toMcpJson()).toList(),
      ),
    );
    return;
  }

  _printBox(
    '${_cClay("✦")} ${_cBold("内置原子工具矩阵 (${specs.length} 项)")}',
    [
      '默认启用敏感凭据防护 (.env / 私钥拦截)，支持按入口独立绑定目录白名单与只读策略',
    ],
  );
  stdout.writeln();
  for (final t in specs) {
    final badge = t.annotations.readOnlyHint
        ? _cSage('[READ ]')
        : (t.annotations.destructiveHint
            ? _cClay('[EXEC ]')
            : _cBold('[WRITE]'));
    final nameCol = t.baseName.padRight(18);
    stdout.writeln('  $badge  $nameCol ${_cMuted(t.description)}');
  }
}

void _cmdSnippet(List<String> args) {
  final target = args.isNotEmpty && !args.first.startsWith('-')
      ? args.first.toLowerCase()
      : 'all';
  String? wantedProfId;
  for (var i = 0; i < args.length - 1; i++) {
    if (args[i] == '--profile' || args[i] == '-p') {
      wantedProfId = args[i + 1];
    }
  }

  final saved = loadSavedConfig();
  final profs = ensureProfilesInConfig(saved);
  final port = int.tryParse('${saved['port'] ?? 8778}') ?? 8778;
  final prof = wantedProfId != null
      ? (profs.where((e) => e['id'] == wantedProfId).firstOrNull ?? profs.first)
      : (profs.where((e) => e['enabled'] != false).firstOrNull ?? profs.first);

  final fallbackHost = (saved['host'] == '0.0.0.0' || saved['host'] == null)
      ? '100.x.y.z'
      : saved['host'].toString();
  final urls = resolveProfileBaseUrls(
    prof,
    port: port,
    fallbackHost: fallbackHost,
  );
  final mcpUrl = '${urls.first}/mcp';
  final srvName = (saved['server_name'] ?? 'remote-agent-mcp').toString();
  final isBearer = prof['auth_mode'] == 'bearer';
  final keyHint = isBearer ? '<YOUR_BEARER_API_KEY>' : '<YOUR_ACCESS_TOKEN>';
  final exePath = Platform.resolvedExecutable;
  const enc = JsonEncoder.withIndent('  ');

  if (target == 'all' ||
      target == 'remote' ||
      target == 'claude' ||
      target == 'cursor') {
    stdout.writeln(
      _cBold('1. 电脑端 Claude Code / Cursor / Antigravity 远程连接服务器或手机 (mcpServers):'),
    );
    stdout.writeln(
      enc.convert({
        'mcpServers': {
          srvName: {
            'url': mcpUrl,
            if (prof['auth_mode'] != 'none')
              'headers': {'Authorization': 'Bearer $keyHint'},
          },
        },
      }),
    );
    stdout.writeln();
  }

  if (target == 'all' || target == 'python' || target == 'py') {
    stdout.writeln(
      _cBold('2. Python 官方 MCP SDK 程序化远程调用 (pip install mcp):'),
    );
    stdout.writeln('''import asyncio
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

async def main():
    headers = {"Authorization": "Bearer $keyHint"}
    async with streamablehttp_client("$mcpUrl", headers=headers) as (read, write, _):
        async with ClientSession(read, write) as session:
            await session.initialize()
            roots = await session.call_tool("list_roots", {})
            print(roots.content[0].text)

asyncio.run(main())
''');
  }

  if (target == 'all' || target == 'ts' || target == 'typescript' || target == 'node') {
    stdout.writeln(
      _cBold('3. TypeScript / Node.js 官方 SDK 远程调用 (npm i @modelcontextprotocol/sdk):'),
    );
    stdout.writeln('''import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const client = new Client({ name: "my-agent", version: "1.0.0" });
const transport = new StreamableHTTPClientTransport(new URL("$mcpUrl"), {
  requestInit: { headers: { Authorization: "Bearer $keyHint" } },
});
await client.connect(transport);
const res = await client.callTool({ name: "list_roots", arguments: {} });
console.log(res.content);
''');
  }

  if (target == 'all' || target == 'curl') {
    stdout.writeln(_cBold('4. curl 零依赖 JSON-RPC 远程直调示例:'));
    stdout.writeln('''curl -sS -X POST "$mcpUrl" \\
  -H "Content-Type: application/json" \\
  -H "Authorization: Bearer $keyHint" \\
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_roots","arguments":{}}}'
''');
  }

  if (target == 'all' || target == 'gemini' || target == 'http') {
    stdout.writeln(
      _cBold('5. Gemini Web / Claude Web 浏览器端连接 (${prof['name']}):'),
    );
    stdout.writeln('  URL      : ${_cSage(mcpUrl)}');
    stdout.writeln('  Auth Mode: ${prof['auth_mode']}');
    if (prof['auth_mode'] == 'oauth-local') {
      stdout.writeln('  OAuth 2.1: 支持 RFC 7591 动态注册，填入 URL 后输入节点管理密码即可完成授权');
    }
    stdout.writeln();
  }

  if (target == 'all' || target == 'stdio' || target == 'codex') {
    stdout.writeln(_cBold('6. 本机同机 stdio 挂载 (Codex / Claude Desktop):'));
    stdout.writeln('  codex mcp add $srvName -- "$exePath" run -t stdio --relaxed-cmd');
  }
}

String _prompt(String label, [String defaultVal = '']) {
  final suffix = defaultVal.isNotEmpty ? ' [$defaultVal]' : '';
  stdout.write('$label$suffix: ');
  final line = stdin.readLineSync()?.trim() ?? '';
  return line.isEmpty ? defaultVal : line;
}

Future<void> _cmdSetup() async {
  final cfgFile = StoragePaths.instance.defaultConfigFile;
  final data = loadSavedConfig(cfgFile);
  _printBox('${_cClay("✦")} ${_cBold("Agent MCP 交互式终端配置向导")}', [
    '直接按回车保持方括号内当前值不变',
  ]);
  stdout.writeln();

  final defName =
      (data['server_name'] ?? 'mcp-${Platform.localHostname}').toString();
  data['server_name'] = _prompt('MCP 服务名称', defName);

  final defPfx = (data['tool_prefix'] ?? '').toString();
  final pfxIn =
      _prompt('工具名前缀 (留空或输入 n 不加前缀)', defPfx.isEmpty ? 'n' : defPfx);
  data['tool_prefix'] =
      (pfxIn.toLowerCase() == 'n' || pfxIn.toLowerCase() == 'none')
          ? ''
          : sanitizePrefix(pfxIn).replaceAll(RegExp(r'_+$'), '');

  final tr = _prompt(
    '传输模式 (dual / http / sse / stdio)',
    (data['transport'] ?? 'dual').toString(),
  ).toLowerCase();
  data['transport'] =
      {'dual', 'http', 'sse', 'stdio'}.contains(tr) ? tr : 'dual';

  if (data['transport'] != 'stdio') {
    final curHosts = parseBindHosts(data['hosts'], data['host']).join(', ');
    final rawHosts = _prompt('监听 Host (可填 0.0.0.0 或逗号分隔多个网卡 IP)', curHosts);
    final normHosts = parseBindHosts(rawHosts);
    data['hosts'] = normHosts;
    data['host'] = normHosts.first;
    final portStr = _prompt('监听 Port', '${data['port'] ?? 8778}');
    data['port'] = int.tryParse(portStr) ?? 8778;
  }

  final auth = _prompt(
    '默认鉴权方式 (oauth-local / bearer / none)',
    (data['auth_mode'] ?? 'oauth-local').toString(),
  ).toLowerCase();
  data['auth_mode'] =
      {'oauth-local', 'bearer', 'none'}.contains(auth) ? auth : 'bearer';

  if (data['auth_mode'] == 'bearer') {
    final curKey = (data['api_key'] ?? '').toString();
    var k = _prompt('Bearer API Key (留空自动生成)', curKey);
    if (k.isEmpty) {
      k = 'sk-mcp-${randomTokenUrlSafe(24)}';
      stdout.writeln('  -> 已生成 API Key: $k');
    }
    data['api_key'] = k;
  } else if (data['auth_mode'] == 'oauth-local') {
    final pwd = _prompt('设置全局管理 / OAuth 授权密码 (留空保留原密码或自动生成)', '');
    if (pwd.isNotEmpty) {
      data['oauth_local_password_hash'] = hashPassword(pwd);
    } else if ((data['oauth_local_password_hash'] ?? '').toString().isEmpty) {
      final autoPwd = randomTokenUrlSafe(10);
      data['oauth_local_password_hash'] = hashPassword(autoPwd);
      stdout.writeln('  -> 已生成本地授权密码: $autoPwd');
    }
  }

  final relaxed = _prompt(
    '是否开启客户端免弹窗声明 (y/N)',
    data['relaxed_command_annotations'] == true ? 'y' : 'n',
  );
  data['relaxed_command_annotations'] =
      relaxed.toLowerCase() == 'y' || relaxed.toLowerCase() == 'yes';

  data['profiles'] = ensureProfilesInConfig(data);
  saveConfigFile(cfgFile, data);
  stdout.writeln('\n${_cSage("✓")} 配置已保存至: ${cfgFile.path}');
}

String _maskSecret(String raw) {
  if (raw.isEmpty) return '';
  return raw.length > 8 ? '${raw.substring(0, 6)}***' : '***';
}

void _cmdConfig(List<String> args) {
  final cfgFile = StoragePaths.instance.defaultConfigFile;
  final saved = loadSavedConfig(cfgFile);
  final rawProfs = ensureProfilesInConfig(saved);

  final maskedProfs = rawProfs.map((p) {
    final cp = Map<String, dynamic>.from(p);
    if ((cp['api_key'] ?? '').toString().isNotEmpty) {
      cp['api_key'] = _maskSecret(cp['api_key'].toString());
    }
    if ((cp['oauth_client_secret'] ?? '').toString().isNotEmpty) {
      cp['oauth_client_secret'] = '***';
    }
    if ((cp['tunnel_token'] ?? '').toString().isNotEmpty) {
      cp['tunnel_token'] = '***';
    }
    return cp;
  }).toList();

  final bindHosts = parseBindHosts(saved['hosts'], saved['host']);
  final sanitized = Map<String, dynamic>.from(saved)
    ..['host'] = bindHosts.first
    ..['hosts'] = bindHosts
    ..['profiles'] = maskedProfs;

  if ((sanitized['api_key'] ?? '').toString().isNotEmpty) {
    sanitized['api_key'] = _maskSecret(sanitized['api_key'].toString());
  }
  if ((sanitized['oauth_client_secret'] ?? '').toString().isNotEmpty) {
    sanitized['oauth_client_secret'] = '***';
  }
  if ((sanitized['oauth_local_password_hash'] ?? '').toString().isNotEmpty) {
    sanitized['oauth_local_password_hash'] = '<pbkdf2-sha256-configured>';
  }

  if (args.contains('--json')) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(sanitized));
    return;
  }

  final port = int.tryParse('${sanitized['port'] ?? 8000}') ?? 8000;
  _printBox('${_cClay("✦")} ${_cBold("当前生效配置摘要")}', [
    '配置文件   : ${cfgFile.path}',
    '服务名称   : ${sanitized['server_name'] ?? 'agent-mcp'}',
    '监听地址   : ${bindHosts.join(", ")} : $port (${sanitized['transport'] ?? 'dual'})',
    '全局鉴权   : ${sanitized['auth_mode'] ?? 'bearer'}',
    '读写权限   : ${sanitized['read_only'] == true ? "只读模式" : "允许写入与执行"}',
    '免弹窗声明 : ${sanitized['relaxed_command_annotations'] == true ? "已开启" : "未开启"}',
  ]);

  stdout.writeln('\n${_cBold("接入入口 (Profiles):")}');
  for (final p in maskedProfs) {
    final st = p['enabled'] != false ? _cSage('ON ') : _cMuted('OFF');
    final urls =
        resolveProfileBaseUrls(p, port: port, fallbackHost: bindHosts.first);
    final suf =
        (p['transport'] ?? 'dual').toString().toLowerCase() == 'sse'
            ? '/sse'
            : '/mcp';
    final pName = _cBold('${p['name']}');
    stdout.writeln(
      '  [$st] ${p['id']} · $pName (${p['transport']} / ${p['auth_mode']} / tunnel:${p['tunnel_mode']})',
    );
    for (final u in urls) {
      stdout.writeln('        -> ${_cSage("$u$suf")}');
    }
  }
}

void _cmdProfile(List<String> args) {
  final cfgFile = StoragePaths.instance.defaultConfigFile;
  final saved = loadSavedConfig(cfgFile);
  final profs = ensureProfilesInConfig(saved);
  final port = int.tryParse('${saved['port'] ?? 8000}') ?? 8000;
  final bindHosts = parseBindHosts(saved['hosts'], saved['host']);

  final sub = args.isEmpty ? 'list' : args.first.toLowerCase();
  if (sub == 'list') {
    for (final p in profs) {
      final st =
          p['enabled'] != false ? _cSage('ENABLED ') : _cMuted('DISABLED');
      final urls =
          resolveProfileBaseUrls(p, port: port, fallbackHost: bindHosts.first);
      final suf =
          (p['transport'] ?? 'dual').toString().toLowerCase() == 'sse'
              ? '/sse'
              : '/mcp';
      final pName = _cBold('${p['name']}');
      stdout.writeln(
        '$st  ${p['id'].toString().padRight(14)} $pName  [${p['transport']} | ${p['auth_mode']} | tunnel=${p['tunnel_mode']}]',
      );
      for (final u in urls) {
        stdout.writeln('          -> $u$suf');
      }
    }
    return;
  }

  Map<String, dynamic>? findProf(String idOrName) {
    return profs
        .where((p) => p['id'] == idOrName || p['name'] == idOrName)
        .firstOrNull;
  }

  if ((sub == 'enable' || sub == 'disable') && args.length >= 2) {
    final target = findProf(args[1]);
    if (target == null) {
      stderr.writeln('未找到入口: ${args[1]}');
      exitCode = 1;
      return;
    }
    target['enabled'] = sub == 'enable';
    saveUpdatedConfigMap(cfgFile, {'profiles': profs});
    stdout.writeln(
      '${_cSage("✓")} 已${sub == 'enable' ? '启用' : '停用'}入口: ${target['name']}',
    );
    return;
  }

  if ((sub == 'add-ip' || sub == 'remove-ip') && args.length >= 3) {
    final target = findProf(args[1]);
    if (target == null) {
      stderr.writeln('未找到入口: ${args[1]}');
      exitCode = 1;
      return;
    }
    final ip = args[2].trim();
    final curIps = ((target['direct_ips'] as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (sub == 'add-ip') {
      if (!curIps.contains(ip)) curIps.add(ip);
    } else {
      curIps.remove(ip);
    }
    target['direct_ips'] = curIps;
    saveUpdatedConfigMap(cfgFile, {'profiles': profs});
    stdout.writeln(
      '${_cSage("✓")} 已更新入口 ${target['name']} 网卡 IP 列表: ${curIps.join(", ")}',
    );
    return;
  }

  if (sub == 'add-url' && args.length >= 3) {
    final target = findProf(args[1]);
    if (target == null) {
      stderr.writeln('未找到入口: ${args[1]}');
      exitCode = 1;
      return;
    }
    final norm = normalizeDirectBaseUrl(args[2]);
    final curUrls = ((target['manual_urls'] as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (norm.isNotEmpty && !curUrls.contains(norm)) {
      curUrls.add(norm);
    }
    target['manual_urls'] = curUrls;
    saveUpdatedConfigMap(cfgFile, {'profiles': profs});
    stdout.writeln(
      '${_cSage("✓")} 已为入口 ${target['name']} 添加自定义地址: $norm',
    );
    return;
  }

  stderr.writeln(
    '用法: agent-mcp profile <list|enable|disable|add-ip|remove-ip|add-url> <id> [value]',
  );
  exitCode = 1;
}

Future<void> _cmdSub(List<String> args) async {
  final sub = args.isEmpty ? 'list' : args.first.toLowerCase();
  if (sub == 'list') {
    final items = SubMcpManager.instance.listWithStatus();
    if (items.isEmpty) {
      stdout.writeln('当前未配置任何子 MCP 服务。');
      return;
    }
    for (final it in items) {
      final st = it['enabled'] != false ? _cSage('ON ') : _cMuted('OFF');
      final sName = _cBold('${it['name']}');
      stdout.writeln(
        '[$st] $sName (${it['transport']}) - ${it['description'] ?? ''}',
      );
    }
    return;
  }

  if (sub == 'inspect' && args.length >= 2) {
    final name = args[1];
    final res = await SubMcpManager.instance.discoverTools(name, refresh: true);
    if (res['ok'] != true) {
      stderr.writeln('探测失败: ${res['error']}');
      exitCode = 1;
      return;
    }
    final tools = (res['tools'] as List).cast<Map<String, dynamic>>();
    if (args.length >= 3) {
      final tName = args[2];
      final match = tools.where((t) => t['name'] == tName).firstOrNull;
      if (match == null) {
        stderr.writeln('未找到工具: $tName');
        exitCode = 1;
        return;
      }
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(match));
      return;
    }
    final bName = _cBold(name);
    stdout.writeln('$bName 共暴露 ${tools.length} 个工具 (${res['ms']} ms):');
    for (final t in tools) {
      final tLabel = _cSage('${t['name']}');
      stdout.writeln('  - $tLabel: ${t['description'] ?? ''}');
    }
    return;
  }

  if ((sub == 'enable' || sub == 'disable') && args.length >= 2) {
    SubMcpManager.instance.toggleEntry(args[1], sub == 'enable');
    stdout.writeln(
      '${_cSage("✓")} 已更新子 MCP ${args[1]} 状态为 ${sub == 'enable' ? '启用' : '停用'}',
    );
    return;
  }

  stderr.writeln(
    '用法: agent-mcp sub <list|inspect|enable|disable> [name] [tool]',
  );
  exitCode = 1;
}

Future<void> _cmdTunnel(List<String> args) async {
  final sub = args.isEmpty ? 'status' : args.first.toLowerCase();
  if (sub == 'status') {
    final st = TunnelManager.instance.getStatuses();
    if (args.contains('--json')) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(st));
      return;
    }
    final installed = st['installed'] == true;
    _printBox('${_cClay("✦")} ${_cBold("Cloudflared 隧道状态")}', [
      '二进制状态 : ${installed ? _cSage("已安装 ${st['version'] ?? ''}") : _cMuted("未安装")}',
      '二进制路径 : ${st['binary'] ?? "(未检测到)"}',
    ]);
    final tMap = (st['tunnels'] as Map?) ?? const {};
    if (tMap.isNotEmpty) {
      stdout.writeln('\n${_cBold("活跃隧道记录:")}');
      tMap.forEach((k, v) {
        if (v is Map) {
          final run = v['running'] == true ? _cSage('ONLINE') : _cMuted('IDLE');
          stdout.writeln('  [$run] $k  ${v['live_url'] ?? v['error'] ?? ''}');
        }
      });
    }
    return;
  }
  if (sub == 'install') {
    stdout.writeln('开始下载官方 cloudflared...');
    await TunnelManager.instance.startCloudflaredDownload(forceUpdate: true);
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final st = TunnelManager.instance.getStatuses()['install'] as Map;
      stdout.write('\r${st['status'] ?? ''} ${st['percent'] ?? 0}%   ');
      if (st['active'] != true) {
        stdout.writeln();
        if ((st['error'] ?? '').toString().isNotEmpty) {
          stderr.writeln(st['error']);
          exitCode = 1;
        }
        break;
      }
    }
    return;
  }
  if (sub == 'stop-all') {
    await TunnelManager.instance.stopAll();
    stdout.writeln('${_cSage("✓")} 已停止所有运行中的隧道。');
    return;
  }
  if ((sub == 'start' || sub == 'stop') && args.length >= 2) {
    final pid = args[1];
    if (sub == 'stop') {
      await TunnelManager.instance.stopTunnel(pid);
      stdout.writeln('${_cSage("✓")} 已停止隧道: $pid');
      return;
    }
    final saved = loadSavedConfig();
    final profs = ensureProfilesInConfig(saved);
    final prof =
        profs.where((p) => p['id'] == pid || p['name'] == pid).firstOrNull;
    if (prof == null) {
      stderr.writeln('未找到入口: $pid');
      exitCode = 1;
      return;
    }
    final port = int.tryParse('${saved['port'] ?? 8000}') ?? 8000;
    final res = await TunnelManager.instance.startTunnel(prof, port);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(res));
    return;
  }

  stderr.writeln(
    '用法: agent-mcp tunnel <status|start|stop|stop-all|install> [profile_id]',
  );
  exitCode = 1;
}
