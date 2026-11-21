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
      final res = await runWithMinDuration(() => widget.backend.testSubMcp(name));
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
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('子 MCP 网关', style: serifTitleStyle(c, size: 24)),
                        const SizedBox(height: 4),
                        Text(
                          '把常用 MCP 服务挂在这里按需取用 · 免去首轮冗长工具列表，改完立即生效',
                          style: sansStyle(c, size: 12.5, color: c.muted),
                        ),
                      ],
                    ),
                    Wrap(
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
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
          ),
        ),
        if (widget.servers.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ClaudeStaggeredReveal(
              index: 2,
              child: Center(
                key: const ValueKey('empty-submcp'),
                child: ClaudeCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 42,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: ShapeDecoration(
                          color: c.clay.withValues(alpha: 0.12),
                          shape: claudeSuperellipse(15),
                        ),
                        alignment: Alignment.center,
                        child: const ClaudeSparkIcon(size: 22),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '尚未挂载嵌套子 MCP 服务',
                        style: serifTitleStyle(c, size: 19),
                      ),
                      const SizedBox(height: 8),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: Text(
                          '支持直接粘贴 Claude Desktop、Cursor 或 Antigravity 的 mcpServers JSON 配置，由三元网关统一按需调度。',
                          textAlign: TextAlign.center,
                          style: sansStyle(
                            c,
                            size: 13.5,
                            color: c.muted,
                            height: 1.60,
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
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: (MediaQuery.sizeOf(context).width < 700 ? 124 : 36) + widget.extraBottomPadding,
            ),
            sliver: SliverList.separated(
              key: const ValueKey('submcp-list'),
              itemCount: widget.servers.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (ctx, idx) {
                      final s = widget.servers[idx];
                      final name = (s['name'] ?? '').toString();
                      final enabled = s['enabled'] != false;
                      final tr = (s['transport'] ?? 'stdio').toString();
                      final isTesting = _testingNames.contains(name);
                      final status = isTesting
                          ? 'testing'
                          : (s['status'] ?? 'idle').toString();
                      final tools = ((s['tools'] as List?) ?? const [])
                          .whereType<Map>()
                          .map((e) => Map<String, dynamic>.from(e))
                          .toList();
                      final open = _openDrawers.contains(name);
                      final endpoint = tr == 'stdio'
                          ? '${s['command'] ?? ''} ${((s['args'] as List?) ?? const []).join(' ')}'
                              .trim()
                          : (s['url'] ?? '').toString();
                      final lastErr = (s['last_error'] ?? '').toString();

                      Color dotColor = c.meta.withValues(alpha: 0.6);
                      if (status == 'ok') dotColor = c.sage;
                      if (status == 'error') dotColor = c.danger;
                      if (status == 'testing') dotColor = c.clay;

                      return RepaintBoundary(
                        child: AnimatedOpacity(
                          key: ValueKey('sub-$name'),
                          duration:
                              ClaudeMotion.duration(context, ClaudeMotion.base),
                          curve: ClaudeMotion.editorialOut,
                          opacity: enabled ? 1.0 : 0.58,
                          child: ClaudeCard(
                            hoverable: true,
                            padding: const EdgeInsets.all(18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  alignment: WrapAlignment.spaceBetween,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 10,
                                  runSpacing: 8,
                                  children: [
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ClaudeStatusDot(
                                          color: dotColor,
                                          pulsing: isTesting ||
                                              (enabled && status == 'ok'),
                                          size: 7.5,
                                        ),
                                        const SizedBox(width: 8),
                                        Flexible(
                                          child: Text(
                                            name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: serifTitleStyle(c, size: 18),
                                          ),
                                        ),
                                        const SizedBox(width: 9),
                                        ClaudePill(
                                          text: tr.toUpperCase(),
                                          fg: tr == 'stdio'
                                              ? c.clay
                                              : (tr == 'sse'
                                                  ? c.purple
                                                  : c.sage),
                                          bg: tr == 'stdio'
                                              ? c.clay.withValues(alpha: 0.12)
                                              : (tr == 'sse'
                                                  ? c.purpleBg
                                                  : c.sageBg),
                                          border: tr == 'stdio'
                                              ? c.clay.withValues(alpha: 0.24)
                                              : null,
                                        ),
                                      ],
                                    ),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 6,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        ClaudeSwitch(
                                          value: enabled,
                                          onChanged: (v) async {
                                            await widget.backend
                                                .toggleSubMcp(name, v);
                                            await widget.onRefresh();
                                          },
                                        ),
                                        ClaudeButton(
                                          label:
                                              isTesting ? '探测中...' : '探测工具',
                                          compact: true,
                                          loading: isTesting,
                                          leading: const Icon(
                                            Icons.radar_rounded,
                                          ),
                                          onPressed: isTesting
                                              ? null
                                              : () => _testServer(name),
                                        ),
                                        if (tools.isNotEmpty)
                                          ClaudeButton(
                                            label: open
                                                ? '收起 (${tools.length})'
                                                : '工具 (${tools.length})',
                                            compact: true,
                                            leading: AnimatedRotation(
                                              turns: open ? 0.5 : 0.0,
                                              duration: ClaudeMotion.duration(
                                                context,
                                                ClaudeMotion.base,
                                              ),
                                              curve: ClaudeMotion.editorialOut,
                                              child: const Icon(
                                                Icons.expand_more_rounded,
                                              ),
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
                                          ),
                                        ClaudeButton(
                                          label: '编辑',
                                          compact: true,
                                          variant: ClaudeBtnVariant.ghost,
                                          onPressed: () =>
                                              _openEditModal(existing: s),
                                        ),
                                        ClaudeButton(
                                          label: '删除',
                                          compact: true,
                                          variant: ClaudeBtnVariant.ghost,
                                          onPressed: () async {
                                            final ok =
                                                await showClaudeConfirmDialog(
                                              context,
                                              title: '删除子 MCP',
                                              message:
                                                  '确定移除嵌套子 MCP「$name」吗？',
                                              confirmText: '删除',
                                              destructive: true,
                                            );
                                            if (ok) {
                                              await widget.backend
                                                  .deleteSubMcp(name);
                                              await widget.onRefresh();
                                              widget.onToast('已删除 $name');
                                            }
                                          },
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                if ((s['description'] ?? '')
                                    .toString()
                                    .trim()
                                    .isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    s['description'].toString(),
                                    style: sansStyle(
                                      c,
                                      size: 13,
                                      color: c.muted,
                                      height: 1.5,
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 10),
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  decoration: ShapeDecoration(
                                    color: c.recessed,
                                    shape: claudeSuperellipse(11),
                                  ),
                                  child: SelectableText(
                                    endpoint,
                                    maxLines: 1,
                                    style: monoStyle(c, size: 12),
                                  ),
                                ),
                                ClaudeCollapsible(
                                  expanded: lastErr.isNotEmpty,
                                  builder: (_) => Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.all(10),
                                      decoration: ShapeDecoration(
                                        color: c.dangerBg,
                                        shape: claudeSuperellipse(
                                          10,
                                          side: BorderSide(
                                            color: c.danger
                                                .withValues(alpha: 0.28),
                                          ),
                                        ),
                                      ),
                                      child: Text(
                                        lastErr,
                                        style: monoStyle(
                                          c,
                                          size: 11.5,
                                          color: c.danger,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                ClaudeCollapsible(
                                  expanded: open && tools.isNotEmpty,
                                  builder: (_) => Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const SizedBox(height: 12),
                                      Divider(color: c.hairline.withValues(alpha: 0.45), height: 1),
                                      const SizedBox(height: 12),
                                      LayoutBuilder(
                                        builder: (ctx, tbox) {
                                          final cols = tbox.maxWidth < 460
                                              ? 1
                                              : (tbox.maxWidth < 740 ? 2 : 3);
                                          final gap = 9.0;
                                          final itemW = (tbox.maxWidth -
                                                  gap * (cols - 1)) /
                                              cols;
                                          return Wrap(
                                            spacing: gap,
                                            runSpacing: gap,
                                            children: tools.map((t) {
                                              final toolName =
                                                  (t['name'] ?? '').toString();
                                              final tKey = '$name::$toolName';
                                              final isToolOpen = _expandedTools
                                                  .contains(tKey);
                                              return SizedBox(
                                                width: itemW,
                                                child: _SubMcpToolTile(
                                                  tool: t,
                                                  expanded: isToolOpen,
                                                  onToggle: () {
                                                    setState(() {
                                                      if (isToolOpen) {
                                                        _expandedTools
                                                            .remove(tKey);
                                                      } else {
                                                        _expandedTools
                                                            .add(tKey);
                                                      }
                                                    });
                                                  },
                                                  onCopyName: () {
                                                    Clipboard.setData(
                                                      ClipboardData(
                                                        text: toolName,
                                                      ),
                                                    );
                                                    widget.onToast(
                                                      '已复制工具名: $toolName',
                                                    );
                                                  },
                                                ),
                                              );
                                            }).toList(),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                );
              },
            ),
          ),
      ],
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
        22,
        side: BorderSide(color: c.hairline),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 590, maxHeight: 700),
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
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 10,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const ClaudeSparkIcon(size: 18),
                      const SizedBox(width: 10),
                      Text(
                        widget.existing != null ? '编辑子 MCP' : '添加子 MCP',
                        style: serifTitleStyle(c, size: 20),
                      ),
                    ],
                  ),
                  if (widget.existing == null)
                    ClaudeSegmented<bool>(
                      value: _jsonMode,
                      items: const [(false, '表单配置'), (true, '粘贴 JSON')],
                      onChanged: (v) => setState(() => _jsonMode = v),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Flexible(
                child: SingleChildScrollView(
                  child: AnimatedSize(
                    duration: ClaudeMotion.duration(context, ClaudeMotion.base),
                    curve: ClaudeMotion.editorialOut,
                    alignment: Alignment.topCenter,
                    child: _jsonMode
                        ? Column(
                            key: const ValueKey('json-mode'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '支持直接粘贴 Claude Desktop、Cursor 或 Antigravity 的 mcpServers JSON 配置：',
                                style: sansStyle(
                                  c,
                                  size: 12.5,
                                  color: c.muted,
                                ),
                              ),
                              const SizedBox(height: 10),
                              TextField(
                                controller: _jsonCtrl,
                                maxLines: 12,
                                style: monoStyle(c, size: 12.5, color: c.ink),
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
                                labelWidth: 104,
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
                                    onChanged: (v) =>
                                        setState(() => _proto = v),
                                  ),
                                ),
                              ),
                              ClaudeCollapsible(
                                expanded: _proto == 'stdio',
                                builder: (_) => Column(
                                  children: [
                                    ClaudeFormRow(
                                      label: '启动命令',
                                      labelWidth: 104,
                                      stackBreakpoint: 430,
                                      child: TextField(
                                        controller: _cmdCtrl,
                                        style: monoStyle(
                                          c,
                                          size: 13,
                                          color: c.ink,
                                        ),
                                        decoration: const InputDecoration(
                                          hintText: '如 npx、uvx、python',
                                        ),
                                      ),
                                    ),
                                    ClaudeFormRow(
                                      label: '命令参数',
                                      labelWidth: 104,
                                      stackBreakpoint: 430,
                                      child: TextField(
                                        controller: _argsCtrl,
                                        maxLines: 3,
                                        style: monoStyle(
                                          c,
                                          size: 12.5,
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
                                      labelWidth: 104,
                                      stackBreakpoint: 430,
                                      child: TextField(
                                        controller: _cwdCtrl,
                                        style: monoStyle(
                                          c,
                                          size: 12.5,
                                          color: c.ink,
                                        ),
                                        decoration: const InputDecoration(
                                          hintText: '留空使用默认目录（选填）',
                                        ),
                                      ),
                                    ),
                                    ClaudeFormRow(
                                      label: '环境变量',
                                      labelWidth: 104,
                                      stackBreakpoint: 430,
                                      child: TextField(
                                        controller: _envCtrl,
                                        maxLines: 2,
                                        style: monoStyle(
                                          c,
                                          size: 12.5,
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
                                      labelWidth: 104,
                                      stackBreakpoint: 430,
                                      child: TextField(
                                        controller: _urlCtrl,
                                        style: monoStyle(
                                          c,
                                          size: 13,
                                          color: c.ink,
                                        ),
                                        decoration: const InputDecoration(
                                          hintText: 'https://example.com/mcp',
                                        ),
                                      ),
                                    ),
                                    ClaudeFormRow(
                                      label: '请求头 Headers',
                                      labelWidth: 104,
                                      stackBreakpoint: 430,
                                      child: TextField(
                                        controller: _headersCtrl,
                                        maxLines: 2,
                                        style: monoStyle(
                                          c,
                                          size: 12.5,
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
                                labelWidth: 104,
                                stackBreakpoint: 430,
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _nameCtrl,
                                        style: monoStyle(
                                          c,
                                          size: 13,
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
                                labelWidth: 104,
                                stackBreakpoint: 430,
                                child: TextField(
                                  controller: _descCtrl,
                                  style: sansStyle(c, size: 13, color: c.ink),
                                  decoration: const InputDecoration(
                                    hintText: '自动识别或手动填写（选填）',
                                  ),
                                ),
                              ),
                              ClaudeFormRow(
                                label: '超时（秒）',
                                labelWidth: 104,
                                stackBreakpoint: 430,
                                horizontalAlignment: CrossAxisAlignment.center,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  child: SizedBox(
                                    width: 112,
                                    child: TextField(
                                      controller: _timeoutCtrl,
                                      keyboardType: TextInputType.number,
                                      style: monoStyle(
                                        c,
                                        size: 13,
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
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  ClaudeButton(
                    label: _saving ? '保存中...' : '保存配置',
                    compact: true,
                    variant: ClaudeBtnVariant.clay,
                    onPressed: _saving ? null : _save,
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

class _SubMcpToolTile extends StatelessWidget {
  final Map<String, dynamic> tool;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onCopyName;

  const _SubMcpToolTile({
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

    return AnimatedContainer(
      duration: ClaudeMotion.duration(context, ClaudeMotion.base),
      curve: ClaudeMotion.editorialOut,
      decoration: ShapeDecoration(
        color: expanded ? c.paper2 : c.recessed,
        shape: claudeSuperellipse(
          11,
          side: BorderSide(
            color: expanded ? c.clay.withValues(alpha: 0.45) : c.hairline,
          ),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(11),
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: expanded ? 2 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(
                          c,
                          size: 12,
                          color: c.ink,
                          weight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (props.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      ClaudePill(
                        text: '${props.length} 参数',
                        mono: false,
                        bg: c.paper3,
                      ),
                    ],
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: expanded ? 0.5 : 0.0,
                      duration: ClaudeMotion.duration(
                        context,
                        const Duration(milliseconds: 180),
                      ),
                      curve: ClaudeMotion.editorialOut,
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 16,
                        color: c.muted,
                      ),
                    ),
                  ],
                ),
                if (!expanded && desc.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    desc,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: sansStyle(
                      c,
                      size: 11.5,
                      color: c.muted,
                      height: 1.45,
                    ),
                  ),
                ],
                ClaudeCollapsible(
                  expanded: expanded,
                  builder: (_) => Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (desc.isNotEmpty)
                          SelectableText(
                            desc,
                            style: sansStyle(
                              c,
                              size: 12,
                              color: c.inkSoft,
                              height: 1.5,
                            ),
                          ),
                        if (props.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(9),
                            decoration: ShapeDecoration(
                              color: c.recessed,
                              shape: claudeSuperellipse(
                                9,
                                side: BorderSide(color: c.hairline),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: props.entries.map((e) {
                                final pMap = e.value is Map
                                    ? Map<String, dynamic>.from(e.value as Map)
                                    : const <String, dynamic>{};
                                final pType =
                                    (pMap['type'] ?? 'any').toString();
                                final pDesc =
                                    (pMap['description'] ?? '').toString().trim();
                                final isReq = requiredSet.contains(e.key);
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Wrap(
                                        spacing: 6,
                                        runSpacing: 4,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                            e.key,
                                            style: monoStyle(
                                              c,
                                              size: 11.5,
                                              color: c.ink,
                                              weight: FontWeight.w600,
                                            ),
                                          ),
                                          ClaudePill(
                                            text: pType,
                                            bg: c.paper2,
                                          ),
                                          if (isReq)
                                            ClaudePill(
                                              text: '必填',
                                              mono: false,
                                              fg: c.clay,
                                              bg: c.clay.withValues(alpha: 0.12),
                                            ),
                                        ],
                                      ),
                                      if (pDesc.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          pDesc,
                                          style: sansStyle(
                                            c,
                                            size: 11,
                                            color: c.muted,
                                            height: 1.4,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            ClaudeButton(
                              label: '复制工具名',
                              compact: true,
                              leading: const Icon(Icons.copy_rounded),
                              onPressed: onCopyName,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
