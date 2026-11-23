import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/console_backend.dart';
import '../theme/claude_theme.dart';

class SubMcpGatewayPage extends StatefulWidget {
  final ConsoleBackend backend;
  final List<Map<String, dynamic>> servers;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onToast;
  final double topPadding;
  final double extraBottomPadding;

  const SubMcpGatewayPage({
    super.key,
    required this.backend,
    required this.servers,
    required this.onRefresh,
    required this.onToast,
    this.topPadding = 0.0,
    this.extraBottomPadding = 0.0,
  });

  @override
  State<SubMcpGatewayPage> createState() => _SubMcpGatewayPageState();
}

class _SubMcpGatewayPageState extends State<SubMcpGatewayPage> {
  final Set<String> _testingNames = <String>{};
  final Set<String> _openDrawers = <String>{};
  final Set<String> _expandedTools = <String>{};
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _testServer(String name) async {
    setState(() => _testingNames.add(name));
    try {
      final res =
          await runWithMinDuration(() => widget.backend.testSubMcp(name));
      await widget.onRefresh();
      if (res['ok'] == true) {
        final cnt = (res['tools'] as List?)?.length ?? 0;
        if (mounted) setState(() => _openDrawers.add(name));
        widget.onToast('连接成功：发现 $cnt 个工具 (${res['ms']} ms)');
      } else {
        widget.onToast('连接失败：${res['error'] ?? ''}');
      }
    } finally {
      if (mounted) setState(() => _testingNames.remove(name));
    }
  }

