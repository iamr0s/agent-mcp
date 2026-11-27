import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/console_backend.dart';
import '../theme/prism_theme.dart';

enum UpdateDialogOutcome {
  later,
  skipThisVersion,
  openedDownloadPage,
  launchedInstaller,
}

Future<UpdateDownloadChannel?> showUpdateChannelsDialog({
  required BuildContext context,
  required ConsoleBackend backend,
  required UpdateInfo latest,
  String mirrorPrefix = '',
  ValueChanged<String>? onToast,
}) {
  return showPrismDialog<UpdateDownloadChannel>(
    context: context,
    builder: (_) => _UpdateChannelsDialog(
      backend: backend,
      latest: latest,
      mirrorPrefix: mirrorPrefix,
      onToast: onToast,
    ),
  );
}

IconData _iconForChannel(UpdateDownloadChannel ch) {
  final token = '${ch.id} ${ch.name} ${ch.url}'.toLowerCase();
  if (token.contains('quark') || token.contains('夸克')) {
    return Icons.bolt_rounded;
  }
  if (token.contains('123') || token.contains('直链')) {
    return Icons.rocket_launch_rounded;
  }
  if (token.contains('baidu') || token.contains('百度')) {
    return Icons.cloud_circle_outlined;
  }
  if (token.contains('ali') || token.contains('阿里')) {
    return Icons.folder_special_outlined;
  }
  if (token.contains('github')) {
    return Icons.public_rounded;
  }
  return Icons.cloud_download_rounded;
}

String _channelSubtitle(UpdateDownloadChannel ch) {
  if (ch.subtitle.trim().isNotEmpty) return ch.subtitle.trim();
  try {
    final uri = Uri.parse(ch.url.trim());
    if (uri.host.isNotEmpty) {
      return uri.host;
    }
  } catch (_) {}
  return ch.url.trim();
}

class _UpdateChannelsDialog extends StatefulWidget {
  final ConsoleBackend backend;
  final UpdateInfo latest;
  final String mirrorPrefix;
  final ValueChanged<String>? onToast;

  const _UpdateChannelsDialog({
    required this.backend,
    required this.latest,
    this.mirrorPrefix = '',
    this.onToast,
  });

  @override
  State<_UpdateChannelsDialog> createState() => _UpdateChannelsDialogState();
}

class _UpdateChannelsDialogState extends State<_UpdateChannelsDialog> {
  bool _showAllPlatforms = false;
  String? _openingId;

  List<UpdateDownloadChannel> get _allValidChannels => widget.latest.channels
      .where((c) => c.url.trim().isNotEmpty && c.name.trim().isNotEmpty)
      .toList();

  List<UpdateDownloadChannel> get _platformChannels =>
      widget.latest.channelsForPlatform(
        isWindows: widget.backend.isWindowsPlatform,
        isAndroid: widget.backend.isAndroidPlatform,
        isLinux: widget.backend.isLinuxPlatform,
        isMacOS: widget.backend.isMacOSPlatform,
      );

