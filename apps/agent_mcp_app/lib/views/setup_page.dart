import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/console_backend.dart';
import '../theme/claude_theme.dart';
import 'android_privilege_card.dart';
import 'exposure_page.dart';
import 'profile_dialogs.dart';
import 'profile_endpoints_helper.dart';

class ServiceSetupPage extends StatefulWidget {
  final ConsoleBackend backend;
  final Map<String, dynamic> config;
  final Map<String, dynamic> tunnelInfo;
  final Map<String, dynamic> storageStats;
  final Map<String, dynamic> exposureSummary;
  final bool isRunning;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final Future<void> Function() onRefreshStatus;
  final Future<void> Function() onRefreshStorage;
  final Future<void> Function() onRestartService;
  final ValueChanged<String> onToast;
  final double topPadding;
  final double extraBottomPadding;

  const ServiceSetupPage({
    super.key,
    required this.backend,
    required this.config,
    required this.tunnelInfo,
    required this.storageStats,
    this.exposureSummary = const <String, dynamic>{},
    required this.isRunning,
    required this.themeMode,
    required this.onThemeChanged,
    required this.onRefreshStatus,
    required this.onRefreshStorage,
    required this.onRestartService,
    required this.onToast,
    this.topPadding = 0.0,
    this.extraBottomPadding = 0.0,
  });

  @override
  State<ServiceSetupPage> createState() => _ServiceSetupPageState();
}

class _ServiceSetupPageState extends State<ServiceSetupPage> {
  final _nameCtrl = TextEditingController();
  final _prefixCtrl = TextEditingController();
  final List<TextEditingController> _hostCtrls = [
    TextEditingController(text: kLoopbackIpv4),
  ];
  final List<FocusNode> _hostFocusNodes = [FocusNode()];
  final _portCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _rootsCtrl = TextEditingController();
  final _logFileCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  bool _bindAllInterfaces = false;
  List<String> _customHostsBackup = <String>[kLoopbackIpv4];
  bool _autoStart = true;
  bool _launchAtStartup = false;
  bool _silentStart = false;
  bool _windowEffect = true;
  bool _writable = true;
  bool _allowSecrets = false;
  bool _relaxedCmd = false;
  String _logLevel = 'INFO';
  bool _savingBasic = false;
  bool _restartingBasic = false;
  bool _savingPerm = false;
  bool _refreshingStorage = false;
  String? _cleaningTarget;
  String _setupSection = 'basic';
  final Set<String> _togglingTunnels = <String>{};

  String _lastSyncedKey = '';

  List<String> _parseLines(String raw) => raw
      .split(RegExp(r'[\r\n,]+'))
      .map((e) => e.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  List<String> _normalizeHostItems(Iterable<String> rawItems) {
    final out = <String>[];
    for (final raw in rawItems) {
      for (final part in raw.split(RegExp(r'[\r\n,;]+'))) {
        final s = part.trim();
        if (s.isEmpty) continue;
        if (s == '0.0.0.0') return <String>['0.0.0.0'];
        if (!out.contains(s)) out.add(s);
      }
    }
    return out.isEmpty ? <String>[kLoopbackIpv4] : out;
  }

  List<String> _savedConfigHosts(Map<String, dynamic> cfg) {
    final rawList = cfg['hosts'];
    if (rawList is List && rawList.isNotEmpty) {
      return _normalizeHostItems(rawList.map((e) => e.toString()));
    }
    return _normalizeHostItems([(cfg['host'] ?? kLoopbackIpv4).toString()]);
  }

  List<String> get _effectiveHosts {
    if (_bindAllInterfaces) return <String>['0.0.0.0'];
    return _normalizeHostItems(_hostCtrls.map((c) => c.text));
  }

  void _setHostControllers(List<String> values) {
    final targets = values.isEmpty ? <String>[kLoopbackIpv4] : values;
    while (_hostCtrls.length > targets.length) {
      _hostCtrls.removeLast().dispose();
      _hostFocusNodes.removeLast().dispose();
    }
    for (var i = 0; i < targets.length; i++) {
      if (i < _hostCtrls.length) {
        _hostCtrls[i].text = targets[i];
      } else {
        _hostCtrls.add(TextEditingController(text: targets[i]));
        _hostFocusNodes.add(FocusNode());
      }
    }
  }

  void _addHostRow() {
    final nextFocus = FocusNode();
    setState(() {
      _hostCtrls.add(TextEditingController());
      _hostFocusNodes.add(nextFocus);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && nextFocus.canRequestFocus) {
        nextFocus.requestFocus();
      }
    });
  }

  void _removeHostRow(int index) {
    if (_hostCtrls.length <= 1 || index < 0 || index >= _hostCtrls.length) {
      return;
    }
    setState(() {
      _hostCtrls.removeAt(index).dispose();
      _hostFocusNodes.removeAt(index).dispose();
      final nonEmpty = _hostCtrls
          .map((c) => c.text.trim())
          .where((s) => s.isNotEmpty && s != '0.0.0.0')
          .toList();
      if (nonEmpty.isNotEmpty) {
        _customHostsBackup = nonEmpty;
      }
    });
  }

  bool get _basicDirty {
    final cfg = widget.config;
    if (_nameCtrl.text != (cfg['server_name'] ?? 'agent-mcp').toString()) {
      return true;
    }
    if (_prefixCtrl.text != (cfg['tool_prefix'] ?? '').toString()) {
      return true;
    }
    final curHosts = _effectiveHosts;
    final cfgHosts = _savedConfigHosts(cfg);
    if (curHosts.length != cfgHosts.length) return true;
    for (var i = 0; i < curHosts.length; i++) {
      if (curHosts[i] != cfgHosts[i]) return true;
    }
    if (_portCtrl.text != '${cfg['port'] ?? 8000}') {
      return true;
    }
    if (_pwdCtrl.text.trim().isNotEmpty) {
      return true;
    }
    return false;
  }

