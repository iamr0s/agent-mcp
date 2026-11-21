import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/console_backend.dart';
import '../theme/claude_theme.dart';
import 'profile_endpoints_helper.dart';

class ExposureSharePage extends StatefulWidget {
  final ConsoleBackend backend;
  final Map<String, dynamic> exposureSummary;
  final double topPadding;
  final double extraBottomPadding;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onToast;

  const ExposureSharePage({
    super.key,
    required this.backend,
    required this.exposureSummary,
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
      widget.onToast('已开启外网映射与分享功能');
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
      widget.onToast('已一键关闭全部 $cnt 条分享链接');
    } finally {
      if (mounted) setState(() => _closingAll = false);
    }
  }

  Future<void> _copyText(String text, String tip) async {
    await Clipboard.setData(ClipboardData(text: text));
    widget.onToast(tip);
  }

  Future<void> _openCreateDialog() async {
    final created = await showClaudeDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _CreateExposureDialog(
        backend: widget.backend,
        defaultTtlMinutes: _defaultTtl,
      ),
    );
    if (created != null) {
      await widget.onRefresh();
      final url = (created['primary_url'] ?? '').toString();
      if (url.isNotEmpty) {
        await Clipboard.setData(ClipboardData(text: url));
        widget.onToast('分享已开启并复制链接：$url');
      } else {
        widget.onToast('已创建外网分享');
      }
    }
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
      tsSummary = '已在设置中关闭联动（可在服务配置中随时打开）';
    } else if (tsDns.isNotEmpty) {
      tsSummary =
          '$tsDns · ${_tsMode == "funnel" ? "优先 Funnel 公网直连" : "仅组网内访问"}';
    } else if (tsIps.isNotEmpty) {
      tsSummary = '组网地址 ${tsIps.join(", ")} 已就绪，同账号手机可直接打开';
    } else {
      tsSummary = '当前未检测到活跃组网，启动 Tailscale 后自动识别';
    }

    final gwSummary = _pubBases.isNotEmpty
        ? '已复用公网域名 ${_pubBases.first}，零等待直出外网链接'
        : '本地与局域网直享已就绪；绑定隧道域名后可免开端口直享公网';

    final cfSummary = _cfInstalled
        ? '已就绪：分享本地网站端口或无固定域名时自动生成临时 HTTPS 链接'
        : '未安装 cloudflared（需要临时公网域名时可在服务配置一键下载）';

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
                constraints: const BoxConstraints(maxWidth: 650),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('外网映射与链接分享', style: serifTitleStyle(c, size: 24)),
                    const SizedBox(height: 4),
                    Text(
                      '将本地视频、静态网页或网站端口（如 :3000）生成临时外网链接，随时一键收回。',
                      style: sansStyle(
                        c,
                        size: 12.8,
                        color: c.muted,
                        height: 1.4,
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
                    loading: _refreshing,
                    leading: const Icon(Icons.refresh_rounded),
                    onPressed: _doRefresh,
                  ),
                  if (items.isNotEmpty)
                    ClaudeButton(
                      label: _closingAll ? '关闭中...' : '全部关闭 (${items.length})',
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
                    onPressed: _enabled ? _openCreateDialog : null,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (!_enabled) ...[
            ClaudeCard(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.pause_circle_outline_rounded, color: c.clay, size: 22),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '外网分享当前处于关闭状态',
                          style: sansStyle(
                            c,
                            size: 14,
                            weight: FontWeight.w600,
                            color: c.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '关闭期间 AI 无法通过 manage_expose 创建新链接，已有外部链接也会暂停响应。',
                          style: sansStyle(c, size: 12.4, color: c.muted),
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
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: ShapeDecoration(
              color: c.paper2,
              shape: claudeSuperellipse(14, side: BorderSide(color: c.hairline)),
              shadows: c.whisperShadow,
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
                              'Tailscale · ${!_tsEnabled ? '已关闭' : (tsReachable ? '已连通' : '待启动')}',
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
                              '网关直享 (/share) · ${_pubBases.isNotEmpty ? '公网秒出' : '局域网就绪'}',
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
                              '临时隧道 · ${_cfInstalled ? '按需可用' : '未安装'}',
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
              Icon(Icons.public_rounded, size: 20, color: c.clay),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  hasActiveItems
                      ? '外网分享使用指南 · 两种方式随时调用'
                      : '当前没有活跃的外网分享 · 两种方式随时用起来',
                  style: serifTitleStyle(c, size: 17),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _HowToUseStepRow(
            step: '方式 1',
            title: '直接对 AI 说一句话（最省心）',
            desc:
                '做完视频、静态网页或跑起开发服务器后，直接告诉 AI：“把这个视频映射出来发我链接预览，我看完再关掉”。AI 会自动调用 manage_expose 工具并返回手机可直接点开的播放或预览地址。',
          ),
          const SizedBox(height: 10),
          _HowToUseStepRow(
            step: '方式 2',
            title: '点右上角「新建外网分享」手动创建',
            desc:
                '填入本地端口（如 3000 / 5173）、单个文件（支持 MP4 拖动进度条在线播放、APK 安装包直下）或前端打包文件夹，系统会自动组合 Tailscale 与公网通道生成链接，并按设定时长自动到期关闭。',
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
      padding: const EdgeInsets.all(14),
      decoration: ShapeDecoration(
        color: c.recessed,
        shape: claudeSuperellipse(13, side: BorderSide(color: c.hairline)),
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
                bg: c.clay.withValues(alpha: c.isDark ? 0.16 : 0.10),
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
            style: sansStyle(c, size: 12.4, color: c.muted, height: 1.5),
          ),
        ],
      ),
    );
  }
}

class _ActiveExposureCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool closing;
  final Future<void> Function(String text, String tip) onCopy;
  final ValueChanged<String> onOpenBrowser;
  final VoidCallback onClose;

  const _ActiveExposureCard({
    required this.item,
    required this.closing,
    required this.onCopy,
    required this.onOpenBrowser,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final kind = (item['kind'] ?? 'file').toString();
    final label = (item['label'] ?? '未命名分享').toString();
    final target = (item['target'] ?? '').toString();
    final scope = (item['scope'] ?? 'auto').toString();
    final primaryUrl = (item['primary_url'] ?? '').toString();
    final directFileUrl = (item['direct_file_url'] ?? '').toString();
    final hitCount = int.tryParse('${item['hit_count'] ?? 0}') ?? 0;
    final bytesHuman = (item['bytes_sent_human'] ?? '0 B').toString();
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
      'port' => (Icons.lan_outlined, '本地端口'),
      'dir' => (Icons.web_outlined, '静态网站'),
      _ => (Icons.smart_display_outlined, '文件 / 视频'),
    };

    final scopeText = switch (scope) {
      'tailscale' => '仅 Tailscale 组网',
      'public' => '公网 HTTPS',
      'lan' => '仅局域网',
      _ => '自动优选通道',
    };

    String ttlText = '手动关闭前有效';
    if (remSec != null) {
      final mins = (remSec / 60).ceil();
      ttlText = mins >= 60
          ? '剩余 ${(mins / 60).toStringAsFixed(1)} 小时'
          : '剩余 $mins 分钟';
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

    return ClaudeCard(
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
                ],
              ),
              Text(
                '$scopeText · $ttlText · 访问 $hitCount 次 ($bytesHuman)',
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: ShapeDecoration(
              color: c.recessed,
              shape: claudeSuperellipse(
                12,
                side: BorderSide(color: c.hairline),
              ),
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
                    ClaudeButton(
                      label: '打开预览',
                      compact: true,
                      leading: const Icon(Icons.open_in_new_rounded),
                      onPressed: () => onOpenBrowser(primaryUrl),
                    ),
                    if (copyOptions.length > 1)
                      EndpointCopyDropButton(
                        label: '更多通道 (${copyOptions.length})',
                        options: copyOptions,
                        onSelect: (opt) =>
                            onCopy(opt.url, '已复制 ${opt.badge} 地址：${opt.url}'),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CreateExposureDialog extends StatefulWidget {
  final ConsoleBackend backend;
  final int defaultTtlMinutes;

  const _CreateExposureDialog({
    required this.backend,
    required this.defaultTtlMinutes,
  });

  @override
  State<_CreateExposureDialog> createState() => _CreateExposureDialogState();
}

class _CreateExposureDialogState extends State<_CreateExposureDialog> {
  String _mode = 'port'; // 'port' | 'file' | 'dir'
  final TextEditingController _targetCtrl = TextEditingController(text: '3000');
  final TextEditingController _labelCtrl = TextEditingController();
  String _scope = 'auto';
  late int _ttlMinutes = widget.defaultTtlMinutes;
  bool _spa = false;
  bool _submitting = false;
  String _error = '';

  @override
  void dispose() {
    _targetCtrl.dispose();
    _labelCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final raw = _targetCtrl.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = '请填写端口号或本地文件/目录路径');
      return;
    }
    setState(() {
      _submitting = true;
      _error = '';
    });
    try {
      final res = await widget.backend.openExposure(
        target: raw,
        port: _mode == 'port' ? int.tryParse(raw) : null,
        scope: _scope,
        label: _labelCtrl.text.trim(),
        ttlMinutes: _ttlMinutes,
        spa: _mode == 'dir' && _spa,
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
    final compact = MediaQuery.sizeOf(context).width < 540;

    return Dialog(
      backgroundColor: c.paper2,
      elevation: 0,
      insetPadding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 28,
        vertical: 18,
      ),
      shape: claudeSuperellipse(22, side: BorderSide(color: c.hairline)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            compact ? 18 : 26,
            20,
            compact ? 18 : 26,
            18,
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
                  '你要分享什么内容？',
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
                    ('dir', '静态网页目录'),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _mode = v;
                      _error = '';
                      if (v == 'port' && int.tryParse(_targetCtrl.text) == null) {
                        _targetCtrl.text = '3000';
                      } else if (v != 'port' &&
                          int.tryParse(_targetCtrl.text) != null) {
                        _targetCtrl.clear();
                      }
                    });
                  },
                ),
                const SizedBox(height: 14),
                Text(
                  _mode == 'port'
                      ? '本地端口号（常见如 Next.js 3000、Vite 5173）'
                      : (_mode == 'file'
                          ? '本地文件完整路径（如 D:\\demo.mp4）'
                          : '静态网站目录完整路径（自动识别 index.html）'),
                  style: sansStyle(
                    c,
                    size: 12.6,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 7),
                TextField(
                  controller: _targetCtrl,
                  style: monoStyle(c, size: 13, color: c.ink),
                  decoration: InputDecoration(
                    hintText: _mode == 'port'
                        ? '例如 3000 或 5173'
                        : (_mode == 'file'
                            ? '例如 D:\\agent_mcp_tttmp\\demo.mp4'
                            : '例如 D:\\my_web\\dist'),
                  ),
                ),
                if (_mode == 'port') ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final p in const ['3000', '5173', '8080', '8000', '4173'])
                        ClaudeButton(
                          label: ':$p',
                          compact: true,
                          onPressed: () => setState(() => _targetCtrl.text = p),
                        ),
                    ],
                  ),
                ],
                if (_mode == 'dir') ...[
                  const SizedBox(height: 8),
                  ClaudeCheckToggle(
                    value: _spa,
                    label: '单页前端路由模式（子路径自动回退到 index.html）',
                    onChanged: (v) => setState(() => _spa = v),
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  '谁可以访问？',
                  style: sansStyle(
                    c,
                    size: 12.6,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 7),
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
                const SizedBox(height: 14),
                Text(
                  '自动关闭时间',
                  style: sansStyle(
                    c,
                    size: 12.6,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                const SizedBox(height: 7),
                ClaudeSegmented<int>(
                  value: const [30, 120, 1440, 0].contains(_ttlMinutes)
                      ? _ttlMinutes
                      : 120,
                  items: const [
                    (30, '30 分钟'),
                    (120, '2 小时'),
                    (1440, '24 小时'),
                    (0, '手动关闭'),
                  ],
                  onChanged: (v) => setState(() => _ttlMinutes = v),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _labelCtrl,
                  style: sansStyle(c, size: 13, color: c.ink),
                  decoration: const InputDecoration(
                    hintText: '可选备注名称（如：宣传片初稿预览、新官网测试版）',
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
            '控制 AI 能否把做好的视频、网页或本地端口生成外部访问链接（manage_expose），以及是否联动你的 Tailscale 节点对外分享。',
            style: sansStyle(c, size: 13, color: c.muted, height: 1.52),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: ShapeDecoration(
              color: c.recessed,
              shape: claudeSuperellipse(14, side: BorderSide(color: c.hairline)),
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
                            '开启后，对 AI 说“把这个视频/网站发链接给我预览”即可直接拿到访问地址；关闭后立即阻断所有外网分享。',
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
                        (0, '手动关闭'),
                      ],
                      onChanged: !_exposeEnabled
                          ? (_) {}
                          : (v) => _patch(
                                {'expose_default_ttl_minutes': v},
                                v == 0
                                    ? '默认设为手动关闭前长期有效'
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