  Future<void> _selectChannel(UpdateDownloadChannel ch) async {
    if (_openingId != null) return;
    setState(() => _openingId = ch.id);
    final code = ch.code.trim();
    if (code.isNotEmpty) {
      try {
        await Clipboard.setData(ClipboardData(text: code));
      } catch (_) {}
      widget.onToast?.call('已自动复制提取码 $code，正在打开 ${ch.name}...');
    } else {
      widget.onToast?.call('正在打开 ${ch.name}...');
    }
    final url = applyGithubMirrorPrefix(ch.url, widget.mirrorPrefix);
    await widget.backend.openExternalUrl(url);
    if (!mounted) return;
    Navigator.of(context).pop(ch);
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final allChannels = _allValidChannels;
    final matched = _platformChannels;
    final visibleChannels = _showAllPlatforms ? allChannels : matched;
    final hasHiddenOtherPlatforms = allChannels.length > matched.length;

    return Dialog(
      backgroundColor: c.paper,
      elevation: 0,
      shape: prismSuperellipse(
        28,
        side: BorderSide(color: c.hairline.withValues(alpha: 0.72)),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 530, maxHeight: 580),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(13),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF4338CA)
                              .withValues(alpha: c.isDark ? 0.32 : 0.18),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const PrismSparkIcon(size: 38),
                  ),
                  const SizedBox(width: 12),
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
                              '选择下载渠道',
                              style: serifTitleStyle(c, size: 18.5),
                            ),
                            PrismPill(
                              text: widget.latest.tag,
                              fg: c.clay,
                              bg: c.clay.withValues(alpha: 0.12),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '点选任意网盘或镜像渠道，含提取码时会自动复制到剪贴板',
                          style: sansStyle(c, size: 12, color: c.muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  PrismWindowCaptionButton(
                    tooltip: '关闭',
                    glyph: PrismCaptionGlyph.close,
                    isClose: true,
                    enabled: _openingId == null,
                    palette: c,
                    onTap: _openingId != null
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              if (hasHiddenOtherPlatforms) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: PrismButton(
                    label: _showAllPlatforms
                        ? '仅看当前设备 (${matched.length})'
                        : '显示全平台渠道 (${allChannels.length})',
                    compact: true,
                    variant: PrismBtnVariant.ghost,
                    onPressed: () => setState(
                      () => _showAllPlatforms = !_showAllPlatforms,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Flexible(
                child: SingleChildScrollView(
                  child: PrismListGroup(
                    children: [
                      for (var i = 0; i < visibleChannels.length; i++)
                        _buildChannelRow(c, visibleChannels[i], isPrimary: i == 0),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  PrismButton(
                    label: '查看发布页说明',
                    compact: true,
                    variant: PrismBtnVariant.ghost,
                    leading: const Icon(Icons.article_outlined),
                    onPressed: () async {
                      final ghUrl = applyGithubMirrorPrefix(
                        widget.latest.effectiveGithubReleaseUrl,
                        widget.mirrorPrefix,
                      );
                      await widget.backend.openExternalUrl(ghUrl);
                    },
                  ),
                  PrismButton(
                    label: '返回',
                    compact: true,
                    onPressed: _openingId != null
                        ? null
                        : () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChannelRow(
    PrismPalette c,
    UpdateDownloadChannel ch, {
    required bool isPrimary,
  }) {
    final code = ch.code.trim();
    final badge = ch.badge.trim();
    final isOpening = _openingId == ch.id;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _openingId != null ? null : () => _selectChannel(ch),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: LayoutBuilder(
          builder: (ctx, box) {
            final isNarrow = box.maxWidth < 380;
            final iconWell = Container(
              width: 38,
              height: 38,
              decoration: ShapeDecoration(
                color: isPrimary
                    ? c.clay.withValues(alpha: c.isDark ? 0.16 : 0.10)
                    : c.recessed,
                shape: prismSuperellipse(
                  13,
                  side: BorderSide(
                    color: isPrimary
                        ? c.clay.withValues(alpha: 0.24)
                        : c.hairline.withValues(alpha: 0.58),
                  ),
                ),
              ),
              alignment: Alignment.center,
              child: Icon(
                _iconForChannel(ch),
                size: 17.5,
                color: isPrimary ? c.clay : c.inkSoft,
              ),
            );

            final infoCol = Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        ch.name,
                        style: sansStyle(
                          c,
                          size: 13.5,
                          weight: FontWeight.w600,
                          color: c.ink,
                        ),
                      ),
                      if (badge.isNotEmpty)
                        PrismPill(
                          text: badge,
                          mono: false,
                          fg: c.clay,
                          bg: c.clay.withValues(alpha: 0.12),
                        ),
                      if (code.isNotEmpty)
                        PrismPill(
                          text: '提取码 $code',
                          fg: c.sage,
                          bg: c.sageBg,
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _channelSubtitle(ch),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sansStyle(c, size: 11.8, color: c.muted),
                  ),
                ],
              ),
            );

            final openBtn = PrismButton(
              key: ValueKey('update-channel-btn-${ch.id}'),
              label: code.isNotEmpty ? '复制码并前往' : '前往下载',
              compact: true,
              loading: isOpening,
              variant: isPrimary ? PrismBtnVariant.clay : PrismBtnVariant.neutral,
              leading: const Icon(Icons.open_in_new_rounded),
              onPressed: _openingId != null ? null : () => _selectChannel(ch),
            );

            if (isNarrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      iconWell,
                      const SizedBox(width: 11),
                      infoCol,
                    ],
                  ),
                  const SizedBox(height: 9),
                  Align(
                    alignment: Alignment.centerRight,
                    child: openBtn,
                  ),
                ],
              );
            }

            return Row(
              children: [
                iconWell,
                const SizedBox(width: 12),
                infoCol,
                const SizedBox(width: 10),
                openBtn,
              ],
            );
          },
        ),
      ),
    );
  }
}

