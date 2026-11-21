import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/console_backend.dart';
import '../theme/claude_theme.dart';
import 'profile_endpoints_helper.dart';

class ProfileEditDialog extends StatefulWidget {
  final Map<String, dynamic>? existing;
  final int serverPort;
  final List<HostIpOption> ipOptions;
  final List<String> boundHosts;

  const ProfileEditDialog({
    super.key,
    required this.existing,
    required this.serverPort,
    required this.ipOptions,
    required this.boundHosts,
  });

  @override
  State<ProfileEditDialog> createState() => _ProfileEditDialogState();
}

class _ProfileEditDialogState extends State<ProfileEditDialog> {
  final _nameCtrl = TextEditingController();
  final _baseCtrl = TextEditingController();
  final List<TextEditingController> _manualUrlCtrls = [TextEditingController()];
  final _tunTokenCtrl = TextEditingController();
  final _cidCtrl = TextEditingController();
  final _csecCtrl = TextEditingController();
  final _rurisCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _rootsCtrl = TextEditingController();

  late List<HostIpOption> _allIpOptions;
  final Set<String> _selectedDirectIps = <String>{};
  bool _syncBindHosts = true;

  String _transport = 'dual';
  String _tunnelMode = 'none';
  bool _tunnelAuto = true;
  String _authMode = 'oauth-local';
  bool _inheritPerm = true;
  bool _writable = true;
  bool _allowSecrets = false;
  bool _relaxedCmd = false;