  bool get _permDirty {
    final cfg = widget.config;
    if (_writable != (cfg['read_only'] != true)) return true;
    if (_allowSecrets != (cfg['allow_secrets'] == true)) return true;
    if (_relaxedCmd != (cfg['relaxed_command_annotations'] == true)) {
      return true;
    }
    final cfgLog = (cfg['log_level'] ?? 'INFO').toString().toUpperCase();
    final normCfgLog =
        {'DEBUG', 'INFO', 'WARNING', 'ERROR'}.contains(cfgLog) ? cfgLog : 'INFO';
    if (_logLevel != normCfgLog) return true;
    if (_logFileCtrl.text.trim() != (cfg['log_file'] ?? '').toString().trim()) {
      return true;
    }
    final curRoots = _parseLines(_rootsCtrl.text);
    final cfgRoots = ((cfg['roots'] as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (curRoots.length != cfgRoots.length) return true;
    for (var i = 0; i < curRoots.length; i++) {
      if (curRoots[i] != cfgRoots[i]) return true;
    }
    return false;
  }

  @override
  void initState() {
    super.initState();
    _syncFromConfig(force: true);
  }

  @override
  void didUpdateWidget(covariant ServiceSetupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFromConfig(force: false);
  }

  void _syncFromConfig({required bool force}) {
    final cfg = widget.config;
    final cfgHostsKey = _savedConfigHosts(cfg).join(',');
    final key =
        '${cfg['server_name']}|$cfgHostsKey|${cfg['port']}|${cfg['auto_start']}|${cfg['launch_at_startup']}|${cfg['silent_start']}|${cfg['window_effect']}|${cfg['read_only']}|${cfg['allow_secrets']}|${cfg['relaxed_command_annotations']}';
    if (!force && key == _lastSyncedKey) return;
    _lastSyncedKey = key;

    if (force || !_basicDirty) {
      _nameCtrl.text = (cfg['server_name'] ?? 'agent-mcp').toString();
      _prefixCtrl.text = (cfg['tool_prefix'] ?? '').toString();
      final cfgHosts = _savedConfigHosts(cfg);
      _bindAllInterfaces = cfgHosts.length == 1 && cfgHosts.first == '0.0.0.0';
      if (!_bindAllInterfaces) {
        _customHostsBackup = List<String>.from(cfgHosts);
        _setHostControllers(cfgHosts);
      } else {
        _setHostControllers(_customHostsBackup);
      }
      _portCtrl.text = '${cfg['port'] ?? 8000}';
      _autoStart = cfg['auto_start'] != false;
      _launchAtStartup = cfg['launch_at_startup'] == true;
      _silentStart = cfg['silent_start'] == true;
      _windowEffect = cfg['window_effect'] != false;
    }
    if (force || !_permDirty) {
      _writable = cfg['read_only'] != true;
      _allowSecrets = cfg['allow_secrets'] == true;
      _relaxedCmd = cfg['relaxed_command_annotations'] == true;
      _rootsCtrl.text = ((cfg['roots'] as List?) ?? const []).join('\n');
      _logLevel = (cfg['log_level'] ?? 'INFO').toString().toUpperCase();
      if (!{'DEBUG', 'INFO', 'WARNING', 'ERROR'}.contains(_logLevel)) {
        _logLevel = 'INFO';
      }
      _logFileCtrl.text = (cfg['log_file'] ?? '').toString();
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _prefixCtrl.dispose();
    for (final ctrl in _hostCtrls) {
      ctrl.dispose();
    }
    for (final fn in _hostFocusNodes) {
      fn.dispose();
    }
    _portCtrl.dispose();
    _pwdCtrl.dispose();
    _rootsCtrl.dispose();
    _logFileCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> get _profiles {
    final raw = widget.config['profiles'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const [];
  }

  String _osAutoStartCaption() {
    final os =
        (widget.config['host_os'] ?? 'windows').toString().toLowerCase();
    return switch (os) {
      'macos' =>
        '写入 macOS LaunchAgents (~/Library/LaunchAgents/com.iamr0s.agentmcp.plist)',
      'linux' =>
        '写入 Linux XDG 自启 (~/.config/autostart/agent-mcp.desktop)',
      _ =>
        r'写入 Windows 当前用户注册表 (HKCU\Software\Microsoft\Windows\CurrentVersion\Run)',
    };
  }

  Future<void> _applyStartupToggle({
    bool? autoStart,
    bool? launchAtStartup,
    bool? silentStart,
    bool? windowEffect,
    required String toastMsg,
  }) async {
    setState(() {
      if (autoStart != null) _autoStart = autoStart;
      if (launchAtStartup != null) _launchAtStartup = launchAtStartup;
      if (silentStart != null) _silentStart = silentStart;
      if (windowEffect != null) _windowEffect = windowEffect;
    });
    await widget.backend.saveConfig({
      'auto_start': _autoStart,
      'launch_at_startup': _launchAtStartup,
      'silent_start': _silentStart,
      'window_effect': _windowEffect,
    });
    await widget.onRefreshStatus();
    widget.onToast(toastMsg);
  }

  Future<void> _saveBasic({required bool restart}) async {
    if (_savingBasic || _restartingBasic) return;
    setState(() {
      if (restart) {
        _restartingBasic = true;
      } else {
        _savingBasic = true;
      }
    });
    try {
      await runWithMinDuration(() async {
        final bindHosts = _effectiveHosts;
        final patch = <String, dynamic>{
          'server_name': _nameCtrl.text.trim(),
          'tool_prefix': _prefixCtrl.text.trim(),
          'host': bindHosts.first,
          'hosts': bindHosts,
          'port': int.tryParse(_portCtrl.text.trim()) ?? 8000,
          'auto_start': _autoStart,
          'launch_at_startup': _launchAtStartup,
          'silent_start': _silentStart,
          'window_effect': _windowEffect,
        };
        if (_pwdCtrl.text.trim().isNotEmpty) {
          patch['oauth_local_password'] = _pwdCtrl.text.trim();
        }
        await widget.backend.saveConfig(patch);
        _pwdCtrl.clear();
        if (restart) {
          await widget.onRestartService();
        } else {
          await widget.onRefreshStatus();
        }
      });
      widget.onToast(
        restart ? '已保存基础配置并重启服务' : '已保存基础配置（密码修改即时生效）',
      );
    } finally {
      if (mounted) {
        setState(() {
          _savingBasic = false;
          _restartingBasic = false;
        });
      }
    }
  }

  Future<void> _savePerm() async {
    if (_savingPerm) return;
    setState(() => _savingPerm = true);
    try {
      await runWithMinDuration(() async {
        final roots = _parseLines(_rootsCtrl.text);
        await widget.backend.saveConfig({
          'read_only': !_writable,
          'allow_secrets': _allowSecrets,
          'relaxed_command_annotations': _relaxedCmd,
          'roots': roots,
          'log_level': _logLevel,
          'log_file': _logFileCtrl.text.trim().isEmpty
              ? null
              : _logFileCtrl.text.trim(),
        });
        await widget.onRefreshStatus();
      });
      widget.onToast('全局权限与日志策略已热加载生效');
    } finally {
      if (mounted) setState(() => _savingPerm = false);
    }
  }

  Future<void> _saveProfilesList(List<Map<String, dynamic>> next) async {
    await widget.backend.saveConfig({'profiles': next});
    await widget.onRefreshStatus();
  }

  List<String> get _hostLanIpsList {
    return ((widget.config['lan_ips'] as List?) ?? widget.backend.deviceLanIps)
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<void> _openProfileModal([int? editIdx]) async {
    final current = List<Map<String, dynamic>>.from(_profiles);
    final existing =
        (editIdx != null && editIdx >= 0 && editIdx < current.length)
            ? current[editIdx]
            : null;
    final portVal = int.tryParse(_portCtrl.text.trim()) ??
        (int.tryParse('${widget.config['port'] ?? 8000}') ?? 8000);
    final ipOpts = parseHostIpOptions(widget.config, _hostLanIpsList);
    final curBoundHosts = _effectiveHosts;

    final edited = await showClaudeDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => ProfileEditDialog(
        existing: existing,
        serverPort: portVal,
        ipOptions: ipOpts,
        boundHosts: curBoundHosts,
      ),
    );
    if (edited == null) return;

    final syncBindIps = ((edited.remove('_sync_bind_ips') as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();

    if (editIdx != null && editIdx >= 0 && editIdx < current.length) {
      current[editIdx] = edited;
    } else {
      current.add(edited);
    }

    if (syncBindIps.isNotEmpty && !_bindAllInterfaces) {
      final mergedHosts = List<String>.from(curBoundHosts);
      for (final ip in syncBindIps) {
        if (!mergedHosts.contains(ip)) mergedHosts.add(ip);
      }
      setState(() {
        _customHostsBackup = List<String>.from(mergedHosts);
        _setHostControllers(mergedHosts);
      });
      await widget.backend.saveConfig({
        'profiles': current,
        'host': mergedHosts.first,
        'hosts': mergedHosts,
      });
      if (widget.isRunning) {
        await widget.onRestartService();
      } else {
        await widget.onRefreshStatus();
      }
      widget.onToast('入口已保存，并已同步开放所选网卡监听');
      return;
    }

    await _saveProfilesList(current);
    widget.onToast('入口配置已热加载生效');
  }

  Future<void> _openConnectModal(Map<String, dynamic> prof) async {
    final tMap = (widget.tunnelInfo['tunnels'] as Map?) ?? const {};
    final tState = tMap[prof['id']] is Map
        ? Map<String, dynamic>.from(tMap[prof['id']] as Map)
        : const <String, dynamic>{};
    final hostCfg = (widget.config['host'] ?? kLoopbackIpv4).toString();
    final localHost =
        (hostCfg == '0.0.0.0' || hostCfg == '::') ? kLoopbackIpv4 : hostCfg;
    final port = int.tryParse('${widget.config['port'] ?? 8000}') ?? 8000;
    final liveQuick = (tState['live_url'] ?? '').toString().trim();

    final resolvedUrls = resolveUiProfileBaseUrls(
      prof,
      port: port,
      fallbackHost: localHost,
      liveQuickUrl: liveQuick,
    );
    final effectiveList = resolvedUrls.isNotEmpty
        ? resolvedUrls
        : <String>['http://$localHost:$port'];

    await showClaudeDialog<void>(
      context: context,
      builder: (ctx) => ProfileConnectDialog(
        backend: widget.backend,
        profile: prof,
        effectiveBaseUrls: effectiveList,
        onToast: widget.onToast,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final profs = _profiles;
    final ti = widget.tunnelInfo;
    final inst = (ti['install'] as Map?) != null
        ? Map<String, dynamic>.from(ti['install'] as Map)
        : const <String, dynamic>{};
    final tMap = (ti['tunnels'] as Map?) != null
        ? Map<String, dynamic>.from(ti['tunnels'] as Map)
        : const <String, dynamic>{};
    final isAndroidHost =
        (widget.config['host_os'] ?? '').toString().toLowerCase() == 'android';

    final showDesktopWindowToggle =
        widget.backend.hasCustomTitleBar && !widget.backend.isRemoteNodeActive;
    final showBasic = _setupSection == 'basic' || _setupSection == 'all';
    final showProfiles = _setupSection == 'profiles' || _setupSection == 'all';
    final showExpose = _setupSection == 'expose' || _setupSection == 'all';
    final showSecurity = _setupSection == 'security' || _setupSection == 'all';

    return SingleChildScrollView(
      controller: _scrollCtrl,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.only(
        top: widget.topPadding,
        right: 2,
        bottom: (MediaQuery.sizeOf(context).width < 700 ? 124 : 42) + widget.extraBottomPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClaudeStaggeredReveal(
            index: 0,
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 10,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('服务配置', style: serifTitleStyle(c, size: 25)),
                    const SizedBox(height: 2),
                    Text(
                      '按分组收纳基础监听、接入入口、外网联动与安全权限，也可一键展开全部。',
                      style: sansStyle(c, size: 12.5, color: c.muted),
                    ),
                  ],
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ClaudeSegmented<String>(
                    value: _setupSection,
                    items: [
                      ('basic', _basicDirty ? '基础与外观 ●' : '基础与外观'),
                      ('profiles', '接入入口 (${profs.length})'),
                      ('expose', '外网与隧道'),
                      ('security', _permDirty ? '权限与维护 ●' : '权限与维护'),
                      ('all', '全部展开'),
                    ],
                    onChanged: (next) => setState(() => _setupSection = next),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (showBasic) ...[
                ClaudeStaggeredReveal(
                  index: 1,
                  child: ClaudeCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('基础服务与全局密码', style: serifTitleStyle(c, size: 18)),
                        const SizedBox(height: 16),
                        _ResponsiveGridRow(
                          label: 'MCP 服务名称',
                          child: TextField(
                            controller: _nameCtrl,
                            onChanged: (_) => setState(() {}),
                            style: sansStyle(c, size: 13.5, color: c.ink),
                          ),
                        ),
                        _ResponsiveGridRow(
                          label: '工具名前缀 (可选)',
                          trailing: ClaudeButton(
                            label: '用服务名',
                            compact: true,
                            onPressed: () {
                              _prefixCtrl.text = _nameCtrl.text
                                  .trim()
                                  .replaceAll(RegExp(r'[^a-zA-Z0-9_]+'), '_');
                              setState(() {});
                            },
                          ),
                          child: TextField(
                            controller: _prefixCtrl,
                            onChanged: (_) => setState(() {}),
                            style: monoStyle(c, size: 13, color: c.ink),
                            decoration: const InputDecoration(
                              hintText: '留空不加前缀，多台设备防重名可填如 omen_pc',
                            ),
                          ),
                        ),
                        _ResponsiveGridRow(
                          label: '监听 Host / Port',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 10,
                                runSpacing: 8,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  ClaudeSegmented<bool>(
                                    value: _bindAllInterfaces,
                                    items: const [
                                      (true, '全开 0.0.0.0'),
                                      (false, '手动指定'),
                                    ],
                                    onChanged: (all) {
                                      setState(() {
                                        if (all) {
                                          final cur = _hostCtrls
                                              .map((x) => x.text.trim())
                                              .where(
                                                (s) =>
                                                    s.isNotEmpty &&
                                                    s != '0.0.0.0',
                                              )
                                              .toList();
                                          if (cur.isNotEmpty) {
                                            _customHostsBackup = cur;
                                          }
                                        } else {
                                          final hasValid = _hostCtrls.any(
                                            (x) =>
                                                x.text.trim().isNotEmpty &&
                                                x.text.trim() != '0.0.0.0',
                                          );
                                          if (!hasValid) {
                                            _setHostControllers(
                                              _customHostsBackup,
                                            );
                                          }
                                        }
                                        _bindAllInterfaces = all;
                                      });
                                    },
                                  ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '端口',
                                        style: sansStyle(
                                          c,
                                          size: 12.5,
                                          color: c.muted,
                                        ),
                                      ),
                                      const SizedBox(width: 7),
                                      SizedBox(
                                        width: 96,
                                        child: TextField(
                                          controller: _portCtrl,
                                          keyboardType: TextInputType.number,
                                          onChanged: (_) => setState(() {}),
                                          style: monoStyle(
                                            c,
                                            size: 13,
                                            color: c.ink,
                                          ),
                                          decoration: const InputDecoration(
                                            hintText: '8000',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              ClaudeCollapsible(
                                expanded: !_bindAllInterfaces,
                                builder: (_) => Padding(
                                  padding: const EdgeInsets.only(top: 9),
                                  child: AnimatedSize(
                                    duration: ClaudeMotion.duration(
                                      context,
                                      const Duration(milliseconds: 200),
                                    ),
                                    curve: ClaudeMotion.snappySpring,
                                    alignment: Alignment.topLeft,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        for (var i = 0;
                                            i < _hostCtrls.length;
                                            i++) ...[
                                          if (i > 0) const SizedBox(height: 7),
                                          ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              maxWidth: 410,
                                            ),
                                            child: Row(
                                              children: [
                                                Expanded(
                                                  child: TextField(
                                                    controller: _hostCtrls[i],
                                                    focusNode:
                                                        _hostFocusNodes[i],
                                                    onChanged: (_) {
                                                      final cur = _hostCtrls
                                                          .map((x) =>
                                                              x.text.trim())
                                                          .where(
                                                            (s) =>
                                                                s.isNotEmpty &&
                                                                s != '0.0.0.0',
                                                          )
                                                          .toList();
                                                      if (cur.isNotEmpty) {
                                                        _customHostsBackup =
                                                            cur;
                                                      }
                                                      setState(() {});
                                                    },
                                                    style: monoStyle(
                                                      c,
                                                      size: 13,
                                                      color: c.ink,
                                                    ),
                                                    decoration: InputDecoration(
                                                      hintText: i == 0
                                                          ? '127.0.0.1（本机回环）'
                                                          : '如 192.168.1.x 或 Tailscale IP',
                                                    ),
                                                  ),
                                                ),
                                                if (_hostCtrls.length > 1) ...[
                                                  const SizedBox(width: 6),
                                                  ClaudeButton(
                                                    label: '',
                                                    compact: true,
                                                    tooltip: '移除此监听地址',
                                                    leading: const Icon(
                                                      Icons.remove_rounded,
                                                    ),
                                                    onPressed: () =>
                                                        _removeHostRow(i),
                                                  ),
                                                ],
                                                if (i ==
                                                    _hostCtrls.length - 1) ...[
                                                  const SizedBox(width: 6),
                                                  ClaudeButton(
                                                    label: '',
                                                    compact: true,
                                                    variant:
                                                        ClaudeBtnVariant.clay,
                                                    tooltip: '再添加一个监听地址',
                                                    leading: const Icon(
                                                      Icons.add_rounded,
                                                    ),
                                                    onPressed: _addHostRow,
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              ClaudeCollapsible(
                                expanded: _bindAllInterfaces,
                                builder: (_) => Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    '监听全部网卡 0.0.0.0:${_portCtrl.text.trim().isEmpty ? '8000' : _portCtrl.text.trim()}（允许本机、局域网其他设备与容器访问）',
                                    style: sansStyle(
                                      c,
                                      size: 11.5,
                                      color: c.muted,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        _ResponsiveGridRow(
                          label: 'OAuth 2.1 本地密码',
                          trailing: ClaudeButton(
                            label: '随机生成',
                            compact: true,
                            leading: const Icon(Icons.casino_outlined),
                            onPressed: () {
                              _pwdCtrl.text = generateRandomToken('', 14);
                              setState(() {});
                            },
                          ),
                          child: ClaudePasswordField(
                            controller: _pwdCtrl,
                            onChanged: (_) => setState(() {}),
                            hintText: widget.config['has_password'] == true
                                ? '已设置密码（留空保持不变，输入新密码保存即刻生效）'
                                : '用于 OAuth 2.1 客户端网页授权与 /dashboard 登录',
                          ),
                        ),
                        _ResponsiveGridRow(
                          label: '界面主题',
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: ClaudeSegmented<ThemeMode>(
                              value: widget.themeMode,
                              items: const [
                                (ThemeMode.system, '跟随系统'),
                                (ThemeMode.light, '暖纸浅色'),
                                (ThemeMode.dark, '深岩暗色'),
                              ],
                              onChanged: widget.onThemeChanged,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: ShapeDecoration(
                            color: c.recessed,
                            shape: claudeSuperellipse(
                              14,
                              side: BorderSide(color: c.hairline),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (showDesktopWindowToggle) ...[
                                _StartupSwitchRow(
                                  palette: c,
                                  title: '窗口云母与毛玻璃透光 (Win11 Mica)',
                                  subtitle:
                                      '启用 Windows 11 原生 DWM 云母材质背板与半透明侧边栏叠色（支持实时切换）',
                                  value: _windowEffect,
                                  onChanged: (v) => _applyStartupToggle(
                                    windowEffect: v,
                                    toastMsg: v
                                        ? '已启用 Win11 云母透光背板'
                                        : '已切换为纯色纸感背板',
                                  ),
                                ),
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                  child: Divider(color: c.hairline, height: 1),
                                ),
                              ],
                              if (isAndroidHost) ...[
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.notifications_active_outlined,
                                      size: 18,
                                      color: c.clay,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '通知栏常驻保活与快捷启停',
                                            style: sansStyle(
                                              c,
                                              size: 13.5,
                                              weight: FontWeight.w600,
                                              color: c.ink,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            '手机锁屏或切到后台时保持本机服务不断连，下拉通知栏即可随时停止或重启。',
                                            style: sansStyle(
                                              c,
                                              size: 12,
                                              color: c.muted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                  child: Divider(color: c.hairline, height: 1),
                                ),
                              ] else ...[
                                _StartupSwitchRow(
                                  palette: c,
                                  title: '开机自动启动应用',
                                  subtitle:
                                      '${_osAutoStartCaption()}；配合静默模式自动附带 --silent 参数',
                                  value: _launchAtStartup,
                                  onChanged: (v) => _applyStartupToggle(
                                    launchAtStartup: v,
                                    toastMsg: v
                                        ? (_silentStart
                                            ? '已开启系统开机静默自启'
                                            : '已开启系统开机自启')
                                        : '已移除系统开机自启项',
                                  ),
                                ),
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                  child: Divider(color: c.hairline, height: 1),
                                ),
                                _StartupSwitchRow(
                                  palette: c,
                                  title: '静默启动至后台托盘（不弹出窗口）',
                                  subtitle:
                                      '启动时跳过主窗口绘制、零闪烁驻留系统托盘（支持命令行 --silent，点击托盘或再次运行可唤醒）',
                                  value: _silentStart,
                                  onChanged: (v) => _applyStartupToggle(
                                    silentStart: v,
                                    toastMsg: v
                                        ? '已开启静默驻留托盘启动模式'
                                        : '已恢复常规窗口启动模式',
                                  ),
                                ),
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                  child: Divider(color: c.hairline, height: 1),
                                ),
                              ],
                              _StartupSwitchRow(
                                palette: c,
                                title: '启动后自动开启 MCP 服务与隧道',
                                subtitle:
                                    '进程拉起后立即监听 HTTP 端口并自动连接已启用的公网隧道',
                                value: _autoStart,
                                onChanged: (v) => _applyStartupToggle(
                                  autoStart: v,
                                  toastMsg: v
                                      ? '已开启启动自动运行 MCP 服务'
                                      : '已关闭启动自动运行 MCP 服务',
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        Divider(color: c.hairline, height: 1),
                        const SizedBox(height: 14),
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            Text(
                              _basicDirty
                                  ? '● 有未保存的修改（改端口或前缀建议保存并重启）'
                                  : '修改密码保存即生效；修改监听端口建议保存并重启',
                              style: sansStyle(
                                c,
                                size: 12.5,
                                color: _basicDirty ? c.clay : c.meta,
                                weight: _basicDirty
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                ClaudeButton(
                                  label: _savingBasic ? '保存中...' : '保存基础配置',
                                  compact: true,
                                  loading: _savingBasic,
                                  leading: const Icon(Icons.save_outlined),
                                  onPressed: _restartingBasic
                                      ? null
                                      : () => _saveBasic(restart: false),
                                ),
                                ClaudeButton(
                                  label: _restartingBasic ? '重启中...' : '保存并重启',
                                  compact: true,
                                  loading: _restartingBasic,
                                  leading: const Icon(Icons.restart_alt_rounded),
                                  variant: ClaudeBtnVariant.ink,
                                  onPressed: _savingBasic
                                      ? null
                                      : () => _saveBasic(restart: true),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                if (isAndroidHost) ...[
                  const SizedBox(height: 16),
                  ClaudeStaggeredReveal(
                    index: 2,
                    child: AndroidPrivilegeCard(
                      backend: widget.backend,
                      config: widget.config,
                      onRefreshStatus: widget.onRefreshStatus,
                      onToast: widget.onToast,
                    ),
                  ),
                ],
          ],
          if (showProfiles) ...[
                if (showBasic) const SizedBox(height: 16),
                ClaudeStaggeredReveal(
                  index: 2,
                  child: ClaudeCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            Text(
                              '传输、鉴权与权限入口',
                              style: serifTitleStyle(c, size: 18),
                            ),
                            ClaudeButton(
                              label: '添加入口',
                              compact: true,
                              leading: const Icon(Icons.add_rounded),
                              variant: ClaudeBtnVariant.clay,
                              onPressed: () => _openProfileModal(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '为不同 AI 客户端分配独立的连接方式与目录权限：例如主力编程助手开放代码读写，远程网页端开启登录验证或只读目录，保存立即生效。',
                          style: sansStyle(
                            c,
                            size: 13,
                            color: c.muted,
                            height: 1.56,
                          ),
                        ),
                        const SizedBox(height: 14),
                        for (var i = 0; i < profs.length; i++) ...[
                          if (i > 0) const SizedBox(height: 10),
                          _buildProfileItem(c, profs, i, tMap),
                        ],
                      ],
                    ),
                  ),
                ),
          ],
          if (showExpose) ...[
                if (showBasic || showProfiles) const SizedBox(height: 16),
                ClaudeStaggeredReveal(
                  index: 2,
                  child: TailscaleExposureSettingsCard(
                    backend: widget.backend,
                    config: widget.config,
                    exposureSummary: widget.exposureSummary,
                    onRefreshStatus: widget.onRefreshStatus,
                    onToast: widget.onToast,
                  ),
                ),
                const SizedBox(height: 16),
                ClaudeStaggeredReveal(
                  index: 3,
                  child: ClaudeCard(
                    child: _buildCloudflaredCard(c, ti, inst, tMap),
                  ),
                ),
          ],
          if (showSecurity) ...[
                if (showBasic || showProfiles || showExpose)
                  const SizedBox(height: 16),
                ClaudeStaggeredReveal(
                  index: 4,
                  child: ClaudeCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('全局默认权限与日志', style: serifTitleStyle(c, size: 18)),
                        const SizedBox(height: 14),
                        Wrap(
                          spacing: 20,
                          runSpacing: 8,
                          children: [
                            ClaudeCheckToggle(
                              value: _writable,
                              label: '允许写入与执行',
                              onChanged: (v) => setState(() => _writable = v),
                            ),
                            ClaudeCheckToggle(
                              value: _allowSecrets,
                              label: '允许读取敏感文件',
                              onChanged: (v) =>
                                  setState(() => _allowSecrets = v),
                            ),
                            ClaudeCheckToggle(
                              value: _relaxedCmd,
                              label: '客户端免弹窗声明（全工具静默注解）',
                              onChanged: (v) => setState(() => _relaxedCmd = v),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        _ResponsiveGridRow(
                          label: '默认目录白名单\n(留空 = 全盘)',
                          child: TextField(
                            controller: _rootsCtrl,
                            maxLines: 2,
                            onChanged: (_) => setState(() {}),
                            style: monoStyle(c, size: 12.5, color: c.ink),
                            decoration: const InputDecoration(
                              hintText: '每行一个目录路径，留空允许全盘访问',
                            ),
                          ),
                        ),
                        _ResponsiveGridRow(
                          label: '日志等级 / 日志文件',
                          child: Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              ClaudeDropMenu<String>(
                                value: _logLevel,
                                leadingIcon: Icons.tune_rounded,
                                minMenuWidth: 168,
                                items: const [
                                  ClaudeDropMenuItem(
                                    value: 'DEBUG',
                                    label: 'DEBUG · 调试',
                                    icon: Icons.bug_report_outlined,
                                  ),
                                  ClaudeDropMenuItem(
                                    value: 'INFO',
                                    label: 'INFO · 标准',
                                    icon: Icons.info_outline_rounded,
                                  ),
                                  ClaudeDropMenuItem(
                                    value: 'WARNING',
                                    label: 'WARN · 告警',
                                    icon: Icons.warning_amber_rounded,
                                  ),
                                  ClaudeDropMenuItem(
                                    value: 'ERROR',
                                    label: 'ERROR · 仅异常',
                                    icon: Icons.error_outline_rounded,
                                  ),
                                ],
                                onChanged: (v) => setState(() => _logLevel = v),
                              ),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minWidth: 160,
                                  maxWidth: 260,
                                ),
                                child: TextField(
                                  controller: _logFileCtrl,
                                  onChanged: (_) => setState(() {}),
                                  style: monoStyle(c, size: 12.5, color: c.ink),
                                  decoration: const InputDecoration(
                                    hintText: '可选: logs/mcp.log',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Divider(color: c.hairline, height: 1),
                        const SizedBox(height: 14),
                        Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            Text(
                              _permDirty
                                  ? '● 有未保存的权限修改'
                                  : '保存后全局默认权限即时热加载生效',
                              style: sansStyle(
                                c,
                                size: 12.5,
                                color: _permDirty ? c.clay : c.meta,
                                weight: _permDirty
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                            ClaudeButton(
                              label: _savingPerm ? '保存中...' : '保存权限与日志',
                              compact: true,
                              loading: _savingPerm,
                              leading: const Icon(Icons.save_outlined),
                              onPressed: _savePerm,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ClaudeStaggeredReveal(
                  index: 5,
                  child: ClaudeCard(
                    child: _buildStorageCard(c),
                  ),
                ),
          ],
              ],
            ),
          );
  }

  Widget _buildProfileItem(
    ClaudePalette c,
    List<Map<String, dynamic>> profs,
    int idx,
    Map<String, dynamic> tMap,
  ) {
    final p = profs[idx];
    final pid = (p['id'] ?? 'default').toString();
    final enabled = p['enabled'] != false;
    final tMode = (p['tunnel_mode'] ?? 'none').toString();
    final hasTun = tMode == 'token' || tMode == 'quick';
    final tState = tMap[pid] is Map
        ? Map<String, dynamic>.from(tMap[pid] as Map)
        : const <String, dynamic>{};
    final tunRunning = tState['running'] == true;
    final liveQuick =
        tMode == 'quick' ? (tState['live_url'] ?? '').toString() : '';
    final tunReady =
        !hasTun || (tMode == 'quick' ? liveQuick.isNotEmpty : tunRunning);

    final hostCfg = (widget.config['host'] ?? kLoopbackIpv4).toString();
    final localHost =
        (hostCfg == '0.0.0.0' || hostCfg == '::') ? kLoopbackIpv4 : hostCfg;
    final portVal = int.tryParse('${widget.config['port'] ?? 8000}') ?? 8000;
    final trMode = (p['transport'] ?? 'dual').toString().toLowerCase();
    final epSuffix = trMode == 'sse' ? '/sse' : '/mcp';

    final resolvedBases = resolveUiProfileBaseUrls(
      p,
      port: portVal,
      fallbackHost: localHost,
      liveQuickUrl: liveQuick,
    );
    final copyOptions = tunReady
        ? buildProfileEndpointCopyOptions(p, resolvedBases)
        : const <EndpointCopyOption>[];

    String endpointText;
    if (hasTun) {
      if (tMode == 'quick') {
        endpointText = liveQuick.isNotEmpty
            ? '$liveQuick$epSuffix'
            : '隧道未启动（点击「开启隧道」自动分配公网 trycloudflare 地址）';
      } else {
        final b = (p['base_url'] ?? '').toString();
        endpointText = tunRunning
            ? (b.isNotEmpty ? '$b$epSuffix' : 'Token 隧道已运行（请在编辑中填写绑定域名）')
            : (b.isNotEmpty ? '$b$epSuffix（隧道未启动）' : '隧道未启动');
      }
    } else {
      endpointText = resolvedBases
          .map((u) => '${u.replaceAll(RegExp(r'/+$'), '')}$epSuffix')
          .join('\n');
    }

    const authLabels = {
      'oauth-local': 'OAuth 2.1',
      'bearer': 'Bearer Key',
      'none': '无鉴权',
    };
    final authMode = (p['auth_mode'] ?? 'oauth-local').toString();
    final isLiveActive = widget.isRunning && enabled && tunReady;

    return AnimatedOpacity(
      duration: ClaudeMotion.duration(context, ClaudeMotion.base),
      curve: ClaudeMotion.editorialOut,
      opacity: enabled ? 1.0 : 0.58,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: ShapeDecoration(
          color: c.recessed,
          shape: claudeSuperellipse(
            15,
            side: BorderSide(color: c.hairline),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ClaudeStatusDot(
                      color: isLiveActive ? c.sage : c.meta,
                      pulsing: isLiveActive,
                      size: 7.5,
                    ),
                    Text(
                      (p['name'] ?? '入口').toString(),
                      style: serifTitleStyle(c, size: 16.5),
                    ),
                    ClaudePill(
                      text: (p['transport'] ?? 'dual').toString().toUpperCase(),
                      fg: c.sage,
                      bg: c.sageBg,
                    ),
                    ClaudePill(
                      text: authLabels[authMode] ?? authMode,
                      fg: c.clay,
                      bg: c.clay.withValues(alpha: 0.12),
                      border: c.clay.withValues(alpha: 0.24),
                    ),
                    if (hasTun)
                      ClaudePill(
                        leading: const Icon(Icons.cloud_outlined),
                        text: tunRunning
                            ? (tMode == 'quick'
                                ? (liveQuick.isNotEmpty ? 'Quick 在线' : '分配中...')
                                : 'Token 在线')
                            : '隧道未启动',
                        mono: false,
                        bg: c.paper2,
                      ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ClaudeSwitch(
                      value: enabled,
                      onChanged: (v) async {
                        final next = List<Map<String, dynamic>>.from(profs);
                        next[idx] = Map<String, dynamic>.from(p)
                          ..['enabled'] = v;
                        await _saveProfilesList(next);
                      },
                    ),
                    if (hasTun)
                      ClaudeButton(
                        label: _togglingTunnels.contains(pid)
                            ? (tunRunning ? '停止中...' : '开启中...')
                            : (tunRunning ? '停止隧道' : '开启隧道'),
                        compact: true,
                        loading: _togglingTunnels.contains(pid),
                        leading: Icon(
                          tunRunning
                              ? Icons.stop_circle_outlined
                              : Icons.cloud_queue_rounded,
                        ),
                        onPressed: () async {
                          setState(() => _togglingTunnels.add(pid));
                          try {
                            await runWithMinDuration(() async {
                              if (tunRunning) {
                                await widget.backend.stopTunnel(pid);
                                widget.onToast('已停止隧道');
                              } else {
                                final r = await widget.backend.startTunnel(pid);
                                if (r['ok'] == true) {
                                  widget.onToast('隧道已启动，正在连接...');
                                } else {
                                  widget.onToast(
                                      r['error']?.toString() ?? '启动失败');
                                }
                              }
                              await widget.onRefreshStatus();
                            });
                          } finally {
                            if (mounted) {
                              setState(() => _togglingTunnels.remove(pid));
                            }
                          }
                        },
                      ),
                    if (tunReady && copyOptions.isNotEmpty)
                      EndpointCopyDropButton(
                        label: '复制地址',
                        options: copyOptions,
                        onSelect: (opt) {
                          Clipboard.setData(ClipboardData(text: opt.url));
                          widget.onToast(
                            opt.isCopyAll
                                ? '已复制该入口全部地址'
                                : '已复制 (${opt.badge}): ${opt.url}',
                          );
                        },
                      ),
                    ClaudeButton(
                      label: '连接与检测',
                      compact: true,
                      leading: const Icon(Icons.link_rounded),
                      onPressed: tunReady ? () => _openConnectModal(p) : null,
                    ),
                    ClaudeButton(
                      label: '编辑',
                      compact: true,
                      variant: ClaudeBtnVariant.ghost,
                      onPressed: () => _openProfileModal(idx),
                    ),
                    if (profs.length > 1)
                      ClaudeButton(
                        label: '删除',
                        compact: true,
                        variant: ClaudeBtnVariant.ghost,
                        onPressed: () async {
                          final ok = await showClaudeConfirmDialog(
                            context,
                            title: '删除入口',
                            message: '确定删除入口「${p['name']}」吗？',
                            confirmText: '删除',
                            destructive: true,
                          );
                          if (ok) {
                            final next = List<Map<String, dynamic>>.from(profs)
                              ..removeAt(idx);
                            await _saveProfilesList(next);
                          }
                        },
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7.5),
              decoration: ShapeDecoration(
                color: c.paper2,
                shape: claudeSuperellipse(
                  10,
                  side: BorderSide(color: c.hairline),
                ),
              ),
              child: SelectableText(
                endpointText,
                style: monoStyle(
                  c,
                  size: 12,
                  color: tunReady ? c.inkSoft : c.meta,
                ),
              ),
            ),
            ClaudeCollapsible(
              expanded: (tState['error'] ?? '').toString().isNotEmpty,
              builder: (_) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Cloudflared: ${tState['error']}',
                  style: monoStyle(c, size: 11.5, color: c.danger),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  p['inherit_permissions'] != false
                      ? Icons.shield_outlined
                      : (p['read_only'] == true
                          ? Icons.lock_outline_rounded
                          : Icons.tune_rounded),
                  size: 13.5,
                  color: c.meta,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    p['inherit_permissions'] != false
                        ? '权限策略：继承全局默认权限'
                        : [
                            p['read_only'] == true ? '仅只读' : '可写执行',
                            if (p['allow_secrets'] == true) '允许敏感文件',
                            if (p['relaxed_command_annotations'] == true)
                              '免弹窗声明',
                            ((p['roots'] as List?)?.isNotEmpty ?? false)
                                ? '限定 ${(p['roots'] as List).length} 个目录'
                                : '全盘访问',
                          ].join(' · '),
                    style: sansStyle(c, size: 12, color: c.meta, tabular: true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCloudflaredCard(
    ClaudePalette c,
    Map<String, dynamic> ti,
    Map<String, dynamic> inst,
    Map<String, dynamic> tMap,
  ) {
    final installed = ti['installed'] == true;
    final ver = (ti['version'] ?? '').toString();
    final activeDl = inst['active'] == true;
    final pausedDl = inst['paused'] == true;
    final pct = ((inst['percent'] as num?)?.toDouble() ?? 0).clamp(0.0, 100.0);
    final dlUrl = (ti['download_url'] ?? '').toString();
    final activeCnt =
        tMap.values.where((x) => x is Map && x['running'] == true).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 8,
          children: [
            Text('Cloudflared 隧道组件', style: serifTitleStyle(c, size: 18)),
            ClaudePill(
              leading: Icon(
                installed ? Icons.check_circle_outline_rounded : Icons.cloud_off,
              ),
              text: activeDl
                  ? '下载中 ${pct.toInt()}%'
                  : (pausedDl
                      ? '已暂停 ${pct.toInt()}%'
                      : (installed
                          ? '已安装${ver.isNotEmpty ? ' v$ver' : ''}'
                          : '未安装')),
              fg: installed ? c.sage : c.clay,
              bg: installed ? c.sageBg : c.clay.withValues(alpha: 0.12),
              border: installed ? null : c.clay.withValues(alpha: 0.24),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (activeDl || pausedDl) ...[
          Text(
            (inst['status'] ?? '正在下载 cloudflared...').toString(),
            style: sansStyle(c, size: 12.5, color: c.muted),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: pct / 100.0),
              duration: ClaudeMotion.duration(context, ClaudeMotion.base),
              curve: ClaudeMotion.editorialOut,
              builder: (ctx, val, _) => LinearProgressIndicator(
                value: val,
                minHeight: 7,
                backgroundColor: c.paper3,
                valueColor: AlwaysStoppedAnimation<Color>(c.clay),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (pausedDl)
                ClaudeButton(
                  label: '继续下载',
                  compact: true,
                  leading: const Icon(Icons.play_arrow_rounded),
                  variant: ClaudeBtnVariant.clay,
                  onPressed: () async {
                    await widget.backend.installCloudflared(resume: true);
                    await widget.onRefreshStatus();
                  },
                )
              else
                ClaudeButton(
                  label: '暂停',
                  compact: true,
                  leading: const Icon(Icons.pause_rounded),
                  onPressed: () async {
                    await widget.backend.pauseCloudflared();
                    await widget.onRefreshStatus();
                  },
                ),
              ClaudeButton(
                label: '取消',
                compact: true,
                leading: const Icon(Icons.close_rounded),
                onPressed: () async {
                  await widget.backend.cancelCloudflared();
                  await widget.onRefreshStatus();
                },
              ),
            ],
          ),
        ] else if (installed) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: ShapeDecoration(
              color: c.recessed,
              shape: claudeSuperellipse(
                10,
                side: BorderSide(color: c.hairline),
              ),
            ),
            child: SelectableText(
              (ti['binary'] ?? 'cloudflared').toString(),
              style: monoStyle(c, size: 12),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Text(
                activeCnt > 0
                    ? '当前有 $activeCnt 条隧道运行中'
                    : '已就绪，可在上方任意入口启用 Token 或 Quick 隧道',
                style: sansStyle(c, size: 12.5, color: c.muted, tabular: true),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ClaudeButton(
                    label: '更新到最新版',
                    compact: true,
                    leading: const Icon(Icons.refresh_rounded),
                    onPressed: () async {
                      await widget.backend.installCloudflared(force: true);
                      await widget.onRefreshStatus();
                    },
                  ),
                  ClaudeButton(
                    label: '导入替换',
                    compact: true,
                    leading: const Icon(Icons.upload_file_outlined),
                    onPressed: () async {
                      final r = await widget.backend.pickAndImportCloudflared();
                      if (r != null) {
                        widget.onToast(
                          (r['message'] ?? r['error'] ?? '').toString(),
                        );
                        await widget.onRefreshStatus();
                      }
                    },
                  ),
                  if (ti['local_managed'] == true)
                    ClaudeButton(
                      label: '移除本地副本',
                      compact: true,
                      variant: ClaudeBtnVariant.ghost,
                      onPressed: () async {
                        final r = await widget.backend.uninstallCloudflared();
                        widget.onToast(
                          (r['message'] ?? r['error'] ?? '').toString(),
                        );
                        await widget.onRefreshStatus();
                      },
                    ),
                ],
              ),
            ],
          ),
        ] else ...[
          Text(
            '未检测到 cloudflared。可一键在线下载到项目 bin/ 目录（支持断点续传），或从官方地址手动下载后导入。',
            style: sansStyle(c, size: 13, color: c.muted, height: 1.56),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ClaudeButton(
                label: '一键下载 cloudflared',
                compact: true,
                leading: const Icon(Icons.download_rounded),
                variant: ClaudeBtnVariant.clay,
                onPressed: () async {
                  await widget.backend.installCloudflared();
                  await widget.onRefreshStatus();
                },
              ),
              ClaudeButton(
                label: '选择文件导入',
                compact: true,
                leading: const Icon(Icons.upload_file_outlined),
                onPressed: () async {
                  final r = await widget.backend.pickAndImportCloudflared();
                  if (r != null) {
                    widget.onToast(
                      (r['message'] ?? r['error'] ?? '').toString(),
                    );
                    await widget.onRefreshStatus();
                  }
                },
              ),
              if (dlUrl.isNotEmpty)
                ClaudeButton(
                  label: '复制官方直链',
                  compact: true,
                  leading: const Icon(Icons.copy_rounded),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: dlUrl));
                    widget.onToast('已复制官方下载地址');
                  },
                ),
            ],
          ),
        ],
        ClaudeCollapsible(
          expanded: (inst['error'] ?? '').toString().isNotEmpty,
          builder: (_) => Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              inst['error'].toString(),
              style: monoStyle(c, size: 11.5, color: c.danger),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStorageCard(ClaudePalette c) {
    final st = widget.storageStats;
    const labels = [
      ('config', '配置文件 (config/)'),
      ('data', '运行数据 (data/)'),
      ('cache', '缓存目录 (cache/)'),
      ('logs', '日志文件 (logs/)'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          runSpacing: 8,
          children: [
            Text('存储与维护', style: serifTitleStyle(c, size: 18)),
            ClaudeButton(
              label: _refreshingStorage ? '刷新中...' : '刷新占用',
              compact: true,
              loading: _refreshingStorage,
              leading: const Icon(Icons.refresh_rounded),
              onPressed: () async {
                setState(() => _refreshingStorage = true);
                try {
                  await runWithMinDuration(widget.onRefreshStorage);
                  widget.onToast('已更新磁盘占用统计');
                } finally {
                  if (mounted) setState(() => _refreshingStorage = false);
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (ctx, sbox) {
            final cols = sbox.maxWidth < 380
                ? 1
                : (sbox.maxWidth < 720 ? 2 : 4);
            const gap = 10.0;
            final tileW = (sbox.maxWidth - gap * (cols - 1)) / cols;

            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: labels.map((item) {
                final d = st[item.$1] is Map
                    ? Map<String, dynamic>.from(st[item.$1] as Map)
                    : const <String, dynamic>{};
                final sizeText = formatBytesHuman(d['bytes'] as num?);
                return SizedBox(
                  width: tileW,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: ShapeDecoration(
                      color: c.recessed,
                      shape: claudeSuperellipse(
                        13,
                        side: BorderSide(color: c.hairline),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.$2,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: sansStyle(c, size: 11.5, color: c.muted),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          sizeText,
                          maxLines: 1,
                          style: monoStyle(
                            c,
                            size: 15,
                            color: c.ink,
                            weight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${d['files'] ?? 0} 个文件',
                          style: sansStyle(
                            c,
                            size: 11,
                            color: c.meta,
                            tabular: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ClaudeButton(
              label: _cleaningTarget == 'cache' ? '清理中...' : '清理缓存',
              compact: true,
              loading: _cleaningTarget == 'cache',
              leading: const Icon(Icons.cleaning_services_outlined),
              onPressed: _cleaningTarget != null
                  ? null
                  : () async {
                      setState(() => _cleaningTarget = 'cache');
                      try {
                        final r = await runWithMinDuration(
                          () => widget.backend.cleanStorageTarget('cache'),
                        );
                        widget.onToast((r['message'] ?? '已清理缓存').toString());
                        await widget.onRefreshStorage();
                      } finally {
                        if (mounted) setState(() => _cleaningTarget = null);
                      }
                    },
            ),
            ClaudeButton(
              label: _cleaningTarget == 'logs' ? '清理中...' : '清理日志',
              compact: true,
              loading: _cleaningTarget == 'logs',
              leading: const Icon(Icons.notes_rounded),
              onPressed: _cleaningTarget != null
                  ? null
                  : () async {
                      setState(() => _cleaningTarget = 'logs');
                      try {
                        final r = await runWithMinDuration(
                          () => widget.backend.cleanStorageTarget('logs'),
                        );
                        widget.onToast((r['message'] ?? '已清理日志').toString());
                        await widget.onRefreshStorage();
                      } finally {
                        if (mounted) setState(() => _cleaningTarget = null);
                      }
                    },
            ),
            ClaudeButton(
              label: _cleaningTarget == 'oauth' ? '清空中...' : '清空 OAuth 会话',
              compact: true,
              loading: _cleaningTarget == 'oauth',
              leading: const Icon(Icons.key_off_outlined),
              onPressed: _cleaningTarget != null
                  ? null
                  : () async {
                      final ok = await showClaudeConfirmDialog(
                        context,
                        title: '清空 OAuth 会话',
                        message:
                            '清空后已绑定的远程客户端（如 Gemini 网页端）需要重新授权登录，确定继续？',
                        confirmText: '清空会话',
                        destructive: true,
                      );
                      if (ok) {
                        setState(() => _cleaningTarget = 'oauth');
                        try {
                          final r = await runWithMinDuration(
                            () => widget.backend.cleanStorageTarget('oauth'),
                          );
                          widget.onToast((r['message'] ?? '已清空').toString());
                          await widget.onRefreshStorage();
                        } finally {
                          if (mounted) setState(() => _cleaningTarget = null);
                        }
                      }
                    },
            ),
          ],
        ),
      ],
    );
  }
}

class _ResponsiveGridRow extends StatelessWidget {
  final String label;
  final Widget child;
  final Widget? trailing;

  const _ResponsiveGridRow({
    required this.label,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    return LayoutBuilder(
      builder: (ctx, box) {
        final compact = box.maxWidth < 480;
        if (compact) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        label.replaceAll('\n', ' '),
                        style: sansStyle(
                          c,
                          size: 13,
                          weight: FontWeight.w500,
                          color: c.muted,
                        ),
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 8),
                      trailing!,
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                child,
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox(
                width: 162,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    label,
                    style: sansStyle(c, size: 13, color: c.muted),
                  ),
                ),
              ),
              Expanded(child: child),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        );
      },
    );
  }
}

class _StartupSwitchRow extends StatelessWidget {
  final ClaudePalette palette;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _StartupSwitchRow({
    required this.palette,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(!value),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: sansStyle(
                      palette,
                      size: 13.5,
                      color: palette.ink,
                      weight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2.5),
                  Text(
                    subtitle,
                    style: sansStyle(
                      palette,
                      size: 12,
                      color: palette.muted,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            ClaudeSwitch(
              value: value,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