class UpdateAvailableDialog extends StatefulWidget {
  final ConsoleBackend backend;
  final String currentVersion;
  final UpdateInfo latest;
  final String mirrorPrefix;
  final ValueChanged<String>? onToast;

  const UpdateAvailableDialog({
    super.key,
    required this.backend,
    required this.currentVersion,
    required this.latest,
    this.mirrorPrefix = '',
    this.onToast,
  });

  @override
  State<UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<UpdateAvailableDialog> {
  bool _downloading = false;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  String _stageText = '';
  String? _errorText;
  String? _downloadedPath;

  UpdateAsset? get _matchedAsset => widget.latest.preferredAsset(
        isWindows: widget.backend.isWindowsPlatform,
        isAndroid: widget.backend.isAndroidPlatform,
        isLinux: widget.backend.isLinuxPlatform,
        isMacOS: widget.backend.isMacOSPlatform,
        cpuArch: widget.backend.hostCpuArch,
      );

  List<UpdateDownloadChannel> get _matchedChannels =>
      widget.latest.channelsForPlatform(
        isWindows: widget.backend.isWindowsPlatform,
        isAndroid: widget.backend.isAndroidPlatform,
        isLinux: widget.backend.isLinuxPlatform,
        isMacOS: widget.backend.isMacOSPlatform,
      );

  bool get _canOneClickUpgrade =>
      widget.backend.supportsInAppUpgrade && _matchedAsset != null;

  String _formatPublishedDate(String raw) {
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return raw;
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} ${pad(dt.hour)}:${pad(dt.minute)}';
  }

  Future<void> _handleOpenDownload() async {
    final channels = _matchedChannels;
    if (channels.isNotEmpty) {
      final selected = await showUpdateChannelsDialog(
        context: context,
        backend: widget.backend,
        latest: widget.latest,
        mirrorPrefix: widget.mirrorPrefix,
        onToast: widget.onToast,
      );
      if (selected != null && mounted) {
        Navigator.of(context).pop(UpdateDialogOutcome.openedDownloadPage);
      }
      return;
    }

    final targetUrl =
        applyGithubMirrorPrefix(widget.latest.releaseUrl, widget.mirrorPrefix);
    await widget.backend.openExternalUrl(targetUrl);
    if (mounted) {
      Navigator.of(context).pop(UpdateDialogOutcome.openedDownloadPage);
    }
  }