  Future<void> _openEditModal({
    Map<String, dynamic>? existing,
    bool jsonMode = false,
  }) async {
    final saved = await showClaudeDialog<bool>(
      context: context,
      builder: (ctx) => _SubMcpModalDialog(
        backend: widget.backend,
        existing: existing,
        initialJsonMode: jsonMode,
        onToast: widget.onToast,
      ),
    );
    if (saved == true) {
      await widget.onRefresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final enabledCount =
        widget.servers.where((s) => s['enabled'] != false).length;

    return CustomScrollView(
      controller: _scrollCtrl,
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.topPadding > 0) SizedBox(height: widget.topPadding),
              ClaudeStaggeredReveal(
                index: 0,
                child: ClaudeEditorialPageHeader(
                  eyebrow: 'SUB-MCP GATEWAY',
                  leadingDot: ClaudeStatusDot(
                    color: enabledCount > 0 ? c.sage : c.meta,
                    pulsing: enabledCount > 0,
                    size: 6.0,
                  ),
                  title: '子 MCP 网关',
                  titleBadge: widget.servers.isNotEmpty
                      ? ClaudePill(
                          text: '$enabledCount / ${widget.servers.length} 已启用',
                          mono: false,
                          fg: enabledCount > 0 ? c.sage : c.muted,
                          bg: enabledCount > 0 ? c.sageBg : c.recessed,
                        )
                      : null,
                  subtitle: '挂载第三方 MCP 服务并由热驻留网关按需转发，避免客户端首轮工具表膨胀',
                  trailing: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ClaudeButton(
                        label: '粘贴 JSON 导入',
                        compact: true,
                        leading: const Icon(Icons.data_object_rounded),
                        onPressed: () => _openEditModal(jsonMode: true),
                      ),
                      ClaudeButton(
                        label: '添加子 MCP',
                        compact: true,
                        leading: const Icon(Icons.add_rounded),
                        variant: ClaudeBtnVariant.clay,
                        onPressed: () => _openEditModal(),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
        if (widget.servers.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ClaudeStaggeredReveal(
              index: 1,
              child: Center(
                key: const ValueKey('empty-submcp'),
                child: ClaudeCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 38,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: ShapeDecoration(
                          color: c.clay.withValues(alpha: 0.12),
                          shape: claudeSuperellipse(11),
                        ),
                        alignment: Alignment.center,
                        child: Icon(Icons.layers_outlined, size: 20, color: c.clay),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '尚未挂载嵌套子 MCP 服务',
                        style: serifTitleStyle(c, size: 17),
                      ),
                      const SizedBox(height: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 440),
                        child: Text(
                          '支持直接粘贴 Claude Desktop、Cursor 或 Antigravity 的 mcpServers JSON 配置，热驻留进程池按需毫秒级响应。',
                          textAlign: TextAlign.center,
                          style: sansStyle(
                            c,
                            size: 12.8,
                            color: c.muted,
                            height: 1.54,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          )
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: (MediaQuery.sizeOf(context).width < 700 ? 124 : 32) +
                    widget.extraBottomPadding,
              ),
              child: ClaudeListGroup(
                dividerIndent: 58,
                children: [
                  for (var idx = 0; idx < widget.servers.length; idx++)
                    _buildServerRow(context, c, widget.servers[idx]),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildServerRow(
    BuildContext context,
    ClaudePalette c,
    Map<String, dynamic> s,
  ) {
    final name = (s['name'] ?? '').toString();
    final enabled = s['enabled'] != false;
    final tr = (s['transport'] ?? 'stdio').toString();
    final isTesting = _testingNames.contains(name);
    final status =
        isTesting ? 'testing' : (s['status'] ?? 'idle').toString();
    final tools = ((s['tools'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final open = _openDrawers.contains(name);
    final endpoint = tr == 'stdio'
        ? '${s['command'] ?? ''} ${((s['args'] as List?) ?? const []).join(' ')}'
            .trim()
        : (s['url'] ?? '').toString();
    final desc = (s['description'] ?? '').toString().trim();
    final lastErr = (s['last_error'] ?? '').toString();

    Color dotColor = c.meta;
    if (status == 'ok') dotColor = c.sage;
    if (status == 'error') dotColor = c.danger;
    if (status == 'testing') dotColor = c.clay;

    final trColor = tr == 'stdio'
        ? c.clay
        : (tr == 'sse' ? c.purple : c.sage);

    return RepaintBoundary(
      key: ValueKey('sub-$name'),
      child: Opacity(
        opacity: enabled ? 1.0 : 0.62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: tools.isEmpty
                  ? null
                  : () {
                      setState(() {
                        if (open) {
                          _openDrawers.remove(name);
                        } else {
                          _openDrawers.add(name);
                        }
                      });
                    },
              hoverColor: c.paper3.withValues(alpha: 0.45),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 11,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // OrbStack-style compact server icon + live status dot
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: ShapeDecoration(
                            color: c.recessed,
                            shape: claudeSuperellipse(
                              8.5,
                              side: BorderSide(color: c.hairline),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            tr == 'stdio'
                                ? Icons.terminal_rounded
                                : Icons.public_rounded,
                            size: 16,
                            color: enabled ? trColor : c.muted,
                          ),
                        ),
                        Positioned(
                          right: -2,
                          bottom: -2,
                          child: Container(
                            padding: const EdgeInsets.all(1.5),
                            decoration: BoxDecoration(
                              color: c.paper2,
                              shape: BoxShape.circle,
                            ),
                            child: ClaudeStatusDot(
                              color: dotColor,
                              pulsing: isTesting || (enabled && status == 'ok'),
                              size: 6.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Wrap(
                            spacing: 6,
                            runSpacing: 3,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: sansStyle(
                                  c,
                                  size: 13.5,
                                  weight: FontWeight.w600,
                                  color: c.ink,
                                ),
                              ),
                              ClaudePill(
                                text: tr.toUpperCase(),
                                fg: trColor,
                                bg: trColor.withValues(alpha: 0.10),
                                border: trColor.withValues(alpha: 0.22),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2.5),
                          Text(
                            desc.isNotEmpty ? '$desc · $endpoint' : endpoint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle(c, size: 11.2, color: c.muted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Right controls: Tool count / Probe + Switch + ⋯ Menu
                    if (tools.isNotEmpty)
                      ClaudeButton(
                        label: MediaQuery.sizeOf(context).width < 430
                            ? '${tools.length}'
                            : '${tools.length} 工具',
                        compact: true,
                        variant: ClaudeBtnVariant.ghost,
                        leading: AnimatedRotation(
                          turns: open ? 0.5 : 0.0,
                          duration: ClaudeMotion.duration(
                            context,
                            ClaudeMotion.fast,
                          ),
                          child: const Icon(Icons.expand_more_rounded),
                        ),
                        onPressed: () {
                          setState(() {
                            if (open) {
                              _openDrawers.remove(name);
                            } else {
                              _openDrawers.add(name);
                            }
                          });
                        },
                      )
                    else
                      ClaudeButton(
                        label: isTesting ? '探测中' : '探测',
                        compact: true,
                        loading: isTesting,
                        variant: ClaudeBtnVariant.ghost,
                        leading: const Icon(Icons.radar_rounded),
                        onPressed: isTesting ? null : () => _testServer(name),
                      ),
                    const SizedBox(width: 8),
                    ClaudeSwitch(
                      value: enabled,
                      onChanged: (v) async {
                        await widget.backend.toggleSubMcp(name, v);
                        await widget.onRefresh();
                      },
                    ),
                    const SizedBox(width: 6),
                    ClaudeActionMenuButton(
                      tooltip: '更多操作',
                      actions: [
                        ClaudeMenuAction(
                          label: isTesting ? '正在探测工具...' : '探测并刷新工具列表',
                          icon: Icons.radar_rounded,
                          onSelected: () {
                            if (!isTesting) _testServer(name);
                          },
                        ),
                        ClaudeMenuAction(
                          label: '编辑服务配置',
                          icon: Icons.edit_outlined,
                          onSelected: () => _openEditModal(existing: s),
                        ),
                        ClaudeMenuAction(
                          label: tr == 'stdio' ? '复制启动命令' : '复制服务地址',
                          subtitle: endpoint,
                          icon: Icons.copy_rounded,
                          onSelected: () {
                            Clipboard.setData(ClipboardData(text: endpoint));
                            widget.onToast('已复制：$endpoint');
                          },
                        ),
                        ClaudeMenuAction(
                          label: '删除此子 MCP',
                          icon: Icons.delete_outline_rounded,
                          dividerBefore: true,
                          destructive: true,
                          onSelected: () async {
                            final ok = await showClaudeConfirmDialog(
                              context,
                              title: '删除子 MCP',
                              message: '确定移除嵌套子 MCP「$name」吗？',
                              confirmText: '删除',
                              destructive: true,
                            );
                            if (ok) {
                              await widget.backend.deleteSubMcp(name);
                              await widget.onRefresh();
                              widget.onToast('已删除 $name');
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            ClaudeCollapsible(
              expanded: lastErr.isNotEmpty,
              builder: (_) => Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(58, 0, 14, 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                decoration: ShapeDecoration(
                  color: c.dangerBg,
                  shape: claudeSuperellipse(
                    8,
                    side: BorderSide(color: c.danger.withValues(alpha: 0.28)),
                  ),
                ),
                child: Text(
                  lastErr,
                  style: monoStyle(c, size: 11.2, color: c.danger),
                ),
              ),
            ),
            ClaudeCollapsible(
              expanded: open && tools.isNotEmpty,
              builder: (_) => Container(
                decoration: BoxDecoration(
                  color: c.isDark
                      ? c.recessed.withValues(alpha: 0.65)
                      : c.recessed.withValues(alpha: 0.55),
                  border: Border(top: BorderSide(color: c.hairline)),
                ),
                padding: const EdgeInsets.fromLTRB(58, 8, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var ti = 0; ti < tools.length; ti++) ...[
                      if (ti > 0)
                        Divider(
                          height: 1,
                          color: c.hairline.withValues(alpha: 0.65),
                        ),
                      _SubMcpToolRow(
                        tool: tools[ti],
                        expanded: _expandedTools.contains(
                          '$name::${tools[ti]['name']}',
                        ),
                        onToggle: () {
                          final tKey = '$name::${tools[ti]['name']}';
                          setState(() {
                            if (_expandedTools.contains(tKey)) {
                              _expandedTools.remove(tKey);
                            } else {
                              _expandedTools.add(tKey);
                            }
                          });
                        },
                        onCopyName: () {
                          final toolName =
                              (tools[ti]['name'] ?? '').toString();
                          Clipboard.setData(ClipboardData(text: toolName));
                          widget.onToast('已复制工具名: $toolName');
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubMcpToolRow extends StatelessWidget {
  final Map<String, dynamic> tool;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onCopyName;

  const _SubMcpToolRow({
    required this.tool,
    required this.expanded,
    required this.onToggle,
    required this.onCopyName,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final name = (tool['name'] ?? '').toString();
    final desc = (tool['description'] ?? '').toString().trim();
    final schema = tool['inputSchema'] is Map
        ? Map<String, dynamic>.from(tool['inputSchema'] as Map)
        : const <String, dynamic>{};
    final props = schema['properties'] is Map
        ? Map<String, dynamic>.from(schema['properties'] as Map)
        : const <String, dynamic>{};
    final requiredSet = ((schema['required'] as List?) ?? const [])
        .map((e) => e.toString())
        .toSet();

    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.build_outlined, size: 12.5, color: c.clay),
                const SizedBox(width: 7),
                Text(
                  name,
                  style: monoStyle(
                    c,
                    size: 11.8,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                const SizedBox(width: 8),
                if (desc.isNotEmpty && !expanded)
                  Expanded(
                    child: Text(
                      desc,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sansStyle(c, size: 11.5, color: c.muted),
                    ),
                  )
                else
                  const Spacer(),
                if (props.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  ClaudePill(
                    text: '${props.length} 参数',
                    mono: false,
                    bg: c.paper2,
                  ),
                ],
                const SizedBox(width: 4),
                Tooltip(
                  message: '复制工具名',
                  child: InkWell(
                    onTap: onCopyName,
                    borderRadius: BorderRadius.circular(5),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        Icons.copy_rounded,
                        size: 12.5,
                        color: c.muted,
                      ),
                    ),
                  ),
                ),
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 15,
                  color: c.meta,
                ),
              ],
            ),
            ClaudeCollapsible(
              expanded: expanded,
              builder: (_) => Padding(
                padding: const EdgeInsets.fromLTRB(19, 6, 4, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (desc.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: SelectableText(
                          desc,
                          style: sansStyle(
                            c,
                            size: 11.8,
                            color: c.inkSoft,
                            height: 1.45,
                          ),
                        ),
                      ),
                    if (props.isNotEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(9),
                        decoration: ShapeDecoration(
                          color: c.paper2,
                          shape: claudeSuperellipse(
                            8,
                            side: BorderSide(color: c.hairline),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final e in props.entries)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: Builder(
                                  builder: (_) {
                                    final pMap = e.value is Map
                                        ? Map<String, dynamic>.from(
                                            e.value as Map,
                                          )
                                        : const <String, dynamic>{};
                                    final pType =
                                        (pMap['type'] ?? 'any').toString();
                                    final pDesc = (pMap['description'] ?? '')
                                        .toString()
                                        .trim();
                                    final isReq = requiredSet.contains(e.key);
                                    return Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          e.key,
                                          style: monoStyle(
                                            c,
                                            size: 11.4,
                                            weight: FontWeight.w600,
                                            color: c.ink,
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        ClaudePill(text: pType),
                                        if (isReq) ...[
                                          const SizedBox(width: 5),
                                          ClaudePill(
                                            text: '必填',
                                            mono: false,
                                            fg: c.clay,
                                            bg: c.clay.withValues(alpha: 0.10),
                                          ),
                                        ],
                                        if (pDesc.isNotEmpty) ...[
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              pDesc,
                                              style: sansStyle(
                                                c,
                                                size: 11.2,
                                                color: c.muted,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    );
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SubMcpModalDialog extends StatefulWidget {
  final ConsoleBackend backend;
  final Map<String, dynamic>? existing;
  final bool initialJsonMode;
  final ValueChanged<String> onToast;

  const _SubMcpModalDialog({
    required this.backend,
    required this.existing,
    required this.initialJsonMode,
    required this.onToast,
  });

  @override
  State<_SubMcpModalDialog> createState() => _SubMcpModalDialogState();
}

class _SubMcpModalDialogState extends State<_SubMcpModalDialog> {
  late bool _jsonMode = widget.initialJsonMode && widget.existing == null;
  String _proto = 'stdio';
  bool _probing = false;
  bool _saving = false;

  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _cmdCtrl = TextEditingController();
  final _argsCtrl = TextEditingController();
  final _cwdCtrl = TextEditingController();
  final _envCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _headersCtrl = TextEditingController();
  final _timeoutCtrl = TextEditingController(text: '30');
  final _jsonCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _proto = (e['transport'] ?? 'stdio').toString();
      _nameCtrl.text = (e['name'] ?? '').toString();
      _descCtrl.text = (e['description'] ?? '').toString();
      _cmdCtrl.text = (e['command'] ?? '').toString();
      _argsCtrl.text = ((e['args'] as List?) ?? const []).join('\n');
      _cwdCtrl.text = (e['cwd'] ?? '').toString();
      final env = (e['env'] as Map?) ?? const {};
      _envCtrl.text =
          env.entries.map((x) => '${x.key}=${x.value}').join('\n');
      _urlCtrl.text = (e['url'] ?? '').toString();
      final hdrs = (e['headers'] as Map?) ?? const {};
      _headersCtrl.text =
          hdrs.entries.map((x) => '${x.key}: ${x.value}').join('\n');
      _timeoutCtrl.text = '${e['timeout'] ?? 30}';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _cmdCtrl.dispose();
    _argsCtrl.dispose();
    _cwdCtrl.dispose();
    _envCtrl.dispose();
    _urlCtrl.dispose();
    _headersCtrl.dispose();
    _timeoutCtrl.dispose();
    _jsonCtrl.dispose();
    super.dispose();
  }

  Map<String, String> _parseKv(String raw, String sep) {
    final out = <String, String>{};
    for (final line in raw.split('\n')) {
      final s = line.trim();
      if (s.isEmpty || s.startsWith('#')) continue;
      final idx = s.indexOf(sep);
      if (idx > 0) {
        out[s.substring(0, idx).trim()] = s.substring(idx + 1).trim();
      }
    }
    return out;
  }

  Map<String, dynamic> _buildDraft() {
    return {
      'name': _nameCtrl.text.trim(),
      'description': _descCtrl.text.trim(),
      'transport': _proto,
      'enabled': widget.existing?['enabled'] ?? true,
      'command': _cmdCtrl.text.trim(),
      'args': _argsCtrl.text
          .split('\n')
          .map((e) => e.trim())
          .where((s) => s.isNotEmpty)
          .toList(),
      'cwd': _cwdCtrl.text.trim(),
      'env': _parseKv(_envCtrl.text, '='),
      'url': _urlCtrl.text.trim(),
      'headers': _parseKv(_headersCtrl.text, ':'),
      'timeout': int.tryParse(_timeoutCtrl.text.trim()) ?? 30,
    };
  }

  Future<void> _probe() async {
    setState(() => _probing = true);
    try {
      final res = await widget.backend.probeSubMcpDraft(_buildDraft());
      if (res['ok'] == true) {
        if (_nameCtrl.text.trim().isEmpty &&
            (res['name'] ?? '').toString().isNotEmpty) {
          _nameCtrl.text = res['name'].toString();
        }
        if (_descCtrl.text.trim().isEmpty &&
            (res['description'] ?? '').toString().isNotEmpty) {
          _descCtrl.text = res['description'].toString();
        }
        widget.onToast(
          '探测成功：发现 ${res['tool_count']} 个工具 (${res['ms']} ms)',
        );
      } else {
        widget.onToast('探测失败：${res['error'] ?? ''}');
      }
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      if (_jsonMode) {
        final res = await widget.backend.importSubMcpsJson(_jsonCtrl.text);
        if (res['ok'] == true) {
          widget.onToast('成功导入 ${res['count']} 个子 MCP');
          if (mounted) Navigator.of(context).pop(true);
        } else {
          widget.onToast(res['error']?.toString() ?? '导入失败');
        }
        return;
      }

      final res = await widget.backend.upsertSubMcp(
        _buildDraft(),
        oldName: widget.existing?['name']?.toString(),
      );
      if (res['ok'] == true) {
        widget.onToast('已保存子 MCP');
        if (mounted) Navigator.of(context).pop(true);
      } else {
        widget.onToast(res['error']?.toString() ?? '保存失败');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final compact = MediaQuery.sizeOf(context).width < 540;

    return Dialog(
      backgroundColor: c.paper2,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 28,
        vertical: 18,
      ),
      shape: claudeSuperellipse(
        16,
        side: BorderSide(color: c.hairline),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 580, maxHeight: 680),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 16 : 22,
                16,
                compact ? 14 : 18,
                14,
              ),
              child: Row(
                children: [
                  const ClaudeSparkIcon(size: 17),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      widget.existing != null ? '编辑子 MCP 服务' : '添加子 MCP 服务',
                      style: serifTitleStyle(c, size: 17),
                    ),
                  ),
                  if (widget.existing == null) ...[
                    ClaudeSegmented<bool>(
                      value: _jsonMode,
                      items: const [(false, '表单配置'), (true, '粘贴 JSON')],
                      onChanged: (v) => setState(() => _jsonMode = v),
                    ),
                    const SizedBox(width: 8),
                  ],
                  ClaudeButton(
                    label: '',
                    compact: true,
                    variant: ClaudeBtnVariant.ghost,
                    leading: const Icon(Icons.close_rounded, size: 17),
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: c.hairline),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  compact ? 16 : 22,
                  16,
                  compact ? 16 : 22,
                  14,
                ),
                child: _jsonMode
                    ? Column(
                        key: const ValueKey('json-mode'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '支持直接粘贴 Claude Desktop、Cursor 或 Antigravity 的 mcpServers JSON 配置：',
                            style: sansStyle(
                              c,
                              size: 12.2,
                              color: c.muted,
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _jsonCtrl,
                            maxLines: 12,
                            style: monoStyle(c, size: 12.2, color: c.ink),
                            decoration: const InputDecoration(
                              hintText:
                                  '{\n  "mcpServers": {\n    "memory": {\n      "command": "npx",\n      "args": ["-y", "@modelcontextprotocol/server-memory"]\n    }\n  }\n}',
                            ),
                          ),
                        ],
                      )
                    : Column(
                        key: const ValueKey('form-mode'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClaudeFormRow(
                            label: '传输协议',
                            labelWidth: 100,
                            stackBreakpoint: 430,
                            horizontalAlignment: CrossAxisAlignment.center,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: ClaudeSegmented<String>(
                                value: _proto,
                                items: const [
                                  ('stdio', 'stdio 进程'),
                                  ('http', 'Streamable HTTP'),
                                  ('sse', 'SSE'),
                                ],
                                onChanged: (v) => setState(() => _proto = v),
                              ),
                            ),
                          ),
                          ClaudeCollapsible(
                            expanded: _proto == 'stdio',
                            builder: (_) => Column(
                              children: [
                                ClaudeFormRow(
                                  label: '启动命令',
                                  labelWidth: 100,
                                  stackBreakpoint: 430,
                                  child: TextField(
                                    controller: _cmdCtrl,
                                    style: monoStyle(
                                      c,
                                      size: 12.6,
                                      color: c.ink,
                                    ),
                                    decoration: const InputDecoration(
                                      hintText: '如 npx、uvx、python',
                                    ),
                                  ),
                                ),
                                ClaudeFormRow(
                                  label: '命令参数',
                                  labelWidth: 100,
                                  stackBreakpoint: 430,
                                  child: TextField(
                                    controller: _argsCtrl,
                                    maxLines: 3,
                                    style: monoStyle(
                                      c,
                                      size: 12.2,
                                      color: c.ink,
                                    ),
                                    decoration: const InputDecoration(
                                      hintText:
                                          '每行一个参数，例如：\n-y\n@modelcontextprotocol/server-memory',
                                    ),
                                  ),
                                ),
                                ClaudeFormRow(
                                  label: '工作目录',
                                  labelWidth: 100,
                                  stackBreakpoint: 430,
                                  child: TextField(
                                    controller: _cwdCtrl,
                                    style: monoStyle(
                                      c,
                                      size: 12.2,
                                      color: c.ink,
                                    ),
                                    decoration: const InputDecoration(
                                      hintText: '留空使用默认目录（选填）',
                                    ),
                                  ),
                                ),
                                ClaudeFormRow(
                                  label: '环境变量',
                                  labelWidth: 100,
                                  stackBreakpoint: 430,
                                  child: TextField(
                                    controller: _envCtrl,
                                    maxLines: 2,
                                    style: monoStyle(
                                      c,
                                      size: 12.2,
                                      color: c.ink,
                                    ),
                                    decoration: const InputDecoration(
                                      hintText: '每行一个 KEY=VALUE（选填）',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ClaudeCollapsible(
                            expanded: _proto != 'stdio',
                            builder: (_) => Column(
                              children: [
                                ClaudeFormRow(
                                  label: '服务地址 URL',
                                  labelWidth: 100,
                                  stackBreakpoint: 430,
                                  child: TextField(
                                    controller: _urlCtrl,
                                    style: monoStyle(
                                      c,
                                      size: 12.6,
                                      color: c.ink,
                                    ),
                                    decoration: const InputDecoration(
                                      hintText: 'https://example.com/mcp',
                                    ),
                                  ),
                                ),
                                ClaudeFormRow(
                                  label: '请求头 Headers',
                                  labelWidth: 100,
                                  stackBreakpoint: 430,
                                  child: TextField(
                                    controller: _headersCtrl,
                                    maxLines: 2,
                                    style: monoStyle(
                                      c,
                                      size: 12.2,
                                      color: c.ink,
                                    ),
                                    decoration: const InputDecoration(
                                      hintText: '每行一个 Key: Value（选填）',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          ClaudeFormRow(
                            label: '子 MCP 名称',
                            labelWidth: 100,
                            stackBreakpoint: 430,
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _nameCtrl,
                                    style: monoStyle(
                                      c,
                                      size: 12.6,
                                      color: c.ink,
                                    ),
                                    decoration: const InputDecoration(
                                      hintText: '可留空点右侧自动获取',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ClaudeButton(
                                  label: _probing ? '探测中...' : '自动探测',
                                  compact: true,
                                  loading: _probing,
                                  leading: const Icon(
                                    Icons.auto_fix_high_rounded,
                                  ),
                                  onPressed: _probing ? null : _probe,
                                ),
                              ],
                            ),
                          ),
                          ClaudeFormRow(
                            label: '功能简介',
                            labelWidth: 100,
                            stackBreakpoint: 430,
                            child: TextField(
                              controller: _descCtrl,
                              style: sansStyle(c, size: 12.8, color: c.ink),
                              decoration: const InputDecoration(
                                hintText: '自动识别或手动填写（选填）',
                              ),
                            ),
                          ),
                          ClaudeFormRow(
                            label: '超时（秒）',
                            labelWidth: 100,
                            stackBreakpoint: 430,
                            horizontalAlignment: CrossAxisAlignment.center,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: SizedBox(
                                width: 108,
                                child: TextField(
                                  controller: _timeoutCtrl,
                                  keyboardType: TextInputType.number,
                                  style: monoStyle(
                                    c,
                                    size: 12.6,
                                    color: c.ink,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
            Divider(height: 1, color: c.hairline),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 16 : 22,
                vertical: 12,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ClaudeButton(
                    label: '取消',
                    compact: true,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 8),
                  ClaudeButton(
                    label: _saving ? '保存中...' : '保存配置',
                    compact: true,
                    loading: _saving,
                    variant: ClaudeBtnVariant.clay,
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