  @override
  void initState() {
    super.initState();
    final baseOpts = List<HostIpOption>.from(widget.ipOptions);
    final seenIps = baseOpts.map((o) => o.ip).toSet();

    final e = widget.existing;
    if (e != null) {
      _nameCtrl.text = (e['name'] ?? '').toString();
      _transport = (e['transport'] ?? 'dual').toString();
      _tunnelMode = (e['tunnel_mode'] ?? 'none').toString();
      _tunnelAuto = e['tunnel_auto_start'] != false;
      _tunTokenCtrl.text = (e['tunnel_token'] ?? '').toString();
      _baseCtrl.text = (e['base_url'] ?? '').toString();

      final savedDirect = ((e['direct_ips'] as List?) ?? const [])
          .map((x) => x.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();
      for (final ip in savedDirect) {
        _selectedDirectIps.add(ip);
        if (seenIps.add(ip)) {
          baseOpts.add(
            HostIpOption(
              ip: ip,
              iface: '',
              kind: 'saved',
              label: classifyIpKindLabel(ip),
              offlineSaved: true,
            ),
          );
        }
      }

      final savedManual = ((e['manual_urls'] as List?) ?? const [])
          .map((x) => x.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();
      if (savedManual.isEmpty &&
          _tunnelMode == 'none' &&
          savedDirect.isEmpty &&
          _baseCtrl.text.trim().isNotEmpty) {
        savedManual.add(_baseCtrl.text.trim());
      }
      if (savedManual.isNotEmpty) {
        _manualUrlCtrls
          ..clear()
          ..addAll(savedManual.map((u) => TextEditingController(text: u)));
      }

      _authMode = (e['auth_mode'] ?? 'oauth-local').toString();
      _cidCtrl.text = (e['oauth_client_id'] ?? '').toString();
      _csecCtrl.text = (e['oauth_client_secret'] ?? '').toString();
      _rurisCtrl.text =
          ((e['oauth_redirect_uris'] as List?) ?? const []).join('\n');
      _apiKeyCtrl.text = (e['api_key'] ?? '').toString();
      _inheritPerm = e['inherit_permissions'] != false;
      _writable = e['read_only'] != true;
      _allowSecrets = e['allow_secrets'] == true;
      _relaxedCmd = e['relaxed_command_annotations'] == true;
      _rootsCtrl.text = ((e['roots'] as List?) ?? const []).join('\n');
    } else {
      _cidCtrl.text = generateRandomToken('mcp-client-', 10);
      _csecCtrl.text = generateRandomToken('mcp-sec-', 24);
      _apiKeyCtrl.text = generateRandomToken('sk-mcp-', 28);
    }

    _allIpOptions = baseOpts;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _baseCtrl.dispose();
    for (final c in _manualUrlCtrls) {
      c.dispose();
    }
    _tunTokenCtrl.dispose();
    _cidCtrl.dispose();
    _csecCtrl.dispose();
    _rurisCtrl.dispose();
    _apiKeyCtrl.dispose();
    _rootsCtrl.dispose();
    super.dispose();
  }

  List<String> get _orderedSelectedIps {
    final out = <String>[];
    for (final opt in _allIpOptions) {
      if (_selectedDirectIps.contains(opt.ip)) out.add(opt.ip);
    }
    for (final ip in _selectedDirectIps) {
      if (!out.contains(ip)) out.add(ip);
    }
    return out;
  }

  List<String> get _cleanManualUrls {
    final out = <String>[];
    for (final ctrl in _manualUrlCtrls) {
      for (final seg in ctrl.text.split(RegExp(r'[\r\n,;]+'))) {
        final norm = normalizeUiDirectBaseUrl(seg);
        if (norm.isNotEmpty && !out.contains(norm)) out.add(norm);
      }
    }
    return out;
  }

  List<String> get _unboundSelectedIps {
    if (_tunnelMode != 'none') return const <String>[];
    if (widget.boundHosts.contains('0.0.0.0') ||
        widget.boundHosts.contains('::')) {
      return const <String>[];
    }
    return _orderedSelectedIps
        .where((ip) => !widget.boundHosts.contains(ip))
        .toList();
  }

  List<String> get _previewDirectEndpoints {
    final suffix = _transport == 'sse' ? '/sse' : '/mcp';
    final urls = <String>[];
    for (final ip in _orderedSelectedIps) {
      final u = 'http://$ip:${widget.serverPort}$suffix';
      if (!urls.contains(u)) urls.add(u);
    }
    for (final m in _cleanManualUrls) {
      final u = '$m$suffix';
      if (!urls.contains(u)) urls.add(u);
    }
    return urls;
  }

  void _addManualUrlRow() {
    setState(() => _manualUrlCtrls.add(TextEditingController()));
  }

  void _removeManualUrlRow(int idx) {
    if (_manualUrlCtrls.length <= 1) {
      setState(() => _manualUrlCtrls.first.clear());
      return;
    }
    setState(() => _manualUrlCtrls.removeAt(idx).dispose());
  }

  void _submit() {
    final orderedIps =
        _tunnelMode == 'none' ? _orderedSelectedIps : const <String>[];
    final manualList =
        _tunnelMode == 'none' ? _cleanManualUrls : const <String>[];
    final resolvedBases = <String>[];

    String primaryBase = '';
    if (_tunnelMode == 'token') {
      primaryBase = normalizeUiDirectBaseUrl(_baseCtrl.text.trim());
      if (primaryBase.isNotEmpty) resolvedBases.add(primaryBase);
    } else if (_tunnelMode == 'none') {
      for (final ip in orderedIps) {
        final u = 'http://$ip:${widget.serverPort}';
        if (!resolvedBases.contains(u)) resolvedBases.add(u);
      }
      for (final u in manualList) {
        if (!resolvedBases.contains(u)) resolvedBases.add(u);
      }
      primaryBase = resolvedBases.isNotEmpty ? resolvedBases.first : '';
    }

    final missingBind = _unboundSelectedIps;
    final out = <String, dynamic>{
      'id': widget.existing?['id'] ?? generateRandomToken('prof-', 8),
      'name':
          _nameCtrl.text.trim().isEmpty ? '新接入入口' : _nameCtrl.text.trim(),
      'enabled': widget.existing?['enabled'] ?? true,
      'transport': _transport,
      'tunnel_mode': _tunnelMode,
      'tunnel_token': _tunTokenCtrl.text.trim(),
      'tunnel_auto_start': _tunnelAuto,
      'base_url': primaryBase,
      'base_urls': resolvedBases,
      'direct_ips': orderedIps,
      'manual_urls': manualList,
      if (_syncBindHosts && missingBind.isNotEmpty)
        '_sync_bind_ips': missingBind,
      'auth_mode': _authMode,
      'oauth_client_id': _cidCtrl.text.trim(),
      'oauth_client_secret': _csecCtrl.text.trim(),
      'oauth_redirect_uris': _rurisCtrl.text
          .split(RegExp(r'[\r\n,]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      'api_key': _apiKeyCtrl.text.trim(),
      'inherit_permissions': _inheritPerm,
      'read_only': !_writable,
      'allow_secrets': _allowSecrets,
      'relaxed_command_annotations': _relaxedCmd,
      'roots': _rootsCtrl.text
          .split(RegExp(r'[\r\n,]+'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
    };
    Navigator.of(context).pop(out);
  }
  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final compact = MediaQuery.sizeOf(context).width < 540;
    final unboundIps = _unboundSelectedIps;
    final previewEps = _previewDirectEndpoints;

    return Dialog(
      backgroundColor: c.paper2,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 28,
        vertical: 18,
      ),
      shape: claudeSuperellipse(22, side: BorderSide(color: c.hairline)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 760),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 18 : 26,
            20,
            compact ? 18 : 26,
            18,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const ClaudeSparkIcon(size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      widget.existing != null ? '编辑接入入口' : '添加传输与鉴权入口',
                      style: serifTitleStyle(c, size: 20),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _ModalGridRow(
                        label: '入口名称',
                        child: TextField(
                          controller: _nameCtrl,
                          style: sansStyle(c, size: 13.5, color: c.ink),
                          decoration: const InputDecoration(
                            hintText: '如 Gemini 主力、局域网/组网直连、只读审计',
                          ),
                        ),
                      ),
                      _ModalGridRow(
                        label: '传输协议',
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ClaudeSegmented<String>(
                            value: _transport,
                            items: const [
                              ('dual', 'dual 双模'),
                              ('http', 'HTTP'),
                              ('sse', 'SSE'),
                            ],
                            onChanged: (v) => setState(() => _transport = v),
                          ),
                        ),
                      ),
                      _ModalGridRow(
                        label: '接入与隧道',
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ClaudeSegmented<String>(
                            value: _tunnelMode,
                            items: const [
                              ('none', '直连 / 反代'),
                              ('token', 'Token 固定隧道'),
                              ('quick', 'Quick 临时隧道'),
                            ],
                            onChanged: (v) => setState(() => _tunnelMode = v),
                          ),
                        ),
                      ),
                      ClaudeCollapsible(
                        expanded: _tunnelMode == 'none',
                        builder: (_) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(13),
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
                                Wrap(
                                  alignment: WrapAlignment.spaceBetween,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    Text(
                                      '本机网卡 IP（可多选，跟随端口 :${widget.serverPort}）',
                                      style: sansStyle(
                                        c,
                                        size: 12.6,
                                        weight: FontWeight.w600,
                                        color: c.ink,
                                      ),
                                    ),
                                    Wrap(
                                      spacing: 6,
                                      children: [
                                        ClaudeButton(
                                          label: '选局域网与组网',
                                          compact: true,
                                          onPressed: () {
                                            setState(() {
                                              for (final o in _allIpOptions) {
                                                if (o.kind == 'lan' ||
                                                    o.kind == 'vpn') {
                                                  _selectedDirectIps.add(o.ip);
                                                }
                                              }
                                            });
                                          },
                                        ),
                                        if (_selectedDirectIps.isNotEmpty)
                                          ClaudeButton(
                                            label: '清空',
                                            compact: true,
                                            variant: ClaudeBtnVariant.ghost,
                                            onPressed: () => setState(
                                              _selectedDirectIps.clear,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 9),
                                Wrap(
                                  spacing: 7,
                                  runSpacing: 7,
                                  children: [
                                    for (final opt in _allIpOptions)
                                      SelectableIpChip(
                                        option: opt,
                                        selected:
                                            _selectedDirectIps.contains(opt.ip),
                                        onTap: () {
                                          setState(() {
                                            if (_selectedDirectIps
                                                .contains(opt.ip)) {
                                              _selectedDirectIps.remove(opt.ip);
                                            } else {
                                              _selectedDirectIps.add(opt.ip);
                                            }
                                          });
                                        },
                                      ),
                                  ],
                                ),
                                if (unboundIps.isNotEmpty) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 11,
                                      vertical: 8.5,
                                    ),
                                    decoration: ShapeDecoration(
                                      color: c.clay.withValues(
                                        alpha: c.isDark ? 0.14 : 0.08,
                                      ),
                                      shape: claudeSuperellipse(
                                        10,
                                        side: BorderSide(
                                          color: c.clay.withValues(alpha: 0.30),
                                        ),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '提示：当前监听地址尚未包含所选网卡 ${unboundIps.join(", ")}。',
                                          style: sansStyle(
                                            c,
                                            size: 11.8,
                                            color: c.clay,
                                            height: 1.42,
                                          ),
                                        ),
                                        const SizedBox(height: 5),
                                        ClaudeCheckToggle(
                                          value: _syncBindHosts,
                                          label: '保存时自动开放所选网卡监听并平滑重启',
                                          onChanged: (v) =>
                                              setState(() => _syncBindHosts = v),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 12),
                                Text(
                                  '手动输入地址 / 反代域名（可与上方网卡多选叠加）',
                                  style: sansStyle(
                                    c,
                                    size: 12.6,
                                    weight: FontWeight.w600,
                                    color: c.ink,
                                  ),
                                ),
                                const SizedBox(height: 7),
                                for (var i = 0;
                                    i < _manualUrlCtrls.length;
                                    i++) ...[
                                  if (i > 0) const SizedBox(height: 7),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _manualUrlCtrls[i],
                                          onChanged: (_) => setState(() {}),
                                          style: monoStyle(
                                            c,
                                            size: 12.4,
                                            color: c.ink,
                                          ),
                                          decoration: InputDecoration(
                                            hintText: i == 0
                                                ? '可选：如 https://mcp.example.com 或 192.168.1.50:8000'
                                                : '额外反代域名或自定义地址',
                                          ),
                                        ),
                                      ),
                                      if (_manualUrlCtrls.length > 1 ||
                                          _manualUrlCtrls[i]
                                              .text
                                              .trim()
                                              .isNotEmpty) ...[
                                        const SizedBox(width: 6),
                                        ClaudeButton(
                                          label: '',
                                          compact: true,
                                          tooltip: '移除该行',
                                          leading:
                                              const Icon(Icons.remove_rounded),
                                          onPressed: () =>
                                              _removeManualUrlRow(i),
                                        ),
                                      ],
                                      if (i == _manualUrlCtrls.length - 1) ...[
                                        const SizedBox(width: 6),
                                        ClaudeButton(
                                          label: '',
                                          compact: true,
                                          variant: ClaudeBtnVariant.clay,
                                          tooltip: '再添加一个自定义地址',
                                          leading:
                                              const Icon(Icons.add_rounded),
                                          onPressed: _addManualUrlRow,
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                                const SizedBox(height: 9),
                                Text(
                                  previewEps.isEmpty
                                      ? '未勾选或填写时，默认使用本机监听地址访问'
                                      : '已生成 ${previewEps.length} 个入口地址：${previewEps.take(2).join(" · ")}${previewEps.length > 2 ? " 等" : ""}',
                                  style: sansStyle(
                                    c,
                                    size: 11.5,
                                    color: previewEps.isEmpty ? c.meta : c.sage,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      ClaudeCollapsible(
                        expanded: _tunnelMode == 'token',
                        builder: (_) => Column(
                          children: [
                            _ModalGridRow(
                              label: 'Tunnel Token',
                              child: ClaudePasswordField(
                                controller: _tunTokenCtrl,
                                hintText: 'Cloudflare Zero Trust eyJ... Token',
                              ),
                            ),
                            _ModalGridRow(
                              label: '绑定公网域名',
                              child: TextField(
                                controller: _baseCtrl,
                                style: monoStyle(c, size: 12.5, color: c.ink),
                                decoration: const InputDecoration(
                                  hintText: 'https://mcp.example.com',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      ClaudeCollapsible(
                        expanded: _tunnelMode == 'quick',
                        builder: (_) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            '启动 Quick 隧道后会自动生成 trycloudflare.com 公网地址并热注入 OAuth 2.1。',
                            style: sansStyle(c, size: 12.5, color: c.muted),
                          ),
                        ),
                      ),
                      ClaudeCollapsible(
                        expanded: _tunnelMode != 'none',
                        builder: (_) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: ClaudeCheckToggle(
                            value: _tunnelAuto,
                            label: '跟随 MCP 服务自动启停该隧道',
                            onChanged: (v) => setState(() => _tunnelAuto = v),
                          ),
                        ),
                      ),
                      _ModalGridRow(
                        label: '鉴权方式',
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: ClaudeSegmented<String>(
                            value: _authMode,
                            items: const [
                              ('oauth-local', 'OAuth 2.1'),
                              ('bearer', 'Bearer Key'),
                              ('none', '无鉴权'),
                            ],
                            onChanged: (v) => setState(() => _authMode = v),
                          ),
                        ),
                      ),
                      ClaudeCollapsible(
                        expanded: _authMode == 'oauth-local',
                        builder: (_) => Column(
                          children: [
                            _ModalGridRow(
                              label: 'Client ID (备选)',
                              trailing: ClaudeButton(
                                label: '随机',
                                compact: true,
                                onPressed: () => setState(() {
                                  _cidCtrl.text =
                                      generateRandomToken('mcp-client-', 10);
                                }),
                              ),
                              child: TextField(
                                controller: _cidCtrl,
                                style: monoStyle(c, size: 12.5, color: c.ink),
                              ),
                            ),
                            _ModalGridRow(
                              label: 'Client Secret',
                              trailing: ClaudeButton(
                                label: '随机',
                                compact: true,
                                onPressed: () => setState(() {
                                  _csecCtrl.text =
                                      generateRandomToken('mcp-sec-', 24);
                                }),
                              ),
                              child: ClaudePasswordField(controller: _csecCtrl),
                            ),
                            _ModalGridRow(
                              label: '允许的回调 URI',
                              child: TextField(
                                controller: _rurisCtrl,
                                maxLines: 2,
                                style: monoStyle(c, size: 12, color: c.ink),
                                decoration: const InputDecoration(
                                  hintText: '留空自动放行动态注册回调（推荐）；或每行填一个固定 URI',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      ClaudeCollapsible(
                        expanded: _authMode == 'bearer',
                        builder: (_) => _ModalGridRow(
                          label: 'API Key',
                          trailing: ClaudeButton(
                            label: '随机',
                            compact: true,
                            onPressed: () => setState(() {
                              _apiKeyCtrl.text =
                                  generateRandomToken('sk-mcp-', 28);
                            }),
                          ),
                          child: ClaudePasswordField(controller: _apiKeyCtrl),
                        ),
                      ),
                      Divider(color: c.hairline, height: 22),
                      ClaudeCheckToggle(
                        value: _inheritPerm,
                        label: '继承全局默认权限（取消勾选可为该入口单独指定权限）',
                        onChanged: (v) => setState(() => _inheritPerm = v),
                      ),
                      ClaudeCollapsible(
                        expanded: !_inheritPerm,
                        builder: (_) => Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(
                                spacing: 16,
                                runSpacing: 6,
                                children: [
                                  ClaudeCheckToggle(
                                    value: _writable,
                                    label: '允许写入与执行',
                                    onChanged: (v) =>
                                        setState(() => _writable = v),
                                  ),
                                  ClaudeCheckToggle(
                                    value: _allowSecrets,
                                    label: '允许敏感文件',
                                    onChanged: (v) =>
                                        setState(() => _allowSecrets = v),
                                  ),
                                  ClaudeCheckToggle(
                                    value: _relaxedCmd,
                                    label: '客户端免弹窗声明',
                                    onChanged: (v) =>
                                        setState(() => _relaxedCmd = v),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              _ModalGridRow(
                                label: '目录白名单',
                                child: TextField(
                                  controller: _rootsCtrl,
                                  maxLines: 2,
                                  style: monoStyle(c, size: 12, color: c.ink),
                                  decoration: const InputDecoration(
                                    hintText: '每行一个允许访问的目录，留空允许全盘',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 10,
                runSpacing: 8,
                children: [
                  ClaudeButton(
                    label: '取消',
                    compact: true,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  ClaudeButton(
                    label: '确定保存',
                    compact: true,
                    variant: ClaudeBtnVariant.clay,
                    onPressed: _submit,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
class ProfileConnectDialog extends StatefulWidget {
  final ConsoleBackend backend;
  final Map<String, dynamic> profile;
  final List<String> effectiveBaseUrls;
  final ValueChanged<String> onToast;

  const ProfileConnectDialog({
    super.key,
    required this.backend,
    required this.profile,
    required this.effectiveBaseUrls,
    required this.onToast,
  });

  @override
  State<ProfileConnectDialog> createState() => _ProfileConnectDialogState();
}

class _ProfileConnectDialogState extends State<ProfileConnectDialog> {
  late String _selectedBaseUrl;
  Map<String, dynamic>? _healthResult;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _selectedBaseUrl = widget.effectiveBaseUrls.isNotEmpty
        ? widget.effectiveBaseUrls.first
        : 'http://127.0.0.1:8000';
  }

  Future<void> _testHealth() async {
    setState(() => _checking = true);
    try {
      final r = await runWithMinDuration(
        () => widget.backend.checkHealth(_selectedBaseUrl),
      );
      if (mounted) setState(() => _healthResult = r);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  String _withScheme(String raw, String scheme) {
    final stripped =
        raw.trim().replaceFirst(RegExp(r'^https?://', caseSensitive: false), '');
    return '$scheme://$stripped';
  }

  Widget _copyRow(
    ClaudePalette c,
    String label,
    String val,
    bool stackRow, {
    bool isUrl = false,
  }) {
    if (val.isEmpty) return const SizedBox.shrink();
    final valueBox = Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: ShapeDecoration(
        color: c.recessed,
        shape: claudeSuperellipse(10, side: BorderSide(color: c.hairline)),
      ),
      child: SelectableText(
        val,
        maxLines: 1,
        style: monoStyle(c, size: 12, color: c.ink),
      ),
    );
    final Widget copyBtn = isUrl
        ? EndpointCopyDropButton(
            label: '复制',
            options: [
              EndpointCopyOption(
                badge: 'HTTPS',
                url: _withScheme(val, 'https'),
                isHighlight: true,
              ),
              EndpointCopyOption(
                badge: 'HTTP',
                url: _withScheme(val, 'http'),
              ),
            ],
            onSelect: (opt) {
              Clipboard.setData(ClipboardData(text: opt.url));
              widget.onToast('已复制 $label (${opt.badge})');
            },
          )
        : ClaudeButton(
            label: '复制',
            compact: true,
            leading: const Icon(Icons.copy_rounded),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: val));
              widget.onToast('已复制 $label');
            },
          );

    if (stackRow) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(label, style: sansStyle(c, size: 12.5, color: c.muted)),
                copyBtn,
              ],
            ),
            const SizedBox(height: 5),
            valueBox,
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(
        children: [
          SizedBox(
            width: 114,
            child: Text(label, style: sansStyle(c, size: 12.5, color: c.muted)),
          ),
          Expanded(child: valueBox),
          const SizedBox(width: 8),
          copyBtn,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final p = widget.profile;
    final base = _selectedBaseUrl.replaceAll(RegExp(r'/+$'), '');
    final tr = (p['transport'] ?? 'dual').toString();
    final auth = (p['auth_mode'] ?? 'oauth-local').toString();
    final compact = MediaQuery.sizeOf(context).width < 520;
    final hasMultiUrls = widget.effectiveBaseUrls.length > 1;

    return Dialog(
      backgroundColor: c.paper2,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 28,
        vertical: 18,
      ),
      shape: claudeSuperellipse(22, side: BorderSide(color: c.hairline)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 585, maxHeight: 700),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 18 : 26,
            20,
            compact ? 18 : 26,
            18,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        const ClaudeSparkIcon(size: 18),
                        const SizedBox(width: 10),
                        Flexible(
                          child: Text(
                            '${p['name']} · 连接信息',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: serifTitleStyle(c, size: 19.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  ClaudeButton(
                    label: '关闭',
                    compact: true,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: LayoutBuilder(
                    builder: (ctx, box) {
                      final stackRow = box.maxWidth < 430;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (hasMultiUrls)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 11),
                              child: Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  Text(
                                    '切换查看与检测地址 (${widget.effectiveBaseUrls.length} 个)',
                                    style: sansStyle(
                                      c,
                                      size: 12.5,
                                      weight: FontWeight.w500,
                                      color: c.muted,
                                    ),
                                  ),
                                  ClaudeDropMenu<String>(
                                    value: _selectedBaseUrl,
                                    leadingIcon: Icons.lan_outlined,
                                    minMenuWidth: 240,
                                    items: [
                                      for (final u in widget.effectiveBaseUrls)
                                        ClaudeDropMenuItem(
                                          value: u,
                                          label: u,
                                          icon: u.startsWith('https://')
                                              ? Icons.lock_outline_rounded
                                              : Icons.router_outlined,
                                        ),
                                    ],
                                    onChanged: (nextUrl) {
                                      setState(() {
                                        _selectedBaseUrl = nextUrl;
                                        _healthResult = null;
                                      });
                                    },
                                  ),
                                ],
                              ),
                            ),
                          if (tr == 'dual' || tr == 'http')
                            _copyRow(
                              c,
                              'Streamable HTTP',
                              '$base/mcp',
                              stackRow,
                              isUrl: true,
                            ),
                          if (tr == 'dual' || tr == 'sse')
                            _copyRow(
                              c,
                              'Legacy SSE URL',
                              '$base/sse',
                              stackRow,
                              isUrl: true,
                            ),
                          _copyRow(
                            c,
                            '管理面板',
                            '$base/dashboard/',
                            stackRow,
                            isUrl: true,
                          ),
                          if (auth == 'oauth-local') ...[
                            Container(
                              margin: const EdgeInsets.only(bottom: 10, top: 2),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 9,
                              ),
                              decoration: ShapeDecoration(
                                color: c.sageBg,
                                shape: claudeSuperellipse(
                                  10,
                                  side: BorderSide(
                                    color: c.sage.withValues(alpha: 0.25),
                                  ),
                                ),
                              ),
                              child: Text(
                                '支持无感动态授权：客户端直接填入上方 Streamable HTTP 地址并输入本地密码即可完成连接；下方静态凭证仅供不支持动态注册的旧版客户端备用。',
                                style: sansStyle(
                                  c,
                                  size: 12,
                                  color: c.sage,
                                  height: 1.48,
                                ),
                              ),
                            ),
                            _copyRow(
                              c,
                              'OAuth Client ID',
                              (p['oauth_client_id'] ?? '').toString(),
                              stackRow,
                            ),
                            _copyRow(
                              c,
                              'Client Secret',
                              (p['oauth_client_secret'] ?? '').toString(),
                              stackRow,
                            ),
                          ] else if (auth == 'bearer') ...[
                            _copyRow(
                              c,
                              'Bearer Key',
                              (p['api_key'] ?? '').toString(),
                              stackRow,
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_healthResult != null) ...[
                _DialogHealthCard(result: _healthResult!),
                const SizedBox(height: 10),
              ],
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ClaudeButton(
                    label: _checking ? '测试中...' : '测试 /health 连通性',
                    compact: true,
                    loading: _checking,
                    leading: const Icon(Icons.monitor_heart_outlined),
                    variant: ClaudeBtnVariant.ink,
                    onPressed: _checking ? null : _testHealth,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModalGridRow extends StatelessWidget {
  final String label;
  final Widget child;
  final Widget? trailing;

  const _ModalGridRow({
    required this.label,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    return LayoutBuilder(
      builder: (ctx, box) {
        if (box.maxWidth < 480) {
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
                        label,
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
            children: [
              SizedBox(
                width: 152,
                child: Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(label, style: sansStyle(c, size: 13, color: c.muted)),
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

class _DialogHealthCard extends StatelessWidget {
  final Map<String, dynamic> result;

  const _DialogHealthCard({required this.result});

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final ok = result['ok'] == true;
    final rawBody = (result['body'] ?? '').toString().trim();
    final topErr = (result['error'] ?? '').toString().trim();
    final probes = ((result['probes'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    Map<String, dynamic>? parsedBody;
    if (rawBody.startsWith('{')) {
      try {
        final d = jsonDecode(rawBody);
        if (d is Map) parsedBody = Map<String, dynamic>.from(d);
      } catch (_) {}
    }

    final accent = ok ? c.sage : c.danger;
    final bg = ok ? c.sageBg : c.dangerBg;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: ShapeDecoration(
        color: bg,
        shape: claudeSuperellipse(
          12,
          side: BorderSide(color: accent.withValues(alpha: 0.35)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Icon(
                ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                size: 16,
                color: accent,
              ),
              Text(
                ok ? '服务连通正常' : '双协议探测均未连通',
                style: sansStyle(
                  c,
                  size: 12.5,
                  weight: FontWeight.w600,
                  color: accent,
                ),
              ),
              if (ok && parsedBody != null && parsedBody['server_name'] != null)
                ClaudePill(
                  text: '${parsedBody['server_name']}',
                  mono: false,
                  bg: c.paper2.withValues(alpha: 0.82),
                ),
            ],
          ),
          if (probes.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (var i = 0; i < probes.length; i++) ...[
              if (i > 0) const SizedBox(height: 5),
              Row(
                children: [
                  ClaudePill(
                    text: '${probes[i]['protocol'] ?? ''}'.toUpperCase(),
                    fg: '${probes[i]['protocol']}'.toUpperCase() == 'HTTPS'
                        ? c.sage
                        : c.clay,
                    bg: c.paper2,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: SelectableText(
                      '${probes[i]['url'] ?? ''}',
                      maxLines: 1,
                      style: monoStyle(c, size: 11.2, color: c.inkSoft),
                    ),
                  ),
                  const SizedBox(width: 6),
                  ClaudePill(
                    text:
                        '${probes[i]['ok'] == true ? "✓ " : "✕ "}${probes[i]['status_text'] ?? ""}',
                    mono: false,
                    fg: probes[i]['ok'] == true
                        ? c.sage
                        : (ok ? c.muted : c.danger),
                    bg: c.paper2,
                  ),
                ],
              ),
            ],
          ] else if (!ok && topErr.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(topErr, style: monoStyle(c, size: 11.5, color: c.danger)),
          ],
        ],
      ),
    );
  }
}