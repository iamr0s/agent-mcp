import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/console_backend.dart';
import '../theme/claude_theme.dart';
import 'profile_endpoints_helper.dart';

String inferShareModeFromPath(String rawPath) {
  final cleaned = rawPath.trim().replaceAll('"', '');
  final lower = cleaned.toLowerCase();
  if (int.tryParse(lower.replaceAll(':', '')) != null) return 'port';
  if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'site';
  final base = cleaned.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull ?? '';
  // Heuristic when stat isn't needed on UI side: paths without file extension default to folder
  if (base.isNotEmpty && !base.contains('.')) return 'folder';
  return 'file';
}

class ExposureSharePage extends StatefulWidget {
  final ConsoleBackend backend;
  final Map<String, dynamic> exposureSummary;
  final ValueListenable<String?>? droppedPathSignal;
  final VoidCallback? onConsumeDroppedPath;
  final double topPadding;
  final double extraBottomPadding;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onToast;

  const ExposureSharePage({
    super.key,
    required this.backend,
    required this.exposureSummary,
    this.droppedPathSignal,
    this.onConsumeDroppedPath,
    this.topPadding = 0.0,
    this.extraBottomPadding = 0.0,
    required this.onRefresh,
    required this.onToast,
  });

  @override
  State<ExposureSharePage> createState() => _ExposureSharePageState();
}

class _ExposureSharePageState extends State<ExposureSharePage> {
  bool _refreshing = false;
  bool _closingAll = false;
  String? _closingId;
  bool _togglingMaster = false;
  bool _showChannelDetails = false;
  bool _showGuide = false;
  bool _dialogOpen = false;