  Future<void> _handleOneClickUpgrade() async {
    final asset = _matchedAsset;
    if (!widget.backend.supportsInAppUpgrade || asset == null) {
      await _handleOpenDownload();
      return;
    }

    setState(() {
      _downloading = true;
      _receivedBytes = 0;
      _totalBytes = asset.size;
      _errorText = null;
      _stageText = '正在下载 ${asset.name}...';
    });

    final dl = await widget.backend.downloadUpdatePackage(
      asset,
      mirrorPrefix: widget.mirrorPrefix,
      onProgress: (received, total) {
        if (!mounted) return;
        setState(() {
          _receivedBytes = received;
          if (total > 0) _totalBytes = total;
          if (total > 0 && received >= total) {
            _stageText = asset.sha256.isNotEmpty
                ? '下载完成，正在校验 SHA-256 完整性...'
                : '下载完成，准备启动安装向导...';
          }
        });
      },
    );

    if (!mounted) return;
    if (!dl.ok || dl.filePath == null || dl.filePath!.isEmpty) {
      setState(() {
        _downloading = false;
        _errorText = dl.error ?? '安装包下载失败，请点击「前往下载」选择网盘或备用渠道。';
        _stageText = '';
      });
      return;
    }

    _downloadedPath = dl.filePath;
    setState(() {
      _stageText = dl.verified
          ? 'SHA-256 校验通过，正在启动安装向导...'
          : '正在启动安装向导...';
    });

    final launchRes = await widget.backend.launchDownloadedInstaller(
      dl.filePath!,
      silent: false,
      after: 'gui',
    );

    if (!mounted) return;
    if (launchRes['ok'] == true) {
      widget.onToast?.call(
        widget.backend.isWindowsPlatform
            ? '已启动安装向导（将自动识别当前安装位置，安装后自动重回界面）'
            : '已拉起新版本安装程序',
      );
      Navigator.of(context).pop(UpdateDialogOutcome.launchedInstaller);
    } else {
      setState(() {
        _downloading = false;
        _errorText =
            (launchRes['error'] ?? '无法自动启动安装程序，请手动运行已下载文件').toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final asset = _matchedAsset;
    final channels = _matchedChannels;
    final canOneClick = _canOneClickUpgrade;
    final notes = widget.latest.notes.trim().isEmpty
        ? '包含界面优化、稳定性改进与问题修复，详见版本发布说明。'
        : widget.latest.notes.trim();
    final progress = (_totalBytes > 0)
        ? (_receivedBytes / _totalBytes).clamp(0.0, 1.0)
        : null;
    final pct = progress != null ? '${(progress * 100).toStringAsFixed(0)}%' : '';

    return Dialog(
      backgroundColor: c.paper,
      elevation: 0,
      shape: prismSuperellipse(
        28,
        side: BorderSide(color: c.hairline.withValues(alpha: 0.72)),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF4338CA)
                              .withValues(alpha: c.isDark ? 0.35 : 0.20),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: const PrismSparkIcon(size: 42),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              '发现新版本',
                              style: serifTitleStyle(c, size: 19),
                            ),
                            const SizedBox(width: 8),
                            PrismPill(
                              text: widget.latest.tag,
                              fg: c.clay,
                              bg: c.clay.withValues(alpha: 0.12),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '当前 v${widget.currentVersion} → 最新 v${widget.latest.version}',
                              style: monoStyle(c, size: 11.8, color: c.muted),
                            ),
                            if (widget.latest.publishedAt.isNotEmpty)
                              Text(
                                '· ${_formatPublishedDate(widget.latest.publishedAt)}',
                                style: sansStyle(c, size: 11.5, color: c.meta),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  PrismWindowCaptionButton(
                    tooltip: '关闭',
                    glyph: PrismCaptionGlyph.close,
                    isClose: true,
                    enabled: !_downloading,
                    palette: c,
                    onTap: _downloading
                        ? null
                        : () =>
                            Navigator.of(context).pop(UpdateDialogOutcome.later),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (asset != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: ShapeDecoration(
                    color: c.recessed,
                    shape: prismSuperellipse(
                      16,
                      side: BorderSide(
                        color: c.hairline.withValues(alpha: 0.65),
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        widget.backend.isWindowsPlatform
                            ? Icons.desktop_windows_rounded
                            : (widget.backend.isAndroidPlatform
                                ? Icons.android_rounded
                                : Icons.archive_outlined),
                        size: 16,
                        color: c.clay,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          asset.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: monoStyle(c, size: 12, color: c.ink),
                        ),
                      ),
                      if (asset.size > 0) ...[
                        const SizedBox(width: 8),
                        Text(
                          formatBytesHuman(asset.size),
                          style: monoStyle(c, size: 11.5, color: c.muted),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ] else if (channels.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: ShapeDecoration(
                    color: c.recessed,
                    shape: prismSuperellipse(
                      16,
                      side: BorderSide(
                        color: c.hairline.withValues(alpha: 0.65),
                      ),
                    ),
                  ),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Icon(
                        Icons.cloud_download_rounded,
                        size: 16,
                        color: c.clay,
                      ),
                      Text(
                        '已就绪 ${channels.length} 个下载渠道',
                        style: sansStyle(
                          c,
                          size: 12.2,
                          weight: FontWeight.w500,
                          color: c.ink,
                        ),
                      ),
                      for (final ch in channels.take(3))
                        PrismPill(
                          text: ch.name,
                          mono: false,
                          fg: c.clay,
                          bg: c.clay.withValues(alpha: 0.11),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(
                    minHeight: 110,
                    maxHeight: 240,
                  ),
                  padding: const EdgeInsets.all(14),
                  decoration: ShapeDecoration(
                    color: c.paper2,
                    shape: prismSuperellipse(
                      16,
                      side: BorderSide(
                        color: c.hairline.withValues(alpha: 0.65),
                      ),
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      notes,
                      style: sansStyle(
                        c,
                        size: 12.8,
                        color: c.ink,
                        height: 1.55,
                      ),
                    ),
                  ),
                ),
              ),
              if (_downloading || _stageText.isNotEmpty) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _stageText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: sansStyle(c, size: 12, color: c.ink),
                      ),
                    ),
                    if (_totalBytes > 0) ...[
                      const SizedBox(width: 8),
                      Text(
                        '${formatBytesHuman(_receivedBytes)} / ${formatBytesHuman(_totalBytes)} $pct',
                        style: monoStyle(c, size: 11.5, color: c.muted),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    backgroundColor: c.recessed,
                    color: c.clay,
                  ),
                ),
              ],
              if (_errorText != null && _errorText!.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 11,
                    vertical: 8,
                  ),
                  decoration: ShapeDecoration(
                    color: c.dangerBg,
                    shape: prismSuperellipse(
                      14,
                      side: BorderSide(color: c.danger.withValues(alpha: 0.3)),
                    ),
                  ),
                  child: Text(
                    _downloadedPath != null
                        ? '$_errorText\n文件位置：$_downloadedPath'
                        : _errorText!,
                    style: sansStyle(c, size: 12, color: c.danger),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: [
                  PrismButton(
                    label: '不再提醒本次更新',
                    compact: true,
                    variant: PrismBtnVariant.ghost,
                    onPressed: _downloading
                        ? null
                        : () => Navigator.of(context)
                            .pop(UpdateDialogOutcome.skipThisVersion),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      PrismButton(
                        label: '稍后更新',
                        compact: true,
                        onPressed: _downloading
                            ? null
                            : () => Navigator.of(context)
                                .pop(UpdateDialogOutcome.later),
                      ),
                      PrismButton(
                        label: '前往下载',
                        compact: true,
                        variant: canOneClick
                            ? PrismBtnVariant.neutral
                            : PrismBtnVariant.clay,
                        leading: Icon(
                          channels.isNotEmpty
                              ? Icons.cloud_download_rounded
                              : Icons.open_in_new_rounded,
                        ),
                        onPressed: _downloading ? null : _handleOpenDownload,
                      ),
                      if (canOneClick)
                        PrismButton(
                          label: _downloading ? '下载中...' : '一键升级',
                          compact: true,
                          variant: PrismBtnVariant.clay,
                          loading: _downloading,
                          leading:
                              const Icon(Icons.download_for_offline_rounded),
                          onPressed:
                              _downloading ? null : _handleOneClickUpgrade,
                        ),
                    ],
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
