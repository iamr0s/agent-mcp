import 'package:flutter/foundation.dart';
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
  final bool dynamicColor;
  final bool dynamicColorSupported;
  final ValueChanged<bool>? onDynamicColorChanged;
  final Future<void> Function() onRefreshStatus;
  final Future<void> Function() onRefreshStorage;
  final Future<void> Function() onRestartService;
  final ValueChanged<String> onToast;
  final double topPadding;
  final double extraBottomPadding;
  final UpdatePreferences updatePrefs;
  final bool checkingUpdate;
  final UpdateInfo? latestUpdate;
  final Future<void> Function(UpdatePreferences next)? onUpdatePrefsChanged;
  final Future<void> Function()? onCheckUpdate;
  final ValueListenable<String?>? requestedSectionSignal;
  final VoidCallback? onConsumeRequestedSection;

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
    this.dynamicColor = false,
    this.dynamicColorSupported = false,
    this.onDynamicColorChanged,
    required this.onRefreshStatus,
    required this.onRefreshStorage,
    required this.onRestartService,
    required this.onToast,
    this.topPadding = 0.0,
    this.extraBottomPadding = 0.0,
    this.updatePrefs = const UpdatePreferences(),
    this.checkingUpdate = false,
    this.latestUpdate,
    this.onUpdatePrefsChanged,
    this.onCheckUpdate,
    this.requestedSectionSignal,
    this.onConsumeRequestedSection,
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
  final _mirrorCtrl = TextEditingController();
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
  bool _showMirrorConfig = false;
  String? _cleaningTarget;
  String _setupSection = 'basic';
  bool _sectionNavReverse = false;
  bool _mobileInDetail = false;
  String? _activeInlineEdit;
  final Set<String> _togglingTunnels = <String>{};

  static const List<String> _sectionOrder = <String>[
    'basic',
    'profiles',
    'expose',
    'security',
    'about',
    'all',
  ];

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
    final normCfgLog = {'DEBUG', 'INFO', 'WARNING', 'ERROR'}.contains(cfgLog)
        ? cfgLog
        : 'INFO';
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
    _mirrorCtrl.text = widget.updatePrefs.mirrorPrefix;
    _syncFromConfig(force: true);
    widget.requestedSectionSignal?.addListener(_handleRequestedSection);
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleRequestedSection());
  }

  @override
  void didUpdateWidget(covariant ServiceSetupPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.requestedSectionSignal != widget.requestedSectionSignal) {
      oldWidget.requestedSectionSignal?.removeListener(_handleRequestedSection);
      widget.requestedSectionSignal?.addListener(_handleRequestedSection);
    }
    if (oldWidget.updatePrefs.mirrorPrefix != widget.updatePrefs.mirrorPrefix &&
        _mirrorCtrl.text != widget.updatePrefs.mirrorPrefix) {
      _mirrorCtrl.text = widget.updatePrefs.mirrorPrefix;
    }
    _syncFromConfig(force: false);
  }

  void _handleRequestedSection() {
    final target = widget.requestedSectionSignal?.value;
    if (target == null || target.trim().isEmpty || !mounted) return;
    widget.onConsumeRequestedSection?.call();
    _selectSetupSection(target.trim(), openMobileDetail: true);
  }

  void _selectSetupSection(String next, {bool openMobileDetail = false}) {
    if (_setupSection == next && (!openMobileDetail || _mobileInDetail)) {
      return;
    }
    final oldIdx = _sectionOrder.indexOf(_setupSection);
    final newIdx = _sectionOrder.indexOf(next);
    if (_scrollCtrl.hasClients && _scrollCtrl.offset > 0) {
      _scrollCtrl.jumpTo(0);
    }
    setState(() {
      _sectionNavReverse =
          oldIdx != -1 && newIdx != -1 ? newIdx < oldIdx : false;
      _setupSection = next;
      _activeInlineEdit = null;
      if (openMobileDetail) {
        _mobileInDetail = true;
      }
    });
  }

  void _toggleInlineEdit(String key) {
    setState(() {
      if (_activeInlineEdit == key) {
        _pwdCtrl.clear();
        _syncFromConfig(force: true);
        _activeInlineEdit = null;
      } else {
        _activeInlineEdit = key;
      }
    });
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

  void _discardUnsavedChanges() {
    setState(() {
      _pwdCtrl.clear();
      _activeInlineEdit = null;
      _syncFromConfig(force: true);
    });
    widget.onToast('已还原未保存的修改');
  }

  @override
  void dispose() {
    widget.requestedSectionSignal?.removeListener(_handleRequestedSection);
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
    _mirrorCtrl.dispose();
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
    final os = (widget.config['host_os'] ?? 'windows').toString().toLowerCase();
    return switch (os) {
      'macos' =>
        '写入 macOS LaunchAgents (~/Library/LaunchAgents/com.iamr0s.agentmcp.plist)',
      'linux' => '写入 Linux XDG 自启 (~/.config/autostart/agent-mcp.desktop)',
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

  Future<void> _saveAllDirty({required bool restart}) async {
    final wasBasic = _basicDirty;
    final wasPerm = _permDirty;
    if (wasPerm) {
      await _savePerm();
    }
    if (wasBasic || restart) {
      await _saveBasic(restart: restart);
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

  String _formatLastChecked(UpdatePreferences prefs) {
    final dt = prefs.lastCheckedAt?.toLocal();
    if (dt == null) return '尚未检查过更新';
    String pad(int v) => v.toString().padLeft(2, '0');
    return '上次检查：${dt.year}-${pad(dt.month)}-${pad(dt.day)} ${pad(dt.hour)}:${pad(dt.minute)}';
  }

  Widget _buildAboutAndUpdateSection(ClaudePalette c) {
    final prefs = widget.updatePrefs;
    final curVer = widget.backend.currentAppVersion;
    final latest = widget.latestUpdate;
    final hasNewer =
        latest != null && compareSemVer(latest.version, curVer) > 0;
    final hasMirror = prefs.mirrorPrefix.trim().isNotEmpty;
    final showMirror = _showMirrorConfig || hasMirror;
    final osName =
        (widget.config['host_os'] ?? 'windows').toString().toUpperCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: ShapeDecoration(
            color: c.paper2,
            shape: claudeSuperellipse(12, side: BorderSide(color: c.hairline)),
          ),
          child: LayoutBuilder(
            builder: (ctx, box) {
              final isNarrow = box.maxWidth < 480;
              final badge = Stack(
                clipBehavior: Clip.none,
                children: [
                  const ClaudeSparkIcon(size: 46),
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 15,
                      height: 15,
                      decoration: BoxDecoration(
                        color: hasNewer ? c.clay : c.sage,
                        shape: BoxShape.circle,
                        border: Border.all(color: c.paper2, width: 2),
                      ),
                      child: Icon(
                        hasNewer
                            ? Icons.arrow_upward_rounded
                            : Icons.check_rounded,
                        size: 9,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              );

              final metaCol = Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          'Agent MCP',
                          style: sansStyle(
                            c,
                            size: 17,
                            weight: FontWeight.w700,
                            color: c.ink,
                          ),
                        ),
                        ClaudePill(
                          text: 'v$curVer',
                          fg: c.clay,
                          bg: c.clay.withValues(alpha: 0.12),
                        ),
                        ClaudePill(
                          text: hasNewer ? '发现 v${latest.version}' : '已是最新',
                          mono: false,
                          fg: hasNewer ? c.clay : c.sage,
                          bg: hasNewer
                              ? c.clay.withValues(alpha: 0.14)
                              : c.sageBg,
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '$osName Native · Impeller GPU · OAuth 2.1 动态网关',
                      style: sansStyle(c, size: 12.2, color: c.inkSoft),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _formatLastChecked(prefs),
                      style: monoStyle(c, size: 11.4, color: c.muted),
                    ),
                  ],
                ),
              );

              final actionsWrap = Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ClaudeButton(
                    label: 'GitHub Releases',
                    compact: true,
                    variant: ClaudeBtnVariant.neutral,
                    leading: const Icon(Icons.open_in_new_rounded),
                    onPressed: () => widget.backend.openExternalUrl(
                      'https://github.com/iamr0s/agent-mcp/releases',
                    ),
                  ),
                  ClaudeButton(
                    label: widget.checkingUpdate
                        ? '检查中...'
                        : (hasNewer ? '查看更新' : '立即检查更新'),
                    compact: true,
                    loading: widget.checkingUpdate,
                    variant:
                        hasNewer ? ClaudeBtnVariant.clay : ClaudeBtnVariant.ink,
                    leading: Icon(
                      hasNewer
                          ? Icons.download_for_offline_rounded
                          : Icons.refresh_rounded,
                    ),
                    onPressed:
                        widget.checkingUpdate || widget.onCheckUpdate == null
                            ? null
                            : () => widget.onCheckUpdate!(),
                  ),
                ],
              );

              if (isNarrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [badge, const SizedBox(width: 14), metaCol],
                    ),
                    const SizedBox(height: 14),
                    actionsWrap,
                  ],
                );
              }
              return Row(
                children: [
                  badge,
                  const SizedBox(width: 16),
                  metaCol,
                  const SizedBox(width: 14),
                  actionsWrap,
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        ClaudeListGroup(
          headerLabel: '更新策略与下载通道',
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              child: LayoutBuilder(
                builder: (ctx, box) {
                  final isNarrow = box.maxWidth < 430;
                  final freqMenu = ClaudeDropMenu<int>(
                    value: {6, 12, 24, 168}.contains(prefs.checkIntervalHours)
                        ? prefs.checkIntervalHours
                        : 12,
                    tooltip: '自动检测周期',
                    minMenuWidth: 126,
                    items: const [
                      ClaudeDropMenuItem<int>(value: 6, label: '每 6 小时'),
                      ClaudeDropMenuItem<int>(value: 12, label: '每 12 小时'),
                      ClaudeDropMenuItem<int>(value: 24, label: '每天'),
                      ClaudeDropMenuItem<int>(value: 168, label: '每周'),
                    ],
                    onChanged: (hours) async {
                      final next = prefs.copyWith(checkIntervalHours: hours);
                      await widget.onUpdatePrefsChanged?.call(next);
                      widget.onToast('已更新自动检测周期');
                    },
                  );
                  final autoSwitch = ClaudeSwitch(
                    value: prefs.autoCheckEnabled,
                    onChanged: (v) async {
                      final next = prefs.copyWith(autoCheckEnabled: v);
                      await widget.onUpdatePrefsChanged?.call(next);
                      widget.onToast(v ? '已开启定期自动检查更新' : '已关闭定期自动检查更新');
                    },
                  );
                  final titleCol = Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '定期自动检查更新',
                          style: sansStyle(
                            c,
                            size: 13.4,
                            weight: FontWeight.w500,
                            color: c.ink,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '优先拉取 Releases version.json（自动降级 API）',
                          style: sansStyle(c, size: 11.8, color: c.muted),
                        ),
                      ],
                    ),
                  );
                  if (isNarrow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            titleCol,
                            const SizedBox(width: 12),
                            autoSwitch,
                          ],
                        ),
                        if (prefs.autoCheckEnabled) ...[
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Text(
                                '检测频率',
                                style: sansStyle(c, size: 12, color: c.muted),
                              ),
                              const Spacer(),
                              freqMenu,
                            ],
                          ),
                        ],
                      ],
                    );
                  }
                  return Row(
                    children: [
                      titleCol,
                      if (prefs.autoCheckEnabled) ...[
                        const SizedBox(width: 10),
                        freqMenu,
                      ],
                      const SizedBox(width: 10),
                      autoSwitch,
                    ],
                  );
                },
              ),
            ),
            if (prefs.skippedVersion.isNotEmpty)
              ClaudeSettingsRow(
                leading: Icon(
                  Icons.notifications_off_outlined,
                  size: 16,
                  color: c.meta,
                ),
                title: '已跳过 v${prefs.skippedVersion} 的自动弹窗提醒',
                trailing: ClaudeButton(
                  label: '恢复提醒',
                  compact: true,
                  variant: ClaudeBtnVariant.ghost,
                  onPressed: () async {
                    await widget.onUpdatePrefsChanged
                        ?.call(prefs.copyWith(skippedVersion: ''));
                    widget.onToast('已恢复所有版本的更新提醒');
                  },
                ),
              ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClaudeSettingsRow(
                  leading: Icon(Icons.bolt_rounded, size: 16, color: c.meta),
                  title: 'GitHub 下载加速镜像',
                  subtitle: '国内网络环境下用于加速安装包拉取',
                  onTap: () =>
                      setState(() => _showMirrorConfig = !_showMirrorConfig),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClaudePill(
                        text: hasMirror ? '自定义镜像' : '直连 GitHub',
                        mono: false,
                        fg: hasMirror ? c.clay : c.muted,
                        bg: hasMirror
                            ? c.clay.withValues(alpha: 0.12)
                            : c.recessed,
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        showMirror
                            ? Icons.keyboard_arrow_up_rounded
                            : Icons.keyboard_arrow_down_rounded,
                        size: 18,
                        color: c.meta,
                      ),
                    ],
                  ),
                ),
                ClaudeCollapsible(
                  expanded: showMirror,
                  builder: (_) => Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _mirrorCtrl,
                            style: monoStyle(c, size: 12.2, color: c.ink),
                            decoration: const InputDecoration(
                              isDense: true,
                              hintText: '留空直连 GitHub；如 https://gh-proxy.com/',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ClaudeButton(
                          label: '应用',
                          compact: true,
                          variant: ClaudeBtnVariant.clay,
                          onPressed: () async {
                            final trimmed = _mirrorCtrl.text.trim();
                            await widget.onUpdatePrefsChanged
                                ?.call(prefs.copyWith(mirrorPrefix: trimmed));
                            setState(() => _showMirrorConfig = false);
                            widget.onToast(
                              trimmed.isEmpty
                                  ? '已恢复直连 GitHub'
                                  : '已保存 GitHub 加速前缀',
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFloatingUnsavedBar(ClaudePalette c) {
    final anyDirty = _basicDirty || _permDirty;
    if (!anyDirty) return const SizedBox.shrink();

    final saving = _savingBasic || _restartingBasic || _savingPerm;
    final label = _basicDirty && _permDirty
        ? '基础配置与权限策略有未保存的更改'
        : (_basicDirty ? '基础服务配置有未保存的更改' : '权限与日志策略有未保存的更改');

    return Positioned(
      left: 12,
      right: 12,
      bottom: 14 + widget.extraBottomPadding,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: ShapeDecoration(
              color: c.popover,
              shape: claudeSuperellipse(
                12,
                side: BorderSide(color: c.clay.withValues(alpha: 0.42)),
              ),
              shadows: c.popoverShadow,
            ),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: c.clay,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        label,
                        style: sansStyle(
                          c,
                          size: 12.6,
                          weight: FontWeight.w600,
                          color: c.ink,
                        ),
                      ),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ClaudeButton(
                      label: '还原',
                      compact: true,
                      variant: ClaudeBtnVariant.ghost,
                      onPressed: saving ? null : _discardUnsavedChanges,
                    ),
                    ClaudeButton(
                      label: saving ? '保存中...' : '保存修改',
                      compact: true,
                      loading: _savingBasic || _savingPerm,
                      onPressed: saving
                          ? null
                          : () => _saveAllDirty(restart: false),
                    ),
                    if (_basicDirty)
                      ClaudeButton(
                        label: _restartingBasic ? '重启中...' : '保存并重启',
                        compact: true,
                        loading: _restartingBasic,
                        variant: ClaudeBtnVariant.clay,
                        leading: const Icon(Icons.restart_alt_rounded),
                        onPressed: saving
                            ? null
                            : () => _saveAllDirty(restart: true),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
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

    final showBasic = _setupSection == 'basic' || _setupSection == 'all';
    final showProfiles = _setupSection == 'profiles' || _setupSection == 'all';
    final showExpose = _setupSection == 'expose' || _setupSection == 'all';
    final showSecurity = _setupSection == 'security' || _setupSection == 'all';
    final showAbout = _setupSection == 'about' || _setupSection == 'all';

    final screenW = MediaQuery.sizeOf(context).width;
    final isWideDesktop = screenW >= 820;
    final hasDirty = _basicDirty || _permDirty;
    final bottomPad = (screenW < 700 ? 124.0 : 42.0) +
        (hasDirty ? 64.0 : 0.0) +
        widget.extraBottomPadding;
    final curPort =
        _portCtrl.text.trim().isEmpty ? '8000' : _portCtrl.text.trim();
    final curVer = widget.backend.currentAppVersion;
    final hasUpdate = widget.latestUpdate != null &&
        compareSemVer(widget.latestUpdate!.version, curVer) > 0;
    final curRoots = _parseLines(_rootsCtrl.text);
    final listenSummary = _bindAllInterfaces
        ? '0.0.0.0:$curPort · 全网卡'
        : '${_effectiveHosts.join(", ")}:$curPort';

    final navCategories = <(String, IconData, String, String, bool, String?)>[
      (
        'basic',
        Icons.tune_rounded,
        _basicDirty ? '基础与外观 ●' : '基础与外观',
        '监听 $listenSummary · 外观与开机策略',
        _basicDirty,
        null,
      ),
      (
        'profiles',
        Icons.hub_outlined,
        '接入入口 (${profs.length})',
        '管理 MCP 多入口配置与根目录权限',
        false,
        null,
      ),
      (
        'expose',
        Icons.public_rounded,
        '外网与隧道',
        'Tailscale 网卡、外网分享开关与公网隧道',
        false,
        null,
      ),
      (
        'security',
        Icons.shield_outlined,
        _permDirty ? '权限与维护 ●' : '权限与维护',
        '安全权限策略、运行日志与本地缓存清理',
        _permDirty,
        null,
      ),
      (
        'about',
        Icons.verified_outlined,
        '关于与更新',
        hasUpdate
            ? '发现新版本 v${widget.latestUpdate!.version} · 点击升级'
            : '当前版本 v$curVer · 自动更新与镜像设置',
        hasUpdate,
        hasUpdate ? 'NEW' : 'v$curVer',
      ),
    ];

    Widget buildCategoryDetailContent() {
      return Column(
        key: ValueKey('setup-sec-$_setupSection'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showBasic) ...[
            ClaudeListGroup(
              headerLabel: '基础服务与全局密码',
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClaudeSettingsRow(
                      title: 'MCP 服务名称',
                      subtitle: screenW >= 500 ? '向 AI 客户端宣告的节点标识' : null,
                      onTap: () => _toggleInlineEdit('name'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 168),
                              child: Text(
                                _nameCtrl.text.trim().isEmpty
                                    ? 'agent-mcp'
                                    : _nameCtrl.text.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: sansStyle(
                                  c,
                                  size: 13,
                                  weight: FontWeight.w600,
                                  color: c.ink,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Icon(
                            _activeInlineEdit == 'name'
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.chevron_right_rounded,
                            size: 17,
                            color: _activeInlineEdit == 'name' ? c.clay : c.meta,
                          ),
                        ],
                      ),
                    ),
                    ClaudeCollapsible(
                      expanded: _activeInlineEdit == 'name',
                      builder: (_) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _nameCtrl,
                                onChanged: (_) => setState(() {}),
                                style: sansStyle(c, size: 13, color: c.ink),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  hintText: '输入服务显示名称',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ClaudeButton(
                              label: '取消',
                              compact: true,
                              variant: ClaudeBtnVariant.ghost,
                              onPressed: () => _toggleInlineEdit('name'),
                            ),
                            const SizedBox(width: 6),
                            ClaudeButton(
                              label: _savingBasic ? '保存中...' : '保存',
                              compact: true,
                              loading: _savingBasic,
                              variant: ClaudeBtnVariant.clay,
                              onPressed: () async {
                                await _saveBasic(restart: false);
                                if (mounted) {
                                  setState(() => _activeInlineEdit = null);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClaudeSettingsRow(
                      title: '工具名前缀',
                      subtitle: screenW >= 500 ? '多设备同时接入同一客户端时防止工具重名' : null,
                      onTap: () => _toggleInlineEdit('prefix'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: ClaudePill(
                              text: _prefixCtrl.text.trim().isEmpty
                                  ? '未启用前缀'
                                  : '${_prefixCtrl.text.trim()}_*',
                              mono: _prefixCtrl.text.trim().isNotEmpty,
                              fg: _prefixCtrl.text.trim().isEmpty
                                  ? c.muted
                                  : c.clay,
                              bg: _prefixCtrl.text.trim().isEmpty
                                  ? c.recessed
                                  : c.clay.withValues(alpha: 0.12),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Icon(
                            _activeInlineEdit == 'prefix'
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.chevron_right_rounded,
                            size: 17,
                            color:
                                _activeInlineEdit == 'prefix' ? c.clay : c.meta,
                          ),
                        ],
                      ),
                    ),
                    ClaudeCollapsible(
                      expanded: _activeInlineEdit == 'prefix',
                      builder: (_) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(
                                minWidth: 210,
                                maxWidth: 320,
                              ),
                              child: TextField(
                                controller: _prefixCtrl,
                                onChanged: (_) => setState(() {}),
                                style: monoStyle(c, size: 12.6, color: c.ink),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  hintText: '留空不加前缀，如 omen_pc',
                                ),
                              ),
                            ),
                            ClaudeButton(
                              label: '用服务名',
                              compact: true,
                              onPressed: () {
                                _prefixCtrl.text = _nameCtrl.text
                                    .trim()
                                    .replaceAll(RegExp(r'[^a-zA-Z0-9_]+'), '_')
                                    .toLowerCase();
                                setState(() {});
                              },
                            ),
                            ClaudeButton(
                              label: '取消',
                              compact: true,
                              variant: ClaudeBtnVariant.ghost,
                              onPressed: () => _toggleInlineEdit('prefix'),
                            ),
                            ClaudeButton(
                              label: _restartingBasic ? '重启中...' : '保存并重启',
                              compact: true,
                              loading: _restartingBasic,
                              variant: ClaudeBtnVariant.clay,
                              onPressed: () async {
                                await _saveBasic(restart: true);
                                if (mounted) {
                                  setState(() => _activeInlineEdit = null);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClaudeSettingsRow(
                      title: '监听地址与端口',
                      subtitle:
                          screenW >= 500 ? '本地 HTTP Streamable / SSE 协议绑定网卡' : null,
                      onTap: () => _toggleInlineEdit('listen'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: ClaudePill(
                              text: screenW < 440 && _bindAllInterfaces
                                  ? '0.0.0.0:$curPort'
                                  : listenSummary,
                              fg: c.ink,
                              bg: c.recessed,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Icon(
                            _activeInlineEdit == 'listen'
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.chevron_right_rounded,
                            size: 17,
                            color:
                                _activeInlineEdit == 'listen' ? c.clay : c.meta,
                          ),
                        ],
                      ),
                    ),
                    ClaudeCollapsible(
                      expanded: _activeInlineEdit == 'listen',
                      builder: (_) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: ShapeDecoration(
                            color: c.recessed,
                            shape: claudeSuperellipse(
                              10,
                              side: BorderSide(color: c.hairline),
                            ),
                          ),
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
                                          size: 12.2,
                                          color: c.muted,
                                        ),
                                      ),
                                      const SizedBox(width: 7),
                                      SizedBox(
                                        width: 92,
                                        child: TextField(
                                          controller: _portCtrl,
                                          keyboardType: TextInputType.number,
                                          onChanged: (_) => setState(() {}),
                                          style: monoStyle(
                                            c,
                                            size: 12.8,
                                            color: c.ink,
                                          ),
                                          decoration: const InputDecoration(
                                            isDense: true,
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
                                  padding: const EdgeInsets.only(top: 10),
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
                                                  focusNode: _hostFocusNodes[i],
                                                  onChanged: (_) {
                                                    final cur = _hostCtrls
                                                        .map(
                                                          (x) => x.text.trim(),
                                                        )
                                                        .where(
                                                          (s) =>
                                                              s.isNotEmpty &&
                                                              s != '0.0.0.0',
                                                        )
                                                        .toList();
                                                    if (cur.isNotEmpty) {
                                                      _customHostsBackup = cur;
                                                    }
                                                    setState(() {});
                                                  },
                                                  style: monoStyle(
                                                    c,
                                                    size: 12.6,
                                                    color: c.ink,
                                                  ),
                                                  decoration: InputDecoration(
                                                    isDense: true,
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
                              const SizedBox(height: 10),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  ClaudeButton(
                                    label: '取消',
                                    compact: true,
                                    variant: ClaudeBtnVariant.ghost,
                                    onPressed: () =>
                                        _toggleInlineEdit('listen'),
                                  ),
                                  const SizedBox(width: 6),
                                  ClaudeButton(
                                    label:
                                        _restartingBasic ? '重启中...' : '保存并重启',
                                    compact: true,
                                    loading: _restartingBasic,
                                    variant: ClaudeBtnVariant.clay,
                                    leading:
                                        const Icon(Icons.restart_alt_rounded),
                                    onPressed: () async {
                                      await _saveBasic(restart: true);
                                      if (mounted) {
                                        setState(
                                          () => _activeInlineEdit = null,
                                        );
                                      }
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClaudeSettingsRow(
                      title: 'OAuth 2.1 本地密码',
                      subtitle:
                          screenW >= 500 ? '用于远程网页授权与 /dashboard 登录保护' : null,
                      onTap: () => _toggleInlineEdit('password'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: ClaudePill(
                              text: widget.config['has_password'] == true
                                  ? '已设密码保护'
                                  : '未设置密码',
                              mono: false,
                              fg: widget.config['has_password'] == true
                                  ? c.sage
                                  : c.clay,
                              bg: widget.config['has_password'] == true
                                  ? c.sageBg
                                  : c.clay.withValues(alpha: 0.12),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Icon(
                            _activeInlineEdit == 'password'
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.chevron_right_rounded,
                            size: 17,
                            color: _activeInlineEdit == 'password'
                                ? c.clay
                                : c.meta,
                          ),
                        ],
                      ),
                    ),
                    ClaudeCollapsible(
                      expanded: _activeInlineEdit == 'password',
                      builder: (_) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            ConstrainedBox(
                              constraints: const BoxConstraints(
                                minWidth: 220,
                                maxWidth: 320,
                              ),
                              child: ClaudePasswordField(
                                controller: _pwdCtrl,
                                onChanged: (_) => setState(() {}),
                                hintText: widget.config['has_password'] == true
                                    ? '输入新密码即刻覆盖生效'
                                    : '设置 OAuth 2.1 与控制台密码',
                              ),
                            ),
                            ClaudeButton(
                              label: '随机生成',
                              compact: true,
                              leading: const Icon(Icons.casino_outlined),
                              onPressed: () {
                                _pwdCtrl.text = generateRandomToken('', 14);
                                setState(() {});
                              },
                            ),
                            ClaudeButton(
                              label: '取消',
                              compact: true,
                              variant: ClaudeBtnVariant.ghost,
                              onPressed: () => _toggleInlineEdit('password'),
                            ),
                            ClaudeButton(
                              label: _savingBasic ? '保存中...' : '保存密码',
                              compact: true,
                              loading: _savingBasic,
                              variant: ClaudeBtnVariant.clay,
                              onPressed: _pwdCtrl.text.trim().isEmpty
                                  ? null
                                  : () async {
                                      await _saveBasic(restart: false);
                                      if (mounted) {
                                        setState(
                                          () => _activeInlineEdit = null,
                                        );
                                      }
                                    },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                ClaudeSettingsRow(
                  title: '界面主题',
                  subtitle: screenW >= 500 ? '冷瓷浅色与曜石暗色双层高对比画布' : null,
                  allowTrailingWrap: true,
                  stackBreakpoint: 470,
                  trailing: ClaudeSegmented<ThemeMode>(
                    expand: screenW < 500,
                    value: widget.themeMode,
                    items: const [
                      (ThemeMode.system, '跟随系统'),
                      (ThemeMode.light, '冷瓷浅色'),
                      (ThemeMode.dark, '曜石暗色'),
                    ],
                    onChanged: widget.onThemeChanged,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClaudeListGroup(
              headerLabel: '外观与自启策略',
              children: [
                if (isAndroidHost)
                  ClaudeSettingsRow(
                    title: '动态配色 (Android Material You)',
                    subtitle: widget.dynamicColorSupported
                        ? '跟随系统壁纸动态提取主题强调色（支持 Android 12+ 莫奈取色）'
                        : '当前系统版本不支持莫奈壁纸取色（需 Android 12 及以上）',
                    trailing: ClaudeSwitch(
                      value: widget.dynamicColor,
                      onChanged: (v) {
                        if (!widget.dynamicColorSupported && v) {
                          widget.onToast('当前系统暂不支持 Android 12+ 动态配色');
                          return;
                        }
                        widget.onDynamicColorChanged?.call(v);
                        widget.onToast(
                          v ? '已开启动态壁纸配色' : '已恢复默认 Indigo 配色',
                        );
                      },
                    ),
                  ),
                if (!widget.backend.hasCustomTitleBar)
                  ClaudeSettingsRow(
                    title: '界面毛玻璃与柔光背板',
                    subtitle: '启用悬浮导航条与顶栏的实时虚化玻璃质感',
                    trailing: ClaudeSwitch(
                      value: _windowEffect,
                      onChanged: (v) => _applyStartupToggle(
                        windowEffect: v,
                        toastMsg: v ? '已启用界面毛玻璃效果' : '已切换为纯色背板',
                      ),
                    ),
                  ),
                if (isAndroidHost)
                  ClaudeSettingsRow(
                    leading: Icon(
                      Icons.notifications_active_outlined,
                      size: 18,
                      color: c.clay,
                    ),
                    title: '通知栏常驻保活与快捷启停',
                    subtitle: '手机锁屏或切到后台时保持本机服务不断连，下拉通知栏即可随时停止或重启。',
                  )
                else ...[
                  ClaudeSettingsRow(
                    title: '开机自动启动应用',
                    subtitle:
                        '${_osAutoStartCaption()}；配合静默模式自动附带 --silent 参数',
                    trailing: ClaudeSwitch(
                      value: _launchAtStartup,
                      onChanged: (v) => _applyStartupToggle(
                        launchAtStartup: v,
                        toastMsg: v
                            ? (_silentStart ? '已开启系统开机静默自启' : '已开启系统开机自启')
                            : '已移除系统开机自启项',
                      ),
                    ),
                  ),
                  ClaudeSettingsRow(
                    title: '静默启动至后台托盘（不弹出窗口）',
                    subtitle:
                        '启动时跳过主窗口绘制、零闪烁驻留系统托盘（支持命令行 --silent，点击托盘可唤醒）',
                    trailing: ClaudeSwitch(
                      value: _silentStart,
                      onChanged: (v) => _applyStartupToggle(
                        silentStart: v,
                        toastMsg: v ? '已开启静默驻留托盘启动模式' : '已恢复常规窗口启动模式',
                      ),
                    ),
                  ),
                ],
                ClaudeSettingsRow(
                  title: '启动后自动开启 MCP 服务与隧道',
                  subtitle: '进程拉起后立即监听 HTTP 端口并自动连接已启用的公网隧道',
                  trailing: ClaudeSwitch(
                    value: _autoStart,
                    onChanged: (v) => _applyStartupToggle(
                      autoStart: v,
                      toastMsg:
                          v ? '已开启启动自动运行 MCP 服务' : '已关闭启动自动运行 MCP 服务',
                    ),
                  ),
                ),
              ],
            ),
            if (isAndroidHost) ...[
              const SizedBox(height: 16),
              AndroidPrivilegeCard(
                backend: widget.backend,
                config: widget.config,
                onRefreshStatus: widget.onRefreshStatus,
                onToast: widget.onToast,
              ),
            ],
          ],
          if (showProfiles) ...[
            if (showBasic) const SizedBox(height: 18),
            ClaudeListGroup(
              headerLabel: '传输、鉴权与权限入口',
              headerTrailing: ClaudeButton(
                label: '添加入口',
                compact: true,
                leading: const Icon(Icons.add_rounded),
                variant: ClaudeBtnVariant.clay,
                onPressed: () => _openProfileModal(),
              ),
              children: [
                for (var i = 0; i < profs.length; i++)
                  _buildProfileRow(c, profs, i, tMap),
              ],
            ),
          ],
          if (showExpose) ...[
            if (showBasic || showProfiles) const SizedBox(height: 18),
            TailscaleExposureSettingsCard(
              backend: widget.backend,
              config: widget.config,
              exposureSummary: widget.exposureSummary,
              onRefreshStatus: widget.onRefreshStatus,
              onToast: widget.onToast,
            ),
            const SizedBox(height: 16),
            _buildCloudflaredGroup(c, ti, inst, tMap),
          ],
          if (showSecurity) ...[
            if (showBasic || showProfiles || showExpose)
              const SizedBox(height: 18),
            ClaudeListGroup(
              headerLabel: '全局默认权限与日志',
              children: [
                ClaudeSettingsRow(
                  title: '允许写入与执行',
                  subtitle: '关闭后全局降级为安全只读模式，拦截写文件与终端指令',
                  trailing: ClaudeSwitch(
                    value: _writable,
                    onChanged: (v) async {
                      setState(() => _writable = v);
                      await _savePerm();
                    },
                  ),
                ),
                ClaudeSettingsRow(
                  title: '允许读取敏感文件',
                  subtitle: '控制是否允许读取 .env、密钥等受保护路径',
                  trailing: ClaudeSwitch(
                    value: _allowSecrets,
                    onChanged: (v) async {
                      setState(() => _allowSecrets = v);
                      await _savePerm();
                    },
                  ),
                ),
                ClaudeSettingsRow(
                  title: '客户端免弹窗声明（全工具静默注解）',
                  subtitle: '附加只读幂等声明，减少客户端每次工具调用确认弹窗',
                  trailing: ClaudeSwitch(
                    value: _relaxedCmd,
                    onChanged: (v) async {
                      setState(() => _relaxedCmd = v);
                      await _savePerm();
                    },
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClaudeSettingsRow(
                      title: '默认目录白名单',
                      subtitle: curRoots.isEmpty
                          ? '未限定根目录（允许访问本机任意路径）'
                          : curRoots.take(2).join(' · '),
                      onTap: () => _toggleInlineEdit('roots'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClaudePill(
                            text: curRoots.isEmpty
                                ? '全盘开放'
                                : '已限定 ${curRoots.length} 个目录',
                            mono: false,
                            fg: curRoots.isEmpty ? c.muted : c.clay,
                            bg: curRoots.isEmpty
                                ? c.recessed
                                : c.clay.withValues(alpha: 0.12),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            _activeInlineEdit == 'roots'
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.edit_outlined,
                            size: 16,
                            color:
                                _activeInlineEdit == 'roots' ? c.clay : c.meta,
                          ),
                        ],
                      ),
                    ),
                    ClaudeCollapsible(
                      expanded: _activeInlineEdit == 'roots',
                      builder: (_) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            TextField(
                              controller: _rootsCtrl,
                              maxLines: 3,
                              onChanged: (_) => setState(() {}),
                              style: monoStyle(c, size: 12.4, color: c.ink),
                              decoration: const InputDecoration(
                                isDense: true,
                                hintText: '每行一个目录路径，留空允许全盘访问',
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ClaudeButton(
                                  label: '取消',
                                  compact: true,
                                  variant: ClaudeBtnVariant.ghost,
                                  onPressed: () => _toggleInlineEdit('roots'),
                                ),
                                const SizedBox(width: 6),
                                ClaudeButton(
                                  label: _savingPerm ? '保存中...' : '保存白名单',
                                  compact: true,
                                  loading: _savingPerm,
                                  variant: ClaudeBtnVariant.clay,
                                  onPressed: () async {
                                    await _savePerm();
                                    if (mounted) {
                                      setState(
                                        () => _activeInlineEdit = null,
                                      );
                                    }
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ClaudeSettingsRow(
                      title: '运行日志等级',
                      subtitle: _logFileCtrl.text.trim().isEmpty
                          ? '实时环形缓冲（点击右侧图标可配置落盘文件）'
                          : '落盘文件：${_logFileCtrl.text.trim()}',
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
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
                            onChanged: (v) async {
                              setState(() => _logLevel = v);
                              await _savePerm();
                            },
                          ),
                          const SizedBox(width: 6),
                          ClaudeButton(
                            label: '',
                            compact: true,
                            tooltip: '配置落盘日志文件路径',
                            variant: ClaudeBtnVariant.ghost,
                            leading: Icon(
                              _activeInlineEdit == 'logfile'
                                  ? Icons.keyboard_arrow_up_rounded
                                  : Icons.description_outlined,
                              size: 16,
                            ),
                            onPressed: () => _toggleInlineEdit('logfile'),
                          ),
                        ],
                      ),
                    ),
                    ClaudeCollapsible(
                      expanded: _activeInlineEdit == 'logfile',
                      builder: (_) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _logFileCtrl,
                                onChanged: (_) => setState(() {}),
                                style: monoStyle(c, size: 12.4, color: c.ink),
                                decoration: const InputDecoration(
                                  isDense: true,
                                  hintText: '可选落盘路径，如 logs/mcp.log（留空不落盘）',
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            ClaudeButton(
                              label: '取消',
                              compact: true,
                              variant: ClaudeBtnVariant.ghost,
                              onPressed: () => _toggleInlineEdit('logfile'),
                            ),
                            const SizedBox(width: 6),
                            ClaudeButton(
                              label: _savingPerm ? '保存中...' : '保存',
                              compact: true,
                              loading: _savingPerm,
                              variant: ClaudeBtnVariant.clay,
                              onPressed: () async {
                                await _savePerm();
                                if (mounted) {
                                  setState(() => _activeInlineEdit = null);
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildStorageGroup(c),
          ],
          if (showAbout) ...[
            if (showBasic || showProfiles || showExpose || showSecurity)
              const SizedBox(height: 18),
            _buildAboutAndUpdateSection(c),
          ],
        ],
      );
    }

    // 1. Desktop Wide Screen (>= 820px): 2-Pane Master-Detail + Sliding Spring Rail + Shared-Y Switcher
    if (isWideDesktop) {
      const tileH = 36.0;
      const tileGap = 3.0;
      const dividerBlockH = 17.0; // 8 top + 1 divider + 8 bottom
      final catIdx =
          navCategories.indexWhere((item) => item.$1 == _setupSection);
      final double activePillTop = _setupSection == 'all'
          ? (navCategories.length * (tileH + tileGap) - tileGap + dividerBlockH)
          : (catIdx >= 0 ? catIdx : 0) * (tileH + tileGap);

      return Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(top: widget.topPadding),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 214,
                  child: SingleChildScrollView(
                    padding: EdgeInsets.only(right: 14, bottom: bottomPad),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(6, 2, 6, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('服务配置', style: serifTitleStyle(c, size: 20)),
                              const SizedBox(height: 2),
                              Text(
                                '按分类管理节点参数',
                                style: sansStyle(
                                  c,
                                  size: 11.8,
                                  color: c.muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Stack(
                          children: [
                            AnimatedPositioned(
                              duration: ClaudeMotion.duration(
                                context,
                                const Duration(milliseconds: 220),
                              ),
                              curve: ClaudeMotion.snappySpring,
                              top: activePillTop,
                              left: 0,
                              right: 0,
                              height: tileH,
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: ShapeDecoration(
                                    color: c.clay.withValues(
                                      alpha: c.isDark ? 0.20 : 0.10,
                                    ),
                                    shape: claudeSuperellipse(8),
                                  ),
                                ),
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0;
                                    i < navCategories.length;
                                    i++) ...[
                                  if (i > 0) const SizedBox(height: tileGap),
                                  _SetupNavTile(
                                    height: tileH,
                                    icon: navCategories[i].$2,
                                    title: navCategories[i].$3,
                                    badgeDot: navCategories[i].$5,
                                    badgeText: navCategories[i].$6,
                                    active:
                                        _setupSection == navCategories[i].$1,
                                    useExternalPill: true,
                                    onTap: () => _selectSetupSection(
                                      navCategories[i].$1,
                                    ),
                                  ),
                                ],
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 8),
                                  child: Divider(color: c.hairline, height: 1),
                                ),
                                _SetupNavTile(
                                  height: tileH,
                                  icon: Icons.view_agenda_outlined,
                                  title: '全部展开',
                                  badgeDot: false,
                                  active: _setupSection == 'all',
                                  useExternalPill: true,
                                  onTap: () => _selectSetupSection('all'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                Container(width: 1, color: c.hairline),
                const SizedBox(width: 20),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scrollCtrl,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(right: 2, bottom: bottomPad),
                    child: ClaudeSharedAxisSwitcher(
                      axis: Axis.vertical,
                      reverse: _sectionNavReverse,
                      child: buildCategoryDetailContent(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _buildFloatingUnsavedBar(c),
        ],
      );
    }

    // 2. Mobile / Narrow Screen (< 820px): Shared-X Push/Pop between Level-1 & Level-2
    final currentCatTitle = navCategories
            .where((e) => e.$1 == _setupSection)
            .map((e) => e.$3)
            .firstOrNull ??
        '全部配置';

    final Widget mobileView = !_mobileInDetail
        ? SingleChildScrollView(
            key: const ValueKey('setup-mobile-list'),
            controller: _scrollCtrl,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              top: widget.topPadding,
              right: 2,
              bottom: bottomPad,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('服务配置', style: serifTitleStyle(c, size: 22)),
                const SizedBox(height: 3),
                Text(
                  '轻点下方分组进入对应设置项',
                  style: sansStyle(c, size: 12.2, color: c.muted),
                ),
                const SizedBox(height: 12),
                ClaudeListGroup(
                  dividerIndent: 58,
                  children: [
                    for (var i = 0; i < navCategories.length; i++)
                      ClaudeSettingsRow(
                        onTap: () => _selectSetupSection(
                          navCategories[i].$1,
                          openMobileDetail: true,
                        ),
                        leading: Container(
                          width: 34,
                          height: 34,
                          decoration: ShapeDecoration(
                            color: c.clay.withValues(
                              alpha: c.isDark ? 0.16 : 0.10,
                            ),
                            shape: claudeSuperellipse(9),
                          ),
                          child: Icon(
                            navCategories[i].$2,
                            size: 18,
                            color: c.clay,
                          ),
                        ),
                        title: navCategories[i].$3,
                        subtitle: navCategories[i].$4,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (navCategories[i].$6 != null) ...[
                              ClaudePill(
                                text: navCategories[i].$6!,
                                fg: navCategories[i].$5 ? c.clay : c.muted,
                                bg: navCategories[i].$5
                                    ? c.clay.withValues(alpha: 0.14)
                                    : c.recessed,
                              ),
                              const SizedBox(width: 6),
                            ],
                            Icon(
                              Icons.chevron_right_rounded,
                              size: 19,
                              color: c.meta,
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
                if (isAndroidHost) ...[
                  const SizedBox(height: 14),
                  AndroidPrivilegeCard(
                    backend: widget.backend,
                    config: widget.config,
                    onRefreshStatus: widget.onRefreshStatus,
                    onToast: widget.onToast,
                  ),
                ],
              ],
            ),
          )
        : SingleChildScrollView(
            key: ValueKey('setup-mobile-detail-$_setupSection'),
            controller: _scrollCtrl,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.only(
              top: widget.topPadding,
              right: 2,
              bottom: bottomPad,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    ClaudeButton(
                      label: '返回服务配置',
                      compact: true,
                      variant: ClaudeBtnVariant.ghost,
                      leading: const Icon(
                        Icons.arrow_back_ios_new_rounded,
                        size: 14,
                      ),
                      onPressed: () => setState(() {
                        _mobileInDetail = false;
                        _activeInlineEdit = null;
                      }),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        currentCatTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sansStyle(
                          c,
                          size: 15.5,
                          weight: FontWeight.w600,
                          color: c.ink,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                buildCategoryDetailContent(),
              ],
            ),
          );

    return Stack(
      children: [
        ClaudeSharedAxisSwitcher(
          axis: Axis.horizontal,
          reverse: !_mobileInDetail,
          distance: 22.0,
          child: mobileView,
        ),
        _buildFloatingUnsavedBar(c),
      ],
    );
  }

  Widget _buildProfileRow(
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
          .join(' · ');
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
      opacity: enabled ? 1.0 : 0.56,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: [
                Wrap(
                  spacing: 7,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ClaudeStatusDot(
                      color: isLiveActive ? c.sage : c.meta,
                      pulsing: isLiveActive,
                      size: 7,
                    ),
                    Text(
                      (p['name'] ?? '入口').toString(),
                      style: sansStyle(
                        c,
                        size: 14.5,
                        weight: FontWeight.w600,
                        color: c.ink,
                      ),
                    ),
                    ClaudePill(
                      text: (p['transport'] ?? 'dual').toString().toUpperCase(),
                      fg: c.sage,
                      bg: c.sageBg,
                    ),
                    ClaudePill(
                      text: authLabels[authMode] ?? authMode,
                      mono: false,
                      fg: c.clay,
                      bg: c.clay.withValues(alpha: 0.12),
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
                        bg: c.paper3,
                      ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
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
                                final r =
                                    await widget.backend.startTunnel(pid);
                                if (r['ok'] == true) {
                                  widget.onToast('隧道已启动，正在连接...');
                                } else {
                                  widget.onToast(
                                    r['error']?.toString() ?? '启动失败',
                                  );
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
                    ClaudeSwitch(
                      value: enabled,
                      onChanged: (v) async {
                        final next = List<Map<String, dynamic>>.from(profs);
                        next[idx] = Map<String, dynamic>.from(p)
                          ..['enabled'] = v;
                        await _saveProfilesList(next);
                      },
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            SelectableText(
              endpointText,
              style: monoStyle(
                c,
                size: 12,
                color: tunReady ? c.clay : c.meta,
              ),
            ),
            ClaudeCollapsible(
              expanded: (tState['error'] ?? '').toString().isNotEmpty,
              builder: (_) => Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  'Cloudflared: ${tState['error']}',
                  style: monoStyle(c, size: 11.5, color: c.danger),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  p['inherit_permissions'] != false
                      ? Icons.shield_outlined
                      : (p['read_only'] == true
                          ? Icons.lock_outline_rounded
                          : Icons.tune_rounded),
                  size: 13,
                  color: c.meta,
                ),
                const SizedBox(width: 5),
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
                    style: sansStyle(c, size: 11.8, color: c.meta, tabular: true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCloudflaredGroup(
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

    return ClaudeListGroup(
      headerLabel: 'Cloudflared 隧道组件',
      headerTrailing: ClaudePill(
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
        mono: false,
        fg: installed ? c.sage : c.clay,
        bg: installed ? c.sageBg : c.clay.withValues(alpha: 0.12),
      ),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                    duration:
                        ClaudeMotion.duration(context, ClaudeMotion.base),
                    curve: ClaudeMotion.editorialOut,
                    builder: (ctx, val, _) => LinearProgressIndicator(
                      value: val,
                      minHeight: 6,
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
                SelectableText(
                  (ti['binary'] ?? 'cloudflared').toString(),
                  style: monoStyle(c, size: 12, color: c.inkSoft),
                ),
                const SizedBox(height: 10),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Text(
                      activeCnt > 0
                          ? '当前有 $activeCnt 条隧道运行中'
                          : '已就绪，可在接入入口启用 Token 或 Quick 隧道',
                      style: sansStyle(
                        c,
                        size: 12.2,
                        color: c.muted,
                        tabular: true,
                      ),
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
                            await widget.backend.installCloudflared(
                              force: true,
                            );
                            await widget.onRefreshStatus();
                          },
                        ),
                        ClaudeButton(
                          label: '导入替换',
                          compact: true,
                          leading: const Icon(Icons.upload_file_outlined),
                          onPressed: () async {
                            final r =
                                await widget.backend.pickAndImportCloudflared();
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
                              final r =
                                  await widget.backend.uninstallCloudflared();
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
                  style: sansStyle(c, size: 12.6, color: c.muted, height: 1.5),
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
                        final r =
                            await widget.backend.pickAndImportCloudflared();
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
          ),
        ),
      ],
    );
  }

  Widget _buildStorageGroup(ClaudePalette c) {
    final st = widget.storageStats;
    const labels = [
      ('config', '配置文件 (config/)'),
      ('data', '运行数据 (data/)'),
      ('cache', '缓存目录 (cache/)'),
      ('logs', '日志文件 (logs/)'),
    ];

    return ClaudeListGroup(
      headerLabel: '存储与维护',
      headerTrailing: ClaudeButton(
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
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (ctx, sbox) {
              final cols =
                  sbox.maxWidth < 380 ? 1 : (sbox.maxWidth < 720 ? 2 : 4);
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
                        horizontal: 13,
                        vertical: 10,
                      ),
                      decoration: ShapeDecoration(
                        color: c.recessed,
                        shape: claudeSuperellipse(
                          10,
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
                            style: sansStyle(c, size: 11.4, color: c.muted),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            sizeText,
                            maxLines: 1,
                            style: monoStyle(
                              c,
                              size: 14.5,
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
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Wrap(
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
                          widget.onToast(
                            (r['message'] ?? '已清理缓存').toString(),
                          );
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
                          widget.onToast(
                            (r['message'] ?? '已清理日志').toString(),
                          );
                          await widget.onRefreshStorage();
                        } finally {
                          if (mounted) setState(() => _cleaningTarget = null);
                        }
                      },
              ),
              ClaudeButton(
                label:
                    _cleaningTarget == 'oauth' ? '清空中...' : '清空 OAuth 会话',
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
                            widget.onToast(
                              (r['message'] ?? '已清空').toString(),
                            );
                            await widget.onRefreshStorage();
                          } finally {
                            if (mounted) {
                              setState(() => _cleaningTarget = null);
                            }
                          }
                        }
                      },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SetupNavTile extends StatefulWidget {
  final double height;
  final IconData icon;
  final String title;
  final bool active;
  final bool badgeDot;
  final String? badgeText;
  final bool useExternalPill;
  final VoidCallback onTap;

  const _SetupNavTile({
    this.height = 36.0,
    required this.icon,
    required this.title,
    required this.active,
    required this.badgeDot,
    this.badgeText,
    this.useExternalPill = false,
    required this.onTap,
  });

  @override
  State<_SetupNavTile> createState() => _SetupNavTileState();
}

class _SetupNavTileState extends State<_SetupNavTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final bg = widget.active
        ? (widget.useExternalPill
            ? Colors.transparent
            : c.clay.withValues(alpha: c.isDark ? 0.20 : 0.10))
        : (_hovered
            ? (c.isDark
                ? Colors.white.withValues(alpha: 0.05)
                : Colors.black.withValues(alpha: 0.04))
            : Colors.transparent);
    final fg = widget.active ? c.clay : (_hovered ? c.ink : c.inkSoft);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          height: widget.height,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: ShapeDecoration(
            color: bg,
            shape: claudeSuperellipse(8),
          ),
          child: Row(
            children: [
              Icon(widget.icon, size: 16.5, color: fg),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sansStyle(
                    c,
                    size: 13,
                    weight: widget.active ? FontWeight.w600 : FontWeight.w500,
                    color: fg,
                  ),
                ),
              ),
              if (widget.badgeText != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1.5,
                  ),
                  decoration: ShapeDecoration(
                    color: widget.badgeDot
                        ? c.clay.withValues(alpha: 0.16)
                        : (c.isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.black.withValues(alpha: 0.045)),
                    shape: claudeSuperellipse(999),
                  ),
                  child: Text(
                    widget.badgeText!,
                    style: monoStyle(
                      c,
                      size: 10.2,
                      weight: FontWeight.w600,
                      color: widget.badgeDot ? c.clay : c.meta,
                    ),
                  ),
                ),
              ] else if (widget.badgeDot)
                Container(
                  width: 6.5,
                  height: 6.5,
                  decoration: BoxDecoration(
                    color: c.clay,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
