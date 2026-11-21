import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/claude_theme.dart';

const Map<String, (IconData, String)> kToolMeta = {
  'read_file': (Icons.description_outlined, '读取文件'),
  'read_files': (Icons.library_books_outlined, '批量读取'),
  'stat_file': (Icons.info_outline_rounded, '查看属性'),
  'list_dir': (Icons.folder_open_rounded, '浏览目录'),
  'glob_files': (Icons.manage_search_rounded, '查找文件'),
  'search_text': (Icons.search_rounded, '搜索内容'),
  'create_file': (Icons.note_add_outlined, '写入文件'),
  'edit_file': (Icons.edit_note_rounded, '编辑文件'),
  'apply_patch': (Icons.healing_outlined, '应用补丁'),
  'replace_text': (Icons.find_replace_rounded, '批量替换'),
  'file_op': (Icons.drive_file_move_outline, '文件操作'),
  'undo_edit': (Icons.undo_rounded, '撤销修改'),
  'run_command': (Icons.terminal_rounded, '执行命令'),
  'start_process': (Icons.play_circle_outline_rounded, '启动进程'),
  'manage_process': (Icons.tune_rounded, '管理进程'),
  'list_roots': (Icons.explore_outlined, '检查环境'),
  'list_sub_mcps': (Icons.account_tree_outlined, '列出子 MCP'),
  'inspect_sub_mcp': (Icons.radar_rounded, '查看子 MCP 工具'),
  'call_sub_mcp': (Icons.extension_outlined, '调用子 MCP'),
};

(IconData, String) resolveToolMeta(String rawTool) {
  if (rawTool.isEmpty) return (Icons.auto_awesome_outlined, '系统消息');
  for (final e in kToolMeta.entries) {
    if (rawTool == e.key || rawTool.endsWith('_${e.key}')) {
      return e.value;
    }
  }
  return (Icons.handyman_outlined, rawTool);
}

String buildHumanSummary(Map<String, dynamic> ev) {
  final rawArgs = ev['args'];
  final a = rawArgs is Map
      ? Map<String, dynamic>.from(rawArgs)
      : const <String, dynamic>{};
  final t = (ev['tool'] ?? '').toString();
  if (t.endsWith('read_file') && a['path'] != null) {
    final off = a['offset'] != null ? ' (第 ${a['offset']} 行起)' : '';
    return '${a['path']}$off';
  }
  if (t.endsWith('read_files') && a['paths'] is List) {
    final list = a['paths'] as List;
    return '批量读取 ${list.length} 个文件';
  }
  if (t.endsWith('edit_file') && a['path'] != null) {
    final edits = a['edits'];
    final cnt = edits is List ? ' · ${edits.length} 处修改' : '';
    return '${a['path']}$cnt';
  }
  if (t.endsWith('create_file') && a['path'] != null) {
    final ov = a['overwrite'] == true ? ' (覆盖)' : '';
    return '${a['path']}$ov';
  }
  if (t.endsWith('list_dir')) {
    return (a['path'] ?? '.').toString();
  }
  if (t.endsWith('search_text') && a['pattern'] != null) {
    return '"${a['pattern']}" @ ${a['path'] ?? '.'}';
  }
  if (t.endsWith('run_command') && a['command'] != null) {
    return a['command'].toString();
  }
  if (t.endsWith('file_op') && a['action'] != null) {
    final dst = a['dst'] != null ? ' -> ${a['dst']}' : '';
    return '${a['action']}: ${a['src'] ?? ''}$dst';
  }
  if (t.endsWith('inspect_sub_mcp') && a['server_name'] != null) {
    final sub = a['tool_name'] != null ? ' / ${a['tool_name']}' : ' (工具目录)';
    return '${a['server_name']}$sub';
  }
  if (t.endsWith('call_sub_mcp') && a['server_name'] != null) {
    return '${a['server_name']} / ${a['tool_name'] ?? ''}';
  }
  return (ev['summary'] ?? '').toString();
}

class ActivityFeedPage extends StatefulWidget {
  final List<Map<String, dynamic>> events;
  final VoidCallback onClear;
  final VoidCallback onExport;
  final ValueChanged<String> onToast;
  final double topPadding;
  final double extraBottomPadding;

  const ActivityFeedPage({
    super.key,
    required this.events,
    required this.onClear,
    required this.onExport,
    required this.onToast,
    this.topPadding = 0.0,
    this.extraBottomPadding = 0.0,
  });

  @override
  State<ActivityFeedPage> createState() => _ActivityFeedPageState();
}

