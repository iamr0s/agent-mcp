import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/console_backend.dart';
import '../theme/prism_theme.dart';
import 'prism_structured_editors.dart';

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
  final Set<String> _oauthStartingNames = <String>{};
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

  Future<void> _startOAuthConnect(Map<String, dynamic> s) async {
    final name = (s['name'] ?? '').toString();
    if (name.isEmpty || _oauthStartingNames.contains(name)) return;
    setState(() => _oauthStartingNames.add(name));
    try {
      final res = await widget.backend.startSubMcpOAuth(name);
      if (res['ok'] == true) {
        widget.onToast('已在浏览器打开 OAuth 2.1 授权页，授权完成后自动接管并刷新工具表');
        // Poll status for loopback completion over the next ~25s
        unawaited(_pollAfterOAuthRedirect(name));
      } else {
        widget.onToast('发起 OAuth 失败：${res['error'] ?? ''}');
      }
    } finally {
      if (mounted) setState(() => _oauthStartingNames.remove(name));
    }
  }

  Future<void> _pollAfterOAuthRedirect(String name) async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      await widget.onRefresh();
      final match =
          widget.servers.where((e) => e['name'] == name).firstOrNull;
      final oauth = match?['oauth_status'] is Map
          ? Map<String, dynamic>.from(match!['oauth_status'] as Map)
          : const <String, dynamic>{};
      if (oauth['authorized'] == true) {
        widget.onToast('OAuth 2.1 授权已完成：$name');
        await _testServer(name);
        return;
      }
    }
  }

  Future<void> _toggleToolDisabled(
    Map<String, dynamic> server,
    String toolName,
    bool enableTool,
  ) async {
    final disabled = ((server['disabled_tools'] as List?) ?? const [])
        .map((e) => e.toString())
        .toSet();
    if (enableTool) {
      disabled.remove(toolName);
    } else {
      disabled.add(toolName);
    }
    final nextEntry = Map<String, dynamic>.from(server)
      ..['disabled_tools'] = disabled.toList();
    await widget.backend.upsertSubMcp(
      nextEntry,
      oldName: (server['name'] ?? '').toString(),
    );
    await widget.onRefresh();
  }

  Future<void> _openPlayground(
    Map<String, dynamic> server, {
    String? initialToolName,
  }) async {
    await showPrismDialog<void>(
      context: context,
      builder: (ctx) => _SubMcpPlaygroundDialog(
        backend: widget.backend,
        server: server,
        initialToolName: initialToolName,
        onToast: widget.onToast,
      ),
    );
  }

  Future<void> _openEditModal({
    Map<String, dynamic>? existing,
    bool jsonMode = false,
  }) async {
    final saved = await showPrismDialog<bool>(
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
    final c = PrismPalette.of(context);
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
              PrismStaggeredReveal(
                index: 0,
                child: PrismEditorialPageHeader(
                  eyebrow: 'UNIVERSAL SUB-MCP HUB',
                  leadingDot: PrismStatusDot(
                    color: enabledCount > 0 ? c.sage : c.meta,
                    pulsing: enabledCount > 0,
                    size: 6.0,
                  ),
                  title: '子 MCP 全协议中枢',
                  titleBadge: widget.servers.isNotEmpty
                      ? PrismPill(
                          text: '$enabledCount / ${widget.servers.length} 已启用',
                          mono: false,
                          fg: enabledCount > 0 ? c.sage : c.muted,
                          bg: enabledCount > 0 ? c.sageBg : c.recessed,
                        )
                      : null,
                  subtitle:
                      '全面支持 OAuth 2.1 PKCE / M2M / Bearer / API Key 与 Auto / HTTP / SSE / WS / Stdio，支持网关转发或直通挂载',
                  trailing: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      PrismButton(
                        label: '智能导入 JSON / 命令',
                        compact: true,
                        leading: const Icon(Icons.data_object_rounded),
                        onPressed: () => _openEditModal(jsonMode: true),
                      ),
                      PrismButton(
                        label: '添加子 MCP',
                        compact: true,
                        leading: const Icon(Icons.add_rounded),
                        variant: PrismBtnVariant.clay,
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
            child: PrismStaggeredReveal(
              index: 1,
              child: Center(
                key: const ValueKey('empty-submcp'),
                child: PrismCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 38,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: ShapeDecoration(
                          color: c.sageBg,
                          shape: prismSuperellipse(
                            15,
                            side: BorderSide(
                              color: c.sage.withValues(alpha: 0.24),
                            ),
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.layers_outlined,
                          size: 21,
                          color: c.sage,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '尚未挂载子 MCP 服务',
                        style: serifTitleStyle(c, size: 17),
                      ),
                      const SizedBox(height: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 460),
                        child: Text(
                          '支持粘贴 Claude Desktop、Cursor、VS Code 配置、npx / uvx 单行命令或远程 OAuth 2.1 MCP 地址，内置可视化在线调试台。',
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
              child: PrismListGroup(
                dividerIndent: 68,
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

  Widget _buildSubServerWellGlyph({
    required String iconSrc,
    required String transport,
    required bool enabled,
    required Color trColor,
    required PrismPalette palette,
  }) {
    final fallback = Icon(
      transport == 'stdio'
          ? Icons.terminal_rounded
          : (transport == 'ws' ? Icons.cable_rounded : Icons.public_rounded),
      size: 17.5,
      color: enabled ? trColor : palette.muted,
    );
    if (iconSrc.isEmpty) return fallback;
    final lower = iconSrc.toLowerCase();
    if (lower.startsWith('data:image/') &&
        !lower.startsWith('data:image/svg') &&
        iconSrc.contains(';base64,')) {
      try {
        final b64 = iconSrc.substring(iconSrc.indexOf(';base64,') + 8);
        final bytes = base64Decode(b64);
        return ClipRSuperellipse(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            bytes,
            width: 26,
            height: 26,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => fallback,
          ),
        );
      } catch (_) {
        return fallback;
      }
    }
    if (lower.startsWith('https://') || lower.startsWith('http://')) {
      var effectiveUrl = iconSrc;
      String? originFaviconFallback;
      final parsed = Uri.tryParse(iconSrc);
      if (parsed != null && parsed.hasAuthority) {
        final origin = '${parsed.scheme}://${parsed.authority}';
        if (lower.endsWith('.svg')) {
          effectiveUrl = '$origin/favicon.png';
          originFaviconFallback = '$origin/favicon.ico';
        } else {
          originFaviconFallback = '$origin/favicon.ico';
        }
      } else if (lower.endsWith('.svg')) {
        return fallback;
      }
      return ClipRSuperellipse(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          effectiveUrl,
          width: 26,
          height: 26,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) {
            if (originFaviconFallback != null &&
                originFaviconFallback != effectiveUrl) {
              return Image.network(
                originFaviconFallback,
                width: 26,
                height: 26,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => fallback,
              );
            }
            return fallback;
          },
        ),
      );
    }
    return fallback;
  }

  Widget _buildServerRow(
    BuildContext context,
    PrismPalette c,
    Map<String, dynamic> s,
  ) {
    final name = (s['name'] ?? '').toString();
    final enabled = s['enabled'] != false;
    final tr = (s['transport'] ?? 'stdio').toString();
    final authType = (s['auth_type'] ?? 'none').toString();
    final exposeMode = (s['expose_mode'] ?? 'gateway').toString();
    final oauthStatus = s['oauth_status'] is Map
        ? Map<String, dynamic>.from(s['oauth_status'] as Map)
        : const <String, dynamic>{};
    final oauthAuthed = oauthStatus['authorized'] == true;
    final oauthExpired = oauthStatus['expired'] == true;
    final isTesting = _testingNames.contains(name);
    final isOAuthStarting = _oauthStartingNames.contains(name);
    final status =
        isTesting ? 'testing' : (s['status'] ?? 'idle').toString();
    final tools = ((s['tools'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final resources = ((s['resources'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final prompts = ((s['prompts'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final disabledSet = ((s['disabled_tools'] as List?) ?? const [])
        .map((e) => e.toString())
        .toSet();
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

    final trColor = switch (tr) {
      'stdio' => c.clay,
      'sse' || 'ws' => c.purple,
      _ => c.sage,
    };

    String? authBadge;
    Color authFg = c.muted;
    Color authBg = c.paper3;
    if (tr != 'stdio' && authType != 'none') {
      switch (authType) {
        case 'oauth2_pkce':
          if (oauthAuthed && !oauthExpired) {
            authBadge = 'OAuth 已授权';
            authFg = c.sage;
            authBg = c.sageBg;
          } else if (oauthExpired) {
            authBadge = 'OAuth 待续期';
            authFg = c.clay;
            authBg = c.clay.withValues(alpha: 0.12);
          } else {
            authBadge = 'OAuth 未连接';
            authFg = c.clay;
            authBg = c.clay.withValues(alpha: 0.12);
          }
        case 'oauth2_client_credentials':
          authBadge = 'OAuth M2M';
          authFg = c.sage;
          authBg = c.sageBg;
        case 'bearer':
          authBadge = 'Bearer';
          authFg = c.sage;
          authBg = c.sageBg;
        case 'api_key':
          authBadge = 'API Key';
          authFg = c.sage;
          authBg = c.sageBg;
        case 'basic':
          authBadge = 'Basic';
          authFg = c.sage;
          authBg = c.sageBg;
      }
    }

    return RepaintBoundary(
      key: ValueKey('sub-$name'),
      child: Opacity(
        opacity: enabled ? 1.0 : 0.62,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: (tools.isEmpty && resources.isEmpty && prompts.isEmpty)
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
                  horizontal: 16,
                  vertical: 13,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Container(
                          width: 40,
                          height: 40,
                          decoration: ShapeDecoration(
                            color: c.recessed,
                            shape: prismSuperellipse(
                              13.5,
                              side: BorderSide(
                                color: c.hairline.withValues(alpha: 0.65),
                              ),
                            ),
                          ),
                          alignment: Alignment.center,
                          child: _buildSubServerWellGlyph(
                            iconSrc: (s['icon_src'] ?? '').toString().trim(),
                            transport: tr,
                            enabled: enabled,
                            trColor: trColor,
                            palette: c,
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
                            child: PrismStatusDot(
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
                            runSpacing: 4,
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
                              PrismPill(
                                text: tr.toUpperCase(),
                                fg: trColor,
                                bg: trColor.withValues(alpha: 0.10),
                                border: trColor.withValues(alpha: 0.22),
                              ),
                              if (exposeMode == 'direct')
                                PrismPill(
                                  text: '直通挂载',
                                  mono: false,
                                  fg: c.clay,
                                  bg: c.clay.withValues(alpha: 0.12),
                                ),
                              if (authBadge != null)
                                PrismPill(
                                  text: authBadge,
                                  mono: false,
                                  fg: authFg,
                                  bg: authBg,
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
                    const SizedBox(width: 8),
                    if (tr != 'stdio' &&
                        authType == 'oauth2_pkce' &&
                        !oauthAuthed)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: PrismButton(
                          label: isOAuthStarting ? '拉起授权...' : 'OAuth 授权',
                          compact: true,
                          loading: isOAuthStarting,
                          variant: PrismBtnVariant.clay,
                          leading: const Icon(Icons.vpn_key_rounded),
                          onPressed: isOAuthStarting
                              ? null
                              : () => _startOAuthConnect(s),
                        ),
                      ),
                    if (tools.isNotEmpty ||
                        resources.isNotEmpty ||
                        prompts.isNotEmpty) ...[
                      PrismButton(
                        label: '调试',
                        compact: true,
                        variant: PrismBtnVariant.ghost,
                        tooltip: '打开可视化工具与资源调试台',
                        leading: const Icon(Icons.play_circle_outline_rounded),
                        onPressed: () => _openPlayground(s),
                      ),
                      const SizedBox(width: 4),
                      PrismButton(
                        label: MediaQuery.sizeOf(context).width < 430
                            ? '${tools.length}'
                            : '${tools.length} 工具',
                        compact: true,
                        variant: PrismBtnVariant.ghost,
                        leading: AnimatedRotation(
                          turns: open ? 0.5 : 0.0,
                          duration: PrismMotion.duration(
                            context,
                            PrismMotion.fast,
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
                      ),
                    ] else
                      PrismButton(
                        label: isTesting ? '探测中' : '探测',
                        compact: true,
                        loading: isTesting,
                        variant: PrismBtnVariant.ghost,
                        leading: const Icon(Icons.radar_rounded),
                        onPressed: isTesting ? null : () => _testServer(name),
                      ),
                    const SizedBox(width: 6),
                    PrismSwitch(
                      value: enabled,
                      onChanged: (v) async {
                        await widget.backend.toggleSubMcp(name, v);
                        await widget.onRefresh();
                      },
                    ),
                    const SizedBox(width: 4),
                    PrismActionMenuButton(
                      tooltip: '更多操作',
                      actions: [
                        PrismMenuAction(
                          label: isTesting ? '正在探测工具...' : '探测并刷新工具 / 资源列表',
                          icon: Icons.radar_rounded,
                          onSelected: () {
                            if (!isTesting) _testServer(name);
                          },
                        ),
                        PrismMenuAction(
                          label: '在线调试台 (Playground)',
                          icon: Icons.play_circle_outline_rounded,
                          onSelected: () => _openPlayground(s),
                        ),
                        if (tr != 'stdio' && authType == 'oauth2_pkce') ...[
                          PrismMenuAction(
                            label: oauthAuthed
                                ? '重新执行 OAuth 2.1 授权'
                                : '发起 OAuth 2.1 浏览器授权',
                            icon: Icons.vpn_key_rounded,
                            onSelected: () => _startOAuthConnect(s),
                          ),
                          if (oauthAuthed)
                            PrismMenuAction(
                              label: '撤销并清除本地 OAuth 令牌',
                              icon: Icons.key_off_outlined,
                              onSelected: () async {
                                await widget.backend.revokeSubMcpOAuth(name);
                                await widget.onRefresh();
                                widget.onToast('已清除 $name 的 OAuth 授权令牌');
                              },
                            ),
                        ],
                        PrismMenuAction(
                          label: '编辑服务配置',
                          icon: Icons.edit_outlined,
                          onSelected: () => _openEditModal(existing: s),
                        ),
                        PrismMenuAction(
                          label: tr == 'stdio' ? '复制启动命令' : '复制服务地址',
                          subtitle: endpoint,
                          icon: Icons.copy_rounded,
                          onSelected: () {
                            Clipboard.setData(ClipboardData(text: endpoint));
                            widget.onToast('已复制：$endpoint');
                          },
                        ),
                        PrismMenuAction(
                          label: '删除此子 MCP',
                          icon: Icons.delete_outline_rounded,
                          dividerBefore: true,
                          destructive: true,
                          onSelected: () async {
                            final ok = await showPrismConfirmDialog(
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
            PrismCollapsible(
              expanded: lastErr.isNotEmpty,
              builder: (_) => Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(68, 0, 16, 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: ShapeDecoration(
                  color: c.dangerBg,
                  shape: prismSuperellipse(
                    14,
                    side: BorderSide(color: c.danger.withValues(alpha: 0.28)),
                  ),
                ),
                child: Text(
                  lastErr,
                  style: monoStyle(c, size: 11.2, color: c.danger),
                ),
              ),
            ),
            PrismCollapsible(
              expanded: open &&
                  (tools.isNotEmpty ||
                      resources.isNotEmpty ||
                      prompts.isNotEmpty),
              builder: (_) => Container(
                decoration: BoxDecoration(
                  color: c.isDark
                      ? c.recessed.withValues(alpha: 0.65)
                      : c.recessed.withValues(alpha: 0.55),
                  border: Border(top: BorderSide(color: c.hairline)),
                ),
                padding: const EdgeInsets.fromLTRB(68, 10, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (resources.isNotEmpty || prompts.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            if (resources.isNotEmpty)
                              PrismPill(
                                text: '${resources.length} 个资源 (Resources)',
                                mono: false,
                                fg: c.clay,
                                bg: c.clay.withValues(alpha: 0.10),
                              ),
                            if (prompts.isNotEmpty)
                              PrismPill(
                                text: '${prompts.length} 个提示模板 (Prompts)',
                                mono: false,
                                fg: c.sage,
                                bg: c.sageBg,
                              ),
                          ],
                        ),
                      ),
                    for (var ti = 0; ti < tools.length; ti++) ...[
                      if (ti > 0)
                        Divider(
                          height: 1,
                          color: c.hairline.withValues(alpha: 0.65),
                        ),
                      _SubMcpToolRow(
                        tool: tools[ti],
                        enabled: !disabledSet.contains(
                          (tools[ti]['name'] ?? '').toString(),
                        ),
                        expanded: _expandedTools.contains(
                          '$name::${tools[ti]['name']}',
                        ),
                        onToggleExpand: () {
                          final tKey = '$name::${tools[ti]['name']}';
                          setState(() {
                            if (_expandedTools.contains(tKey)) {
                              _expandedTools.remove(tKey);
                            } else {
                              _expandedTools.add(tKey);
                            }
                          });
                        },
                        onToggleEnabled: (v) => _toggleToolDisabled(
                          s,
                          (tools[ti]['name'] ?? '').toString(),
                          v,
                        ),
                        onOpenPlayground: () => _openPlayground(
                          s,
                          initialToolName: (tools[ti]['name'] ?? '').toString(),
                        ),
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
  final bool enabled;
  final bool expanded;
  final VoidCallback onToggleExpand;
  final ValueChanged<bool> onToggleEnabled;
  final VoidCallback onOpenPlayground;
  final VoidCallback onCopyName;

  const _SubMcpToolRow({
    required this.tool,
    required this.enabled,
    required this.expanded,
    required this.onToggleExpand,
    required this.onToggleEnabled,
    required this.onOpenPlayground,
    required this.onCopyName,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
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

    return Opacity(
      opacity: enabled ? 1.0 : 0.55,
      child: InkWell(
        onTap: onToggleExpand,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
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
                    PrismPill(
                      text: '${props.length} 参数',
                      mono: false,
                      bg: c.paper2,
                    ),
                  ],
                  const SizedBox(width: 4),
                  Tooltip(
                    message: '在线试运行此工具',
                    child: InkWell(
                      onTap: onOpenPlayground,
                      borderRadius: BorderRadius.circular(999),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          Icons.play_arrow_rounded,
                          size: 15,
                          color: c.clay,
                        ),
                      ),
                    ),
                  ),
                  Tooltip(
                    message: '复制工具名',
                    child: InkWell(
                      onTap: onCopyName,
                      borderRadius: BorderRadius.circular(999),
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
                  const SizedBox(width: 4),
                  Transform.scale(
                    scale: 0.72,
                    child: PrismSwitch(
                      value: enabled,
                      onChanged: onToggleEnabled,
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
              PrismCollapsible(
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
                          padding: const EdgeInsets.all(11),
                          decoration: ShapeDecoration(
                            color: c.paper2,
                            shape: prismSuperellipse(
                              14,
                              side: BorderSide(
                                color: c.hairline.withValues(alpha: 0.65),
                              ),
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
                                          PrismPill(text: pType),
                                          if (isReq) ...[
                                            const SizedBox(width: 5),
                                            PrismPill(
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
  String _proto = 'auto';
  String _exposeMode = 'gateway';
  String _authType = 'none';
  String _apiKeyIn = 'header';
  bool _insecureTls = false;
  bool _showOAuthAdvanced = false;
  bool _showNetworkAdvanced = false;
  bool _probing = false;
  bool _oauthConnecting = false;
  bool _saving = false;

  final _nameCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _cmdCtrl = TextEditingController();
  final _cwdCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _timeoutCtrl = TextEditingController(text: '30');
  final _jsonCtrl = TextEditingController();

  // Structured list/map states (replacing raw multi-line textareas)
  List<String> _argsList = <String>[];
  Map<String, String> _envMap = <String, String>{};
  Map<String, String> _headersMap = <String, String>{};

  // Auth & proxy fields
  final _bearerTokenCtrl = TextEditingController();
  final _apiKeyCtrl = TextEditingController();
  final _apiKeyNameCtrl = TextEditingController(text: 'X-API-Key');
  final _basicUserCtrl = TextEditingController();
  final _basicPassCtrl = TextEditingController();
  final _oauthClientIdCtrl = TextEditingController();
  final _oauthClientSecretCtrl = TextEditingController();
  final _oauthScopesCtrl = TextEditingController();
  final _oauthCimdCtrl = TextEditingController();
  final _proxyUrlCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _proto = (e['transport'] ?? 'stdio').toString();
      _exposeMode = (e['expose_mode'] ?? 'gateway').toString();
      _authType = (e['auth_type'] ?? 'none').toString();
      _apiKeyIn = (e['api_key_in'] ?? 'header').toString();
      _insecureTls = e['insecure_tls'] == true;
      _nameCtrl.text = (e['name'] ?? '').toString();
      _descCtrl.text = (e['description'] ?? '').toString();
      _cmdCtrl.text = (e['command'] ?? '').toString();
      _argsList = ((e['args'] as List?) ?? const [])
          .map((x) => x.toString().trim())
          .where((s) => s.isNotEmpty)
          .toList();
      _cwdCtrl.text = (e['cwd'] ?? '').toString();
      final env = (e['env'] as Map?) ?? const {};
      _envMap = {
        for (final entry in env.entries)
          entry.key.toString(): entry.value.toString(),
      };
      _urlCtrl.text = (e['url'] ?? '').toString();
      final hdrs = (e['headers'] as Map?) ?? const {};
      _headersMap = {
        for (final entry in hdrs.entries)
          entry.key.toString(): entry.value.toString(),
      };
      _bearerTokenCtrl.text = (e['bearer_token'] ?? '').toString();
      _apiKeyCtrl.text = (e['api_key'] ?? '').toString();
      final kn = (e['api_key_name'] ?? '').toString();
      if (kn.isNotEmpty) _apiKeyNameCtrl.text = kn;
      _basicUserCtrl.text = (e['basic_username'] ?? '').toString();
      _basicPassCtrl.text = (e['basic_password'] ?? '').toString();
      _oauthClientIdCtrl.text = (e['oauth_client_id'] ?? '').toString();
      _oauthClientSecretCtrl.text = (e['oauth_client_secret'] ?? '').toString();
      _oauthScopesCtrl.text = (e['oauth_scopes'] ?? '').toString();
      _oauthCimdCtrl.text = (e['oauth_cimd_url'] ?? '').toString();
      _proxyUrlCtrl.text = (e['proxy_url'] ?? '').toString();
      if (_proxyUrlCtrl.text.isNotEmpty || _insecureTls) {
        _showNetworkAdvanced = true;
      }
      if (_oauthClientIdCtrl.text.isNotEmpty ||
          _oauthCimdCtrl.text.isNotEmpty) {
        _showOAuthAdvanced = true;
      }
      _timeoutCtrl.text = '${e['timeout'] ?? 30}';
    } else {
      _proto = 'stdio';
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    _cmdCtrl.dispose();
    _cwdCtrl.dispose();
    _urlCtrl.dispose();
    _timeoutCtrl.dispose();
    _jsonCtrl.dispose();
    _bearerTokenCtrl.dispose();
    _apiKeyCtrl.dispose();
    _apiKeyNameCtrl.dispose();
    _basicUserCtrl.dispose();
    _basicPassCtrl.dispose();
    _oauthClientIdCtrl.dispose();
    _oauthClientSecretCtrl.dispose();
    _oauthScopesCtrl.dispose();
    _oauthCimdCtrl.dispose();
    _proxyUrlCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> _buildDraft() {
    return {
      'name': _nameCtrl.text.trim(),
      'description': _descCtrl.text.trim(),
      'transport': _proto,
      'expose_mode': _exposeMode,
      'enabled': widget.existing?['enabled'] ?? true,
      if (widget.existing?['disabled_tools'] is List)
        'disabled_tools': widget.existing!['disabled_tools'],
      'command': _cmdCtrl.text.trim(),
      'args': _argsList,
      'cwd': _cwdCtrl.text.trim(),
      'env': _envMap,
      'url': _urlCtrl.text.trim(),
      'headers': _headersMap,
      'auth_type': _proto == 'stdio' ? 'none' : _authType,
      'bearer_token': _bearerTokenCtrl.text.trim(),
      'api_key': _apiKeyCtrl.text.trim(),
      'api_key_in': _apiKeyIn,
      'api_key_name': _apiKeyNameCtrl.text.trim().isEmpty
          ? 'X-API-Key'
          : _apiKeyNameCtrl.text.trim(),
      'basic_username': _basicUserCtrl.text.trim(),
      'basic_password': _basicPassCtrl.text,
      'oauth_client_id': _oauthClientIdCtrl.text.trim(),
      'oauth_client_secret': _oauthClientSecretCtrl.text.trim(),
      'oauth_scopes': _oauthScopesCtrl.text.trim(),
      'oauth_cimd_url': _oauthCimdCtrl.text.trim(),
      'proxy_url': _proxyUrlCtrl.text.trim(),
      'insecure_tls': _insecureTls,
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
        final err = (res['error'] ?? '').toString();
        if (err.contains('401') && _authType == 'none' && mounted) {
          setState(() => _authType = 'oauth2_pkce');
          widget.onToast('检测到远端服务要求鉴权，已为您自动切换至「OAuth 2.1 授权」模式');
        } else {
          widget.onToast('探测失败：$err');
        }
      }
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _startOAuthFromModal() async {
    final draft = _buildDraft();
    if ((draft['url'] ?? '').toString().isEmpty) {
      widget.onToast('请先填写远程 MCP 服务地址 URL');
      return;
    }
    if ((draft['name'] ?? '').toString().isEmpty) {
      try {
        final u = Uri.parse(draft['url'].toString());
        _nameCtrl.text = u.host.replaceAll('.', '-');
        draft['name'] = _nameCtrl.text;
      } catch (_) {
        _nameCtrl.text = 'remote-oauth-mcp';
        draft['name'] = 'remote-oauth-mcp';
      }
    }
    setState(() => _oauthConnecting = true);
    try {
      // Save entry first so callback persists cleanly to its canonical name
      await widget.backend.upsertSubMcp(
        draft,
        oldName: widget.existing?['name']?.toString(),
      );
      final res = await widget.backend.startSubMcpOAuth(
        draft['name'].toString(),
        draft: draft,
      );
      if (res['ok'] == true) {
        widget.onToast('已在浏览器拉起 OAuth 2.1 授权，完成授权后将自动保存令牌');
        if (mounted) Navigator.of(context).pop(true);
      } else {
        widget.onToast('发起 OAuth 失败：${res['error'] ?? ''}');
      }
    } finally {
      if (mounted) setState(() => _oauthConnecting = false);
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
        widget.onToast('已保存子 MCP 服务配置');
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
    final c = PrismPalette.of(context);
    final compact = MediaQuery.sizeOf(context).width < 560;

    return Dialog(
      backgroundColor: c.paper2,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 28,
        vertical: 18,
      ),
      shape: prismSuperellipse(
        28,
        side: BorderSide(color: c.hairline.withValues(alpha: 0.72)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 740),
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
                  const PrismSparkIcon(size: 17),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      widget.existing != null ? '编辑子 MCP 服务' : '添加子 MCP 服务',
                      style: serifTitleStyle(c, size: 17.5),
                    ),
                  ),
                  if (widget.existing == null) ...[
                    PrismSegmented<bool>(
                      value: _jsonMode,
                      items: const [(false, '表单配置'), (true, '智能导入')],
                      onChanged: (v) => setState(() => _jsonMode = v),
                    ),
                    const SizedBox(width: 8),
                  ],
                  PrismButton(
                    label: '',
                    compact: true,
                    variant: PrismBtnVariant.ghost,
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
                            '支持粘贴 Claude Desktop / Cursor (mcpServers)、VS Code (servers) JSON，或直接粘贴 npx / uvx 单行命令、远程 https://.../mcp 地址：',
                            style: sansStyle(
                              c,
                              size: 12.2,
                              color: c.muted,
                              height: 1.45,
                            ),
                          ),
                          const SizedBox(height: 10),
                          TextField(
                            controller: _jsonCtrl,
                            maxLines: 12,
                            style: monoStyle(c, size: 12.2, color: c.ink),
                            decoration: const InputDecoration(
                              hintText:
                                  '示例 1: npx -y @modelcontextprotocol/server-memory\n示例 2: https://mcp.notion.com/mcp\n示例 3: { "mcpServers": { ... } }',
                            ),
                          ),
                        ],
                      )
                    : Column(
                        key: const ValueKey('form-mode'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          PrismFormRow(
                            label: '传输协议',
                            labelWidth: 104,
                            stackBreakpoint: 460,
                            horizontalAlignment: CrossAxisAlignment.center,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: PrismSegmented<String>(
                                value: _proto,
                                items: const [
                                  ('stdio', 'stdio 进程'),
                                  ('auto', '智能远程'),
                                  ('http', 'HTTP'),
                                  ('sse', 'SSE'),
                                  ('ws', 'WebSocket'),
                                ],
                                onChanged: (v) => setState(() => _proto = v),
                              ),
                            ),
                          ),
                          PrismFormRow(
                            label: '暴露模式',
                            labelWidth: 104,
                            stackBreakpoint: 460,
                            horizontalAlignment: CrossAxisAlignment.center,
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: PrismSegmented<String>(
                                value: _exposeMode,
                                items: const [
                                  ('gateway', '网关按需转发（推荐）'),
                                  ('direct', '直通挂载主工具表'),
                                ],
                                onChanged: (v) =>
                                    setState(() => _exposeMode = v),
                              ),
                            ),
                          ),
                          PrismCollapsible(
                            expanded: _proto == 'stdio',
                            builder: (_) => Column(
                              children: [
                                PrismFormRow(
                                  label: '启动命令',
                                  labelWidth: 104,
                                  stackBreakpoint: 460,
                                  child: TextField(
                                    controller: _cmdCtrl,
                                    style: monoStyle(
                                      c,
                                      size: 12.6,
                                      color: c.ink,
                                    ),
                                    decoration: const InputDecoration(
                                      hintText: '如 npx、uvx、python、node',
                                    ),
                                  ),
                                ),
                                PrismFormRow(
                                  label: '命令参数',
                                  labelWidth: 104,
                                  stackBreakpoint: 460,
                                  child: PrismStringListEditor(
                                    values: _argsList,
                                    onChanged: (next) =>
                                        setState(() => _argsList = next),
                                  ),
                                ),
                                PrismFormRow(
                                  label: '工作目录',
                                  labelWidth: 104,
                                  stackBreakpoint: 460,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: _cwdCtrl,
                                          style: monoStyle(
                                            c,
                                            size: 12.2,
                                            color: c.ink,
                                          ),
                                          decoration: const InputDecoration(
                                            hintText: '留空使用默认工作目录（选填）',
                                          ),
                                        ),
                                      ),
                                      if (!widget.backend.isAndroidPlatform) ...[
                                        const SizedBox(width: 6),
                                        PrismButton(
                                          label: '',
                                          compact: true,
                                          tooltip: '选择工作目录',
                                          leading: const Icon(
                                            Icons.folder_open_rounded,
                                            size: 16,
                                          ),
                                          onPressed: () async {
                                            final p = await widget.backend
                                                .pickLocalSharePath(
                                              directory: true,
                                            );
                                            if (p != null &&
                                                p.isNotEmpty &&
                                                mounted) {
                                              setState(
                                                () => _cwdCtrl.text = p,
                                              );
                                            }
                                          },
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                PrismFormRow(
                                  label: '环境变量',
                                  labelWidth: 104,
                                  stackBreakpoint: 460,
                                  child: PrismKeyValueListEditor(
                                    entries: _envMap,
                                    keyHint: 'ENV_NAME',
                                    valueHint: '值（支持 \${ENV:VAR}）',
                                    addLabel: '添加环境变量',
                                    onChanged: (next) =>
                                        setState(() => _envMap = next),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PrismCollapsible(
                            expanded: _proto != 'stdio',
                            builder: (_) => Column(
                              children: [
                                PrismFormRow(
                                  label: '服务地址 URL',
                                  labelWidth: 104,
                                  stackBreakpoint: 460,
                                  child: TextField(
                                    controller: _urlCtrl,
                                    style: monoStyle(
                                      c,
                                      size: 12.6,
                                      color: c.ink,
                                    ),
                                    decoration: InputDecoration(
                                      hintText: _proto == 'ws'
                                          ? 'wss://example.com/mcp'
                                          : 'https://mcp.notion.com/mcp',
                                    ),
                                  ),
                                ),
                                PrismFormRow(
                                  label: '鉴权方式',
                                  labelWidth: 104,
                                  stackBreakpoint: 460,
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: PrismDropMenu<String>(
                                      value: const {
                                        'none',
                                        'oauth2_pkce',
                                        'oauth2_client_credentials',
                                        'bearer',
                                        'api_key',
                                        'basic',
                                      }.contains(_authType)
                                          ? _authType
                                          : 'none',
                                      minMenuWidth: 260,
                                      leadingIcon: Icons.shield_outlined,
                                      items: const [
                                        PrismDropMenuItem(
                                          value: 'none',
                                          label: '免鉴权 (None)',
                                        ),
                                        PrismDropMenuItem(
                                          value: 'oauth2_pkce',
                                          label: 'OAuth 2.1 浏览器授权 (PKCE / DCR)',
                                        ),
                                        PrismDropMenuItem(
                                          value: 'oauth2_client_credentials',
                                          label: 'OAuth 2.1 机器凭证 (M2M)',
                                        ),
                                        PrismDropMenuItem(
                                          value: 'bearer',
                                          label: 'Bearer Token 静态令牌',
                                        ),
                                        PrismDropMenuItem(
                                          value: 'api_key',
                                          label: 'API Key (Header / Query)',
                                        ),
                                        PrismDropMenuItem(
                                          value: 'basic',
                                          label: 'HTTP Basic 用户名密码',
                                        ),
                                      ],
                                      onChanged: (v) =>
                                          setState(() => _authType = v),
                                    ),
                                  ),
                                ),
                                PrismCollapsible(
                                  expanded: _authType == 'oauth2_pkce',
                                  builder: (_) => Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(12),
                                    decoration: ShapeDecoration(
                                      color: c.paper,
                                      shape: prismSuperellipse(
                                        12,
                                        side: BorderSide(color: c.hairline),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              Icons.verified_user_outlined,
                                              size: 16,
                                              color: c.sage,
                                            ),
                                            const SizedBox(width: 7),
                                            Expanded(
                                              child: Text(
                                                '支持 RFC 9728 受保护资源发现 + RFC 8414 / OIDC + RFC 7591 动态注册 + S256 PKCE 自动续期',
                                                style: sansStyle(
                                                  c,
                                                  size: 11.6,
                                                  color: c.muted,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          children: [
                                            PrismButton(
                                              label: _oauthConnecting
                                                  ? '正在拉起浏览器...'
                                                  : '保存并在浏览器中完成 OAuth 授权',
                                              compact: true,
                                              loading: _oauthConnecting,
                                              variant: PrismBtnVariant.clay,
                                              leading: const Icon(
                                                Icons.open_in_browser_rounded,
                                              ),
                                              onPressed: _oauthConnecting
                                                  ? null
                                                  : _startOAuthFromModal,
                                            ),
                                            PrismButton(
                                              label: _showOAuthAdvanced
                                                  ? '收起预注册凭证'
                                                  : '预注册 Client ID / Scope（选填）',
                                              compact: true,
                                              variant: PrismBtnVariant.ghost,
                                              onPressed: () => setState(
                                                () => _showOAuthAdvanced =
                                                    !_showOAuthAdvanced,
                                              ),
                                            ),
                                          ],
                                        ),
                                        PrismCollapsible(
                                          expanded: _showOAuthAdvanced,
                                          builder: (_) => Padding(
                                            padding: const EdgeInsets.only(
                                              top: 10,
                                            ),
                                            child: Column(
                                              children: [
                                                TextField(
                                                  controller:
                                                      _oauthClientIdCtrl,
                                                  style: monoStyle(
                                                    c,
                                                    size: 12,
                                                    color: c.ink,
                                                  ),
                                                  decoration:
                                                      const InputDecoration(
                                                    isDense: true,
                                                    labelText:
                                                        '预注册 Client ID（留空自动动态注册）',
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                PrismPasswordField(
                                                  controller:
                                                      _oauthClientSecretCtrl,
                                                  hintText:
                                                      'Client Secret（公共客户端留空）',
                                                ),
                                                const SizedBox(height: 8),
                                                TextField(
                                                  controller: _oauthScopesCtrl,
                                                  style: monoStyle(
                                                    c,
                                                    size: 12,
                                                    color: c.ink,
                                                  ),
                                                  decoration:
                                                      const InputDecoration(
                                                    isDense: true,
                                                    labelText:
                                                        'Scopes（空格分隔，留空按挑战自动协商）',
                                                  ),
                                                ),
                                                const SizedBox(height: 8),
                                                TextField(
                                                  controller: _oauthCimdCtrl,
                                                  style: monoStyle(
                                                    c,
                                                    size: 12,
                                                    color: c.ink,
                                                  ),
                                                  decoration:
                                                      const InputDecoration(
                                                    isDense: true,
                                                    labelText:
                                                        'CIMD 客户端元数据 URL（选填）',
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
                                PrismCollapsible(
                                  expanded:
                                      _authType == 'oauth2_client_credentials',
                                  builder: (_) => Column(
                                    children: [
                                      PrismFormRow(
                                        label: 'Client ID',
                                        labelWidth: 104,
                                        stackBreakpoint: 460,
                                        child: TextField(
                                          controller: _oauthClientIdCtrl,
                                          style: monoStyle(
                                            c,
                                            size: 12.2,
                                            color: c.ink,
                                          ),
                                        ),
                                      ),
                                      PrismFormRow(
                                        label: 'Client Secret',
                                        labelWidth: 104,
                                        stackBreakpoint: 460,
                                        child: PrismPasswordField(
                                          controller: _oauthClientSecretCtrl,
                                        ),
                                      ),
                                      PrismFormRow(
                                        label: 'Scopes',
                                        labelWidth: 104,
                                        stackBreakpoint: 460,
                                        child: TextField(
                                          controller: _oauthScopesCtrl,
                                          style: monoStyle(
                                            c,
                                            size: 12.2,
                                            color: c.ink,
                                          ),
                                          decoration: const InputDecoration(
                                            hintText: '可选权限范围（空格分隔）',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PrismCollapsible(
                                  expanded: _authType == 'bearer',
                                  builder: (_) => PrismFormRow(
                                    label: 'Bearer Token',
                                    labelWidth: 104,
                                    stackBreakpoint: 460,
                                    child: PrismPasswordField(
                                      controller: _bearerTokenCtrl,
                                      hintText: '输入令牌或 \${ENV:MCP_TOKEN}',
                                    ),
                                  ),
                                ),
                                PrismCollapsible(
                                  expanded: _authType == 'api_key',
                                  builder: (_) => Column(
                                    children: [
                                      PrismFormRow(
                                        label: '传递位置与键名',
                                        labelWidth: 104,
                                        stackBreakpoint: 460,
                                        child: Row(
                                          children: [
                                            PrismSegmented<String>(
                                              value: _apiKeyIn,
                                              items: const [
                                                ('header', 'Header'),
                                                ('query', 'URL Query'),
                                              ],
                                              onChanged: (v) => setState(
                                                () => _apiKeyIn = v,
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: TextField(
                                                controller: _apiKeyNameCtrl,
                                                style: monoStyle(
                                                  c,
                                                  size: 12,
                                                  color: c.ink,
                                                ),
                                                decoration:
                                                    const InputDecoration(
                                                  isDense: true,
                                                  hintText: 'X-API-Key',
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      PrismFormRow(
                                        label: 'API Key 值',
                                        labelWidth: 104,
                                        stackBreakpoint: 460,
                                        child: PrismPasswordField(
                                          controller: _apiKeyCtrl,
                                          hintText: '输入密钥或 \${ENV:API_KEY}',
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PrismCollapsible(
                                  expanded: _authType == 'basic',
                                  builder: (_) => Column(
                                    children: [
                                      PrismFormRow(
                                        label: '用户名',
                                        labelWidth: 104,
                                        stackBreakpoint: 460,
                                        child: TextField(
                                          controller: _basicUserCtrl,
                                          style: monoStyle(
                                            c,
                                            size: 12.2,
                                            color: c.ink,
                                          ),
                                        ),
                                      ),
                                      PrismFormRow(
                                        label: '密码',
                                        labelWidth: 104,
                                        stackBreakpoint: 460,
                                        child: PrismPasswordField(
                                          controller: _basicPassCtrl,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                PrismFormRow(
                                  label: '自定义请求头',
                                  labelWidth: 104,
                                  stackBreakpoint: 460,
                                  child: PrismKeyValueListEditor(
                                    entries: _headersMap,
                                    keyHint: 'Header-Name',
                                    valueHint: 'Header 值（支持 \${ENV:VAR}）',
                                    addLabel: '添加请求头',
                                    onChanged: (next) =>
                                        setState(() => _headersMap = next),
                                  ),
                                ),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: PrismButton(
                                    label: _showNetworkAdvanced
                                        ? '收起代理与 TLS 设置'
                                        : '代理服务器与自签名证书（选填）',
                                    compact: true,
                                    variant: PrismBtnVariant.ghost,
                                    leading: const Icon(Icons.lan_outlined),
                                    onPressed: () => setState(
                                      () => _showNetworkAdvanced =
                                          !_showNetworkAdvanced,
                                    ),
                                  ),
                                ),
                                PrismCollapsible(
                                  expanded: _showNetworkAdvanced,
                                  builder: (_) => Padding(
                                    padding: const EdgeInsets.only(
                                      top: 8,
                                      bottom: 8,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        PrismFormRow(
                                          label: '代理 URL',
                                          labelWidth: 104,
                                          stackBreakpoint: 460,
                                          child: TextField(
                                            controller: _proxyUrlCtrl,
                                            style: monoStyle(
                                              c,
                                              size: 12.2,
                                              color: c.ink,
                                            ),
                                            decoration: const InputDecoration(
                                              hintText:
                                                  '如 http://127.0.0.1:7890（留空直连）',
                                            ),
                                          ),
                                        ),
                                        PrismCheckToggle(
                                          value: _insecureTls,
                                          label: '允许自签名 / 内网私有 HTTPS 证书',
                                          onChanged: (v) => setState(
                                            () => _insecureTls = v,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          PrismFormRow(
                            label: '子 MCP 名称',
                            labelWidth: 104,
                            stackBreakpoint: 460,
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
                                      hintText: '可留空点右侧自动探测填充',
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                PrismButton(
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
                          PrismFormRow(
                            label: '功能简介',
                            labelWidth: 104,
                            stackBreakpoint: 460,
                            child: TextField(
                              controller: _descCtrl,
                              style: sansStyle(c, size: 12.8, color: c.ink),
                              decoration: const InputDecoration(
                                hintText: '自动识别或手动填写（选填）',
                              ),
                            ),
                          ),
                          PrismFormRow(
                            label: '超时（秒）',
                            labelWidth: 104,
                            stackBreakpoint: 460,
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
                  PrismButton(
                    label: '取消',
                    compact: true,
                    onPressed: () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: 8),
                  PrismButton(
                    label: _saving ? '保存中...' : '保存配置',
                    compact: true,
                    loading: _saving,
                    variant: PrismBtnVariant.clay,
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

/// Interactive Visual Playground Drawer/Modal for invoking Sub-MCP Tools, Resources, and Prompts.
class _SubMcpPlaygroundDialog extends StatefulWidget {
  final ConsoleBackend backend;
  final Map<String, dynamic> server;
  final String? initialToolName;
  final ValueChanged<String> onToast;

  const _SubMcpPlaygroundDialog({
    required this.backend,
    required this.server,
    this.initialToolName,
    required this.onToast,
  });

  @override
  State<_SubMcpPlaygroundDialog> createState() =>
      _SubMcpPlaygroundDialogState();
}

class _SubMcpPlaygroundDialogState extends State<_SubMcpPlaygroundDialog> {
  String _kind = 'tool';
  String _selectedName = '';
  bool _rawJsonMode = false;
  bool _running = false;
  String? _outputText;
  double? _elapsedMs;
  bool _outputOk = true;

  final Map<String, TextEditingController> _fieldCtrls = {};
  final Map<String, bool> _boolFields = {};
  final _rawArgsCtrl = TextEditingController(text: '{}');

  List<Map<String, dynamic>> get _tools =>
      ((widget.server['tools'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  List<Map<String, dynamic>> get _resources =>
      ((widget.server['resources'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  List<Map<String, dynamic>> get _prompts =>
      ((widget.server['prompts'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  @override
  void initState() {
    super.initState();
    if (widget.initialToolName != null && widget.initialToolName!.isNotEmpty) {
      _kind = 'tool';
      _selectedName = widget.initialToolName!;
    } else if (_tools.isNotEmpty) {
      _kind = 'tool';
      _selectedName = (_tools.first['name'] ?? '').toString();
    } else if (_resources.isNotEmpty) {
      _kind = 'resource';
      _selectedName = (_resources.first['uri'] ?? '').toString();
    } else if (_prompts.isNotEmpty) {
      _kind = 'prompt';
      _selectedName = (_prompts.first['name'] ?? '').toString();
    }
    _rebuildFieldControllers();
  }

  @override
  void dispose() {
    for (final c in _fieldCtrls.values) {
      c.dispose();
    }
    _rawArgsCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> get _currentSchemaProps {
    if (_kind != 'tool') return const {};
    final t = _tools.where((e) => e['name'] == _selectedName).firstOrNull;
    final schema = t?['inputSchema'];
    if (schema is Map && schema['properties'] is Map) {
      return Map<String, dynamic>.from(schema['properties'] as Map);
    }
    return const {};
  }

  void _rebuildFieldControllers() {
    for (final c in _fieldCtrls.values) {
      c.dispose();
    }
    _fieldCtrls.clear();
    _boolFields.clear();
    final props = _currentSchemaProps;
    for (final e in props.entries) {
      final m = e.value is Map
          ? Map<String, dynamic>.from(e.value as Map)
          : const <String, dynamic>{};
      final t = (m['type'] ?? 'string').toString();
      if (t == 'boolean') {
        _boolFields[e.key] = m['default'] == true;
      } else {
        final defVal = m['default'] != null ? '${m['default']}' : '';
        _fieldCtrls[e.key] = TextEditingController(text: defVal);
      }
    }
  }

  Map<String, dynamic> _collectArguments() {
    if (_rawJsonMode) {
      final raw = _rawArgsCtrl.text.trim();
      if (raw.isEmpty) return const {};
      final d = jsonDecode(raw);
      if (d is Map) return Map<String, dynamic>.from(d);
      return const {};
    }
    final out = <String, dynamic>{};
    final props = _currentSchemaProps;
    for (final e in props.entries) {
      final m = e.value is Map
          ? Map<String, dynamic>.from(e.value as Map)
          : const <String, dynamic>{};
      final t = (m['type'] ?? 'string').toString();
      if (t == 'boolean') {
        out[e.key] = _boolFields[e.key] == true;
        continue;
      }
      final raw = _fieldCtrls[e.key]?.text.trim() ?? '';
      if (raw.isEmpty) continue;
      if (t == 'integer') {
        out[e.key] = int.tryParse(raw) ?? raw;
      } else if (t == 'number') {
        out[e.key] = num.tryParse(raw) ?? raw;
      } else if (t == 'object' || t == 'array') {
        try {
          out[e.key] = jsonDecode(raw);
        } catch (_) {
          out[e.key] = raw;
        }
      } else {
        out[e.key] = raw;
      }
    }
    return out;
  }

  Future<void> _execute() async {
    if (_selectedName.isEmpty) return;
    setState(() => _running = true);
    try {
      final args = _collectArguments();
      final res = await widget.backend.callSubMcpPlayground(
        name: (widget.server['name'] ?? '').toString(),
        kind: _kind,
        toolName: _selectedName,
        uri: _kind == 'resource' ? _selectedName : '',
        arguments: args,
      );
      if (!mounted) return;
      setState(() {
        _outputOk = res['ok'] == true;
        _elapsedMs = (res['ms'] as num?)?.toDouble();
        _outputText = (res['output'] ?? res['error'] ?? '').toString();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _outputOk = false;
        _outputText = '参数解析或调用异常：$e';
      });
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final serverName = (widget.server['name'] ?? '').toString();
    final props = _currentSchemaProps;

    final options = switch (_kind) {
      'resource' => _resources
          .map(
            (r) => PrismDropMenuItem<String>(
              value: (r['uri'] ?? '').toString(),
              label: '${r['name'] ?? r['uri']}',
            ),
          )
          .toList(),
      'prompt' => _prompts
          .map(
            (p) => PrismDropMenuItem<String>(
              value: (p['name'] ?? '').toString(),
              label: (p['name'] ?? '').toString(),
            ),
          )
          .toList(),
      _ => _tools
          .map(
            (t) => PrismDropMenuItem<String>(
              value: (t['name'] ?? '').toString(),
              label: (t['name'] ?? '').toString(),
            ),
          )
          .toList(),
    };

    return Dialog(
      backgroundColor: c.paper,
      elevation: 0,
      shape: prismSuperellipse(
        28,
        side: BorderSide(color: c.hairline.withValues(alpha: 0.72)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const PrismSparkIcon(size: 18),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      '$serverName · 在线调试台',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: serifTitleStyle(c, size: 18),
                    ),
                  ),
                  PrismSegmented<String>(
                    value: _kind,
                    items: [
                      ('tool', '工具 (${_tools.length})'),
                      if (_resources.isNotEmpty)
                        ('resource', '资源 (${_resources.length})'),
                      if (_prompts.isNotEmpty)
                        ('prompt', '模板 (${_prompts.length})'),
                    ],
                    onChanged: (v) {
                      setState(() {
                        _kind = v;
                        _outputText = null;
                        if (v == 'tool' && _tools.isNotEmpty) {
                          _selectedName = (_tools.first['name'] ?? '').toString();
                        } else if (v == 'resource' && _resources.isNotEmpty) {
                          _selectedName =
                              (_resources.first['uri'] ?? '').toString();
                        } else if (v == 'prompt' && _prompts.isNotEmpty) {
                          _selectedName =
                              (_prompts.first['name'] ?? '').toString();
                        } else {
                          _selectedName = '';
                        }
                        _rebuildFieldControllers();
                      });
                    },
                  ),
                  const SizedBox(width: 8),
                  PrismButton(
                    label: '',
                    compact: true,
                    variant: PrismBtnVariant.ghost,
                    leading: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (options.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    '当前分类暂无可调用项，请先在列表点击「探测」拉取元数据。',
                    style: sansStyle(c, size: 12.5, color: c.muted),
                  ),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: PrismDropMenu<String>(
                                value: options.any((o) => o.value == _selectedName)
                                    ? _selectedName
                                    : options.first.value,
                                minMenuWidth: 280,
                                leadingIcon: Icons.build_circle_outlined,
                                items: options,
                                onChanged: (next) {
                                  setState(() {
                                    _selectedName = next;
                                    _outputText = null;
                                    _rebuildFieldControllers();
                                  });
                                },
                              ),
                            ),
                            if (_kind != 'resource') ...[
                              const SizedBox(width: 8),
                              PrismSegmented<bool>(
                                value: _rawJsonMode,
                                items: const [
                                  (false, '可视化表单'),
                                  (true, 'JSON 参数'),
                                ],
                                onChanged: (v) =>
                                    setState(() => _rawJsonMode = v),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_kind != 'resource')
                          Container(
                            padding: const EdgeInsets.all(13),
                            decoration: ShapeDecoration(
                              color: c.paper2,
                              shape: prismSuperellipse(
                                14,
                                side: BorderSide(color: c.hairline),
                              ),
                            ),
                            child: _rawJsonMode
                                ? TextField(
                                    controller: _rawArgsCtrl,
                                    maxLines: 5,
                                    style: monoStyle(
                                      c,
                                      size: 12,
                                      color: c.ink,
                                    ),
                                    decoration: const InputDecoration(
                                      isDense: true,
                                      hintText: '{"query": "example"}',
                                    ),
                                  )
                                : (props.isEmpty
                                    ? Text(
                                        '此操作无需输入参数，直接点击下方「立即执行」即可。',
                                        style: sansStyle(
                                          c,
                                          size: 12,
                                          color: c.muted,
                                        ),
                                      )
                                    : Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          for (final e in props.entries)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 9,
                                              ),
                                              child: _boolFields
                                                      .containsKey(e.key)
                                                  ? PrismCheckToggle(
                                                      value: _boolFields[
                                                              e.key] ==
                                                          true,
                                                      label: e.key,
                                                      onChanged: (v) =>
                                                          setState(() {
                                                        _boolFields[e.key] = v;
                                                      }),
                                                    )
                                                  : TextField(
                                                      controller:
                                                          _fieldCtrls[e.key],
                                                      style: monoStyle(
                                                        c,
                                                        size: 12,
                                                        color: c.ink,
                                                      ),
                                                      decoration:
                                                          InputDecoration(
                                                        isDense: true,
                                                        labelText: e.key,
                                                        hintText: (e.value
                                                                    is Map
                                                                ? e.value[
                                                                    'description']
                                                                : '')
                                                            ?.toString(),
                                                      ),
                                                    ),
                                            ),
                                        ],
                                      )),
                          ),
                        if (_outputText != null) ...[
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              PrismPill(
                                text: _outputOk ? '调用成功' : '返回错误',
                                mono: false,
                                fg: _outputOk ? c.sage : c.danger,
                                bg: _outputOk ? c.sageBg : c.dangerBg,
                              ),
                              if (_elapsedMs != null) ...[
                                const SizedBox(width: 6),
                                PrismPill(text: '$_elapsedMs ms'),
                              ],
                              const Spacer(),
                              PrismButton(
                                label: '复制结果',
                                compact: true,
                                variant: PrismBtnVariant.ghost,
                                leading: const Icon(Icons.copy_rounded),
                                onPressed: () {
                                  Clipboard.setData(
                                    ClipboardData(text: _outputText!),
                                  );
                                  widget.onToast('已复制调试输出');
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Container(
                            constraints: const BoxConstraints(maxHeight: 220),
                            padding: const EdgeInsets.all(12),
                            decoration: ShapeDecoration(
                              color: c.recessed,
                              shape: prismSuperellipse(
                                12,
                                side: BorderSide(color: c.hairline),
                              ),
                            ),
                            child: SingleChildScrollView(
                              child: SelectableText(
                                _outputText!,
                                style: monoStyle(
                                  c,
                                  size: 11.6,
                                  color: _outputOk ? c.ink : c.danger,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PrismButton(
                    label: '关闭',
                    compact: true,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  PrismButton(
                    label: _running ? '执行中...' : '立即执行',
                    compact: true,
                    loading: _running,
                    variant: PrismBtnVariant.clay,
                    leading: const Icon(Icons.play_arrow_rounded),
                    onPressed:
                        _running || options.isEmpty ? null : _execute,
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
