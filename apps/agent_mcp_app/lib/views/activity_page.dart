import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/prism_theme.dart';

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
  'manage_expose': (Icons.public_rounded, '外网分享'),
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
  if (t.endsWith('manage_expose') && a['action'] != null) {
    final act = a['action'].toString();
    final tgt = (a['target'] ?? a['port'] ?? a['id'] ?? '').toString();
    return tgt.isNotEmpty ? '$act -> $tgt' : act;
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
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _listKeyFocusNode = FocusNode();
  final ScrollController _scrollCtrl = ScrollController();
  final Set<int> _expandedIds = <int>{};
  bool _splitView = true;
  int? _selectedSeq;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
    _listKeyFocusNode.dispose();
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
      var hay = ev['_search_blob'] as String?;
      if (hay == null) {
        hay =
            '$tool $source ${ev['summary'] ?? ''} ${ev['result'] ?? ''} ${jsonEncode(ev['args'] ?? '')}'
                .toLowerCase();
        try {
          ev['_search_blob'] = hay;
        } catch (_) {}
      }
      if (!hay.contains(q)) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
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

    return LayoutBuilder(
      builder: (context, pageBox) {
        final canSplit = pageBox.maxWidth >= 900;
        final useSplit = canSplit && _splitView && filtered.isNotEmpty;

        Map<String, dynamic>? activeEv;
        int? activeSeq;
        if (useSplit) {
          for (var i = 0; i < filtered.length; i++) {
            final s = (filtered[i]['_seq'] as int?) ?? i;
            if (s == _selectedSeq) {
              activeEv = filtered[i];
              activeSeq = s;
              break;
            }
          }
          if (activeEv == null) {
            activeEv = filtered.first;
            activeSeq = (activeEv['_seq'] as int?) ?? 0;
          }
        }
        final filterBarWidget = DecoratedBox(
          decoration: ShapeDecoration(
            color: c.paper2,
            shape: prismSuperellipse(
              22,
              side: BorderSide(color: c.hairline.withValues(alpha: 0.62)),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: LayoutBuilder(
              builder: (ctx, fbox) {
                final narrowFilter = fbox.maxWidth < 680;
                final searchField = SizedBox(
                  height: 32,
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocusNode,
                    onChanged: (_) => setState(() {}),
                    style: sansStyle(c, size: 12.5, color: c.ink),
                    decoration: InputDecoration(
                      hintText: '搜索参数、路径或关键词...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(999),
                        borderSide: BorderSide(
                          color: c.hairline.withValues(alpha: 0.72),
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(999),
                        borderSide: BorderSide(
                          color: c.hairline.withValues(alpha: 0.72),
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(999),
                        borderSide: BorderSide(color: c.sage, width: 1.4),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      prefixIcon: Icon(
                        Icons.search_rounded,
                        size: 14.5,
                        color: c.meta,
                      ),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 30,
                      ),
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              iconSize: 13.5,
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

                final filterChips = <Widget>[
                  PrismSegmented<String>(
                    value: _cat,
                    items: const [
                      ('ALL', '全部'),
                      ('TOOL', '工具'),
                      ('OAUTH', '鉴权'),
                      ('ERR', '异常'),
                    ],
                    onChanged: (v) => setState(() => _cat = v),
                  ),
                  PrismDropMenu<String>(
                    value: _sort,
                    leadingIcon: Icons.swap_vert_rounded,
                    highlightActive: _sort != 'newest',
                    minMenuWidth: 152,
                    items: const [
                      PrismDropMenuItem(
                        value: 'newest',
                        label: '最新优先',
                        icon: Icons.schedule_rounded,
                      ),
                      PrismDropMenuItem(
                        value: 'oldest',
                        label: '最早优先',
                        icon: Icons.history_rounded,
                      ),
                      PrismDropMenuItem(
                        value: 'slowest',
                        label: '耗时最长',
                        icon: Icons.speed_rounded,
                      ),
                    ],
                    onChanged: (v) => setState(() => _sort = v),
                  ),
                  if (sortedSources.isNotEmpty)
                    PrismDropMenu<String>(
                      value: _activeSource,
                      leadingIcon: Icons.login_rounded,
                      highlightActive: _activeSource != 'ALL',
                      minMenuWidth: 184,
                      items: [
                        PrismDropMenuItem(
                          value: 'ALL',
                          label: '全部入口',
                          icon: Icons.public_rounded,
                          badge: '${widget.events.length}',
                        ),
                        for (final sName in sortedSources)
                          PrismDropMenuItem(
                            value: sName,
                            label: sName,
                            icon: Icons.login_rounded,
                            badge: '${sourceCounts[sName]}',
                          ),
                      ],
                      onChanged: (v) => setState(() => _activeSource = v),
                    ),
                  if (sortedTools.isNotEmpty)
                    PrismDropMenu<String>(
                      value: _activeTool,
                      leadingIcon: Icons.handyman_outlined,
                      highlightActive: _activeTool != 'ALL',
                      minMenuWidth: 206,
                      searchable: sortedTools.length >= 6,
                      items: [
                        PrismDropMenuItem(
                          value: 'ALL',
                          label: '全部工具',
                          icon: Icons.apps_rounded,
                          badge: '$toolCalls',
                        ),
                        for (final tName in sortedTools)
                          PrismDropMenuItem(
                            value: tName,
                            label: resolveToolMeta(tName).$2,
                            subtitle: tName,
                            icon: resolveToolMeta(tName).$1,
                            badge: '${toolCounts[tName]}',
                          ),
                      ],
                      onChanged: (v) => setState(() => _activeTool = v),
                    ),
                  if (hasActiveFilter)
                    PrismButton(
                      label: '重置',
                      compact: true,
                      variant: PrismBtnVariant.ghost,
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
                ];

                if (narrowFilter) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      searchField,
                      const SizedBox(height: 6),
                      PrismScrollHintRow(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < filterChips.length; i++) ...[
                              if (i > 0) const SizedBox(width: 6),
                              filterChips[i],
                            ],
                          ],
                        ),
                      ),
                    ],
                  );
                }

                return Row(
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        minWidth: 180,
                        maxWidth: 250,
                      ),
                      child: searchField,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: PrismScrollHintRow(
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < filterChips.length; i++) ...[
                              if (i > 0) const SizedBox(width: 6),
                              filterChips[i],
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );

        final headerSliver = SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.topPadding > 0) SizedBox(height: widget.topPadding),
              PrismStaggeredReveal(
                index: 0,
                child: PrismEditorialPageHeader(
                  eyebrow: 'LIVE INSPECTOR',
                  leadingDot: PrismStatusDot(
                    color: errCount > 0 ? c.danger : c.sage,
                    pulsing: widget.events.isNotEmpty,
                    size: 6.0,
                  ),
                  title: '活动与调用流',
                  titleBadge: _InlineTelemetryRibbon(
                    total: widget.events.length,
                    toolCalls: toolCalls,
                    errCount: errCount,
                    avgText: avgText,
                  ),
                  trailing: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (canSplit)
                        PrismSegmented<bool>(
                          value: _splitView,
                          items: const [
                            (true, '分栏预览'),
                            (false, '行内展开'),
                          ],
                          onChanged: (v) => setState(() => _splitView = v),
                        ),
                      PrismButton(
                        label: '清空',
                        compact: true,
                        leading: const Icon(Icons.delete_sweep_outlined),
                        onPressed: widget.onClear,
                      ),
                      PrismButton(
                        label: '导出日志',
                        compact: true,
                        leading: const Icon(Icons.download_outlined),
                        onPressed: widget.onExport,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              PrismStaggeredReveal(index: 1, child: filterBarWidget),
              const SizedBox(height: 8),
            ],
          ),
        );

        final feedSlivers = <Widget>[
        if (filtered.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: PrismStaggeredReveal(
              index: 2,
              child: Center(
                key: const ValueKey('empty-feed'),
                child: PrismCard(
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
                          shape: prismSuperellipse(14),
                        ),
                        alignment: Alignment.center,
                        child: const PrismSparkIcon(size: 20),
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
              bottom: (MediaQuery.sizeOf(context).width < 700 ? 124 : 28) +
                  widget.extraBottomPadding,
            ),
            sliver: SliverList.builder(
              key: const ValueKey('event-list'),
              itemCount: filtered.length,
              itemBuilder: (ctx, idx) {
                final ev = filtered[idx];
                final seqId = (ev['_seq'] as int?) ?? idx;
                final open = !useSplit && _expandedIds.contains(seqId);
                final isSelected = useSplit && seqId == activeSeq;
                return RepaintBoundary(
                  child: _EventCard(
                    key: ValueKey('ev-$seqId'),
                    ev: ev,
                    expanded: open,
                    selected: isSelected,
                    splitMode: useSplit,
                    isFirst: idx == 0,
                    isLast: idx == filtered.length - 1,
                    onToggle: () {
                      setState(() {
                        if (useSplit) {
                          _selectedSeq = seqId;
                          if (!_searchFocusNode.hasFocus) {
                            _listKeyFocusNode.requestFocus();
                          }
                        } else if (open) {
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
      ];

        if (!useSplit) {
          return CustomScrollView(
            controller: _scrollCtrl,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [headerSliver, ...feedSlivers],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.only(top: widget.topPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PrismEditorialPageHeader(
                    eyebrow: 'LIVE INSPECTOR',
                    leadingDot: PrismStatusDot(
                      color: errCount > 0 ? c.danger : c.sage,
                      pulsing: widget.events.isNotEmpty,
                      size: 6.0,
                    ),
                    title: '活动与调用流',
                    titleBadge: _InlineTelemetryRibbon(
                      total: widget.events.length,
                      toolCalls: toolCalls,
                      errCount: errCount,
                      avgText: avgText,
                    ),
                    trailing: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        PrismSegmented<bool>(
                          value: _splitView,
                          items: const [
                            (true, '分栏预览'),
                            (false, '行内展开'),
                          ],
                          onChanged: (v) => setState(() => _splitView = v),
                        ),
                        PrismButton(
                          label: '清空',
                          compact: true,
                          leading: const Icon(Icons.delete_sweep_outlined),
                          onPressed: widget.onClear,
                        ),
                        PrismButton(
                          label: '导出日志',
                          compact: true,
                          leading: const Icon(Icons.download_outlined),
                          onPressed: widget.onExport,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 11),
                  filterBarWidget,
                  const SizedBox(height: 10),
                ],
              ),
            ),
            Expanded(
              child: Focus(
                focusNode: _listKeyFocusNode,
                onKeyEvent: (_, KeyEvent keyEv) {
                  if (_searchFocusNode.hasFocus || keyEv is! KeyDownEvent) {
                    return KeyEventResult.ignored;
                  }
                  if (keyEv.logicalKey != LogicalKeyboardKey.arrowDown &&
                      keyEv.logicalKey != LogicalKeyboardKey.arrowUp) {
                    return KeyEventResult.ignored;
                  }
                  final curIdx = filtered.indexWhere(
                    (e) => ((e['_seq'] as int?) ?? -1) == activeSeq,
                  );
                  if (curIdx < 0) return KeyEventResult.ignored;
                  final nextIdx = keyEv.logicalKey == LogicalKeyboardKey.arrowDown
                      ? (curIdx + 1).clamp(0, filtered.length - 1)
                      : (curIdx - 1).clamp(0, filtered.length - 1);
                  if (nextIdx != curIdx) {
                    setState(() {
                      _selectedSeq = (filtered[nextIdx]['_seq'] as int?) ?? nextIdx;
                    });
                  }
                  return KeyEventResult.handled;
                },
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: 46,
                      child: CustomScrollView(
                        controller: _scrollCtrl,
                        physics: const AlwaysScrollableScrollPhysics(),
                        slivers: feedSlivers,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      flex: 54,
                      child: Padding(
                        padding: EdgeInsets.only(
                          bottom: 24 + widget.extraBottomPadding,
                        ),
                        child: PrismFadeBox(
                          duration: const Duration(milliseconds: 140),
                          alignment: Alignment.topLeft,
                          child: KeyedSubtree(
                            key: ValueKey('insp-$activeSeq-${activeEv!['status']}'),
                            child: _DockedInspectorPane(
                              ev: activeEv,
                              onCopy: (txt, msg) {
                                Clipboard.setData(ClipboardData(text: txt));
                                widget.onToast(msg);
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _InlineTelemetryRibbon extends StatelessWidget {
  final int total;
  final int toolCalls;
  final int errCount;
  final String avgText;

  const _InlineTelemetryRibbon({
    required this.total,
    required this.toolCalls,
    required this.errCount,
    required this.avgText,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    Widget item(String label, String val, {Color? accent}) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: sansStyle(c, size: 12, color: c.muted)),
          const SizedBox(width: 4.5),
          Text(
            val,
            style: monoStyle(
              c,
              size: 12.5,
              weight: FontWeight.w600,
              color: accent ?? c.ink,
            ),
          ),
        ],
      );
    }

    Widget dot() => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text('·', style: sansStyle(c, size: 12, color: c.meta)),
        );

    return DecoratedBox(
      decoration: ShapeDecoration(
        color: c.recessed,
        shape: const StadiumBorder(),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            item('事件', '$total'),
            dot(),
            item('调用', '$toolCalls'),
            dot(),
            item(
              '异常',
              '$errCount',
              accent: errCount > 0 ? c.danger : null,
            ),
            dot(),
            item('均值', avgText),
          ],
        ),
      ),
    );
  }
}

class _DockedInspectorPane extends StatefulWidget {
  final Map<String, dynamic> ev;
  final void Function(String text, String msg) onCopy;

  const _DockedInspectorPane({
    required this.ev,
    required this.onCopy,
  });

  @override
  State<_DockedInspectorPane> createState() => _DockedInspectorPaneState();
}

class _DockedInspectorPaneState extends State<_DockedInspectorPane> {
  String _tab = 'overview'; // overview | json

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
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
    final tsFull = (ev['ts_full'] ?? ts).toString().trim();
    final rawArgs = ev['args'];
    final argsMap = rawArgs is Map && rawArgs.isNotEmpty
        ? Map<String, dynamic>.from(rawArgs)
        : null;
    final resultStr = (ev['result'] ?? '').toString();

    final accent = switch (kind) {
      'err' => c.danger,
      'ok' => c.sage,
      'call' => c.clay,
      'oauth' => c.purple,
      _ => c.muted,
    };

    final rawJsonStr = const JsonEncoder.withIndent('  ').convert({
      'tool': toolRaw,
      'status': status,
      if (ms != null) 'latency_ms': ms,
      if (source.isNotEmpty) 'source': source,
      if (tsFull.isNotEmpty) 'timestamp': tsFull,
      if (argsMap != null) 'arguments': argsMap,
      if (resultStr.isNotEmpty) 'result': resultStr,
    });

    return PrismCard(
      radius: 12,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PrismStatusDot(
                      color: accent,
                      pulsing: isRunning,
                      size: 6.5,
                    ),
                    const SizedBox(width: 7),
                    Icon(tm.$1, size: 15, color: c.inkSoft),
                    const SizedBox(width: 6),
                    Text(
                      tm.$2,
                      style: sansStyle(
                        c,
                        size: 13.5,
                        weight: FontWeight.w600,
                        color: c.ink,
                      ),
                    ),
                    if (toolRaw.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Text(
                        toolRaw,
                        style: monoStyle(c, size: 11.2, color: c.meta),
                      ),
                    ],
                  ],
                ),
                Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (source.isNotEmpty)
                      PrismPill(
                        text: source,
                        mono: false,
                        fg: c.muted,
                        bg: c.recessed,
                      ),
                    if (tsFull.isNotEmpty)
                      PrismPill(
                        key: const ValueKey('inspector-timestamp-pill'),
                        text: tsFull,
                        fg: c.muted,
                        bg: c.recessed,
                      ),
                    PrismPill(
                      text: ms != null
                          ? '$badge · ${ms.toStringAsFixed(1)} ms'
                          : badge,
                      mono: false,
                      fg: accent,
                      bg: accent.withValues(alpha: 0.12),
                    ),
                    PrismSegmented<String>(
                      value: _tab,
                      items: const [
                        ('overview', '结构化'),
                        ('json', 'Raw JSON'),
                      ],
                      onChanged: (v) => setState(() => _tab = v),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Divider(color: c.hairline, height: 1),
          Expanded(
            child: _tab == 'json'
                ? Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              [
                                if (source.isNotEmpty) '来源: $source',
                                if (tsFull.isNotEmpty) '时间: $tsFull',
                              ].join('  ·  '),
                              style: monoStyle(c, size: 11.2, color: c.muted),
                            ),
                            PrismButton(
                              label: '复制 JSON',
                              compact: true,
                              leading: const Icon(Icons.copy_rounded),
                              onPressed: () =>
                                  widget.onCopy(rawJsonStr, '已复制完整 JSON'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: _StructuredCodeSheet(
                            text: rawJsonStr,
                            palette: c,
                            headerLabel: 'JSON 负载',
                            fillHeight: true,
                          ),
                        ),
                      ],
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.only(top: 10),
                    child: _RichToolDetailDrawer(
                      ev: ev,
                      toolRaw: toolRaw,
                      argsMap: argsMap,
                      resultStr: resultStr,
                      summary: summary,
                      onCopy: widget.onCopy,
                      docked: true,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EventCard extends StatefulWidget {
  final Map<String, dynamic> ev;
  final bool expanded;
  final bool selected;
  final bool splitMode;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onToggle;
  final void Function(String text, String msg) onCopy;

  const _EventCard({
    super.key,
    required this.ev,
    required this.expanded,
    this.selected = false,
    this.splitMode = false,
    this.isFirst = false,
    this.isLast = false,
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
    final c = PrismPalette.of(context);
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
                PrismStatusDot(
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

    final borderRad = BorderRadius.vertical(
      top: widget.isFirst ? const Radius.circular(20) : Radius.zero,
      bottom: widget.isLast ? const Radius.circular(20) : Radius.zero,
    );
    final rowBg = widget.selected
        ? Color.alphaBlend(
            c.clay.withValues(alpha: c.isDark ? 0.16 : 0.08),
            c.paper2,
          )
        : (_hovered
            ? Color.alphaBlend(
                c.paper3.withValues(alpha: 0.65),
                c.paper2,
              )
            : c.paper2);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: CustomPaint(
        foregroundPainter: _EventRowBorderPainter(
          borderColor: c.hairline,
          selectedColor: widget.selected ? c.clay : null,
          isFirst: widget.isFirst,
          isLast: widget.isLast,
          radius: 20,
        ),
        child: ClipRRect(
          borderRadius: borderRad,
          child: ColoredBox(
            color: rowBg,
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
                      horizontal: 14,
                      vertical: 10,
                    ),
                    child: LayoutBuilder(
                      builder: (ctx, rowBox) {
                        final isCompactRow = rowBox.maxWidth < 640;
                        final chevron = widget.splitMode
                            ? Icon(
                                Icons.chevron_right_rounded,
                                size: 16,
                                color: widget.selected ? c.clay : c.meta,
                              )
                            : AnimatedRotation(
                                turns: widget.expanded ? 0.5 : 0.0,
                                duration: PrismMotion.duration(
                                  context,
                                  PrismMotion.base,
                                ),
                                curve: PrismMotion.editorialOut,
                                child: Icon(
                                  Icons.expand_more_rounded,
                                  size: 17,
                                  color: _hovered ? c.inkSoft : c.meta,
                                ),
                              );

                        final statusLead = isRunning || kind == 'err'
                            ? buildStatusAccentPill()
                            : Container(
                                width: 3.5,
                                height: 15,
                                decoration: BoxDecoration(
                                  color: accent,
                                  borderRadius: BorderRadius.circular(99),
                                ),
                              );

                        final metaTrail = Text(
                          [
                            if (!isCompactRow &&
                                !widget.splitMode &&
                                source.isNotEmpty)
                              source,
                            if (ms != null) '${ms.toStringAsFixed(0)} ms',
                            if (ts.isNotEmpty) ts,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(c, size: 11.2, color: c.meta),
                        );

                        if (isCompactRow) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  statusLead,
                                  const SizedBox(width: 8),
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
                                  const SizedBox(width: 6),
                                  Flexible(child: metaTrail),
                                  const SizedBox(width: 4),
                                  chevron,
                                ],
                              ),
                              if (summary.isNotEmpty || source.isNotEmpty) ...[
                                const SizedBox(height: 5),
                                Row(
                                  children: [
                                    if (source.isNotEmpty) ...[
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 110,
                                        ),
                                        child: Text(
                                          '$source · ',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: sansStyle(
                                            c,
                                            size: 11.5,
                                            color: c.muted,
                                          ),
                                        ),
                                      ),
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
                            statusLead,
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 118,
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
                            metaTrail,
                            const SizedBox(width: 6),
                            chevron,
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
                PrismCollapsible(
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
      ),
    );
  }
}

class _EventRowBorderPainter extends CustomPainter {
  final Color borderColor;
  final Color? selectedColor;
  final bool isFirst;
  final bool isLast;
  final double radius;

  const _EventRowBorderPainter({
    required this.borderColor,
    required this.selectedColor,
    required this.isFirst,
    required this.isLast,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = borderColor
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final rTop = isFirst ? Radius.circular(radius) : Radius.zero;
    final rBot = isLast ? Radius.circular(radius) : Radius.zero;
    final rect = (Offset.zero & size).deflate(0.5);

    if (isFirst) {
      final rrect = RRect.fromRectAndCorners(
        rect,
        topLeft: rTop,
        topRight: rTop,
        bottomLeft: rBot,
        bottomRight: rBot,
      );
      canvas.drawRRect(rrect, p);
    } else if (isLast) {
      final path = Path()
        ..moveTo(rect.left, 0)
        ..lineTo(rect.left, rect.bottom - radius)
        ..arcToPoint(
          Offset(rect.left + radius, rect.bottom),
          radius: Radius.circular(radius),
          clockwise: false,
        )
        ..lineTo(rect.right - radius, rect.bottom)
        ..arcToPoint(
          Offset(rect.right, rect.bottom - radius),
          radius: Radius.circular(radius),
          clockwise: false,
        )
        ..lineTo(rect.right, 0);
      canvas.drawPath(path, p);
    } else {
      canvas.drawLine(Offset(rect.left, 0), Offset(rect.left, size.height), p);
      canvas.drawLine(Offset(rect.right, 0), Offset(rect.right, size.height), p);
      canvas.drawLine(
        Offset(rect.left, rect.bottom),
        Offset(rect.right, rect.bottom),
        p,
      );
    }

    if (selectedColor != null) {
      final clipRRect = RRect.fromRectAndCorners(
        Offset.zero & size,
        topLeft: rTop,
        bottomLeft: rBot,
      );
      canvas.save();
      canvas.clipRRect(clipRRect);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, 3.0, size.height),
        Paint()..color = selectedColor!,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _EventRowBorderPainter oldDelegate) =>
      oldDelegate.borderColor != borderColor ||
      oldDelegate.selectedColor != selectedColor ||
      oldDelegate.isFirst != isFirst ||
      oldDelegate.isLast != isLast;
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
    final c = PrismPalette.of(context);
    final t = (ev['tool'] ?? '').toString();
    final rawArgs = ev['args'];
    final a = rawArgs is Map
        ? Map<String, dynamic>.from(rawArgs)
        : const <String, dynamic>{};

    Widget pill(String text, {Color? accent, bool mono = false}) {
      final col = accent ?? c.inkSoft;
      return PrismPill(
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
      return Wrap(
        spacing: 6,
        runSpacing: 3,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
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
            ],
          ),
          ...pills,
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
              color: c.codeHeader,
              shape: prismSuperellipse(5, side: BorderSide(color: c.hairline)),
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
            PrismPill(text: sh, bg: c.paper3),
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
            PrismPill(text: '#$pid', bg: c.paper3),
          ],
          if (tail != null && act == 'read') ...[
            const SizedBox(width: 6),
            PrismPill(text: '末尾 $tail 行', mono: false, bg: c.paper3),
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
            PrismPill(text: glob, bg: c.paper3),
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
          PrismPill(text: srv, mono: false, bg: c.paper3),
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
          child: PrismPill(
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
  final bool docked;

  const _RichToolDetailDrawer({
    required this.ev,
    required this.toolRaw,
    required this.argsMap,
    required this.resultStr,
    required this.summary,
    required this.onCopy,
    this.docked = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
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
      margin: docked
          ? const EdgeInsets.fromLTRB(16, 0, 16, 16)
          : const EdgeInsets.fromLTRB(14, 0, 14, 14),
      padding: docked ? EdgeInsets.zero : const EdgeInsets.all(14),
      decoration: docked
          ? const BoxDecoration()
          : ShapeDecoration(
              color: c.recessed,
              shape: prismSuperellipse(
                16,
                side: BorderSide(color: c.hairline.withValues(alpha: 0.65)),
              ),
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
                Builder(
                  builder: (ctx) {
                    final outText = resultStr.isNotEmpty ? resultStr : summary;
                    final trimmedOut = outText.trim();
                    final isSingleLineReceipt = resultStr.isNotEmpty &&
                        !trimmedOut.contains('\n') &&
                        trimmedOut.length <= 180 &&
                        (ev['kind'] ?? 'ok') != 'err';

                    if (isSingleLineReceipt) {
                      return Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 8,
                        ),
                        decoration: ShapeDecoration(
                          color: c.sageBg,
                          shape: prismSuperellipse(
                            14,
                            side: BorderSide(
                              color: c.sage.withValues(alpha: 0.28),
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.check_circle_outline_rounded,
                              size: 15,
                              color: c.sage,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: SelectableText(
                                  trimmedOut,
                                  maxLines: 1,
                                  style: monoStyle(
                                    c,
                                    size: 11.8,
                                    color: c.ink,
                                    weight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            PrismButton(
                              label: '复制',
                              compact: true,
                              tooltip: '复制结果',
                              variant: PrismBtnVariant.ghost,
                              leading: const Icon(Icons.copy_rounded, size: 13.5),
                              onPressed: () => onCopy(outText, '已复制结果内容'),
                            ),
                          ],
                        ),
                      );
                    }

                    return _StructuredCodeSheet(
                      text: outText,
                      palette: c,
                      headerLabel: resultStr.isNotEmpty ? '执行结果' : '事件详情',
                      maxHeight: docked ? 440 : 280,
                      onCopy: () => onCopy(outText, '已复制结果内容'),
                      copyLabel: '复制结果',
                    );
                  },
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _pathBanner(
    PrismPalette c,
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
        shape: prismSuperellipse(14, side: BorderSide(color: c.hairline.withValues(alpha: 0.68))),
      ),
      child: LayoutBuilder(
        builder: (ctx, pBox) => Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 6,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: pBox.maxWidth.isFinite ? pBox.maxWidth : 640,
              ),
              child: Row(
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
            ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ...pills,
                PrismButton(
                  label: copyLabel,
                  compact: true,
                  onPressed: () => onCopy(path, '已复制路径'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSemanticArgsTable(
    PrismPalette c,
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
            PrismButton(
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

  Widget _buildListDirSection(PrismPalette c, Map<String, dynamic> a) {
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
          PrismPill(
            text: '遍历深度 $depth 层',
            mono: false,
            fg: c.sage,
            bg: c.sageBg,
          ),
        if (maxEntries != null)
          PrismPill(text: '上限 $maxEntries 项', mono: false),
        PrismPill(
          text: hidden ? '包含隐藏项' : '忽略隐藏项',
          mono: false,
          fg: hidden ? c.clay : c.muted,
          bg: hidden ? c.clay.withValues(alpha: 0.12) : c.paper3,
        ),
      ],
    );
  }

  Widget _buildStatOrUndoSection(
    PrismPalette c,
    Map<String, dynamic> a, {
    required bool isUndo,
  }) {
    final path = (a['path'] ?? '').toString();
    return _pathBanner(
      c,
      path,
      icon: isUndo ? Icons.undo_rounded : Icons.info_outline_rounded,
      pills: [
        PrismPill(
          text: isUndo ? '回滚最近一次编辑' : '文件元数据探测',
          mono: false,
          fg: c.purple,
          bg: c.purpleBg,
        ),
      ],
    );
  }

  Widget _buildApplyPatchSection(PrismPalette c, Map<String, dynamic> a) {
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
            PrismPill(
              text: 'Unified Diff 补丁',
              mono: false,
              fg: c.purple,
              bg: c.purpleBg,
            ),
            if (dry)
              PrismPill(
                text: '仅预览',
                mono: false,
                fg: c.clay,
                bg: c.clay.withValues(alpha: 0.12),
              ),
          ],
        ),
        if (patch.isNotEmpty) ...[
          const SizedBox(height: 8),
          _StructuredCodeSheet(
            text: patch,
            palette: c,
            headerLabel: '补丁内容',
            maxHeight: 240,
            onCopy: () => onCopy(patch, '已复制补丁内容'),
            copyLabel: '复制补丁',
          ),
        ],
      ],
    );
  }

  Widget _buildReplaceTextSection(PrismPalette c, Map<String, dynamic> a) {
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
            if (glob.isNotEmpty) PrismPill(text: glob),
            if (regex) PrismPill(text: '正则替换', mono: false),
            PrismPill(
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
    PrismPalette c,
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
            if (glob.isNotEmpty) PrismPill(text: '过滤 $glob', mono: false),
            if (!isGlob && regex != null)
              PrismPill(
                text: regex == true ? '正则匹配' : '字面匹配',
                mono: false,
              ),
            if (!isGlob && caseSens == false)
              const PrismPill(text: '忽略大小写', mono: false),
            if (ctxLines is num && ctxLines > 0)
              PrismPill(text: '上下文 $ctxLines 行', mono: false),
            if (maxRes != null)
              PrismPill(text: '上限 $maxRes 条', mono: false),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8.5),
          decoration: ShapeDecoration(
            color: c.paper2,
            shape: prismSuperellipse(14, side: BorderSide(color: c.hairline.withValues(alpha: 0.68))),
          ),
          child: Row(
            children: [
              PrismPill(
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
              PrismButton(
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

  Widget _buildFileOpSection(PrismPalette c, Map<String, dynamic> a) {
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
            PrismPill(
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
              PrismPill(text: '目标位置', mono: false),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildManageProcessSection(PrismPalette c, Map<String, dynamic> a) {
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
        shape: prismSuperellipse(14, side: BorderSide(color: c.hairline.withValues(alpha: 0.68))),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          PrismPill(
            text: actLabel,
            mono: false,
            fg: col,
            bg: col.withValues(alpha: 0.12),
          ),
          if (pid.isNotEmpty)
            PrismPill(text: '进程 ID · $pid', bg: c.recessed),
          if (tail != null)
            PrismPill(text: '尾部 $tail 行', mono: false, bg: c.recessed),
          if (input.isNotEmpty)
            PrismPill(text: '输入 ${input.length} 字符', mono: false),
        ],
      ),
    );
  }

  Widget _buildReadFilesSection(PrismPalette c, Map<String, dynamic> a) {
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
              PrismPill(text: '#${i + 1}/${paths.length}'),
            ],
          ),
        ],
      ],
    );
  }

  Widget _buildSubMcpSection(
    PrismPalette c,
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
            shape: prismSuperellipse(14, side: BorderSide(color: c.hairline.withValues(alpha: 0.68))),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PrismPill(
                text: '子服务 · $srv',
                mono: false,
                fg: c.clay,
                bg: c.clay.withValues(alpha: 0.12),
              ),
              if (subTool.isNotEmpty) ...[
                Icon(Icons.arrow_forward_rounded, size: 13, color: c.meta),
                PrismPill(text: subTool, bg: c.recessed),
              ] else
                const PrismPill(text: '读取工具架构清单', mono: false),
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

  Widget _buildReadFileSection(PrismPalette c, Map<String, dynamic> a) {
    final path = (a['path'] ?? '').toString();
    final off = a['offset'];
    final lim = a['limit'];
    return _pathBanner(
      c,
      path,
      pills: [
        if (off != null) PrismPill(text: '起始行 $off', mono: false),
        if (lim != null) PrismPill(text: '读取 $lim 行', mono: false),
      ],
    );
  }

  Widget _buildEditFileSection(PrismPalette c, Map<String, dynamic> a) {
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
            PrismPill(
              text: '${edits.length} 处修改',
              fg: c.clay,
              bg: c.clay.withValues(alpha: 0.12),
              mono: false,
            ),
            if (dry)
              PrismPill(
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

  Widget _buildCreateFileSection(PrismPalette c, Map<String, dynamic> a) {
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
            PrismPill(text: '$lines 行 · ${content.length} 字符', mono: false),
          ],
        ),
        const SizedBox(height: 8),
        _StructuredCodeSheet(
          text: preview,
          palette: c,
          headerLabel: '写入内容',
          maxHeight: 256,
          onCopy: () => onCopy(content, '已复制写入内容'),
          copyLabel: '复制内容',
        ),
      ],
    );
  }

  Widget _buildRunCommandSection(
    PrismPalette c,
    Map<String, dynamic> a, {
    bool isBackground = false,
  }) {
    final cmd = (a['command'] ?? '').toString();
    final cwd = (a['cwd'] ?? '').toString();
    final shell = (a['shell'] ?? '').toString();
    final timeout = a['timeout'];

    return Container(
      width: double.infinity,
      decoration: ShapeDecoration(
        color: c.codeSheet,
        shape: prismSuperellipse(
          16,
          side: BorderSide(color: c.codeBorder),
        ),
      ),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6.5),
              decoration: BoxDecoration(
                color: c.codeHeader,
                border: Border(bottom: BorderSide(color: c.codeBorder)),
              ),
              child: Wrap(
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
                        PrismPill(
                          text: '后台驻留进程',
                          mono: false,
                          fg: c.sage,
                          bg: c.sageBg,
                        ),
                      if (shell.isNotEmpty)
                        PrismPill(
                          text: shell,
                          fg: c.inkSoft,
                          bg: c.paper2,
                          border: c.hairline,
                        ),
                      if (timeout != null)
                        PrismPill(
                          text: '超时 ${timeout}s',
                          mono: false,
                          fg: c.muted,
                          bg: c.paper2,
                        ),
                      if (cwd.isNotEmpty)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 260),
                          child: Text(
                            cwd,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: monoStyle(c, size: 11, color: c.muted),
                          ),
                        ),
                    ],
                  ),
                  PrismButton(
                    label: '复制命令',
                    compact: true,
                    onPressed: () => onCopy(cmd, '已复制命令'),
                  ),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: SelectableText(
                '\$ $cmd',
                style: monoStyle(
                  c,
                  size: 12.2,
                  color: c.clay,
                  weight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineDiffBlock extends StatefulWidget {
  final int index;
  final String oldStr;
  final String newStr;
  final PrismPalette palette;

  const _InlineDiffBlock({
    required this.index,
    required this.oldStr,
    required this.newStr,
    required this.palette,
  });

  @override
  State<_InlineDiffBlock> createState() => _InlineDiffBlockState();
}

class _InlineDiffBlockState extends State<_InlineDiffBlock> {
  bool _softWrap = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.palette;
    final oldLines = widget.oldStr.split('\n');
    final newLines = widget.newStr.split('\n');
    final diffRows = <({String numLabel, String prefix, String text, int kind})>[];
    final maxOld = oldLines.length > 28 ? 28 : oldLines.length;
    for (var i = 0; i < maxOld; i++) {
      diffRows.add((
        numLabel: '${i + 1}',
        prefix: '-',
        text: oldLines[i],
        kind: -1,
      ));
    }
    if (oldLines.length > 28) {
      diffRows.add((
        numLabel: '…',
        prefix: ' ',
        text: '(已省略 ${oldLines.length - 28} 行旧代码)',
        kind: 0,
      ));
    }
    final maxNew = newLines.length > 28 ? 28 : newLines.length;
    for (var i = 0; i < maxNew; i++) {
      diffRows.add((
        numLabel: '${i + 1}',
        prefix: '+',
        text: newLines[i],
        kind: 1,
      ));
    }
    if (newLines.length > 28) {
      diffRows.add((
        numLabel: '…',
        prefix: ' ',
        text: '(已省略 ${newLines.length - 28} 行新代码)',
        kind: 0,
      ));
    }

    const rowHeight = 20.0;
    final strut = const StrutStyle(
      fontFamily: kFontMono,
      fontSize: 11.8,
      height: 1.55,
      forceStrutHeight: true,
    );

    Widget buildCodeColumn({required bool wrapped}) {
      return Column(
        crossAxisAlignment:
            wrapped ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final r in diffRows)
            Container(
              color: r.kind < 0
                  ? c.diffDelBg
                  : (r.kind > 0 ? c.diffAddBg : Colors.transparent),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
              constraints: wrapped ? null : const BoxConstraints(minHeight: rowHeight),
              alignment: Alignment.centerLeft,
              child: SelectableText(
                '${r.prefix} ${r.text}',
                strutStyle: strut,
                style: monoStyle(
                  c,
                  size: 11.8,
                  height: 1.55,
                  color: r.kind < 0
                      ? c.diffDelFg
                      : (r.kind > 0 ? c.diffAddFg : c.muted),
                ),
              ),
            ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      decoration: ShapeDecoration(
        color: c.codeSheet,
        shape: prismSuperellipse(
          16,
          side: BorderSide(color: c.codeBorder),
        ),
      ),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
              decoration: BoxDecoration(
                color: c.codeHeader,
                border: Border(bottom: BorderSide(color: c.codeBorder)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '变更片段 #${widget.index}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: monoStyle(
                        c,
                        size: 11.2,
                        color: c.clay,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => setState(() => _softWrap = !_softWrap),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      child: Text(
                        _softWrap ? '自动换行：开' : '左右滑动',
                        style: sansStyle(
                          c,
                          size: 11,
                          weight: FontWeight.w500,
                          color: _softWrap ? c.clay : c.muted,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_softWrap)
              buildCodeColumn(wrapped: true)
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 38,
                    decoration: BoxDecoration(
                      color: c.codeGutter,
                      border: Border(right: BorderSide(color: c.codeBorder)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final r in diffRows)
                          Container(
                            height: rowHeight,
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 7),
                            color: r.kind < 0
                                ? c.diffDelBg
                                : (r.kind > 0
                                    ? c.diffAddBg
                                    : Colors.transparent),
                            child: Text(
                              r.numLabel,
                              style: monoStyle(
                                c,
                                size: 10.6,
                                color: r.kind < 0
                                    ? c.diffDelFg.withValues(alpha: 0.78)
                                    : (r.kind > 0
                                        ? c.diffAddFg.withValues(alpha: 0.78)
                                        : c.meta),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (ctx, hBox) => SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: hBox.maxWidth.isFinite ? hBox.maxWidth : 0,
                          ),
                          child: buildCodeColumn(wrapped: false),
                        ),
                      ),
                    ),
                  ),
                ],
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
  final PrismPalette palette;

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
        child: PrismPill(
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
        child: PrismPill(
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
        shape: prismSuperellipse(9, side: BorderSide(color: palette.hairline)),
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

/// Theme-adaptive code & diff viewer with pinned left line-number gutter,
/// smooth 2D horizontal scrolling (zero awkward mid-identifier hard-wraps),
/// and an optional one-click soft-wrap toggle.
class _StructuredCodeSheet extends StatefulWidget {
  final String text;
  final PrismPalette palette;
  final String headerLabel;
  final double? maxHeight;
  final bool fillHeight;
  final VoidCallback? onCopy;
  final String copyLabel;

  const _StructuredCodeSheet({
    required this.text,
    required this.palette,
    required this.headerLabel,
    this.maxHeight,
    this.fillHeight = false,
    this.onCopy,
    this.copyLabel = '复制',
  });

  @override
  State<_StructuredCodeSheet> createState() => _StructuredCodeSheetState();
}

class _StructuredCodeSheetState extends State<_StructuredCodeSheet> {
  bool _softWrap = false;

  static final RegExp _tokenRegex = RegExp(
    r'(//[^\n]*|#[^\n]*)'
    r'''|('(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*")'''
    r'|\b(import|export|library|part|class|enum|mixin|extension|extends|implements|with|final|const|var|late|required|return|async|await|yield|void|bool|int|double|num|dynamic|if|else|switch|case|default|for|in|while|do|break|continue|try|catch|finally|throw|new|this|super|true|false|null|static|override|function|def|let|interface|type|struct|impl|fn|pub|use|from|as)\b'
    r'|(@[A-Za-z_]\w*|\b[A-Z][A-Za-z0-9_]*\b)'
    r'|\b(\d+(?:\.\d+)?)\b',
  );

  TextSpan _buildSyntaxSpan(PrismPalette c, String src) {
    final baseStyle = monoStyle(c, size: 11.8, height: 1.62, color: c.termFg);
    if (src.isEmpty || src.length > 48000) {
      return TextSpan(text: src, style: baseStyle);
    }
    final commentCol = c.meta;
    final stringCol =
        c.isDark ? const Color(0xFF6EE7B7) : const Color(0xFF047857);
    final keywordCol =
        c.isDark ? const Color(0xFFC4B5FD) : const Color(0xFF6D28D9);
    final typeCol =
        c.isDark ? const Color(0xFF7DD3FC) : const Color(0xFF0369A1);
    final numCol =
        c.isDark ? const Color(0xFFFCD34D) : const Color(0xFFB45309);

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final m in _tokenRegex.allMatches(src)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: src.substring(cursor, m.start)));
      }
      Color tokenColor = c.termFg;
      FontWeight weight = FontWeight.w400;
      if (m.group(1) != null) {
        tokenColor = commentCol;
      } else if (m.group(2) != null) {
        tokenColor = stringCol;
      } else if (m.group(3) != null) {
        tokenColor = keywordCol;
        weight = FontWeight.w500;
      } else if (m.group(4) != null) {
        tokenColor = typeCol;
      } else if (m.group(5) != null) {
        tokenColor = numCol;
      }
      spans.add(
        TextSpan(
          text: m.group(0),
          style: TextStyle(color: tokenColor, fontWeight: weight),
        ),
      );
      cursor = m.end;
    }
    if (cursor < src.length) {
      spans.add(TextSpan(text: src.substring(cursor)));
    }
    return TextSpan(style: baseStyle, children: spans);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.palette;
    final cleanText = widget.text.replaceAll('\r\n', '\n');
    final lines = cleanText.isEmpty ? const <String>[''] : cleanText.split('\n');
    final isDiff = cleanText.contains('\n@@ ') ||
        cleanText.startsWith('@@ ') ||
        cleanText.contains('\n--- a/') ||
        cleanText.startsWith('--- a/');
    final gutterDigits = lines.length.toString().length.clamp(2, 5);
    final gutterWidth = gutterDigits * 8.2 + 18.0;
    const lineH = 19.5;
    final strut = const StrutStyle(
      fontFamily: kFontMono,
      fontSize: 11.8,
      height: 1.62,
      forceStrutHeight: true,
    );

    Widget buildBody() {
      if (_softWrap) {
        if (!isDiff) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SelectableText.rich(
              _buildSyntaxSpan(c, cleanText),
              strutStyle: strut,
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final line in lines)
              _buildDiffLineBox(c, line, strut: strut, minHeight: null),
          ],
        );
      }

      // Default: Pinned non-selectable line-number gutter + smooth horizontal scroll!
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: gutterWidth,
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: c.codeGutter,
              border: Border(right: BorderSide(color: c.codeBorder)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < lines.length; i++)
                  SizedBox(
                    height: lineH,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Text(
                          '${i + 1}',
                          style: monoStyle(c, size: 10.6, color: c.meta),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (ctx, hBox) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: hBox.maxWidth.isFinite ? hBox.maxWidth : 0,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: isDiff
                        ? Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final line in lines)
                                _buildDiffLineBox(
                                  c,
                                  line,
                                  strut: strut,
                                  minHeight: lineH,
                                ),
                            ],
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: SelectableText.rich(
                              _buildSyntaxSpan(c, cleanText),
                              strutStyle: strut,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    final scrollBody = SingleChildScrollView(child: buildBody());

    return Container(
      width: double.infinity,
      constraints: !widget.fillHeight && widget.maxHeight != null
          ? BoxConstraints(maxHeight: widget.maxHeight!)
          : null,
      decoration: ShapeDecoration(
        color: c.codeSheet,
        shape: prismSuperellipse(
          16,
          side: BorderSide(color: c.codeBorder),
        ),
      ),
      child: ClipRSuperellipse(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          mainAxisSize: widget.fillHeight ? MainAxisSize.max : MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                color: c.codeHeader,
                border: Border(bottom: BorderSide(color: c.codeBorder)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${widget.headerLabel} · ${lines.length} 行',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sansStyle(
                        c,
                        size: 11.5,
                        weight: FontWeight.w600,
                        color: c.inkSoft,
                        tabular: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => setState(() => _softWrap = !_softWrap),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2.5,
                      ),
                      child: Text(
                        _softWrap ? '自动换行：开' : '左右滑动',
                        style: sansStyle(
                          c,
                          size: 11,
                          weight: FontWeight.w500,
                          color: _softWrap ? c.clay : c.muted,
                        ),
                      ),
                    ),
                  ),
                  if (widget.onCopy != null) ...[
                    const SizedBox(width: 6),
                    PrismButton(
                      label: widget.copyLabel,
                      compact: true,
                      leading: const Icon(Icons.copy_rounded, size: 13),
                      onPressed: widget.onCopy,
                    ),
                  ],
                ],
              ),
            ),
            if (widget.fillHeight)
              Expanded(child: scrollBody)
            else
              Flexible(child: scrollBody),
          ],
        ),
      ),
    );
  }

  Widget _buildDiffLineBox(
    PrismPalette c,
    String line, {
    required StrutStyle strut,
    required double? minHeight,
  }) {
    Color? bg;
    Color fg = c.termFg;
    if (line.startsWith('+') && !line.startsWith('+++')) {
      bg = c.diffAddBg;
      fg = c.diffAddFg;
    } else if (line.startsWith('-') && !line.startsWith('---')) {
      bg = c.diffDelBg;
      fg = c.diffDelFg;
    } else if (line.startsWith('@@')) {
      fg = c.diffHunkFg;
    }
    return Container(
      height: minHeight,
      alignment: Alignment.centerLeft,
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: SelectableText(
        line,
        strutStyle: strut,
        style: monoStyle(c, size: 11.8, height: 1.62, color: fg),
      ),
    );
  }
}