class _ActivityFeedPageState extends State<ActivityFeedPage> {
  String _cat = 'ALL';
  String _sort = 'newest';
  String _activeTool = 'ALL';
  String _activeSource = 'ALL';
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final Set<int> _expandedIds = <int>{};

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  bool _matches(Map<String, dynamic> ev) {
    final kind = (ev['kind'] ?? 'info').toString();
    final level = (ev['level'] ?? 'INFO').toString();
    final tool = (ev['tool'] ?? '').toString();
    final source = (ev['source'] ?? '').toString();

    if (_cat == 'TOOL' &&
        !(kind == 'call' ||
            kind == 'ok' ||
            (kind == 'err' && tool.isNotEmpty))) {
      return false;
    }
    if (_cat == 'OAUTH' && kind != 'oauth') return false;
    if (_cat == 'ERR' &&
        !(kind == 'err' || level == 'WARNING' || level == 'ERROR')) {
      return false;
    }
    if (_activeTool != 'ALL' && tool != _activeTool) return false;
    if (_activeSource != 'ALL' && source != _activeSource) return false;

    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isNotEmpty) {
      final hay =
          '$tool $source ${ev['summary'] ?? ''} ${ev['result'] ?? ''} ${jsonEncode(ev['args'] ?? '')}'
              .toLowerCase();
      if (!hay.contains(q)) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    var toolCalls = 0;
    var errCount = 0;
    var msSum = 0.0;
    var msCnt = 0;
    final toolCounts = <String, int>{};
    final sourceCounts = <String, int>{};

    for (final e in widget.events) {
      final t = (e['tool'] ?? '').toString();
      final s = (e['source'] ?? '').toString();
      final kind = (e['kind'] ?? '').toString();
      final lvl = (e['level'] ?? '').toString();
      if (t.isNotEmpty) {
        toolCalls++;
        toolCounts[t] = (toolCounts[t] ?? 0) + 1;
      }
      if (s.isNotEmpty) {
        sourceCounts[s] = (sourceCounts[s] ?? 0) + 1;
      }
      if (kind == 'err' || lvl == 'WARNING' || lvl == 'ERROR') {
        errCount++;
      }
      final ms = e['ms'];
      if (ms is num) {
        msSum += ms.toDouble();
        msCnt++;
      }
    }

    if (_activeTool != 'ALL' && !toolCounts.containsKey(_activeTool)) {
      _activeTool = 'ALL';
    }
    if (_activeSource != 'ALL' && !sourceCounts.containsKey(_activeSource)) {
      _activeSource = 'ALL';
    }

    var filtered = widget.events.where(_matches).toList();
    if (_sort == 'newest') {
      filtered = filtered.reversed.toList();
    } else if (_sort == 'slowest') {
      filtered.sort((a, b) {
        final ma = (a['ms'] as num?)?.toDouble() ?? -1;
        final mb = (b['ms'] as num?)?.toDouble() ?? -1;
        return mb.compareTo(ma);
      });
    }
    if (filtered.length > 300) {
      filtered = filtered.sublist(0, 300);
    }

    final avgText =
        msCnt > 0 ? '${(msSum / msCnt).toStringAsFixed(0)} ms' : '—';

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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 10,
                children: [
                  Text('活动与调用流', style: serifTitleStyle(c, size: 25)),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ClaudeButton(
                        label: '清空',
                        compact: true,
                        leading: const Icon(Icons.delete_sweep_outlined),
                        onPressed: widget.onClear,
                      ),
                      ClaudeButton(
                        label: '导出日志',
                        compact: true,
                        leading: const Icon(Icons.download_outlined),
                        onPressed: widget.onExport,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              LayoutBuilder(
                builder: (ctx, box) {
                  final tiles = [
                    _StatTile(
                      label: '总事件数',
                      value: '${widget.events.length}',
                    ),
                    _StatTile(label: '工具调用', value: '$toolCalls'),
                    _StatTile(
                      label: '错误 / 警告',
                      value: '$errCount',
                      accent: errCount > 0 ? c.danger : null,
                    ),
                    _StatTile(label: '平均耗时', value: avgText),
                  ];

                  if (box.maxWidth < 600) {
                    return Column(
                      children: [
                        Row(
                          children: [
                            Expanded(child: tiles[0]),
                            const SizedBox(width: 10),
                            Expanded(child: tiles[1]),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(child: tiles[2]),
                            const SizedBox(width: 10),
                            Expanded(child: tiles[3]),
                          ],
                        ),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: tiles[0]),
                      const SizedBox(width: 12),
                      Expanded(child: tiles[1]),
                      const SizedBox(width: 12),
                      Expanded(child: tiles[2]),
                      const SizedBox(width: 12),
                      Expanded(child: tiles[3]),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ClaudeStaggeredReveal(
          index: 1,
          child: ClaudeGlassBar(
            blurSigma: 16,
            borderRadius: 16,
            tintColor: c.paper2.withValues(alpha: c.isDark ? 0.84 : 0.88),
            boxShadow: c.whisperShadow,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: LayoutBuilder(
              builder: (ctx, fbox) {
                final narrowFilter = fbox.maxWidth < 640;
                final searchField = SizedBox(
                  height: 35,
                  child: TextField(
                    controller: _searchCtrl,
                    onChanged: (_) => setState(() {}),
                    style: sansStyle(c, size: 13, color: c.ink),
                    decoration: InputDecoration(
                      hintText: '搜索参数、路径或关键词...',
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        size: 16,
                        color: c.meta,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 34,
                        minHeight: 32,
                      ),
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              iconSize: 14,
                              padding: EdgeInsets.zero,
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() {});
                              },
                              icon: Icon(Icons.close_rounded, color: c.meta),
                            ),
                    ),
                  ),
                );

                final sortedSources = sourceCounts.keys.toList()..sort();
                final sortedTools = toolCounts.keys.toList()..sort();
                final hasActiveFilter = _cat != 'ALL' ||
                    _activeSource != 'ALL' ||
                    _activeTool != 'ALL' ||
                    _searchCtrl.text.trim().isNotEmpty;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        ClaudeSegmented<String>(
                          value: _cat,
                          items: const [
                            ('ALL', '全部'),
                            ('TOOL', '工具'),
                            ('OAUTH', '鉴权'),
                            ('ERR', '异常'),
                          ],
                          onChanged: (v) => setState(() => _cat = v),
                        ),
                        ClaudeDropMenu<String>(
                          value: _sort,
                          leadingIcon: Icons.swap_vert_rounded,
                          highlightActive: _sort != 'newest',
                          minMenuWidth: 156,
                          items: const [
                            ClaudeDropMenuItem(
                              value: 'newest',
                              label: '最新优先',
                              icon: Icons.schedule_rounded,
                            ),
                            ClaudeDropMenuItem(
                              value: 'oldest',
                              label: '最早优先',
                              icon: Icons.history_rounded,
                            ),
                            ClaudeDropMenuItem(
                              value: 'slowest',
                              label: '耗时最长',
                              icon: Icons.speed_rounded,
                            ),
                          ],
                          onChanged: (v) => setState(() => _sort = v),
                        ),
                        if (sortedSources.isNotEmpty)
                          ClaudeDropMenu<String>(
                            value: _activeSource,
                            leadingIcon: Icons.login_rounded,
                            highlightActive: _activeSource != 'ALL',
                            minMenuWidth: 190,
                            items: [
                              ClaudeDropMenuItem(
                                value: 'ALL',
                                label: '全部入口',
                                icon: Icons.public_rounded,
                                badge: '${widget.events.length}',
                              ),
                              for (final sName in sortedSources)
                                ClaudeDropMenuItem(
                                  value: sName,
                                  label: sName,
                                  icon: Icons.login_rounded,
                                  badge: '${sourceCounts[sName]}',
                                ),
                            ],
                            onChanged: (v) => setState(() => _activeSource = v),
                          ),
                        if (sortedTools.isNotEmpty)
                          ClaudeDropMenu<String>(
                            value: _activeTool,
                            leadingIcon: Icons.handyman_outlined,
                            highlightActive: _activeTool != 'ALL',
                            minMenuWidth: 200,
                            items: [
                              ClaudeDropMenuItem(
                                value: 'ALL',
                                label: '全部工具',
                                icon: Icons.apps_rounded,
                                badge: '$toolCalls',
                              ),
                              for (final tName in sortedTools)
                                ClaudeDropMenuItem(
                                  value: tName,
                                  label: resolveToolMeta(tName).$2,
                                  icon: resolveToolMeta(tName).$1,
                                  badge: '${toolCounts[tName]}',
                                ),
                            ],
                            onChanged: (v) => setState(() => _activeTool = v),
                          ),
                        if (hasActiveFilter)
                          ClaudeButton(
                            label: '重置',
                            compact: true,
                            variant: ClaudeBtnVariant.ghost,
                            leading: const Icon(Icons.filter_alt_off_outlined),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() {
                                _cat = 'ALL';
                                _activeSource = 'ALL';
                                _activeTool = 'ALL';
                              });
                            },
                          ),
                        if (!narrowFilter)
                          ConstrainedBox(
                            constraints: const BoxConstraints(
                              minWidth: 180,
                              maxWidth: 280,
                            ),
                            child: searchField,
                          ),
                      ],
                    ),
                    if (narrowFilter) ...[
                      const SizedBox(height: 8),
                      searchField,
                    ],
                  ],
                );
              },
            ),
          ),
        ),
              const SizedBox(height: 10),
            ],
          ),
        ),
        if (filtered.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: ClaudeStaggeredReveal(
              index: 2,
              child: Center(
                key: const ValueKey('empty-feed'),
                child: ClaudeCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 38,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: ShapeDecoration(
                          color: c.clay.withValues(alpha: 0.12),
                          shape: claudeSuperellipse(14),
                        ),
                        alignment: Alignment.center,
                        child: const ClaudeSparkIcon(size: 20),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        '暂无匹配的活动记录',
                        style: serifTitleStyle(c, size: 18),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '启动 MCP 服务后，每一次 Agent 工具调用、耗时与返回快照都会在此实时呈现。',
                        style: sansStyle(
                          c,
                          size: 13.5,
                          color: c.muted,
                          height: 1.55,
                        ),
                        textAlign: TextAlign.center,
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
              key: const ValueKey('event-list'),
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (ctx, idx) {
                final ev = filtered[idx];
                final seqId = (ev['_seq'] as int?) ?? idx;
                final open = _expandedIds.contains(seqId);
                return RepaintBoundary(
                  child: _EventCard(
                    key: ValueKey('ev-$seqId'),
                    ev: ev,
                    expanded: open,
                    onToggle: () {
                      setState(() {
                        if (open) {
                          _expandedIds.remove(seqId);
                        } else {
                          _expandedIds.add(seqId);
                        }
                      });
                    },
                    onCopy: (txt, msg) {
                      Clipboard.setData(ClipboardData(text: txt));
                      widget.onToast(msg);
                    },
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color? accent;

  const _StatTile({
    required this.label,
    required this.value,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: c.paper2,
        shape: claudeSuperellipse(16, side: BorderSide(color: c.hairline)),
        shadows: c.whisperShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sansStyle(
                c,
                size: 12,
                color: c.muted,
                height: 1.2,
                letterSpacing: 0.1,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: serifTitleStyle(
                c,
                size: 21,
                color: accent ?? c.ink,
                height: 1.15,
                tabular: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventCard extends StatefulWidget {
  final Map<String, dynamic> ev;
  final bool expanded;
  final VoidCallback onToggle;
  final void Function(String text, String msg) onCopy;

  const _EventCard({
    super.key,
    required this.ev,
    required this.expanded,
    required this.onToggle,
    required this.onCopy,
  });

  @override
  State<_EventCard> createState() => _EventCardState();
}

class _EventCardState extends State<_EventCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final ev = widget.ev;
    final kind = (ev['kind'] ?? 'info').toString();
    final status = (ev['status'] ?? 'done').toString();
    final isRunning = status == 'running';
    final badge = isRunning ? '执行中' : (ev['badge'] ?? '完成').toString();
    final toolRaw = (ev['tool'] ?? '').toString();
    final tm = resolveToolMeta(toolRaw);
    final summary = buildHumanSummary(ev);
    final source = (ev['source'] ?? '').toString();
    final ms = ev['ms'] as num?;
    final ts = (ev['ts'] ?? '').toString();

    Color accent;
    Color badgeBg;
    switch (kind) {
      case 'err':
        accent = c.danger;
        badgeBg = c.dangerBg;
      case 'ok':
        accent = c.sage;
        badgeBg = c.sageBg;
      case 'call':
        accent = c.clay;
        badgeBg = c.clay.withValues(alpha: 0.14);
      case 'oauth':
        accent = c.purple;
        badgeBg = c.purpleBg;
      default:
        accent = c.muted;
        badgeBg = c.paper3;
    }

    final rawArgs = ev['args'];
    final argsMap = rawArgs is Map && rawArgs.isNotEmpty
        ? Map<String, dynamic>.from(rawArgs)
        : null;
    final resultStr = (ev['result'] ?? '').toString();

    Widget buildBadgePill() {
      return DecoratedBox(
        decoration: ShapeDecoration(
          color: badgeBg,
          shape: const StadiumBorder(),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.5, vertical: 2.5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isRunning) ...[
                ClaudeStatusDot(
                  color: accent,
                  pulsing: true,
                  size: 5.5,
                ),
                const SizedBox(width: 3),
              ],
              Text(
                badge,
                style: sansStyle(
                  c,
                  size: 11.5,
                  weight: FontWeight.w600,
                  color: accent,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget buildStatusAccentPill() {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 3.5,
            height: 16,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(99),
            ),
          ),
          const SizedBox(width: 8),
          buildBadgePill(),
        ],
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
        curve: ClaudeMotion.editorialOut,
        decoration: ShapeDecoration(
          color: c.paper2,
          shape: claudeSuperellipse(
            14,
            side: BorderSide(
              color: widget.expanded
                  ? accent.withValues(alpha: 0.42)
                  : (_hovered ? c.ringHover : c.hairline),
            ),
          ),
          shadows: _hovered ? c.cardHoverShadow : c.whisperShadow,
        ),
        child: ClipRSuperellipse(
          borderRadius: BorderRadius.circular(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onToggle,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 10.5,
                    ),
                    child: LayoutBuilder(
                      builder: (ctx, rowBox) {
                        final isCompactRow = rowBox.maxWidth < 660;
                        final chevron = AnimatedRotation(
                          turns: widget.expanded ? 0.5 : 0.0,
                          duration: ClaudeMotion.duration(
                            context,
                            ClaudeMotion.base,
                          ),
                          curve: ClaudeMotion.editorialOut,
                          child: Icon(
                            Icons.expand_more_rounded,
                            size: 17,
                            color: _hovered ? c.inkSoft : c.meta,
                          ),
                        );

                        if (isCompactRow) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  buildStatusAccentPill(),
                                  const SizedBox(width: 9),
                                    Icon(tm.$1, size: 15, color: c.inkSoft),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: Text(
                                        tm.$2,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: sansStyle(
                                          c,
                                          size: 13,
                                          weight: FontWeight.w600,
                                          color: c.ink,
                                          height: 1.2,
                                        ),
                                      ),
                                    ),
                                    if (ms != null) ...[
                                      const SizedBox(width: 6),
                                      ClaudePill(
                                        text: '${ms.toStringAsFixed(0)} ms',
                                      ),
                                    ],
                                    if (ts.isNotEmpty) ...[
                                      const SizedBox(width: 6),
                                      Text(
                                        ts,
                                        style: monoStyle(
                                          c,
                                          size: 11,
                                          color: c.meta,
                                        ),
                                      ),
                                    ],
                                    const SizedBox(width: 4),
                                    chevron,
                                  ],
                                ),
                                if (summary.isNotEmpty || source.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      if (source.isNotEmpty) ...[
                                        ClaudePill(
                                          text: source,
                                          leading:
                                              const Icon(Icons.login_rounded),
                                          fg: c.clay,
                                          bg: c.clay.withValues(alpha: 0.10),
                                          border:
                                              c.clay.withValues(alpha: 0.24),
                                          mono: false,
                                        ),
                                        const SizedBox(width: 7),
                                      ],
                                      Expanded(
                                        child: _RichEventSummary(
                                          ev: ev,
                                          fallback: summary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ],
                            );
                          }

                          return Row(
                            children: [
                              buildStatusAccentPill(),
                              const SizedBox(width: 11),
                              SizedBox(
                                width: 136,
                                child: Row(
                                  children: [
                                    Icon(tm.$1, size: 15, color: c.inkSoft),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        tm.$2,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: sansStyle(
                                          c,
                                          size: 13,
                                          weight: FontWeight.w600,
                                          color: c.ink,
                                          height: 1.2,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _RichEventSummary(
                                  ev: ev,
                                  fallback: summary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (source.isNotEmpty) ...[
                                ClaudePill(
                                  text: source,
                                  leading: const Icon(Icons.login_rounded),
                                  fg: c.clay,
                                  bg: c.clay.withValues(alpha: 0.10),
                                  border: c.clay.withValues(alpha: 0.24),
                                  mono: false,
                                ),
                                const SizedBox(width: 6),
                              ],
                              if (ms != null) ...[
                                ClaudePill(text: '${ms.toStringAsFixed(1)} ms'),
                                const SizedBox(width: 6),
                              ],
                              Text(
                                ts,
                                style: monoStyle(c, size: 11.5, color: c.meta),
                              ),
                              const SizedBox(width: 6),
                              chevron,
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                ClaudeCollapsible(
                  expanded: widget.expanded,
                  builder: (_) => _RichToolDetailDrawer(
                    ev: ev,
                    toolRaw: toolRaw,
                    argsMap: argsMap,
                    resultStr: resultStr,
                    summary: summary,
                    onCopy: widget.onCopy,
                  ),
                ),
              ],
            ),
          ),
        ),
    );
  }
}

(String dir, String base) _splitCompactPath(String rawPath) {
  final trimmed = rawPath.trim();
  if (trimmed == '.' || trimmed.isEmpty) return ('', '当前工作区');
  var norm = trimmed.replaceAll('\\', '/');
  if (norm.length > 1) {
    norm = norm.replaceAll(RegExp(r'/+$'), '');
  }
  final idx = norm.lastIndexOf('/');
  if (idx < 0) return ('', norm);
  final base = norm.substring(idx + 1);
  if (base.isEmpty) return ('', norm);
  final parts =
      norm.substring(0, idx).split('/').where((s) => s.isNotEmpty).toList();
  final tailDir = parts.length > 2
      ? '…/${parts.sublist(parts.length - 2).join('/')}/'
      : (parts.isEmpty ? '/' : '${parts.join('/')}/');
  return (tailDir, base);
}

String _semanticParamLabel(String key) {
  return switch (key) {
    'path' => '目标路径',
    'paths' => '文件列表',
    'source' => '源路径',
    'destination' => '目标路径',
    'max_depth' => '遍历深度',
    'max_entries' => '条目上限',
    'show_hidden' => '隐藏文件',
    'offset' => '起始行',
    'limit' => '读取行数',
    'pattern' => '匹配规则',
    'find' => '查找文本',
    'replace' => '替换为',
    'regex' => '正则模式',
    'case_sensitive' => '区分大小写',
    'context_lines' => '上下文行数',
    'glob' => '文件过滤',
    'max_results' => '结果上限',
    'dry_run' => '预览模式',
    'overwrite' => '覆盖写入',
    'command' => '执行命令',
    'cwd' => '工作目录',
    'shell' => '终端环境',
    'timeout' => '超时时限',
    'env' => '环境变量',
    'action' => '执行动作',
    'process_id' => '进程标识',
    'input_text' => '标准输入',
    'tail_lines' => '尾部行数',
    'server_name' => '子 MCP 服务',
    'tool_name' => '目标工具',
    'arguments' => '转发参数',
    'patch' => '补丁内容',
    _ => key.replaceAll('_', ' '),
  };
}

String _semanticParamInlineValue(String key, dynamic val) {
  if (val is bool) {
    return switch (key) {
      'dry_run' => val ? '仅预览' : '直接写入',
      'show_hidden' => val ? '含隐藏项' : '忽略隐藏项',
      'overwrite' => val ? '允许覆盖' : '禁止覆盖',
      'case_sensitive' => val ? '大小写敏感' : '忽略大小写',
      'regex' => val ? '正则' : '字面量',
      _ => val ? '开启' : '关闭',
    };
  }
  if (val is num) {
    return switch (key) {
      'max_depth' => '$val 层',
      'max_entries' || 'max_results' => '上限 $val',
      'offset' => '第 $val 行起',
      'limit' || 'tail_lines' || 'context_lines' => '$val 行',
      'timeout' => '${val}s',
      _ => '$val',
    };
  }
  if (val is List) return '${val.length} 项';
  if (val is Map) return '${val.length} 个字段';
  final s = val?.toString().trim() ?? '';
  return s.length > 28 ? '${s.substring(0, 28)}…' : s;
}

class _RichEventSummary extends StatelessWidget {
  final Map<String, dynamic> ev;
  final String fallback;

  const _RichEventSummary({required this.ev, required this.fallback});

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final t = (ev['tool'] ?? '').toString();
    final rawArgs = ev['args'];
    final a = rawArgs is Map
        ? Map<String, dynamic>.from(rawArgs)
        : const <String, dynamic>{};

    Widget pill(String text, {Color? accent, bool mono = false}) {
      final col = accent ?? c.inkSoft;
      return ClaudePill(
        text: text,
        fg: col,
        bg: (accent ?? c.clay).withValues(alpha: accent != null ? 0.11 : 0.0),
        border: accent != null
            ? accent.withValues(alpha: 0.24)
            : c.hairline,
        mono: mono,
      );
    }

    Widget pathWithPills(
      String path, {
      IconData? icon,
      List<Widget> pills = const [],
    }) {
      final (dir, base) = _splitCompactPath(path);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13.5, color: c.muted),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                children: [
                  if (dir.isNotEmpty)
                    TextSpan(
                      text: dir,
                      style: monoStyle(c, size: 11.5, color: c.meta),
                    ),
                  TextSpan(
                    text: base,
                    style: monoStyle(
                      c,
                      size: 12,
                      color: c.inkSoft,
                      weight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          for (final p in pills) ...[
            const SizedBox(width: 6),
            p,
          ],
        ],
      );
    }

    if (t.endsWith('list_dir')) {
      final path = (a['path'] ?? '.').toString();
      final depth = a['max_depth'];
      final hidden = a['show_hidden'] == true;
      return pathWithPills(
        path,
        icon: Icons.folder_open_rounded,
        pills: [
          if (depth != null) pill('深度 $depth 层', accent: c.sage),
          if (hidden) pill('含隐藏项', accent: c.clay),
        ],
      );
    }

    if (t.endsWith('read_file') && a['path'] != null) {
      final off = a['offset'];
      final lim = a['limit'];
      String? rangeBadge;
      if (off != null && lim != null) {
        final start = int.tryParse('$off') ?? 1;
        final cnt = int.tryParse('$lim') ?? 0;
        rangeBadge = cnt > 0 ? 'L$start–${start + cnt - 1}' : 'L$start+';
      } else if (off != null) {
        rangeBadge = 'L$off+';
      } else if (lim != null) {
        rangeBadge = '前 $lim 行';
      }
      return pathWithPills(
        a['path'].toString(),
        pills: [
          if (rangeBadge != null) pill(rangeBadge, accent: c.sage),
        ],
      );
    }

    if (t.endsWith('read_files') && a['paths'] is List) {
      final list = (a['paths'] as List).map((e) => e.toString()).toList();
      if (list.isNotEmpty) {
        return pathWithPills(
          list.first,
          pills: [
            pill(
              list.length > 1 ? '共 ${list.length} 个文件' : '单文件',
              accent: c.sage,
            ),
          ],
        );
      }
    }

    if (t.endsWith('edit_file') && a['path'] != null) {
      final edits = a['edits'];
      final cnt = edits is List ? edits.length : 0;
      final dry = a['dry_run'] == true;
      return pathWithPills(
        a['path'].toString(),
        pills: [
          pill(cnt > 0 ? '$cnt 处替换' : '编辑', accent: c.clay),
          if (dry) pill('仅预览', accent: c.purple),
        ],
      );
    }

    if (t.endsWith('create_file') && a['path'] != null) {
      final ov = a['overwrite'] == true;
      return pathWithPills(
        a['path'].toString(),
        pills: [
          pill(ov ? '覆盖写入' : '新建文件', accent: ov ? c.clay : c.sage),
        ],
      );
    }

    if ((t.endsWith('apply_patch') ||
            t.endsWith('stat_file') ||
            t.endsWith('undo_edit')) &&
        a['path'] != null) {
      final label = t.endsWith('apply_patch')
          ? 'Unified Diff'
          : (t.endsWith('undo_edit') ? '撤销修改' : '文件属性');
      return pathWithPills(
        a['path'].toString(),
        pills: [
          pill(label, accent: c.purple),
          if (a['dry_run'] == true) pill('仅预览', accent: c.clay),
        ],
      );
    }

    if (t.endsWith('file_op')) {
      final act = (a['action'] ?? '').toString().toLowerCase();
      final actLabel = switch (act) {
        'move' => '移动',
        'copy' => '复制',
        'delete' => '删除',
        _ => act.isEmpty ? '文件操作' : act,
      };
      final src = (a['source'] ?? a['path'] ?? '').toString();
      final dst = (a['destination'] ?? '').toString();
      final accent = act == 'delete' ? c.danger : c.clay;
      return Row(
        children: [
          pill(actLabel, accent: accent),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              _splitCompactPath(src).$2,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(c, size: 12, color: c.inkSoft, weight: FontWeight.w600),
            ),
          ),
          if (dst.isNotEmpty) ...[
            const SizedBox(width: 5),
            Icon(Icons.arrow_forward_rounded, size: 12, color: c.meta),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                _splitCompactPath(dst).$2,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: monoStyle(c, size: 12, color: c.inkSoft),
              ),
            ),
          ],
        ],
      );
    }

    if ((t.endsWith('run_command') || t.endsWith('start_process')) &&
        a['command'] != null) {
      final isBg = t.endsWith('start_process');
      final sh = (a['shell'] ?? '').toString();
      return Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            decoration: ShapeDecoration(
              color: c.termBg,
              shape: claudeSuperellipse(5),
            ),
            child: Text(
              isBg ? 'BG \$' : r'$',
              style: monoStyle(
                c,
                size: 10.5,
                color: isBg ? c.sage : c.clay,
                weight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              a['command'].toString(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(c, size: 12, color: c.inkSoft),
            ),
          ),
          if (sh.isNotEmpty && sh != 'auto') ...[
            const SizedBox(width: 6),
            ClaudePill(text: sh, bg: c.paper3),
          ],
        ],
      );
    }

    if (t.endsWith('manage_process')) {
      final act = (a['action'] ?? 'list').toString().toLowerCase();
      final pid = (a['process_id'] ?? '').toString();
      final tail = a['tail_lines'];
      final (actLabel, col) = switch (act) {
        'read' => ('读取输出', c.sage),
        'write' => ('发送输入', c.clay),
        'kill' => ('终止进程', c.danger),
        _ => ('查看后台进程', c.purple),
      };
      return Row(
        children: [
          pill(actLabel, accent: col),
          if (pid.isNotEmpty) ...[
            const SizedBox(width: 6),
            ClaudePill(text: '#$pid', bg: c.paper3),
          ],
          if (tail != null && act == 'read') ...[
            const SizedBox(width: 6),
            ClaudePill(text: '末尾 $tail 行', mono: false, bg: c.paper3),
          ],
        ],
      );
    }

    if (t.endsWith('glob_files') && a['pattern'] != null) {
      final pat = a['pattern'].toString();
      final pth = (a['path'] ?? '.').toString();
      return Row(
        children: [
          Icon(Icons.travel_explore_rounded, size: 13.5, color: c.clay),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              pat,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(c, size: 12, color: c.clay, weight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              '@ ${_splitCompactPath(pth).$2}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(c, size: 11.5, color: c.muted),
            ),
          ),
        ],
      );
    }

    if (t.endsWith('search_text') && a['pattern'] != null) {
      final glob = (a['glob'] ?? '').toString();
      return Row(
        children: [
          Flexible(
            child: Text(
              '"${a['pattern']}"',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(
                c,
                size: 12,
                color: c.clay,
                weight: FontWeight.w600,
              ),
            ),
          ),
          if (a['path'] != null) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '@ ${_splitCompactPath(a['path'].toString()).$2}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: monoStyle(c, size: 11.5, color: c.muted),
              ),
            ),
          ],
          if (glob.isNotEmpty) ...[
            const SizedBox(width: 6),
            ClaudePill(text: glob, bg: c.paper3),
          ],
        ],
      );
    }

    if (t.endsWith('replace_text') && a['find'] != null) {
      final dry = a['dry_run'] == true;
      return Row(
        children: [
          Flexible(
            child: Text(
              '"${a['find']}"',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(c, size: 11.8, color: c.danger),
            ),
          ),
          const SizedBox(width: 5),
          Icon(Icons.arrow_forward_rounded, size: 12, color: c.meta),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              '"${a['replace'] ?? ''}"',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoStyle(c, size: 11.8, color: c.sage),
            ),
          ),
          if (dry) ...[
            const SizedBox(width: 6),
            pill('仅预览', accent: c.purple),
          ],
        ],
      );
    }

    if (t.endsWith('list_roots')) {
      return Text(
        '查询服务工作目录与安全访问边界',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sansStyle(c, size: 12, color: c.muted),
      );
    }

    if (t.endsWith('list_sub_mcps')) {
      return Text(
        '扫描已挂载的嵌套子 MCP 服务列表',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sansStyle(c, size: 12, color: c.muted),
      );
    }

    if ((t.endsWith('call_sub_mcp') || t.endsWith('inspect_sub_mcp')) &&
        a['server_name'] != null) {
      final srv = a['server_name'].toString();
      final sub = (a['tool_name'] ?? '').toString();
      return Row(
        children: [
          ClaudePill(text: srv, mono: false, bg: c.paper3),
          const SizedBox(width: 5),
          Icon(Icons.arrow_forward_rounded, size: 12, color: c.meta),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              sub.isNotEmpty ? sub : '查看工具架构清单',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sub.isNotEmpty
                  ? monoStyle(c, size: 12, color: c.inkSoft)
                  : sansStyle(c, size: 12, color: c.muted),
            ),
          ),
        ],
      );
    }

    // Semantic fallback for any custom / third-party tool arguments
    if (a.isNotEmpty) {
      final chips = a.entries.take(3).map((e) {
        final label = _semanticParamLabel(e.key);
        final val = _semanticParamInlineValue(e.key, e.value);
        return Padding(
          padding: const EdgeInsets.only(right: 6),
          child: ClaudePill(
            text: '$label · $val',
            mono: false,
            bg: c.paper3,
          ),
        );
      }).toList();
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        child: Row(mainAxisSize: MainAxisSize.min, children: chips),
      );
    }

    if (t.isNotEmpty && (fallback.isEmpty || fallback == '(无参数)')) {
      return Text(
        '直接执行（无需附加参数）',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: sansStyle(c, size: 12, color: c.meta),
      );
    }

    return Text(
      fallback,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: monoStyle(c, size: 12, color: c.muted),
    );
  }
}