  @override
  void initState() {
    super.initState();
    widget.droppedPathSignal?.addListener(_handleDroppedSignal);
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleDroppedSignal());
  }

  @override
  void didUpdateWidget(covariant ExposureSharePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.droppedPathSignal != widget.droppedPathSignal) {
      oldWidget.droppedPathSignal?.removeListener(_handleDroppedSignal);
      widget.droppedPathSignal?.addListener(_handleDroppedSignal);
    }
  }

  @override
  void dispose() {
    widget.droppedPathSignal?.removeListener(_handleDroppedSignal);
    super.dispose();
  }

  void _handleDroppedSignal() {
    final dropped = widget.droppedPathSignal?.value;
    if (dropped == null || dropped.trim().isEmpty || !mounted || _dialogOpen) {
      return;
    }
    widget.onConsumeDroppedPath?.call();
    if (!_enabled) {
      widget.onToast('请先开启外链分享后再拖入文件');
      return;
    }
    final mode = inferShareModeFromPath(dropped);
    _openCreateDialog(initialMode: mode, initialTarget: dropped);
  }

  bool get _enabled => widget.exposureSummary['enabled'] != false;
  bool get _tsEnabled => widget.exposureSummary['tailscale_enabled'] != false;
  String get _tsMode =>
      (widget.exposureSummary['tailscale_mode'] ?? 'funnel').toString();
  bool get _cfInstalled =>
      widget.exposureSummary['cloudflared_installed'] == true;
  int get _defaultTtl =>
      int.tryParse('${widget.exposureSummary['default_ttl_minutes'] ?? 120}') ??
      120;

  Map<String, dynamic> get _tsStatus {
    final raw = widget.exposureSummary['tailscale_status'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const <String, dynamic>{};
  }

  List<String> get _pubBases {
    final raw = widget.exposureSummary['public_gateway_bases'];
    if (raw is List) return raw.map((e) => e.toString()).toList();
    return const <String>[];
  }

  List<int> get _activePorts {
    final raw = widget.exposureSummary['active_local_ports'];
    if (raw is List) {
      return raw
          .map((e) => int.tryParse('$e'))
          .whereType<int>()
          .toList();
    }
    return const <int>[];
  }

  List<Map<String, dynamic>> get _items {
    final raw = widget.exposureSummary['items'];
    if (raw is List) {
      return raw
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return const <Map<String, dynamic>>[];
  }

  Future<void> _doRefresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await runWithMinDuration(widget.onRefresh);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _enableMasterNow() async {
    if (_togglingMaster) return;
    setState(() => _togglingMaster = true);
    try {
      await widget.backend.saveConfig({'expose_enabled': true});
      await widget.onRefresh();
      widget.onToast('已开启随手分享功能');
    } finally {
      if (mounted) setState(() => _togglingMaster = false);
    }
  }

  Future<void> _closeOne(String id, String label) async {
    if (_closingId != null) return;
    setState(() => _closingId = id);
    try {
      await runWithMinDuration(() => widget.backend.closeExposure(id));
      await widget.onRefresh();
      widget.onToast('已收起分享：$label');
    } finally {
      if (mounted) setState(() => _closingId = null);
    }
  }

  Future<void> _closeAll() async {
    if (_closingAll) return;
    setState(() => _closingAll = true);
    try {
      final res = await runWithMinDuration(widget.backend.closeAllExposures);
      await widget.onRefresh();
      final cnt = res['closed_count'] ?? 0;
      widget.onToast('已一键收起全部 $cnt 条分享链接');
    } finally {
      if (mounted) setState(() => _closingAll = false);
    }
  }

  Future<void> _copyText(String text, String tip) async {
    await Clipboard.setData(ClipboardData(text: text));
    widget.onToast(tip);
  }

  Future<void> _openCreateDialog({
    String initialMode = 'file',
    String? initialTarget,
  }) async {
    _dialogOpen = true;
    Map<String, dynamic>? created;
    try {
      created = await showClaudeDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => _CreateExposureDialog(
          backend: widget.backend,
          defaultTtlMinutes: _defaultTtl,
          activeLocalPorts: _activePorts,
          initialMode: initialMode,
          initialTarget: initialTarget,
        ),
      );
    } finally {
      _dialogOpen = false;
    }
    if (created != null) {
      await widget.onRefresh();
      final url = (created['primary_url'] ?? '').toString();
      if (url.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: url));
        widget.onToast('链接已生成并自动复制：$url');
      } else {
        widget.onToast('已创建分享链接');
      }
    }
  }

  Future<void> _openQrModal(String title, String url) async {
    await showClaudeDialog<void>(
      context: context,
      builder: (_) => _ShareQrDialog(
        title: title,
        url: url,
        onCopy: () => _copyText(url, '已复制分享链接：$url'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final items = _items;
    final ts = _tsStatus;
    final tsReachable = ts['reachable'] == true;
    final tsIps = ((ts['tailscale_ips'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final tsDns = (ts['dns_name'] ?? '').toString();

    String tsSummary;
    if (!_tsEnabled) {
      tsSummary = '已在设置中暂停（需要时可在服务配置里一键打开）';
    } else if (tsDns.isNotEmpty) {
      tsSummary =
          '$tsDns · ${_tsMode == "funnel" ? "优先 Funnel 公网直达" : "组网内设备直连"}';
    } else if (tsIps.isNotEmpty) {
      tsSummary = '组网地址 ${tsIps.join(", ")} 已就绪，同账号手机可直接点开';
    } else {
      tsSummary = '打开 Tailscale 后会自动识别组网地址';
    }

    final gwSummary = _pubBases.isNotEmpty
        ? '已就绪公网域名 ${_pubBases.first}，秒出外网链接'
        : '本机与局域网直享已就绪；配置隧道域名后可免端口公网直达';

    final cfSummary = _cfInstalled
        ? '已就绪：无固定域名时自动拉起临时 HTTPS 链接'
        : '按需可选：在服务配置下载 cloudflared 后可分配临时公网域名';

    return SingleChildScrollView(
      padding: EdgeInsets.only(
        top: widget.topPadding,
        bottom: 36 + widget.extraBottomPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 10,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 660),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('外网映射与链接分享', style: serifTitleStyle(c, size: 24)),
                    const SizedBox(height: 4),
                    Text(
                      '支持单个文件、文件夹目录浏览、静态网站/HTML 与本地端口四种形态（桌面端可直接拖入文件或文件夹秒建分享）。',
                      style: sansStyle(
                        c,
                        size: 13,
                        color: c.muted,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ClaudeButton(
                    label: _refreshing ? '刷新中...' : '刷新',
                    compact: true,
                    variant: ClaudeBtnVariant.ghost,
                    loading: _refreshing,
                    leading: const Icon(Icons.refresh_rounded),
                    onPressed: _doRefresh,
                  ),
                  if (items.isNotEmpty)
                    ClaudeButton(
                      label: _closingAll ? '收起中...' : '全部关闭 (${items.length})',
                      compact: true,
                      loading: _closingAll,
                      leading: const Icon(Icons.link_off_rounded),
                      onPressed: _closeAll,
                    ),
                  ClaudeButton(
                    label: '新建外网分享',
                    compact: true,
                    variant: ClaudeBtnVariant.clay,
                    leading: const Icon(Icons.add_link_rounded),
                    onPressed:
                        _enabled ? () => _openCreateDialog(initialMode: 'port') : null,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!_enabled) ...[
            ClaudeCard(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  Icon(Icons.pause_circle_outline_rounded, color: c.clay, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '外链分享目前已暂停',
                          style: sansStyle(
                            c,
                            size: 14,
                            weight: FontWeight.w600,
                            color: c.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '暂停期间外部无法访问任何分享链接，点右侧按钮即可随时恢复。',
                          style: sansStyle(c, size: 12.5, color: c.muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  ClaudeButton(
                    label: _togglingMaster ? '开启中...' : '立即开启',
                    compact: true,
                    loading: _togglingMaster,
                    variant: ClaudeBtnVariant.clay,
                    onPressed: _enableMasterNow,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
          ],

          // Adaptive Share Dropzone: high-visibility dashed dropbar when active shares exist; hero dashed dropzone + 4-mode cards when empty
          if (_enabled && items.isNotEmpty) ...[
            _DashedDropZone(
              borderColor: c.clay.withValues(alpha: c.isDark ? 0.55 : 0.45),
              fillColor: c.clay.withValues(alpha: c.isDark ? 0.08 : 0.045),
              radius: 14,
              onTap: () => _openCreateDialog(initialMode: 'file'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            color: c.clay.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(9),
                          ),
                          child: Icon(Icons.file_upload_rounded, size: 17, color: c.clay),
                        ),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '拖拽文件、文件夹或 HTML 到此处一键分享',
                                  style: sansStyle(c, size: 13, weight: FontWeight.w600, color: c.ink),
                                ),
                                const SizedBox(width: 7),
                                ClaudePill(
                                  text: '支持拖拽',
                                  fg: c.clay,
                                  bg: c.clay.withValues(alpha: 0.12),
                                ),
                              ],
                            ),
                            Text(
                              '松手自动识别形态，也可点击右侧按钮手动新建',
                              style: sansStyle(c, size: 11.5, color: c.muted),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        ClaudeButton(
                          label: '单文件',
                          compact: true,
                          variant: ClaudeBtnVariant.ghost,
                          onPressed: () => _openCreateDialog(initialMode: 'file'),
                        ),
                        ClaudeButton(
                          label: '文件夹',
                          compact: true,
                          variant: ClaudeBtnVariant.ghost,
                          onPressed: () => _openCreateDialog(initialMode: 'folder'),
                        ),
                        ClaudeButton(
                          label: '静态网站',
                          compact: true,
                          variant: ClaudeBtnVariant.ghost,
                          onPressed: () => _openCreateDialog(initialMode: 'site'),
                        ),
                        ClaudeButton(
                          label: '端口转发',
                          compact: true,
                          variant: ClaudeBtnVariant.ghost,
                          onPressed: () => _openCreateDialog(initialMode: 'port'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ] else if (_enabled) ...[
            _DashedDropZone(
              borderColor: c.clay.withValues(alpha: c.isDark ? 0.58 : 0.48),
              fillColor: c.clay.withValues(alpha: c.isDark ? 0.08 : 0.045),
              radius: 16,
              onTap: () => _openCreateDialog(initialMode: 'file'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: c.clay.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(Icons.drive_folder_upload_rounded, size: 23, color: c.clay),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                '拖拽任意文件、文件夹或静态网站目录到此处',
                                style: sansStyle(c, size: 14.5, weight: FontWeight.w600, color: c.ink),
                              ),
                              ClaudePill(
                                text: '拖拽即享',
                                fg: c.clay,
                                bg: c.clay.withValues(alpha: 0.14),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '松手自动识别单文件预览 / 文件夹浏览 / 静态 HTML 站点；也可以点击此处或下方卡片手动选择。',
                            style: sansStyle(c, size: 12.2, color: c.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (ctx, qbox) {
                final cols = qbox.maxWidth < 520
                    ? 1
                    : (qbox.maxWidth < 920 ? 2 : 4);
                const gap = 10.0;
                final cardW = (qbox.maxWidth - gap * (cols - 1)) / cols;
                const modeCards = [
                  (
                    'file',
                    Icons.smart_display_outlined,
                    '1. 单个文件分享',
                    '视频流式拖进度条播放，PDF/图片直接看，安装包直下',
                  ),
                  (
                    'folder',
                    Icons.folder_open_rounded,
                    '2. 文件夹目录分享',
                    '展示目录与子文件夹，点击文件无缝进入单文件预览态',
                  ),
                  (
                    'site',
                    Icons.web_rounded,
                    '3. 静态网站 / HTML',
                    '单个 .html 或前端目录直接作为正式网页全屏运行',
                  ),
                  (
                    'port',
                    Icons.podcasts_rounded,
                    '4. 端口转发分享',
                    '把本机 :3000 / :5173 等正在运行的服务实时映射出去',
                  ),
                ];
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (final mc in modeCards)
                      SizedBox(
                        width: cardW,
                        child: ClaudeCard(
                          hoverable: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          onTap: () => _openCreateDialog(initialMode: mc.$1),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      mc.$3,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: sansStyle(
                                        c,
                                        size: 13.8,
                                        weight: FontWeight.w600,
                                        color: c.ink,
                                      ),
                                    ),
                                  ),
                                  Icon(mc.$2, size: 17, color: c.clay),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Text(
                                mc.$4,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: sansStyle(
                                  c,
                                  size: 12,
                                  color: c.muted,
                                  height: 1.42,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
          ],

          // Quiet 1-line network readiness strip (borderless tonal surface)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: ShapeDecoration(
              color: c.recessed,
              shape: claudeSuperellipse(15),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    Wrap(
                      spacing: 14,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ClaudeStatusDot(
                              color: (_tsEnabled && tsReachable)
                                  ? c.sage
                                  : c.meta,
                              pulsing: _tsEnabled && tsReachable,
                              size: 6.5,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Tailscale · ${!_tsEnabled ? '未启用' : (tsReachable ? '已就绪' : '待连接')}',
                              style: sansStyle(
                                c,
                                size: 12.5,
                                weight: FontWeight.w600,
                                color: (_tsEnabled && tsReachable)
                                    ? c.sage
                                    : c.muted,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ClaudeStatusDot(
                              color: _enabled ? c.sage : c.meta,
                              size: 6.5,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '直享通道 · ${_pubBases.isNotEmpty ? '公网秒开' : '局域网就绪'}',
                              style: sansStyle(c, size: 12.5, color: c.inkSoft),
                            ),
                          ],
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ClaudeStatusDot(
                              color: _cfInstalled ? c.sage : c.meta,
                              size: 6.5,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '临时隧道 · ${_cfInstalled ? '按需可用' : '可选'}',
                              style: sansStyle(c, size: 12.5, color: c.muted),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Wrap(
                      spacing: 6,
                      children: [
                        ClaudeButton(
                          label: _showChannelDetails ? '收起通道详情' : '通道详情',
                          compact: true,
                          variant: ClaudeBtnVariant.ghost,
                          onPressed: () => setState(
                            () => _showChannelDetails = !_showChannelDetails,
                          ),
                        ),
                        if (items.isNotEmpty)
                          ClaudeButton(
                            label: _showGuide ? '收起说明' : '用法说明',
                            compact: true,
                            variant: ClaudeBtnVariant.ghost,
                            onPressed: () =>
                                setState(() => _showGuide = !_showGuide),
                          ),
                      ],
                    ),
                  ],
                ),
                ClaudeCollapsible(
                  expanded: _showChannelDetails,
                  builder: (_) => Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: LayoutBuilder(
                      builder: (ctx, box) {
                        final cols = box.maxWidth < 760 ? 1 : 3;
                        const gap = 10.0;
                        final tileW = (box.maxWidth - gap * (cols - 1)) / cols;
                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            SizedBox(
                              width: tileW,
                              child: _ChannelStatusTile(
                                icon: Icons.hub_rounded,
                                title: 'Tailscale 组网 / Funnel',
                                badge: !_tsEnabled
                                    ? '已关闭'
                                    : (tsReachable ? '已连通' : '待启动'),
                                active: _tsEnabled && tsReachable,
                                subtitle: tsSummary,
                              ),
                            ),
                            SizedBox(
                              width: tileW,
                              child: _ChannelStatusTile(
                                icon: Icons.bolt_rounded,
                                title: '网关直享通道 (/share)',
                                badge: _pubBases.isNotEmpty ? '公网秒出' : '局域网就绪',
                                active: _enabled,
                                subtitle: gwSummary,
                              ),
                            ),
                            SizedBox(
                              width: tileW,
                              child: _ChannelStatusTile(
                                icon: Icons.cloud_outlined,
                                title: '临时公网隧道兜底',
                                badge: _cfInstalled ? '按需可用' : '未安装',
                                active: _cfInstalled,
                                subtitle: cfSummary,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
          ClaudeCollapsible(
            expanded: items.isNotEmpty && _showGuide,
            builder: (_) => Padding(
              padding: const EdgeInsets.only(top: 12),
              child: _buildEmptyGuideCard(c, hasActiveItems: true),
            ),
          ),
          const SizedBox(height: 14),
          if (items.isEmpty)
            _buildEmptyGuideCard(c)
          else
            Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: 12),
                  _ActiveExposureCard(
                    item: items[i],
                    closing: _closingId == items[i]['id']?.toString(),
                    onCopy: _copyText,
                    onShowQr: (title, url) => _openQrModal(title, url),
                    onOpenBrowser: (url) async {
                      final ok = await widget.backend.openExternalUrl(url);
                      if (!ok) {
                        await _copyText(url, '已复制链接：$url');
                      }
                    },
                    onClose: () => _closeOne(
                      (items[i]['id'] ?? '').toString(),
                      (items[i]['label'] ?? '').toString(),
                    ),
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyGuideCard(ClaudePalette c, {bool hasActiveItems = false}) {
    return ClaudeCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.send_rounded, size: 19, color: c.clay),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  hasActiveItems
                      ? '外链分享小贴士 · 一句话或点选卡片都能发'
                      : '还没有正在分享的内容 · 点上方任意卡片或让 AI 帮你发',
                  style: serifTitleStyle(c, size: 17),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _HowToUseStepRow(
            step: '超省心用法',
            title: '直接对 AI 说一句话就行',
            desc:
                '比如：“把这个课件文件夹做成目录链接发我”、“把这个 html 当静态网页发我预览”或“把 5173 端口映射给手机看”，AI 会自动选好对应形态并返回可点开的链接。',
          ),
          const SizedBox(height: 10),
          _HowToUseStepRow(
            step: '手动点选',
            title: '点上方 4 张模式卡片直接选文件或文件夹',
            desc:
                '选「文件夹目录」时对方可层层点进子目录，点任意文件即进入单文件在线预览；选「静态网站 / HTML」时无论是单页 .html 还是前端目录都会直接作为正式网页全屏打开。',
          ),
        ],
      ),
    );
  }
}

class _ChannelStatusTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String badge;
  final bool active;
  final String subtitle;

  const _ChannelStatusTile({
    required this.icon,
    required this.title,
    required this.badge,
    required this.active,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    return ClaudeCard(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 17, color: active ? c.sage : c.muted),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: sansStyle(
                    c,
                    size: 13.5,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
              ),
              ClaudePill(
                leading: ClaudeStatusDot(
                  color: active ? c.sage : c.meta,
                  pulsing: active,
                  size: 6,
                ),
                text: badge,
                mono: false,
                fg: active ? c.sage : c.muted,
                bg: active ? c.sageBg : c.paper3,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: sansStyle(c, size: 12, color: c.muted, height: 1.44),
          ),
        ],
      ),
    );
  }
}

class _HowToUseStepRow extends StatelessWidget {
  final String step;
  final String title;
  final String desc;

  const _HowToUseStepRow({
    required this.step,
    required this.title,
    required this.desc,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: ShapeDecoration(
        color: c.recessed,
        shape: claudeSuperellipse(15),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClaudePill(
                text: step,
                mono: false,
                fg: c.clay,
                bg: c.clay.withValues(alpha: c.isDark ? 0.16 : 0.11),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: sansStyle(
                    c,
                    size: 13.5,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            desc,
            style: sansStyle(c, size: 12.5, color: c.muted, height: 1.52),
          ),
        ],
      ),
    );
  }
}

class _ActiveExposureCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final bool closing;
  final Future<void> Function(String text, String tip) onCopy;
  final void Function(String title, String url) onShowQr;
  final ValueChanged<String> onOpenBrowser;
  final VoidCallback onClose;

  const _ActiveExposureCard({
    required this.item,
    required this.closing,
    required this.onCopy,
    required this.onShowQr,
    required this.onOpenBrowser,
    required this.onClose,
  });

  @override
  State<_ActiveExposureCard> createState() => _ActiveExposureCardState();
}

class _ActiveExposureCardState extends State<_ActiveExposureCard> {
  bool _hovered = false;

  Map<String, dynamic> get item => widget.item;
  bool get closing => widget.closing;
  Future<void> Function(String text, String tip) get onCopy => widget.onCopy;
  void Function(String title, String url) get onShowQr => widget.onShowQr;
  ValueChanged<String> get onOpenBrowser => widget.onOpenBrowser;
  VoidCallback get onClose => widget.onClose;

  @override
  Widget build(BuildContext context) {
    final revealSecondary = _hovered || MediaQuery.sizeOf(context).width < 760;
    final c = ClaudePalette.of(context);
    final kind = (item['kind'] ?? 'file').toString();
    final label = (item['label'] ?? '未命名分享').toString();
    final target = (item['target'] ?? '').toString();
    final scope = (item['scope'] ?? 'auto').toString();
    final primaryUrl = (item['primary_url'] ?? '').toString();
    final directFileUrl = (item['direct_file_url'] ?? '').toString();
    final hitCount = int.tryParse('${item['hit_count'] ?? 0}') ?? 0;
    final bytesHuman = (item['bytes_sent_human'] ?? '0 B').toString();
    final hasPin = item['has_pin'] == true;
    final pinCode = (item['pin_code'] ?? '').toString();
    final remDl = item['remaining_downloads'] is int
        ? item['remaining_downloads'] as int
        : int.tryParse('${item['remaining_downloads'] ?? ''}');
    final remSec = item['remaining_seconds'] is int
        ? item['remaining_seconds'] as int
        : int.tryParse('${item['remaining_seconds'] ?? ''}');

    final pubUrls = ((item['public_urls'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final tsUrls = ((item['tailscale_urls'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final lanUrls = ((item['lan_urls'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();

    final (IconData kindIcon, String kindLabel) = switch (kind) {
      'port' => (Icons.podcasts_rounded, '端口转发'),
      'folder' => (Icons.folder_open_rounded, '文件夹目录'),
      'site' || 'dir' => (Icons.web_rounded, '静态网站 / HTML'),
      _ => (Icons.smart_display_outlined, '单个文件'),
    };

    final scopeText = switch (scope) {
      'tailscale' => '仅组网设备',
      'public' => '公网直达',
      'lan' => '仅局域网',
      _ => '自动优选',
    };

    String ttlText = '手动收起前有效';
    if (remSec != null) {
      final mins = (remSec / 60).ceil();
      ttlText = mins >= 60
          ? '${(mins / 60).toStringAsFixed(1)} 小时后收起'
          : '$mins 分钟后收起';
    }

    final copyOptions = <EndpointCopyOption>[];
    for (final u in pubUrls) {
      copyOptions.add(
        EndpointCopyOption(badge: '公网', url: u, isHighlight: true),
      );
    }
    for (final u in tsUrls) {
      if (pubUrls.contains(u)) continue;
      copyOptions.add(
        EndpointCopyOption(badge: 'Tailscale', url: u, isHighlight: true),
      );
    }
    for (final u in lanUrls) {
      copyOptions.add(EndpointCopyOption(badge: '局域网', url: u));
    }
    if (directFileUrl.isNotEmpty) {
      copyOptions.add(
        EndpointCopyOption(badge: '原文件直链', url: directFileUrl),
      );
    }

    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: ClaudeCard(
      padding: const EdgeInsets.all(16),
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
                  Icon(kindIcon, size: 19, color: c.clay),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      style: sansStyle(
                        c,
                        size: 15,
                        weight: FontWeight.w600,
                        color: c.ink,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ClaudePill(
                    leading: ClaudeStatusDot(
                      color: c.sage,
                      pulsing: true,
                      size: 6.5,
                    ),
                    text: kindLabel,
                    mono: false,
                    fg: c.sage,
                    bg: c.sageBg,
                  ),
                  if (hasPin) ...[
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: pinCode.isNotEmpty
                          ? () => onCopy(pinCode, '已复制提取码：$pinCode')
                          : null,
                      child: ClaudePill(
                        text: pinCode.isNotEmpty ? '提取码 $pinCode' : '口令保护',
                        mono: false,
                        fg: c.clay,
                        bg: c.clay.withValues(alpha: 0.13),
                      ),
                    ),
                  ],
                ],
              ),
              Text(
                '$scopeText · $ttlText${remDl != null ? " · 剩余下载 $remDl 次" : ""} · 访问 $hitCount 次 ($bytesHuman)',
                style: sansStyle(c, size: 12, color: c.muted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '本地目标：$target',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: monoStyle(c, size: 11.8, color: c.meta),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: ShapeDecoration(
              color: c.recessed,
              shape: claudeSuperellipse(14),
            ),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: [
                SelectableText(
                  primaryUrl,
                  style: monoStyle(
                    c,
                    size: 12.6,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    ClaudeButton(
                      label: '复制链接',
                      compact: true,
                      variant: ClaudeBtnVariant.clay,
                      leading: const Icon(Icons.copy_rounded),
                      onPressed: () =>
                          onCopy(primaryUrl, '已复制分享链接：$primaryUrl'),
                    ),
                    AnimatedOpacity(
                      duration: ClaudeMotion.duration(
                        context,
                        const Duration(milliseconds: 140),
                      ),
                      opacity: revealSecondary ? 1.0 : 0.30,
                      child: Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: [
                          ClaudeButton(
                            label: '二维码',
                            compact: true,
                            variant: ClaudeBtnVariant.ghost,
                            leading: const Icon(Icons.qr_code_rounded),
                            onPressed: () => onShowQr(label, primaryUrl),
                          ),
                          ClaudeButton(
                            label: '打开预览',
                            compact: true,
                            variant: ClaudeBtnVariant.ghost,
                            leading: const Icon(Icons.open_in_new_rounded),
                            onPressed: () => onOpenBrowser(primaryUrl),
                          ),
                          if (copyOptions.length > 1)
                            EndpointCopyDropButton(
                              label: '更多通道 (${copyOptions.length})',
                              options: copyOptions,
                              onSelect: (opt) => onCopy(
                                opt.url,
                                '已复制 ${opt.badge} 地址：${opt.url}',
                              ),
                            ),
                          ClaudeButton(
                            label: closing ? '关闭中...' : '关闭分享',
                            compact: true,
                            loading: closing,
                            variant: ClaudeBtnVariant.ghost,
                            leading: const Icon(Icons.close_rounded),
                            onPressed: onClose,
                          ),
                        ],
                      ),
                    ),
                  ],
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

class _CreateExposureDialog extends StatefulWidget {
  final ConsoleBackend backend;
  final int defaultTtlMinutes;
  final List<int> activeLocalPorts;
  final String initialMode;
  final String? initialTarget;

  const _CreateExposureDialog({
    required this.backend,
    required this.defaultTtlMinutes,
    this.activeLocalPorts = const <int>[],
    this.initialMode = 'port',
    this.initialTarget,
  });

  @override
  State<_CreateExposureDialog> createState() => _CreateExposureDialogState();
}

class _CreateExposureDialogState extends State<_CreateExposureDialog> {
  late String _mode = widget.initialMode; // 'port' | 'file' | 'folder' | 'site'
  late final TextEditingController _targetCtrl = TextEditingController(
    text: (widget.initialTarget != null && widget.initialTarget!.trim().isNotEmpty)
        ? widget.initialTarget!.trim()
        : (widget.initialMode == 'port'
            ? (widget.activeLocalPorts.isNotEmpty
                ? '${widget.activeLocalPorts.first}'
                : '3000')
            : ''),
  );
  final TextEditingController _labelCtrl = TextEditingController();
  final TextEditingController _pinCtrl = TextEditingController();
  String _scope = 'auto';
  late int _ttlMinutes = widget.defaultTtlMinutes;
  int _maxDownloads = 0; // 0 = unlimited
  bool _spa = false;
  bool _picking = false;
  bool _submitting = false;
  String _error = '';

  @override
  void dispose() {
    _targetCtrl.dispose();
    _labelCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  void _onTargetChanged(String val) {
    final cleaned = val.trim().replaceAll('"', '');
    final trimmed = cleaned.toLowerCase();
    setState(() {
      _error = '';
      if ((trimmed.endsWith('.html') || trimmed.endsWith('.htm')) &&
          _mode == 'port') {
        _mode = 'site';
      } else if (_mode == 'port' &&
          cleaned.isNotEmpty &&
          int.tryParse(cleaned.replaceAll(':', '')) == null &&
          !trimmed.startsWith('http://')) {
        _mode = inferShareModeFromPath(cleaned);
      }
    });
  }

  Future<void> _pickPath({required bool directory}) async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _error = '';
    });
    try {
      final picked =
          await widget.backend.pickLocalSharePath(directory: directory);
      if (!mounted || picked == null || picked.isEmpty) return;
      setState(() {
        _targetCtrl.text = picked;
        final lower = picked.toLowerCase();
        if (!directory &&
            (lower.endsWith('.html') || lower.endsWith('.htm')) &&
            _mode != 'file') {
          _mode = 'site';
        }
      });
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _submit() async {
    final raw = _targetCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '请选择或填入要分享的文件、文件夹或端口号');
      return;
    }
    setState(() {
      _submitting = true;
      _error = '';
    });
    try {
      final cleanRaw = raw.replaceAll('"', '').trim();
      final pinText = _pinCtrl.text.trim();
      if (pinText.isNotEmpty && (pinText.length < 4 || pinText.length > 16)) {
        setState(() {
          _error = '提取码长度建议为 4 到 16 位（留空则免口令直接打开）';
          _submitting = false;
        });
        return;
      }
      final res = await widget.backend.openExposure(
        target: cleanRaw,
        mode: _mode,
        port: _mode == 'port'
            ? int.tryParse(cleanRaw.replaceAll(':', '').trim())
            : null,
        scope: _scope,
        label: _labelCtrl.text.trim(),
        ttlMinutes: _ttlMinutes,
        pinCode: pinText.isEmpty ? null : pinText,
        maxDownloads: _maxDownloads > 0 ? _maxDownloads : null,
        spa: _mode == 'site' && _spa,
      );
      if (!mounted) return;
      if (res['ok'] == true && res['exposure'] is Map) {
        Navigator.of(context).pop(
          Map<String, dynamic>.from(res['exposure'] as Map),
        );
      } else {
        setState(() {
          _error = (res['error'] ?? '创建分享失败').toString();
          _submitting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final compact = MediaQuery.sizeOf(context).width < 560;
    final curText = _targetCtrl.text.trim().toLowerCase();
    final isHtmlTarget = curText.endsWith('.html') || curText.endsWith('.htm');

    final modeHelp = switch (_mode) {
      'port' => '填入本机正在运行的端口号（手机或外网打开即实时交互）',
      'file' => '选择单个视频、PDF、图片或安装包（对方打开直接在线播放或下载）',
      'folder' => '选择任意文件夹（对方打开可进入子目录，点里面的文件即进入单文件预览态）',
      _ => '选择单个 .html 文件或含 index.html 的网站目录（直接全屏渲染运行网页）',
    };

    final hintText = switch (_mode) {
      'port' => '例如 3000 或 5173',
      'file' => '例如 D:\\视频\\demo.mp4（可点右侧按钮直接选文件）',
      'folder' => '例如 D:\\教学资料\\实验包（可点右侧按钮直接选文件夹）',
      _ => '例如 D:\\web\\dist（网站目录）或 D:\\lab.html（单页）',
    };

    final defaultPorts = <int>[
      ...widget.activeLocalPorts,
      for (final p in const [3000, 5173, 8080, 8000, 4173])
        if (!widget.activeLocalPorts.contains(p)) p,
    ];

    return Dialog(
      backgroundColor: c.paper2,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 28,
        vertical: 18,
      ),
      shape: claudeSuperellipse(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 18 : 26,
            22,
            compact ? 18 : 26,
            20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const ClaudeSparkIcon(size: 18),
                    const SizedBox(width: 9),
                    Text('新建外网映射与分享', style: serifTitleStyle(c, size: 19)),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  '选择打开形态',
                  style: sansStyle(
                    c,
                    size: 12.6,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 7),
                ClaudeSegmented<String>(
                  value: _mode,
                  items: const [
                    ('port', '本地网站端口'),
                    ('file', '单个视频 / 文件'),
                    ('folder', '文件夹目录'),
                    ('site', '静态网站 / HTML'),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _mode = v;
                      _error = '';
                      if (v == 'port' &&
                          int.tryParse(_targetCtrl.text.trim()) == null) {
                        _targetCtrl.text = widget.activeLocalPorts.isNotEmpty
                            ? '${widget.activeLocalPorts.first}'
                            : '3000';
                      } else if (v != 'port' &&
                          int.tryParse(_targetCtrl.text.trim()) != null) {
                        _targetCtrl.clear();
                      }
                    });
                  },
                ),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        modeHelp,
                        style: sansStyle(c, size: 12.5, color: c.muted),
                      ),
                    ),
                    if (_mode != 'port' && !widget.backend.isAndroidPlatform) ...[
                      const SizedBox(width: 8),
                      Wrap(
                        spacing: 6,
                        children: [
                          if (_mode == 'file' || _mode == 'site')
                            ClaudeButton(
                              label: _picking ? '选择中...' : (_mode == 'site' ? '选 HTML 文件' : '选文件...'),
                              compact: true,
                              leading:
                                  const Icon(Icons.insert_drive_file_outlined),
                              onPressed: _picking
                                  ? null
                                  : () => _pickPath(directory: false),
                            ),
                          if (_mode == 'folder' || _mode == 'site')
                            ClaudeButton(
                              label: _picking ? '选择中...' : (_mode == 'site' ? '选网站文件夹' : '选文件夹...'),
                              compact: true,
                              leading: const Icon(Icons.folder_open_rounded),
                              onPressed: _picking
                                  ? null
                                  : () => _pickPath(directory: true),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _targetCtrl,
                  onChanged: _onTargetChanged,
                  style: monoStyle(c, size: 13, color: c.ink),
                  decoration: InputDecoration(hintText: hintText),
                ),
                if (isHtmlTarget && (_mode == 'file' || _mode == 'site')) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Icon(Icons.tips_and_updates_outlined,
                          size: 14, color: c.clay),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _mode == 'site'
                              ? '当前将该 .html 直接作为网页运行；若只想让人查看源码或下载，可点上方「单个视频 / 文件」。'
                              : '检测到 .html 文件：若希望对方点开直接运行网页，可点上方切到「静态网站 / HTML」。',
                          style: sansStyle(c, size: 11.8, color: c.clay),
                        ),
                      ),
                    ],
                  ),
                ],
                if (_mode == 'port') ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final p in defaultPorts)
                        ClaudeButton(
                          label: widget.activeLocalPorts.contains(p)
                              ? ':$p · 运行中'
                              : ':$p',
                          compact: true,
                          variant: widget.activeLocalPorts.contains(p)
                              ? ClaudeBtnVariant.clay
                              : ClaudeBtnVariant.neutral,
                          onPressed: () =>
                              setState(() => _targetCtrl.text = '$p'),
                        ),
                    ],
                  ),
                ],
                if (_mode == 'site') ...[
                  const SizedBox(height: 8),
                  ClaudeCheckToggle(
                    value: _spa,
                    label: '前端单页应用路由模式（未知子路径自动回退到 index.html）',
                    onChanged: (v) => setState(() => _spa = v),
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  '访问范围与自动收起时间',
                  style: sansStyle(
                    c,
                    size: 12.6,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    ClaudeSegmented<String>(
                      value: _scope,
                      items: const [
                        ('auto', '智能优选'),
                        ('tailscale', '仅 Tailscale'),
                        ('public', '公网直达'),
                        ('lan', '仅局域网'),
                      ],
                      onChanged: (v) => setState(() => _scope = v),
                    ),
                    ClaudeSegmented<int>(
                      value: const [30, 120, 1440, 0].contains(_ttlMinutes)
                          ? _ttlMinutes
                          : 120,
                      items: const [
                        (30, '30 分钟'),
                        (120, '2 小时'),
                        (1440, '24 小时'),
                        (0, '一直开着'),
                      ],
                      onChanged: (v) => setState(() => _ttlMinutes = v),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Text(
                  '安全提取码与限次保护（可选）',
                  style: sansStyle(
                    c,
                    size: 12.6,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 190,
                      child: TextField(
                        controller: _pinCtrl,
                        style: monoStyle(c, size: 13, color: c.ink),
                        decoration: const InputDecoration(
                          hintText: '免口令（或填4-8位提取码）',
                        ),
                      ),
                    ),
                    if (_mode == 'file' || _mode == 'folder')
                      ClaudeSegmented<int>(
                        value: _maxDownloads,
                        items: const [
                          (0, '不限次数'),
                          (1, '1次即焚'),
                          (5, '限5次'),
                          (20, '限20次'),
                        ],
                        onChanged: (v) => setState(() => _maxDownloads = v),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _labelCtrl,
                  style: sansStyle(c, size: 13, color: c.ink),
                  decoration: const InputDecoration(
                    hintText: '可选备注名（留空会自动按文件名或端口号生成）',
                  ),
                ),
                if (_error.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error,
                    style: sansStyle(c, size: 12.2, color: c.clay),
                  ),
                ],
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    ClaudeButton(
                      label: '取消',
                      compact: true,
                      variant: ClaudeBtnVariant.ghost,
                      onPressed:
                          _submitting ? null : () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    ClaudeButton(
                      label: _submitting ? '正在生成链接...' : '生成分享链接',
                      compact: true,
                      loading: _submitting,
                      variant: ClaudeBtnVariant.clay,
                      leading: const Icon(Icons.link_rounded),
                      onPressed: _submit,
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
}

class _ShareQrDialog extends StatelessWidget {
  final String title;
  final String url;
  final VoidCallback onCopy;

  const _ShareQrDialog({
    required this.title,
    required this.url,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final qrImgUrl =
        'https://api.qrserver.com/v1/create-qr-code/?size=240x240&margin=8&data=${Uri.encodeComponent(url)}';

    return Dialog(
      backgroundColor: c.paper2,
      elevation: 0,
      shape: claudeSuperellipse(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: serifTitleStyle(c, size: 18),
              ),
              const SizedBox(height: 6),
              Text(
                '手机相机扫一扫，或直接复制链接发给好友',
                style: sansStyle(c, size: 12.5, color: c.muted),
              ),
              const SizedBox(height: 16),
              Container(
                width: 196,
                height: 196,
                padding: const EdgeInsets.all(12),
                decoration: ShapeDecoration(
                  color: Colors.white,
                  shape: claudeSuperellipse(18),
                ),
                child: Image.network(
                  qrImgUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => CustomPaint(
                    painter: _OfflineMatrixBadgePainter(url.hashCode, c.ink),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                decoration: ShapeDecoration(
                  color: c.recessed,
                  shape: claudeSuperellipse(12),
                ),
                child: SelectableText(
                  url,
                  textAlign: TextAlign.center,
                  style: monoStyle(c, size: 11.8, color: c.inkSoft),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ClaudeButton(
                    label: '关闭',
                    compact: true,
                    variant: ClaudeBtnVariant.ghost,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  ClaudeButton(
                    label: '复制链接',
                    compact: true,
                    variant: ClaudeBtnVariant.clay,
                    leading: const Icon(Icons.copy_rounded),
                    onPressed: () {
                      onCopy();
                      Navigator.of(context).pop();
                    },
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

class _OfflineMatrixBadgePainter extends CustomPainter {
  final int seed;
  final Color color;
  const _OfflineMatrixBadgePainter(this.seed, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = const Color(0xFF1F1E1B);
    const n = 15;
    final cell = math.min(size.width, size.height) / n;
    void finder(int ox, int oy) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(ox * cell, oy * cell, 4 * cell, 4 * cell),
          const Radius.circular(4),
        ),
        p..style = PaintingStyle.stroke..strokeWidth = cell * 0.8,
      );
      canvas.drawRect(
        Rect.fromLTWH((ox + 1.2) * cell, (oy + 1.2) * cell, 1.6 * cell, 1.6 * cell),
        p..style = PaintingStyle.fill,
      );
    }

    finder(1, 1);
    finder(n - 5, 1);
    finder(1, n - 5);
    var s = seed.abs() + 1337;
    for (var y = 1; y < n - 1; y++) {
      for (var x = 1; x < n - 1; x++) {
        if ((x < 6 && y < 6) || (x > n - 7 && y < 6) || (x < 6 && y > n - 7)) {
          continue;
        }
        s = (s * 1103515245 + 12345) & 0x7fffffff;
        if (s % 3 == 0) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(x * cell, y * cell, cell * 0.82, cell * 0.82),
              const Radius.circular(2),
            ),
            p..style = PaintingStyle.fill,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _OfflineMatrixBadgePainter oldDelegate) =>
      oldDelegate.seed != seed;
}

class TailscaleExposureSettingsCard extends StatefulWidget {
  final ConsoleBackend backend;
  final Map<String, dynamic> config;
  final Map<String, dynamic> exposureSummary;
  final Future<void> Function() onRefreshStatus;
  final ValueChanged<String> onToast;

  const TailscaleExposureSettingsCard({
    super.key,
    required this.backend,
    required this.config,
    required this.exposureSummary,
    required this.onRefreshStatus,
    required this.onToast,
  });

  @override
  State<TailscaleExposureSettingsCard> createState() =>
      _TailscaleExposureSettingsCardState();
}

class _TailscaleExposureSettingsCardState
    extends State<TailscaleExposureSettingsCard> {
  bool _probing = false;

  bool get _exposeEnabled => widget.config['expose_enabled'] != false;
  bool get _tsEnabled => widget.config['expose_tailscale_enabled'] != false;
  String get _tsMode {
    final m = (widget.config['expose_tailscale_mode'] ?? 'funnel')
        .toString()
        .toLowerCase();
    return m == 'tailnet' || m == 'serve' ? 'tailnet' : 'funnel';
  }

  bool get _cfFallback =>
      widget.config['expose_cloudflared_fallback'] != false;

  int get _ttlMinutes =>
      int.tryParse('${widget.config['expose_default_ttl_minutes'] ?? 120}') ??
      120;

  Map<String, dynamic> get _tsStatus {
    final raw = widget.exposureSummary['tailscale_status'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const <String, dynamic>{};
  }

  Future<void> _patch(Map<String, dynamic> patch, String toast) async {
    await widget.backend.saveConfig(patch);
    await widget.onRefreshStatus();
    widget.onToast(toast);
  }

  Future<void> _probeTailscale() async {
    if (_probing) return;
    setState(() => _probing = true);
    try {
      await runWithMinDuration(() async {
        await widget.backend.getTailscaleStatus();
        await widget.onRefreshStatus();
      });
      widget.onToast('已刷新 Tailscale 状态');
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final ts = _tsStatus;
    final reachable = ts['reachable'] == true;
    final ips = ((ts['tailscale_ips'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final dns = (ts['dns_name'] ?? '').toString();

    final pillText = !_exposeEnabled
        ? '外网分享已关'
        : (reachable
            ? 'Tailscale 已通${ips.isNotEmpty ? " · ${ips.first}" : ""}'
            : '基础直享就绪');
    final pillActive = _exposeEnabled && reachable;

    return ClaudeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 10,
            runSpacing: 8,
            children: [
              Text('Tailscale 与外网分享设置', style: serifTitleStyle(c, size: 18)),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ClaudePill(
                    leading: ClaudeStatusDot(
                      color: pillActive
                          ? c.sage
                          : (_exposeEnabled ? c.clay : c.meta),
                      pulsing: pillActive,
                      size: 6.5,
                    ),
                    text: pillText,
                    mono: false,
                    fg: pillActive
                        ? c.sage
                        : (_exposeEnabled ? c.inkSoft : c.muted),
                    bg: pillActive ? c.sageBg : c.paper2,
                  ),
                  ClaudeButton(
                    label: _probing ? '检测中...' : '检测 Tailscale',
                    compact: true,
                    loading: _probing,
                    leading: const Icon(Icons.refresh_rounded),
                    onPressed: _probeTailscale,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '控制 AI 能否把做好的文件、文件夹、网页或本地端口生成分享链接，以及是否联动你的 Tailscale 组网。',
            style: sansStyle(c, size: 13, color: c.muted, height: 1.52),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(15),
            decoration: ShapeDecoration(
              color: c.recessed,
              shape: claudeSuperellipse(16),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '允许外网分享与 AI 自动映射 (manage_expose)',
                            style: sansStyle(
                              c,
                              size: 13.5,
                              weight: FontWeight.w600,
                              color: c.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '开启后，对 AI 说一句话即可拿到文件、目录或网站的预览链接；关闭后立即阻断所有外部访问。',
                            style: sansStyle(c, size: 12, color: c.muted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    ClaudeSwitch(
                      value: _exposeEnabled,
                      onChanged: (v) => _patch(
                        {'expose_enabled': v},
                        v ? '已开启外网分享与 AI 映射' : '已关闭外网分享与 AI 映射',
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Divider(color: c.hairline, height: 1),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '启用 Tailscale 组网与 Funnel 联动',
                            style: sansStyle(
                              c,
                              size: 13.5,
                              weight: FontWeight.w600,
                              color: c.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            dns.isNotEmpty
                                ? '已识别节点域名 $dns，开启后自动生成 Tailscale 专属访问链接'
                                : (ips.isNotEmpty
                                    ? '已识别组网地址 ${ips.join(", ")}，同账号手机与设备可直接打开'
                                    : '开启后自动识别本机 Tailscale 100.x 地址及 Serve / Funnel 域名'),
                            style: sansStyle(c, size: 12, color: c.muted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    ClaudeSwitch(
                      value: _tsEnabled,
                      onChanged: !_exposeEnabled
                          ? null
                          : (v) => _patch(
                                {'expose_tailscale_enabled': v},
                                v ? '已启用 Tailscale 分享联动' : '已关闭 Tailscale 分享联动',
                              ),
                    ),
                  ],
                ),
                ClaudeCollapsible(
                  expanded: _exposeEnabled && _tsEnabled,
                  builder: (_) => Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        Text(
                          'Tailscale 默认映射方式',
                          style: sansStyle(c, size: 12.5, color: c.inkSoft),
                        ),
                        ClaudeSegmented<String>(
                          value: _tsMode,
                          items: const [
                            ('funnel', 'Funnel 公网优先'),
                            ('tailnet', '仅组网内私享'),
                          ],
                          onChanged: (v) => _patch(
                            {'expose_tailscale_mode': v},
                            v == 'funnel'
                                ? 'Tailscale 已设为优先尝试 Funnel 公网直连'
                                : 'Tailscale 已设为仅限组网内设备访问',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Divider(color: c.hairline, height: 1),
                ),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '无固定公网域名时自动拉起临时公网隧道',
                            style: sansStyle(
                              c,
                              size: 13.5,
                              weight: FontWeight.w600,
                              color: c.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '分享本地网站端口（如 :3000）或未配置固定域名时，自动用 cloudflared 生成临时 HTTPS 链接。',
                            style: sansStyle(c, size: 12, color: c.muted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    ClaudeSwitch(
                      value: _cfFallback,
                      onChanged: !_exposeEnabled
                          ? null
                          : (v) => _patch(
                                {'expose_cloudflared_fallback': v},
                                v ? '已开启临时公网隧道自动兜底' : '已关闭临时公网隧道兜底',
                              ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Divider(color: c.hairline, height: 1),
                ),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    Text(
                      '新分享默认自动关闭时长',
                      style: sansStyle(
                        c,
                        size: 13,
                        weight: FontWeight.w600,
                        color: c.ink,
                      ),
                    ),
                    ClaudeSegmented<int>(
                      value: const [30, 120, 1440, 0].contains(_ttlMinutes)
                          ? _ttlMinutes
                          : 120,
                      items: const [
                        (30, '30 分钟'),
                        (120, '2 小时'),
                        (1440, '24 小时'),
                        (0, '一直开着'),
                      ],
                      onChanged: !_exposeEnabled
                          ? (_) {}
                          : (v) => _patch(
                                {'expose_default_ttl_minutes': v},
                                v == 0
                                    ? '默认设为一直开着（手动收起）'
                                    : '默认有效期已设为 $v 分钟',
                              ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


class _DashedDropZone extends StatelessWidget {
  final Color borderColor;
  final Color fillColor;
  final double radius;
  final VoidCallback? onTap;
  final Widget child;

  const _DashedDropZone({
    required this.borderColor,
    required this.fillColor,
    required this.child,
    this.radius = 14,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRRectPainter(
        color: borderColor,
        radius: radius,
        strokeWidth: 1.5,
        dashWidth: 6.5,
        dashGap: 4.5,
      ),
      child: Material(
        color: fillColor,
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(radius),
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double strokeWidth;
  final double dashWidth;
  final double dashGap;

  const _DashedRRectPainter({
    required this.color,
    required this.radius,
    this.strokeWidth = 1.5,
    this.dashWidth = 6.5,
    this.dashGap = 4.5,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var dist = 0.0;
      while (dist < metric.length) {
        final next = (dist + dashWidth).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(dist, next), paint);
        dist += dashWidth + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth;
}
