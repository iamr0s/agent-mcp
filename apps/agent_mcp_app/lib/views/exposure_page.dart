import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/console_backend.dart';
import '../theme/prism_theme.dart';
import 'profile_endpoints_helper.dart';

String inferShareModeFromPath(String rawPath) {
  final cleaned = rawPath.trim().replaceAll('"', '');
  final lower = cleaned.toLowerCase();
  if (int.tryParse(lower.replaceAll(':', '')) != null) return 'port';
  if (lower.endsWith('.html') || lower.endsWith('.htm')) return 'site';
  final base =
      cleaned.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull ??
          '';
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
      return raw.map((e) => int.tryParse('$e')).whereType<int>().toList();
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
      widget.onToast('已开启外链分享功能');
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
      widget.onToast('已关闭分享：$label');
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
      widget.onToast('已关闭全部 $cnt 条分享链接');
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
      created = await showPrismDialog<Map<String, dynamic>>(
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
    await showPrismDialog<void>(
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
    final c = PrismPalette.of(context);
    final items = _items;
    final ts = _tsStatus;
    final tsReachable = ts['reachable'] == true;
    final tsIps = ((ts['tailscale_ips'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final tsDns = (ts['dns_name'] ?? '').toString();

    String tsSummary;
    if (!_tsEnabled) {
      tsSummary = '已在服务配置中关闭';
    } else if (tsDns.isNotEmpty) {
      tsSummary =
          '$tsDns · ${_tsMode == "funnel" ? "优先 Funnel 公网直达" : "组网内设备直连"}';
    } else if (tsIps.isNotEmpty) {
      tsSummary = '组网地址 ${tsIps.join(", ")} 已就绪';
    } else {
      tsSummary = '启动 Tailscale 后自动识别组网地址';
    }

    final gwSummary = _pubBases.isNotEmpty
        ? '固定公网网关 ${_pubBases.first}'
        : '局域网直享已就绪（配置隧道域名后可免端口公网直达）';

    final cfSummary = _cfInstalled
        ? 'cloudflared 已安装，按需生成临时 HTTPS 隧道'
        : '未安装 cloudflared（可在服务配置一键下载）';

    final channelReady = _enabled && (tsReachable || _pubBases.isNotEmpty);
    final channelPillLabel = !_enabled
        ? '通道已暂停'
        : (tsReachable && _tsEnabled
            ? 'Tailscale 已通${_pubBases.isNotEmpty ? " · 公网直享" : ""}'
            : (_pubBases.isNotEmpty ? '公网网关就绪' : '局域网直享就绪'));

    return SingleChildScrollView(
      padding: EdgeInsets.only(
        top: widget.topPadding,
        bottom: (MediaQuery.sizeOf(context).width < 700 ? 112 : 36) +
            widget.extraBottomPadding,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PrismEditorialPageHeader(
            eyebrow: 'NETWORK & SHARE',
            leadingDot: PrismStatusDot(
              color: channelReady ? c.sage : (_enabled ? c.clay : c.meta),
              pulsing: channelReady,
              size: 6.0,
            ),
            title: '外网映射与链接分享',
            titleBadge: PrismActionMenuButton(
              label: channelPillLabel,
              tooltip: '查看网络通道就绪状态',
              minMenuWidth: 310,
              leading: PrismStatusDot(
                color: channelReady ? c.sage : (_enabled ? c.clay : c.meta),
                pulsing: channelReady,
                size: 6.5,
              ),
              actions: [
                PrismMenuAction(
                  label: 'Tailscale 组网 / Funnel',
                  subtitle: tsSummary,
                  icon: Icons.hub_rounded,
                  badge: !_tsEnabled ? '已关' : (tsReachable ? '在线' : '待连'),
                  onTap: () {
                    if (tsIps.isNotEmpty) {
                      _copyText(
                        tsIps.first,
                        '已复制本机 Tailscale IP：${tsIps.first}',
                      );
                    } else {
                      _doRefresh();
                    }
                  },
                ),
                PrismMenuAction(
                  label: '网关直享通道 (/share)',
                  subtitle: gwSummary,
                  icon: Icons.bolt_rounded,
                  badge: _pubBases.isNotEmpty ? '公网' : '局域网',
                  onTap: () {
                    if (_pubBases.isNotEmpty) {
                      _copyText(
                        _pubBases.first,
                        '已复制公网网关域名：${_pubBases.first}',
                      );
                    }
                  },
                ),
                PrismMenuAction(
                  label: 'Cloudflared 临时隧道',
                  subtitle: cfSummary,
                  icon: Icons.cloud_outlined,
                  badge: _cfInstalled ? '就绪' : '可选',
                  onTap: _doRefresh,
                ),
                PrismMenuAction(
                  label: '重新检测通道状态',
                  icon: Icons.refresh_rounded,
                  dividerBefore: true,
                  onTap: _doRefresh,
                ),
              ],
            ),
            trailing: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                PrismButton(
                  label: _refreshing ? '刷新中...' : '刷新',
                  compact: true,
                  variant: PrismBtnVariant.ghost,
                  loading: _refreshing,
                  leading: const Icon(Icons.refresh_rounded),
                  onPressed: _doRefresh,
                ),
                if (items.isNotEmpty)
                  PrismButton(
                    label: _closingAll ? '关闭中...' : '全部关闭 (${items.length})',
                    compact: true,
                    loading: _closingAll,
                    leading: const Icon(Icons.link_off_rounded),
                    onPressed: _closeAll,
                  ),
                PrismButton(
                  label: '新建外网分享',
                  compact: true,
                  variant: PrismBtnVariant.clay,
                  leading: const Icon(Icons.add_link_rounded),
                  onPressed: _enabled
                      ? () => _openCreateDialog(initialMode: 'wizard')
                      : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          if (!_enabled) ...[
            PrismListGroup(
              children: [
                PrismSettingsRow(
                  leading: Icon(
                    Icons.pause_circle_outline_rounded,
                    color: c.clay,
                    size: 20,
                  ),
                  title: '外链分享目前已暂停',
                  subtitle: '暂停期间外部无法访问任何分享链接，点击右侧按钮可随时恢复。',
                  trailing: PrismButton(
                    label: _togglingMaster ? '开启中...' : '立即开启',
                    compact: true,
                    loading: _togglingMaster,
                    variant: PrismBtnVariant.clay,
                    onPressed: _enableMasterNow,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          if (_enabled && items.isNotEmpty) ...[
            if (!widget.backend.isAndroidPlatform)
              _DashedDropZone(
                borderColor: c.clay.withValues(alpha: c.isDark ? 0.32 : 0.24),
                fillColor: c.paper2,
                radius: 10,
                onTap: () => _openCreateDialog(initialMode: 'file'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8.5,
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.file_upload_outlined,
                            size: 16,
                            color: c.clay,
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              '拖入文件、目录或 HTML 松手即享',
                              style: sansStyle(
                                c,
                                size: 12.5,
                                weight: FontWeight.w500,
                                color: c.inkSoft,
                              ),
                            ),
                          ),
                        ],
                      ),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          PrismButton(
                            label: '传文件',
                            compact: true,
                            variant: PrismBtnVariant.ghost,
                            onPressed: () =>
                                _openCreateDialog(initialMode: 'file'),
                          ),
                          PrismButton(
                            label: '传目录 / 网站',
                            compact: true,
                            variant: PrismBtnVariant.ghost,
                            onPressed: () =>
                                _openCreateDialog(initialMode: 'folder'),
                          ),
                          PrismButton(
                            label: '映射端口',
                            compact: true,
                            variant: PrismBtnVariant.ghost,
                            onPressed: () =>
                                _openCreateDialog(initialMode: 'port'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 14),
          ],

          if (items.isEmpty)
            _buildEmptyState(c)
          else
            PrismListGroup(
              headerLabel: '活跃分享 (${items.length})',
              dividerIndent: 54,
              children: [
                for (var i = 0; i < items.length; i++)
                  _ActiveExposureRow(
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
            ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(PrismPalette c) {
    final heroBody = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: ShapeDecoration(
              color: c.clay.withValues(alpha: c.isDark ? 0.16 : 0.09),
              shape: prismSuperellipse(13),
            ),
            child: Icon(
              widget.backend.isAndroidPlatform
                  ? Icons.share_arrival_time_outlined
                  : Icons.file_upload_outlined,
              size: 22,
              color: c.clay,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            widget.backend.isAndroidPlatform
                ? '一键生成组网或公网分享链接'
                : '拖入文件、目录或 HTML，松手即生外网链接',
            textAlign: TextAlign.center,
            style: sansStyle(
              c,
              size: 15,
              weight: FontWeight.w600,
              color: c.ink,
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Text(
              '自动识别流式视频、目录树或静态网页，无需手动填表；也可直接对 AI 说“把这个目录做成分享链接”。',
              textAlign: TextAlign.center,
              style: sansStyle(c, size: 12.4, color: c.muted, height: 1.48),
            ),
          ),
          if (_enabled) ...[
            const SizedBox(height: 18),
            if (widget.backend.isAndroidPlatform)
              _MobileQuickShareGrid(
                onOpenMode: (m) => _openCreateDialog(initialMode: m),
              )
            else
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  PrismButton(
                    label: '选择文件',
                    compact: true,
                    variant: PrismBtnVariant.clay,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    onPressed: () => _openCreateDialog(initialMode: 'file'),
                  ),
                  PrismButton(
                    label: '文件夹 / 网站',
                    compact: true,
                    leading: const Icon(Icons.folder_open_rounded),
                    onPressed: () => _openCreateDialog(initialMode: 'folder'),
                  ),
                  PrismButton(
                    label: '映射本地端口',
                    compact: true,
                    leading: const Icon(Icons.podcasts_rounded),
                    onPressed: () => _openCreateDialog(initialMode: 'port'),
                  ),
                ],
              ),
          ],
        ],
      ),
    );

    if (!widget.backend.isAndroidPlatform && _enabled) {
      return _DashedDropZone(
        borderColor: c.clay.withValues(alpha: c.isDark ? 0.36 : 0.26),
        fillColor: c.paper2,
        radius: 22,
        onTap: () => _openCreateDialog(initialMode: 'file'),
        child: heroBody,
      );
    }

    return Container(
      width: double.infinity,
      decoration: ShapeDecoration(
        color: c.paper2,
        shape: prismSuperellipse(
          22,
          side: BorderSide(color: c.hairline.withValues(alpha: 0.62)),
        ),
      ),
      child: heroBody,
    );
  }
}

class _MobileQuickShareGrid extends StatelessWidget {
  final ValueChanged<String> onOpenMode;

  const _MobileQuickShareGrid({required this.onOpenMode});

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    const modes = <(String, IconData, String, String)>[
      ('file', Icons.insert_drive_file_outlined, '单文件', '流式播放 / 直下'),
      ('folder', Icons.folder_open_rounded, '文件夹', '目录树在线浏览'),
      ('site', Icons.web_rounded, '静态网站', 'HTML 全屏运行'),
      ('port', Icons.podcasts_rounded, '端口转发', '本地 Web 服务'),
    ];
    return LayoutBuilder(
      builder: (ctx, box) {
        const gap = 10.0;
        final w = (box.maxWidth - gap) / 2;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final m in modes)
              SizedBox(
                width: w,
                child: Material(
                  color: c.paper2,
                  shape: prismSuperellipse(
                    20,
                    side: BorderSide(
                      color: c.hairline.withValues(alpha: 0.62),
                    ),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => onOpenMode(m.$1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 13,
                        vertical: 12,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: ShapeDecoration(
                              color: c.clay.withValues(
                                alpha: c.isDark ? 0.16 : 0.10,
                              ),
                              shape: prismSuperellipse(12),
                            ),
                            child: Icon(m.$2, size: 17.5, color: c.clay),
                          ),
                          const SizedBox(width: 9),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  m.$3,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: sansStyle(
                                    c,
                                    size: 13,
                                    weight: FontWeight.w600,
                                    color: c.ink,
                                  ),
                                ),
                                Text(
                                  m.$4,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: sansStyle(
                                    c,
                                    size: 11,
                                    color: c.muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ActiveExposureRow extends StatefulWidget {
  final Map<String, dynamic> item;
  final bool closing;
  final Future<void> Function(String text, String tip) onCopy;
  final void Function(String title, String url) onShowQr;
  final ValueChanged<String> onOpenBrowser;
  final VoidCallback onClose;

  const _ActiveExposureRow({
    required this.item,
    required this.closing,
    required this.onCopy,
    required this.onShowQr,
    required this.onOpenBrowser,
    required this.onClose,
  });

  @override
  State<_ActiveExposureRow> createState() => _ActiveExposureRowState();
}

class _ActiveExposureRowState extends State<_ActiveExposureRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final item = widget.item;
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
      'tailscale' => '仅组网',
      'public' => '公网直达',
      'lan' => '局域网',
      _ => '自动优选',
    };

    String ttlText = '常驻';
    if (remSec != null) {
      final mins = (remSec / 60).ceil();
      ttlText = mins >= 60
          ? '${(mins / 60).toStringAsFixed(1)}h 后关闭'
          : '${mins}m 后关闭';
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

    final screenW = MediaQuery.sizeOf(context).width;
    final isNarrow = screenW < 780;

    final actionBar = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        EndpointCopyDropButton(
          label: '复制链接',
          useSplitPrimary: true,
          primaryUrl: primaryUrl,
          onPrimaryTap: () =>
              widget.onCopy(primaryUrl, '已复制分享链接：$primaryUrl'),
          options: copyOptions,
          onSelect: (opt) => widget.onCopy(
            opt.url,
            '已复制 ${opt.badge} 地址：${opt.url}',
          ),
        ),
        PrismButton(
          label: '',
          compact: true,
          variant: PrismBtnVariant.ghost,
          tooltip: '查看二维码',
          leading: const Icon(Icons.qr_code_rounded, size: 16),
          onPressed: () => widget.onShowQr(label, primaryUrl),
        ),
        PrismButton(
          label: '',
          compact: true,
          variant: PrismBtnVariant.ghost,
          tooltip: '浏览器打开预览',
          leading: const Icon(Icons.open_in_new_rounded, size: 16),
          onPressed: () => widget.onOpenBrowser(primaryUrl),
        ),
        PrismButton(
          label: '',
          compact: true,
          loading: widget.closing,
          variant: PrismBtnVariant.ghost,
          tooltip: '关闭分享',
          leading: Icon(
            Icons.link_off_rounded,
            size: 16,
            color: _hovered ? c.danger : c.muted,
          ),
          onPressed: widget.onClose,
        ),
      ],
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        color: _hovered
            ? (c.isDark
                ? Colors.white.withValues(alpha: 0.024)
                : Colors.black.withValues(alpha: 0.016))
            : Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: ShapeDecoration(
                        color: c.clay.withValues(
                          alpha: c.isDark ? 0.16 : 0.10,
                        ),
                        shape: prismSuperellipse(13.5),
                      ),
                      alignment: Alignment.center,
                      child: Icon(kindIcon, size: 18.5, color: c.clay),
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: c.sage,
                          shape: BoxShape.circle,
                          border: Border.all(color: c.paper2, width: 1.8),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 7,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            label,
                            style: sansStyle(
                              c,
                              size: 13.8,
                              weight: FontWeight.w600,
                              color: c.ink,
                            ),
                          ),
                          PrismPill(
                            text: kindLabel,
                            mono: false,
                            fg: c.sage,
                            bg: c.sageBg,
                          ),
                          if (hasPin)
                            GestureDetector(
                              onTap: pinCode.isNotEmpty
                                  ? () => widget.onCopy(
                                        pinCode,
                                        '已复制提取码：$pinCode',
                                      )
                                  : null,
                              child: PrismPill(
                                text: pinCode.isNotEmpty
                                    ? '提取码 $pinCode'
                                    : '口令保护',
                                mono: false,
                                fg: c.clay,
                                bg: c.clay.withValues(alpha: 0.12),
                              ),
                            ),
                          Text(
                            '$scopeText · $ttlText${remDl != null ? " · 剩余 $remDl 次" : ""} · $hitCount 次访问 ($bytesHuman)',
                            style: sansStyle(
                              c,
                              size: 11.5,
                              color: c.muted,
                              tabular: true,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        primaryUrl,
                        maxLines: 1,
                        style: monoStyle(
                          c,
                          size: 12.2,
                          weight: FontWeight.w500,
                          color: c.clay,
                        ),
                      ),
                      if (target.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          target,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(c, size: 11, color: c.meta),
                        ),
                      ],
                    ],
                  ),
                ),
                if (!isNarrow) ...[
                  const SizedBox(width: 12),
                  actionBar,
                ],
              ],
            ),
            if (isNarrow) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: 52),
                child: actionBar,
              ),
            ],
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
  late String _mode =
      widget.initialMode == 'wizard' ? 'folder' : widget.initialMode;
  late bool _inStep1 = widget.initialMode == 'wizard' &&
      (widget.initialTarget == null || widget.initialTarget!.trim().isEmpty);
  bool _folderStep = false;
  late final TextEditingController _targetCtrl = TextEditingController(
    text: (widget.initialTarget != null &&
            widget.initialTarget!.trim().isNotEmpty)
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
  int _maxDownloads = 0;
  bool _spa = false;
  bool _showAdvancedOptions = false;
  bool _editingRawPath = false;
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
        _editingRawPath = false;
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
    final c = PrismPalette.of(context);
    final compact = MediaQuery.sizeOf(context).width < 560;
    final curRaw = _targetCtrl.text.trim();
    final curText = curRaw.toLowerCase();
    final isHtmlTarget = curText.endsWith('.html') || curText.endsWith('.htm');
    final targetBasename = curRaw
            .split(RegExp(r'[/\\]'))
            .where((s) => s.isNotEmpty)
            .lastOrNull ??
        curRaw;

    final scopeSummary = switch (_scope) {
      'tailscale' => '仅 Tailscale',
      'public' => '公网直达',
      'lan' => '仅局域网',
      _ => '智能优选',
    };
    final ttlSummary = switch (_ttlMinutes) {
      30 => '30 分钟',
      120 => '2 小时',
      1440 => '24 小时',
      0 => '常驻开启',
      _ => '$_ttlMinutes 分钟',
    };
    final pinSummary = _pinCtrl.text.trim().isNotEmpty
        ? '已设提取码'
        : (_maxDownloads == 1
            ? '1次即焚'
            : (_maxDownloads > 0 ? '限 $_maxDownloads 次' : '免口令'));

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
      backgroundColor: c.paper,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 28,
        vertical: 18,
      ),
      shape: prismSuperellipse(
        28,
        side: BorderSide(color: c.hairline.withValues(alpha: 0.72)),
      ),
      child: PopScope(
        canPop: _inStep1 || widget.initialMode != 'wizard',
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && mounted) {
            setState(() => _inStep1 = true);
          }
        },
        child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600, maxHeight: 740),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 18 : 22,
                16,
                compact ? 14 : 18,
                14,
              ),
              child: Row(
                children: [
                  const PrismSparkIcon(size: 18),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      '新建外网映射与分享',
                      style: serifTitleStyle(c, size: 17.5),
                    ),
                  ),
                  PrismButton(
                    label: '',
                    compact: true,
                    variant: PrismBtnVariant.ghost,
                    leading: const Icon(Icons.close_rounded, size: 18),
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Divider(color: c.hairline, height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  compact ? 18 : 22,
                  16,
                  compact ? 18 : 22,
                  16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_inStep1) ...[
                      Text(
                        '第 1 步 · 选择要分享的内容类型',
                        style: sansStyle(
                          c,
                          size: 13,
                          weight: FontWeight.w600,
                          color: c.ink,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _WizardChoiceCard(
                        icon: Icons.insert_drive_file_outlined,
                        title: '单个文件',
                        subtitle: '视频流式播放、PDF / 图片直接预览、APK 或安装包高速直下',
                        onTap: () => setState(() {
                          _mode = 'file';
                          _folderStep = false;
                          _inStep1 = false;
                        }),
                      ),
                      const SizedBox(height: 8),
                      _WizardChoiceCard(
                        icon: Icons.folder_open_rounded,
                        title: '文件夹 / 静态网站',
                        subtitle: '下一步选择作为「文件夹目录共享」或「静态网站目录」发布',
                        onTap: () => setState(() {
                          _mode = 'folder';
                          _folderStep = true;
                          _inStep1 = false;
                        }),
                      ),
                      const SizedBox(height: 8),
                      _WizardChoiceCard(
                        icon: Icons.podcasts_rounded,
                        title: '本地端口转发',
                        subtitle: '把本机 :3000 / :5173 等 Web 服务与 WebSocket 实时映射出去',
                        onTap: () => setState(() {
                          _mode = 'port';
                          _folderStep = false;
                          _inStep1 = false;
                          if (_targetCtrl.text.trim().isEmpty) {
                            _targetCtrl.text =
                                widget.activeLocalPorts.isNotEmpty
                                    ? '${widget.activeLocalPorts.first}'
                                    : '3000';
                          }
                        }),
                      ),
                    ] else ...[
                      if (_folderStep) ...[
                        Row(
                          children: [
                            PrismButton(
                              label: '更换类型',
                              compact: true,
                              variant: PrismBtnVariant.ghost,
                              leading: const Icon(
                                Icons.arrow_back_ios_new_rounded,
                                size: 13,
                              ),
                              onPressed: () => setState(() => _inStep1 = true),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '第 2 步 · 选择文件夹分享方式',
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
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _FolderKindChip(
                                icon: Icons.folder_shared_outlined,
                                title: '文件夹目录共享',
                                subtitle: '列表浏览与文件下载',
                                active: _mode == 'folder',
                                onTap: () => setState(() => _mode = 'folder'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _FolderKindChip(
                                icon: Icons.web_rounded,
                                title: '静态网站目录',
                                subtitle: '直接作为网页运行',
                                active: _mode == 'site',
                                onTap: () => setState(() => _mode = 'site'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                      ] else if (widget.initialMode == 'wizard') ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: PrismButton(
                            label: '更换分享类型',
                            compact: true,
                            variant: PrismBtnVariant.ghost,
                            leading: const Icon(
                              Icons.arrow_back_ios_new_rounded,
                              size: 13,
                            ),
                            onPressed: () => setState(() => _inStep1 = true),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (!_folderStep)
                        _ExposureBentoModeGrid(
                          value: _mode,
                          onChanged: (v) {
                            setState(() {
                              _mode = v;
                              _error = '';
                              _editingRawPath = false;
                              if (v == 'port' &&
                                  int.tryParse(_targetCtrl.text.trim()) ==
                                      null) {
                                _targetCtrl.text =
                                    widget.activeLocalPorts.isNotEmpty
                                        ? '${widget.activeLocalPorts.first}'
                                        : '3000';
                              } else if (v != 'port' &&
                                  int.tryParse(_targetCtrl.text.trim()) !=
                                      null) {
                                _targetCtrl.clear();
                              }
                            });
                          },
                        ),
                      if (!_folderStep) const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(15),
                        decoration: ShapeDecoration(
                          color: c.paper2,
                          shape: prismSuperellipse(
                            20,
                            side: BorderSide(
                              color: c.hairline.withValues(alpha: 0.65),
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (_mode == 'port') ...[
                              Row(
                                children: [
                                  Container(
                                    width: 38,
                                    height: 38,
                                    decoration: ShapeDecoration(
                                      color: c.clay.withValues(
                                        alpha: c.isDark ? 0.16 : 0.10,
                                      ),
                                      shape: prismSuperellipse(13),
                                    ),
                                    child: Icon(
                                      Icons.podcasts_rounded,
                                      size: 17.5,
                                      color: c.clay,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '本地监听端口',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: sansStyle(
                                            c,
                                            size: 13.0,
                                            weight: FontWeight.w600,
                                            color: c.ink,
                                          ),
                                        ),
                                        Text(
                                          '实时转发本机 Web 服务与 HMR',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: sansStyle(
                                            c,
                                            size: 11.4,
                                            color: c.muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  SizedBox(
                                    width: 92,
                                    child: TextField(
                                      controller: _targetCtrl,
                                      keyboardType: TextInputType.number,
                                      onChanged: _onTargetChanged,
                                      style: monoStyle(
                                        c,
                                        size: 13.2,
                                        weight: FontWeight.w600,
                                        color: c.ink,
                                      ),
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        prefixText: ':',
                                        hintText: '3000',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final p in defaultPorts)
                                    PrismButton(
                                      label:
                                          widget.activeLocalPorts.contains(p)
                                              ? ':$p · 在线'
                                              : ':$p',
                                      compact: true,
                                      variant:
                                          _targetCtrl.text.trim() == '$p' ||
                                                  widget.activeLocalPorts
                                                      .contains(p)
                                              ? PrismBtnVariant.clay
                                              : PrismBtnVariant.neutral,
                                      onPressed: () => setState(
                                        () => _targetCtrl.text = '$p',
                                      ),
                                    ),
                                ],
                              ),
                            ] else ...[
                              LayoutBuilder(
                                builder: (ctx, cardBox) {
                                  final wideTarget = cardBox.maxWidth >= 430;
                                  final targetHeader = Row(
                                    children: [
                                      Container(
                                        width: 38,
                                        height: 38,
                                        decoration: ShapeDecoration(
                                          color: c.clay.withValues(
                                            alpha: c.isDark ? 0.16 : 0.10,
                                          ),
                                          shape: prismSuperellipse(13),
                                        ),
                                        child: Icon(
                                          _mode == 'folder'
                                              ? Icons.folder_open_rounded
                                              : (_mode == 'site'
                                                  ? Icons.web_rounded
                                                  : Icons
                                                      .insert_drive_file_outlined),
                                          size: 16.5,
                                          color: c.clay,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              curRaw.isNotEmpty
                                                  ? targetBasename
                                                  : '尚未选择目标',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: sansStyle(
                                                c,
                                                size: 13.2,
                                                weight: FontWeight.w600,
                                                color: c.ink,
                                              ),
                                            ),
                                            const SizedBox(height: 2),
                                            Text(
                                              curRaw.isNotEmpty
                                                  ? curRaw
                                                  : modeHelp,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: curRaw.isNotEmpty
                                                  ? monoStyle(
                                                      c,
                                                      size: 11.4,
                                                      color: c.muted,
                                                    )
                                                  : sansStyle(
                                                      c,
                                                      size: 11.5,
                                                      color: c.muted,
                                                    ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  );

                                  final actionButtons = Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    children: [
                                      if (!widget.backend.isAndroidPlatform) ...[
                                        if (_mode == 'file' || _mode == 'site')
                                          PrismButton(
                                            label: _picking
                                                ? '选择中...'
                                                : (_mode == 'site'
                                                    ? '选 HTML 文件'
                                                    : (curRaw.isEmpty
                                                        ? '选文件...'
                                                        : '更换文件')),
                                            compact: true,
                                            variant: curRaw.isEmpty
                                                ? PrismBtnVariant.clay
                                                : PrismBtnVariant.neutral,
                                            leading: const Icon(
                                              Icons.insert_drive_file_outlined,
                                            ),
                                            onPressed: _picking
                                                ? null
                                                : () => _pickPath(
                                                      directory: false,
                                                    ),
                                          ),
                                        if (_mode == 'folder' ||
                                            _mode == 'site')
                                          PrismButton(
                                            label: _picking
                                                ? '选择中...'
                                                : (_mode == 'site'
                                                    ? '选网站文件夹'
                                                    : (curRaw.isEmpty
                                                        ? '选文件夹...'
                                                        : '更换目录')),
                                            compact: true,
                                            variant: curRaw.isEmpty &&
                                                    _mode == 'folder'
                                                ? PrismBtnVariant.clay
                                                : PrismBtnVariant.neutral,
                                            leading: const Icon(
                                              Icons.folder_open_rounded,
                                            ),
                                            onPressed: _picking
                                                ? null
                                                : () =>
                                                    _pickPath(directory: true),
                                          ),
                                      ],
                                      PrismButton(
                                        label: _editingRawPath ? '完成' : '粘贴路径',
                                        compact: true,
                                        tooltip: _editingRawPath
                                            ? '收起手动路径框'
                                            : '手动输入或粘贴路径',
                                        variant: _editingRawPath
                                            ? PrismBtnVariant.neutral
                                            : PrismBtnVariant.ghost,
                                        onPressed: () => setState(
                                          () => _editingRawPath =
                                              !_editingRawPath,
                                        ),
                                      ),
                                    ],
                                  );

                                  if (wideTarget) {
                                    return Row(
                                      children: [
                                        Expanded(child: targetHeader),
                                        const SizedBox(width: 10),
                                        actionButtons,
                                      ],
                                    );
                                  }
                                  return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      targetHeader,
                                      const SizedBox(height: 10),
                                      actionButtons,
                                    ],
                                  );
                                },
                              ),
                              PrismCollapsible(
                                expanded: _editingRawPath ||
                                    widget.backend.isAndroidPlatform ||
                                    widget.backend.isWebMode,
                                builder: (_) => Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: TextField(
                                    controller: _targetCtrl,
                                    onChanged: _onTargetChanged,
                                    style: monoStyle(
                                      c,
                                      size: 12.6,
                                      color: c.ink,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      hintText: hintText,
                                    ),
                                  ),
                                ),
                              ),
                              if (isHtmlTarget &&
                                  (_mode == 'file' || _mode == 'site')) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Icon(
                                      Icons.tips_and_updates_outlined,
                                      size: 13.5,
                                      color: c.clay,
                                    ),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        _mode == 'site'
                                            ? '该 .html 将直接作为网页全屏运行；若仅提供下载可切至「单个文件」。'
                                            : '检测到 .html：切至「静态网页」可让对方打开直接运行网页。',
                                        style: sansStyle(
                                          c,
                                          size: 11.5,
                                          color: c.clay,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      PrismListGroup(
                        children: [
                          PrismSettingsRow(
                            onTap: () => setState(
                              () =>
                                  _showAdvancedOptions = !_showAdvancedOptions,
                            ),
                            leading: Icon(
                              Icons.tune_rounded,
                              size: 15.5,
                              color: _showAdvancedOptions ? c.clay : c.meta,
                            ),
                            title: '默认策略：$scopeSummary · $ttlSummary · $pinSummary',
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '高级保护',
                                  style: sansStyle(
                                    c,
                                    size: 11.8,
                                    weight: FontWeight.w500,
                                    color: _showAdvancedOptions
                                        ? c.clay
                                        : c.muted,
                                  ),
                                ),
                                const SizedBox(width: 2),
                                Icon(
                                  _showAdvancedOptions
                                      ? Icons.keyboard_arrow_up_rounded
                                      : Icons.keyboard_arrow_down_rounded,
                                  size: 17,
                                  color: c.meta,
                                ),
                              ],
                            ),
                          ),
                          PrismCollapsible(
                            expanded: _showAdvancedOptions,
                            builder: (_) => Padding(
                              padding: const EdgeInsets.fromLTRB(
                                14,
                                12,
                                14,
                                14,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    alignment: WrapAlignment.spaceBetween,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    spacing: 10,
                                    runSpacing: 8,
                                    children: [
                                      Text(
                                        '通道范围',
                                        style: sansStyle(
                                          c,
                                          size: 12.2,
                                          color: c.muted,
                                        ),
                                      ),
                                      PrismSegmented<String>(
                                        value: _scope,
                                        items: const [
                                          ('auto', '智能优选'),
                                          ('tailscale', '仅 Tailscale'),
                                          ('public', '公网直达'),
                                          ('lan', '仅局域网'),
                                        ],
                                        onChanged: (v) =>
                                            setState(() => _scope = v),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    alignment: WrapAlignment.spaceBetween,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    spacing: 10,
                                    runSpacing: 8,
                                    children: [
                                      Text(
                                        '有效时长',
                                        style: sansStyle(
                                          c,
                                          size: 12.2,
                                          color: c.muted,
                                        ),
                                      ),
                                      PrismSegmented<int>(
                                        value: const [30, 120, 1440, 0]
                                                .contains(_ttlMinutes)
                                            ? _ttlMinutes
                                            : 120,
                                        items: const [
                                          (30, '30 分钟'),
                                          (120, '2 小时'),
                                          (1440, '24 小时'),
                                          (0, '一直开着'),
                                        ],
                                        onChanged: (v) =>
                                            setState(() => _ttlMinutes = v),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 8,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      SizedBox(
                                        width: 190,
                                        child: TextField(
                                          controller: _pinCtrl,
                                          onChanged: (_) => setState(() {}),
                                          style: monoStyle(
                                            c,
                                            size: 12.6,
                                            color: c.ink,
                                          ),
                                          decoration: const InputDecoration(
                                            isDense: true,
                                            hintText: '免口令（或填4-8位提取码）',
                                          ),
                                        ),
                                      ),
                                      if (_mode == 'file' || _mode == 'folder')
                                        PrismSegmented<int>(
                                          value: _maxDownloads,
                                          items: const [
                                            (0, '不限次数'),
                                            (1, '1次即焚'),
                                            (5, '限5次'),
                                            (20, '限20次'),
                                          ],
                                          onChanged: (v) => setState(
                                            () => _maxDownloads = v,
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  TextField(
                                    controller: _labelCtrl,
                                    style: sansStyle(
                                      c,
                                      size: 12.6,
                                      color: c.ink,
                                    ),
                                    decoration: const InputDecoration(
                                      isDense: true,
                                      hintText: '可选备注名（留空自动按文件名或端口号生成）',
                                    ),
                                  ),
                                  if (_mode == 'site') ...[
                                    const SizedBox(height: 10),
                                    PrismCheckToggle(
                                      value: _spa,
                                      label: '前端单页应用路由模式（未知子路径回退至 index.html）',
                                      onChanged: (v) =>
                                          setState(() => _spa = v),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_error.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          _error,
                          style: sansStyle(c, size: 12, color: c.danger),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            Divider(color: c.hairline, height: 1),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 18 : 22,
                12,
                compact ? 18 : 22,
                14,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PrismButton(
                    label: '取消',
                    compact: true,
                    variant: PrismBtnVariant.ghost,
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                  if (!_inStep1) ...[
                    const SizedBox(width: 8),
                    PrismButton(
                      label: _submitting ? '正在生成链接...' : '生成分享链接',
                      compact: true,
                      loading: _submitting,
                      variant: PrismBtnVariant.clay,
                      leading: const Icon(Icons.link_rounded),
                      onPressed: _submit,
                    ),
                  ],
                ],
              ),
            ),
          ],
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
    final c = PrismPalette.of(context);
    final qrImgUrl =
        'https://api.qrserver.com/v1/create-qr-code/?size=240x240&margin=8&data=${Uri.encodeComponent(url)}';

    return Dialog(
      backgroundColor: c.paper,
      elevation: 0,
      shape: prismSuperellipse(
        28,
        side: BorderSide(color: c.hairline.withValues(alpha: 0.72)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: serifTitleStyle(c, size: 17),
              ),
              const SizedBox(height: 5),
              Text(
                '手机相机扫一扫，或直接复制链接发给好友',
                style: sansStyle(c, size: 12, color: c.muted),
              ),
              const SizedBox(height: 16),
              Container(
                width: 196,
                height: 196,
                padding: const EdgeInsets.all(12),
                decoration: ShapeDecoration(
                  color: Colors.white,
                  shape: prismSuperellipse(
                    20,
                    side: BorderSide(color: c.hairline.withValues(alpha: 0.65)),
                  ),
                ),
                child: Image.network(
                  qrImgUrl,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => CustomPaint(
                    painter: _OfflineMatrixBadgePainter(
                      url.hashCode,
                      const Color(0xFF0F172A),
                    ),
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
                  shape: prismSuperellipse(
                    16,
                    side: BorderSide(color: c.hairline.withValues(alpha: 0.65)),
                  ),
                ),
                child: SelectableText(
                  url,
                  textAlign: TextAlign.center,
                  style: monoStyle(c, size: 11.6, color: c.inkSoft),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  PrismButton(
                    label: '关闭',
                    compact: true,
                    variant: PrismBtnVariant.ghost,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  PrismButton(
                    label: '复制链接',
                    compact: true,
                    variant: PrismBtnVariant.clay,
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
    final p = Paint()..color = color;
    const n = 15;
    final cell = math.min(size.width, size.height) / n;
    void finder(int ox, int oy) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(ox * cell, oy * cell, 4 * cell, 4 * cell),
          const Radius.circular(4),
        ),
        p
          ..style = PaintingStyle.stroke
          ..strokeWidth = cell * 0.8,
      );
      canvas.drawRect(
        Rect.fromLTWH(
          (ox + 1.2) * cell,
          (oy + 1.2) * cell,
          1.6 * cell,
          1.6 * cell,
        ),
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
      oldDelegate.seed != seed || oldDelegate.color != color;
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
    final c = PrismPalette.of(context);
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

    return PrismListGroup(
      headerLabel: 'Tailscale 与外网分享设置',
      headerTrailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PrismPill(
            leading: PrismStatusDot(
              color: pillActive
                  ? c.sage
                  : (_exposeEnabled ? c.clay : c.meta),
              pulsing: pillActive,
              size: 6.5,
            ),
            text: pillText,
            mono: false,
            fg: pillActive ? c.sage : (_exposeEnabled ? c.inkSoft : c.muted),
            bg: pillActive ? c.sageBg : c.paper2,
          ),
          const SizedBox(width: 8),
          PrismButton(
            label: _probing ? '检测中...' : '检测 Tailscale',
            compact: true,
            loading: _probing,
            leading: const Icon(Icons.refresh_rounded),
            onPressed: _probeTailscale,
          ),
        ],
      ),
      children: [
        PrismSettingsRow(
          title: '允许外网分享与 AI 自动映射 (manage_expose)',
          subtitle: '开启后对 AI 说一句话即可拿到文件、目录或网站的预览链接；关闭后立即阻断所有外部访问。',
          trailing: PrismSwitch(
            value: _exposeEnabled,
            onChanged: (v) => _patch(
              {'expose_enabled': v},
              v ? '已开启外网分享与 AI 映射' : '已关闭外网分享与 AI 映射',
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PrismSettingsRow(
              title: '启用 Tailscale 组网与 Funnel 联动',
              subtitle: dns.isNotEmpty
                  ? '已识别节点域名 $dns，自动生成 Tailscale 专属访问链接'
                  : (ips.isNotEmpty
                      ? '已识别组网地址 ${ips.join(", ")}，同账号设备可直接打开'
                      : '开启后自动识别本机 Tailscale 100.x 地址及 Serve / Funnel 域名'),
              trailing: PrismSwitch(
                value: _tsEnabled,
                onChanged: !_exposeEnabled
                    ? null
                    : (v) => _patch(
                          {'expose_tailscale_enabled': v},
                          v ? '已启用 Tailscale 分享联动' : '已关闭 Tailscale 分享联动',
                        ),
              ),
            ),
            PrismCollapsible(
              expanded: _exposeEnabled && _tsEnabled,
              builder: (_) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    Text(
                      'Tailscale 默认映射方式',
                      style: sansStyle(c, size: 12.2, color: c.muted),
                    ),
                    PrismSegmented<String>(
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
          ],
        ),
        PrismSettingsRow(
          title: '无固定公网域名时自动拉起临时公网隧道',
          subtitle: '分享本地网站端口（如 :3000）或未配置固定域名时，自动用 cloudflared 生成临时 HTTPS 链接。',
          trailing: PrismSwitch(
            value: _cfFallback,
            onChanged: !_exposeEnabled
                ? null
                : (v) => _patch(
                      {'expose_cloudflared_fallback': v},
                      v ? '已开启临时公网隧道自动兜底' : '已关闭临时公网隧道兜底',
                    ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Wrap(
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
                  weight: FontWeight.w500,
                  color: c.ink,
                ),
              ),
              PrismSegmented<int>(
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
        ),
      ],
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
    this.radius = 12,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      foregroundPainter: _DashedRRectPainter(
        color: borderColor,
        radius: radius,
        strokeWidth: 1.4,
        dashWidth: 6.0,
        dashGap: 4.0,
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
    this.strokeWidth = 1.4,
    this.dashWidth = 6.0,
    this.dashGap = 4.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final inset = strokeWidth / 2 + 0.5;
    final rrect = RRect.fromRectAndRadius(
      (Offset.zero & size).deflate(inset),
      Radius.circular((radius - inset).clamp(0.0, radius)),
    );
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

class _WizardChoiceCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _WizardChoiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  State<_WizardChoiceCard> createState() => _WizardChoiceCardState();
}

class _WizardChoiceCardState extends State<_WizardChoiceCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
          decoration: ShapeDecoration(
            color: _hovered
                ? c.clay.withValues(alpha: c.isDark ? 0.14 : 0.06)
                : c.paper2,
            shape: prismSuperellipse(
              20,
              side: BorderSide(
                color: _hovered
                    ? c.clay.withValues(alpha: 0.45)
                    : c.hairline.withValues(alpha: 0.65),
              ),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: ShapeDecoration(
                  color: c.clay.withValues(alpha: c.isDark ? 0.18 : 0.10),
                  shape: prismSuperellipse(13.5),
                ),
                child: Icon(widget.icon, size: 18.5, color: c.clay),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: sansStyle(
                        c,
                        size: 13.8,
                        weight: FontWeight.w600,
                        color: c.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.subtitle,
                      style: sansStyle(c, size: 11.8, color: c.muted),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: c.meta),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2×2 Sculptural Bento Mode Grid for Share Creation Dialog.
/// Eliminates cramped 4-column single-row pill clipping on narrow viewports.
class _ExposureBentoModeGrid extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _ExposureBentoModeGrid({
    required this.value,
    required this.onChanged,
  });

  static const _modes = <(String, IconData, String, String)>[
    ('port', Icons.podcasts_rounded, '端口映射', '本地 Web 与热重载'),
    ('file', Icons.insert_drive_file_outlined, '单个文件', '流式预览与直链'),
    ('folder', Icons.folder_open_rounded, '文件夹', '目录树浏览与下载'),
    ('site', Icons.web_rounded, '静态网页', '独立 HTML 站点直出'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: _ExposureBentoModeTile(
                icon: _modes[0].$2,
                title: _modes[0].$3,
                subtitle: _modes[0].$4,
                active: value == _modes[0].$1,
                onTap: () => onChanged(_modes[0].$1),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ExposureBentoModeTile(
                icon: _modes[1].$2,
                title: _modes[1].$3,
                subtitle: _modes[1].$4,
                active: value == _modes[1].$1,
                onTap: () => onChanged(_modes[1].$1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _ExposureBentoModeTile(
                icon: _modes[2].$2,
                title: _modes[2].$3,
                subtitle: _modes[2].$4,
                active: value == _modes[2].$1,
                onTap: () => onChanged(_modes[2].$1),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _ExposureBentoModeTile(
                icon: _modes[3].$2,
                title: _modes[3].$3,
                subtitle: _modes[3].$4,
                active: value == _modes[3].$1,
                onTap: () => onChanged(_modes[3].$1),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ExposureBentoModeTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool active;
  final VoidCallback onTap;

  const _ExposureBentoModeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.active,
    required this.onTap,
  });

  @override
  State<_ExposureBentoModeTile> createState() => _ExposureBentoModeTileState();
}

class _ExposureBentoModeTileState extends State<_ExposureBentoModeTile> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final active = widget.active;
    final bg = active
        ? c.clay
        : (_hovered ? c.paper3.withValues(alpha: 0.75) : c.paper2);
    final titleFg = active ? c.onClay : c.ink;
    final subFg =
        active ? c.onClay.withValues(alpha: 0.72) : c.muted;
    final iconFg = active ? c.onClay : c.inkSoft;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _pressed ? 0.97 : 1.0,
          duration: PrismMotion.duration(
            context,
            const Duration(milliseconds: 120),
          ),
          curve: PrismMotion.snappySpring,
          child: AnimatedContainer(
            duration: PrismMotion.duration(
              context,
              const Duration(milliseconds: 180),
            ),
            curve: PrismMotion.editorialOut,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
            decoration: ShapeDecoration(
              color: bg,
              shape: prismSuperellipse(
                18,
                side: BorderSide(
                  color: active
                      ? c.clay
                      : (_hovered
                          ? c.ringHover
                          : c.hairline.withValues(alpha: 0.65)),
                ),
              ),
              shadows: active
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: c.isDark ? 0.42 : 0.14,
                        ),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : const [],
            ),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: ShapeDecoration(
                    color: active
                        ? c.onClay.withValues(alpha: 0.14)
                        : c.recessed,
                    shape: prismSuperellipse(10),
                  ),
                  alignment: Alignment.center,
                  child: Icon(widget.icon, size: 15, color: iconFg),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sansStyle(
                          c,
                          size: 12.6,
                          weight: FontWeight.w600,
                          color: titleFg,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 1.5),
                      Text(
                        widget.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sansStyle(
                          c,
                          size: 10.6,
                          color: subFg,
                          height: 1.2,
                        ),
                      ),
                    ],
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

class _FolderKindChip extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool active;
  final VoidCallback onTap;

  const _FolderKindChip({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: ShapeDecoration(
          color: active
              ? c.clay.withValues(alpha: c.isDark ? 0.18 : 0.09)
              : c.paper2,
          shape: prismSuperellipse(
            18,
            side: BorderSide(
              color: active ? c.clay : c.hairline.withValues(alpha: 0.65),
              width: active ? 1.3 : 1.0,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 15.5, color: active ? c.clay : c.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sansStyle(
                      c,
                      size: 12.8,
                      weight: FontWeight.w600,
                      color: active ? c.clay : c.ink,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: sansStyle(c, size: 11.2, color: c.muted),
            ),
          ],
        ),
      ),
    );
  }
}