class _RichToolDetailDrawer extends StatelessWidget {
  final Map<String, dynamic> ev;
  final String toolRaw;
  final Map<String, dynamic>? argsMap;
  final String resultStr;
  final String summary;
  final void Function(String text, String msg) onCopy;

  const _RichToolDetailDrawer({
    required this.ev,
    required this.toolRaw,
    required this.argsMap,
    required this.resultStr,
    required this.summary,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final a = argsMap ?? const <String, dynamic>{};
    final isEdit = toolRaw.endsWith('edit_file') && a['edits'] is List;
    final isCreate = toolRaw.endsWith('create_file') && a['content'] != null;
    final isRun = (toolRaw.endsWith('run_command') ||
            toolRaw.endsWith('start_process')) &&
        a['command'] != null;
    final isRead = toolRaw.endsWith('read_file') && a['path'] != null;
    final isListDir = toolRaw.endsWith('list_dir');
    final isStatOrUndo = (toolRaw.endsWith('stat_file') ||
            toolRaw.endsWith('undo_edit')) &&
        a['path'] != null;
    final isPatch = toolRaw.endsWith('apply_patch') && a['path'] != null;
    final isReplace = toolRaw.endsWith('replace_text') && a['find'] != null;
    final isSearchOrGlob = (toolRaw.endsWith('search_text') ||
            toolRaw.endsWith('glob_files')) &&
        a['pattern'] != null;
    final isFileOp = toolRaw.endsWith('file_op');
    final isManageProc = toolRaw.endsWith('manage_process');
    final isReadFiles = toolRaw.endsWith('read_files') && a['paths'] is List;
    final isSubMcp = (toolRaw.endsWith('call_sub_mcp') ||
            toolRaw.endsWith('inspect_sub_mcp')) &&
        a['server_name'] != null;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: c.recessed,
        shape: claudeSuperellipse(12, side: BorderSide(color: c.hairline)),
      ),
      child: LayoutBuilder(
        builder: (ctx, dbox) {
          final stackArgs = dbox.maxWidth < 460;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isEdit) ...[
                _buildEditFileSection(c, a),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (isCreate) ...[
                _buildCreateFileSection(c, a),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (isRun) ...[
                _buildRunCommandSection(
                  c,
                  a,
                  isBackground: toolRaw.endsWith('start_process'),
                ),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (isRead) ...[
                _buildReadFileSection(c, a),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (isListDir) ...[
                _buildListDirSection(c, a),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (isStatOrUndo) ...[
                _buildStatOrUndoSection(c, a, isUndo: toolRaw.endsWith('undo_edit')),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (isPatch) ...[
                _buildApplyPatchSection(c, a),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (isReplace) ...[
                _buildReplaceTextSection(c, a),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (isSearchOrGlob) ...[
                _buildSearchOrGlobSection(
                  c,
                  a,
                  isGlob: toolRaw.endsWith('glob_files'),
                ),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (isFileOp) ...[
                _buildFileOpSection(c, a),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (isManageProc) ...[
                _buildManageProcessSection(c, a),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (isReadFiles) ...[
                _buildReadFilesSection(c, a),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (isSubMcp) ...[
                _buildSubMcpSection(c, a, stackArgs: stackArgs),
                if (resultStr.isNotEmpty) const SizedBox(height: 12),
              ] else if (argsMap != null && argsMap!.isNotEmpty) ...[
                _buildSemanticArgsTable(c, argsMap!, stackArgs: stackArgs),
                if (resultStr.isNotEmpty) const SizedBox(height: 10),
              ],
              if (resultStr.isNotEmpty || argsMap == null) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      resultStr.isNotEmpty ? '执行结果' : '事件详情',
                      style: sansStyle(
                        c,
                        size: 12,
                        weight: FontWeight.w600,
                        color: c.muted,
                      ),
                    ),
                    ClaudeButton(
                      label: '复制结果',
                      compact: true,
                      leading: const Icon(Icons.copy_rounded),
                      onPressed: () => onCopy(
                        resultStr.isNotEmpty ? resultStr : summary,
                        '已复制结果内容',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 280),
                  padding: const EdgeInsets.all(12),
                  decoration: ShapeDecoration(
                    color: c.termBg,
                    shape: claudeSuperellipse(
                      11,
                      side: const BorderSide(color: Color(0xFF2E2D29)),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: _DiffOutputView(
                      text: resultStr.isNotEmpty ? resultStr : summary,
                      palette: c,
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _pathBanner(
    ClaudePalette c,
    String path, {
    IconData icon = Icons.insert_drive_file_outlined,
    String copyLabel = '复制路径',
    List<Widget> pills = const [],
  }) {
    final dispPath = path.trim() == '.' ? '当前工作区 (.)' : path;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: ShapeDecoration(
        color: c.paper2,
        shape: claudeSuperellipse(10, side: BorderSide(color: c.hairline)),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 6,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14.5, color: c.clay),
              const SizedBox(width: 6),
              Flexible(
                child: SelectableText(
                  dispPath,
                  style: monoStyle(c, size: 12, color: c.ink),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ...pills,
              ClaudeButton(
                label: copyLabel,
                compact: true,
                onPressed: () => onCopy(path, '已复制路径'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSemanticArgsTable(
    ClaudePalette c,
    Map<String, dynamic> map, {
    required bool stackArgs,
    String headerTitle = '调用参数',
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              headerTitle,
              style: sansStyle(
                c,
                size: 12,
                weight: FontWeight.w600,
                color: c.muted,
              ),
            ),
            ClaudeButton(
              label: '复制参数',
              compact: true,
              leading: const Icon(Icons.copy_rounded),
              onPressed: () => onCopy(
                const JsonEncoder.withIndent('  ').convert(map),
                '已复制调用参数',
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final entry in map.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: stackArgs
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _semanticParamLabel(entry.key),
                        style: sansStyle(
                          c,
                          size: 11.5,
                          weight: FontWeight.w500,
                          color: c.muted,
                        ),
                      ),
                      const SizedBox(height: 4),
                      _ArgValueBox(
                        paramKey: entry.key,
                        value: entry.value,
                        palette: c,
                      ),
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 110,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            _semanticParamLabel(entry.key),
                            style: sansStyle(
                              c,
                              size: 12,
                              weight: FontWeight.w500,
                              color: c.muted,
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: _ArgValueBox(
                          paramKey: entry.key,
                          value: entry.value,
                          palette: c,
                        ),
                      ),
                    ],
                  ),
          ),
      ],
    );
  }

  Widget _buildListDirSection(ClaudePalette c, Map<String, dynamic> a) {
    final path = (a['path'] ?? '.').toString();
    final depth = a['max_depth'];
    final maxEntries = a['max_entries'];
    final hidden = a['show_hidden'] == true;
    return _pathBanner(
      c,
      path,
      icon: Icons.folder_open_rounded,
      copyLabel: '复制目录',
      pills: [
        if (depth != null)
          ClaudePill(
            text: '遍历深度 $depth 层',
            mono: false,
            fg: c.sage,
            bg: c.sageBg,
          ),
        if (maxEntries != null)
          ClaudePill(text: '上限 $maxEntries 项', mono: false),
        ClaudePill(
          text: hidden ? '包含隐藏项' : '忽略隐藏项',
          mono: false,
          fg: hidden ? c.clay : c.muted,
          bg: hidden ? c.clay.withValues(alpha: 0.12) : c.paper3,
        ),
      ],
    );
  }

  Widget _buildStatOrUndoSection(
    ClaudePalette c,
    Map<String, dynamic> a, {
    required bool isUndo,
  }) {
    final path = (a['path'] ?? '').toString();
    return _pathBanner(
      c,
      path,
      icon: isUndo ? Icons.undo_rounded : Icons.info_outline_rounded,
      pills: [
        ClaudePill(
          text: isUndo ? '回滚最近一次编辑' : '文件元数据探测',
          mono: false,
          fg: c.purple,
          bg: c.purpleBg,
        ),
      ],
    );
  }

  Widget _buildApplyPatchSection(ClaudePalette c, Map<String, dynamic> a) {
    final path = (a['path'] ?? '').toString();
    final patch = (a['patch'] ?? '').toString();
    final dry = a['dry_run'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pathBanner(
          c,
          path,
          pills: [
            ClaudePill(
              text: 'Unified Diff 补丁',
              mono: false,
              fg: c.purple,
              bg: c.purpleBg,
            ),
            if (dry)
              ClaudePill(
                text: '仅预览',
                mono: false,
                fg: c.clay,
                bg: c.clay.withValues(alpha: 0.12),
              ),
          ],
        ),
        if (patch.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 220),
            padding: const EdgeInsets.all(10),
            decoration: ShapeDecoration(
              color: c.termBg,
              shape: claudeSuperellipse(
                10,
                side: const BorderSide(color: Color(0xFF2E2D29)),
              ),
            ),
            child: SingleChildScrollView(
              child: _DiffOutputView(text: patch, palette: c),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildReplaceTextSection(ClaudePalette c, Map<String, dynamic> a) {
    final path = (a['path'] ?? '.').toString();
    final glob = (a['glob'] ?? '').toString();
    final dry = a['dry_run'] == true;
    final regex = a['regex'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pathBanner(
          c,
          path,
          icon: Icons.find_replace_rounded,
          pills: [
            if (glob.isNotEmpty) ClaudePill(text: glob),
            if (regex) ClaudePill(text: '正则替换', mono: false),
            ClaudePill(
              text: dry ? '仅预览 (不落盘)' : '批量替换',
              mono: false,
              fg: dry ? c.purple : c.clay,
              bg: dry ? c.purpleBg : c.clay.withValues(alpha: 0.12),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _InlineDiffBlock(
          index: 1,
          oldStr: (a['find'] ?? '').toString(),
          newStr: (a['replace'] ?? '').toString(),
          palette: c,
        ),
      ],
    );
  }

  Widget _buildSearchOrGlobSection(
    ClaudePalette c,
    Map<String, dynamic> a, {
    required bool isGlob,
  }) {
    final pat = (a['pattern'] ?? '').toString();
    final path = (a['path'] ?? '.').toString();
    final glob = (a['glob'] ?? '').toString();
    final maxRes = a['max_results'];
    final ctxLines = a['context_lines'];
    final caseSens = a['case_sensitive'];
    final regex = a['regex'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pathBanner(
          c,
          path,
          icon: isGlob ? Icons.travel_explore_rounded : Icons.search_rounded,
          copyLabel: '复制目录',
          pills: [
            if (glob.isNotEmpty) ClaudePill(text: '过滤 $glob', mono: false),
            if (!isGlob && regex != null)
              ClaudePill(
                text: regex == true ? '正则匹配' : '字面匹配',
                mono: false,
              ),
            if (!isGlob && caseSens == false)
              const ClaudePill(text: '忽略大小写', mono: false),
            if (ctxLines is num && ctxLines > 0)
              ClaudePill(text: '上下文 $ctxLines 行', mono: false),
            if (maxRes != null)
              ClaudePill(text: '上限 $maxRes 条', mono: false),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8.5),
          decoration: ShapeDecoration(
            color: c.paper2,
            shape: claudeSuperellipse(10, side: BorderSide(color: c.hairline)),
          ),
          child: Row(
            children: [
              ClaudePill(
                text: isGlob ? 'Glob 通配符' : '检索模式',
                mono: false,
                fg: c.clay,
                bg: c.clay.withValues(alpha: 0.12),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  pat,
                  style: monoStyle(
                    c,
                    size: 12.2,
                    color: c.ink,
                    weight: FontWeight.w600,
                  ),
                ),
              ),
              ClaudeButton(
                label: '复制',
                compact: true,
                onPressed: () => onCopy(pat, '已复制匹配表达式'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildFileOpSection(ClaudePalette c, Map<String, dynamic> a) {
    final act = (a['action'] ?? '').toString().toLowerCase();
    final src = (a['source'] ?? a['path'] ?? '').toString();
    final dst = (a['destination'] ?? '').toString();
    final (label, col) = switch (act) {
      'move' => ('移动 / 重命名', c.clay),
      'copy' => ('复制文件', c.sage),
      'delete' => ('删除路径', c.danger),
      _ => ('文件系统操作', c.inkSoft),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pathBanner(
          c,
          src,
          icon: Icons.drive_file_move_outline,
          pills: [
            ClaudePill(
              text: label,
              mono: false,
              fg: col,
              bg: col.withValues(alpha: 0.12),
            ),
          ],
        ),
        if (dst.isNotEmpty) ...[
          const SizedBox(height: 6),
          _pathBanner(
            c,
            dst,
            icon: Icons.subdirectory_arrow_right_rounded,
            pills: const [
              ClaudePill(text: '目标位置', mono: false),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildManageProcessSection(ClaudePalette c, Map<String, dynamic> a) {
    final act = (a['action'] ?? 'list').toString().toLowerCase();
    final pid = (a['process_id'] ?? '').toString();
    final tail = a['tail_lines'];
    final input = (a['input_text'] ?? '').toString();
    final (actLabel, col) = switch (act) {
      'read' => ('读取进程输出', c.sage),
      'write' => ('写入标准输入', c.clay),
      'kill' => ('终止后台进程', c.danger),
      _ => ('列举后台进程', c.purple),
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: ShapeDecoration(
        color: c.paper2,
        shape: claudeSuperellipse(10, side: BorderSide(color: c.hairline)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ClaudePill(
            text: actLabel,
            mono: false,
            fg: col,
            bg: col.withValues(alpha: 0.12),
          ),
          if (pid.isNotEmpty)
            ClaudePill(text: '进程 ID · $pid', bg: c.recessed),
          if (tail != null)
            ClaudePill(text: '尾部 $tail 行', mono: false, bg: c.recessed),
          if (input.isNotEmpty)
            ClaudePill(text: '输入 ${input.length} 字符', mono: false),
        ],
      ),
    );
  }

  Widget _buildReadFilesSection(ClaudePalette c, Map<String, dynamic> a) {
    final paths = (a['paths'] as List).map((e) => e.toString()).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < paths.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          _pathBanner(
            c,
            paths[i],
            pills: [
              ClaudePill(text: '#${i + 1}/${paths.length}'),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSubMcpSection(
    ClaudePalette c,
    Map<String, dynamic> a, {
    required bool stackArgs,
  }) {
    final srv = (a['server_name'] ?? '').toString();
    final subTool = (a['tool_name'] ?? '').toString();
    final innerArgs = a['arguments'] is Map
        ? Map<String, dynamic>.from(a['arguments'] as Map)
        : const <String, dynamic>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: ShapeDecoration(
            color: c.paper2,
            shape: claudeSuperellipse(10, side: BorderSide(color: c.hairline)),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ClaudePill(
                text: '子服务 · $srv',
                mono: false,
                fg: c.clay,
                bg: c.clay.withValues(alpha: 0.12),
              ),
              if (subTool.isNotEmpty) ...[
                Icon(Icons.arrow_forward_rounded, size: 13, color: c.meta),
                ClaudePill(text: subTool, bg: c.recessed),
              ] else
                const ClaudePill(text: '读取工具架构清单', mono: false),
            ],
          ),
        ),
        if (innerArgs.isNotEmpty) ...[
          const SizedBox(height: 10),
          _buildSemanticArgsTable(
            c,
            innerArgs,
            stackArgs: stackArgs,
            headerTitle: '转发子工具参数',
          ),
        ],
      ],
    );
  }

  Widget _buildReadFileSection(ClaudePalette c, Map<String, dynamic> a) {
    final path = (a['path'] ?? '').toString();
    final off = a['offset'];
    final lim = a['limit'];
    return _pathBanner(
      c,
      path,
      pills: [
        if (off != null) ClaudePill(text: '起始行 $off', mono: false),
        if (lim != null) ClaudePill(text: '读取 $lim 行', mono: false),
      ],
    );
  }

  Widget _buildEditFileSection(ClaudePalette c, Map<String, dynamic> a) {
    final path = (a['path'] ?? '').toString();
    final edits = (a['edits'] as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    final dry = a['dry_run'] == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pathBanner(
          c,
          path,
          pills: [
            ClaudePill(
              text: '${edits.length} 处修改',
              fg: c.clay,
              bg: c.clay.withValues(alpha: 0.12),
              mono: false,
            ),
            if (dry)
              ClaudePill(
                text: '仅预览 (未落盘)',
                fg: c.purple,
                bg: c.purpleBg,
                mono: false,
              ),
          ],
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < edits.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _InlineDiffBlock(
            index: i + 1,
            oldStr: (edits[i]['old_str'] ?? '').toString(),
            newStr: (edits[i]['new_str'] ?? '').toString(),
            palette: c,
          ),
        ],
      ],
    );
  }

  Widget _buildCreateFileSection(ClaudePalette c, Map<String, dynamic> a) {
    final path = (a['path'] ?? '').toString();
    final content = (a['content'] ?? '').toString();
    final lines = content.isEmpty ? 0 : content.split('\n').length;
    final preview =
        content.length > 4000 ? '${content.substring(0, 4000)}\n…(已截断)' : content;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pathBanner(
          c,
          path,
          pills: [
            ClaudePill(text: '$lines 行 · ${content.length} 字符', mono: false),
            ClaudeButton(
              label: '复制内容',
              compact: true,
              onPressed: () => onCopy(content, '已复制写入内容'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 240),
          padding: const EdgeInsets.all(11),
          decoration: ShapeDecoration(
            color: c.termBg,
            shape: claudeSuperellipse(
              10,
              side: const BorderSide(color: Color(0xFF2E2D29)),
            ),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              preview,
              style: monoStyle(c, size: 11.8, color: c.termFg),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRunCommandSection(
    ClaudePalette c,
    Map<String, dynamic> a, {
    bool isBackground = false,
  }) {
    final cmd = (a['command'] ?? '').toString();
    final cwd = (a['cwd'] ?? '').toString();
    final shell = (a['shell'] ?? '').toString();
    final timeout = a['timeout'];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: ShapeDecoration(
        color: c.termBg,
        shape: claudeSuperellipse(
          10,
          side: const BorderSide(color: Color(0xFF2E2D29)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (isBackground)
                    ClaudePill(
                      text: '后台驻留进程',
                      mono: false,
                      fg: c.sage,
                      bg: const Color(0xFF233126),
                    ),
                  if (shell.isNotEmpty)
                    ClaudePill(
                      text: shell,
                      fg: const Color(0xFFFAF9F5),
                      bg: const Color(0xFF2B2A27),
                      border: const Color(0xFF45433E),
                    ),
                  if (timeout != null)
                    ClaudePill(
                      text: '超时 ${timeout}s',
                      mono: false,
                      fg: const Color(0xFFA09E96),
                      bg: const Color(0xFF252421),
                    ),
                  if (cwd.isNotEmpty)
                    Text(
                      cwd,
                      style: monoStyle(
                        c,
                        size: 11,
                        color: const Color(0xFFA09E96),
                      ),
                    ),
                ],
              ),
              ClaudeButton(
                label: '复制命令',
                compact: true,
                onPressed: () => onCopy(cmd, '已复制命令'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            '\$ $cmd',
            style: monoStyle(c, size: 12.2, color: const Color(0xFFE9C49A)),
          ),
        ],
      ),
    );
  }
}

class _InlineDiffBlock extends StatelessWidget {
  final int index;
  final String oldStr;
  final String newStr;
  final ClaudePalette palette;

  const _InlineDiffBlock({
    required this.index,
    required this.oldStr,
    required this.newStr,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final oldLines = oldStr.split('\n');
    final newLines = newStr.split('\n');
    return Container(
      width: double.infinity,
      decoration: ShapeDecoration(
        color: palette.termBg,
        shape: claudeSuperellipse(
          10,
          side: const BorderSide(color: Color(0xFF2E2D29)),
        ),
      ),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              color: const Color(0xFF22211E),
              child: Text(
                '变更片段 #$index',
                style: monoStyle(
                  palette,
                  size: 11,
                  color: const Color(0xFFD99A6C),
                  weight: FontWeight.w600,
                ),
              ),
            ),
            for (final line in oldLines.take(24))
              Container(
                color: const Color(0x36C94A4A),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1.5),
                child: SelectableText(
                  '- $line',
                  style: monoStyle(
                    palette,
                    size: 11.8,
                    color: const Color(0xFFFFA8A8),
                  ),
                ),
              ),
            if (oldLines.length > 24)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                child: Text(
                  '…(已省略 ${oldLines.length - 24} 行旧代码)',
                  style: monoStyle(
                    palette,
                    size: 11,
                    color: const Color(0xFF9C9A92),
                  ),
                ),
              ),
            for (final line in newLines.take(24))
              Container(
                color: const Color(0x30788C5D),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1.5),
                child: SelectableText(
                  '+ $line',
                  style: monoStyle(
                    palette,
                    size: 11.8,
                    color: const Color(0xFFC3E88D),
                  ),
                ),
              ),
            if (newLines.length > 24)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                child: Text(
                  '…(已省略 ${newLines.length - 24} 行新代码)',
                  style: monoStyle(
                    palette,
                    size: 11,
                    color: const Color(0xFF9C9A92),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ArgValueBox extends StatelessWidget {
  final String paramKey;
  final dynamic value;
  final ClaudePalette palette;

  const _ArgValueBox({
    required this.paramKey,
    required this.value,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    if (value is bool) {
      final b = value as bool;
      final txt = _semanticParamInlineValue(paramKey, b);
      return Align(
        alignment: Alignment.centerLeft,
        child: ClaudePill(
          text: b ? '✓ $txt' : '— $txt',
          mono: false,
          fg: b ? palette.sage : palette.muted,
          bg: b ? palette.sageBg : palette.paper2,
        ),
      );
    }
    if (value is num) {
      return Align(
        alignment: Alignment.centerLeft,
        child: ClaudePill(
          text: _semanticParamInlineValue(paramKey, value),
          mono: false,
          bg: palette.paper2,
          fg: palette.ink,
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: ShapeDecoration(
        color: palette.paper2,
        shape: claudeSuperellipse(9, side: BorderSide(color: palette.hairline)),
      ),
      child: SelectableText(
        value is String
            ? value as String
            : const JsonEncoder.withIndent('  ').convert(value),
        style: monoStyle(palette, size: 12, color: palette.ink),
      ),
    );
  }
}

class _DiffOutputView extends StatelessWidget {
  final String text;
  final ClaudePalette palette;

  const _DiffOutputView({required this.text, required this.palette});

  @override
  Widget build(BuildContext context) {
    final isDiff = text.contains('\n@@ ') || text.contains('\n--- a/');
    if (!isDiff) {
      return SelectableText(
        text,
        style: monoStyle(palette, size: 12, color: palette.termFg),
      );
    }

    final lines = text.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: lines.map((line) {
        Color? bg;
        Color fg = palette.termFg;
        if (line.startsWith('+') && !line.startsWith('+++')) {
          bg = const Color(0x33788C5D);
          fg = const Color(0xFFC3E88D);
        } else if (line.startsWith('-') && !line.startsWith('---')) {
          bg = const Color(0x38C94A4A);
          fg = const Color(0xFFFF9E9E);
        } else if (line.startsWith('@@')) {
          fg = const Color(0xFFD99A6C);
        }
        return Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: SelectableText(
            line,
            style: monoStyle(palette, size: 12, color: fg),
          ),
        );
      }).toList(),
    );
  }
}
