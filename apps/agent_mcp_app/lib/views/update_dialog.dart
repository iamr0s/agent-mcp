import 'package:flutter/material.dart';

import '../services/console_backend.dart';
import '../theme/claude_theme.dart';

enum UpdateDialogOutcome {
  later,
  skipThisVersion,
  openedDownloadPage,
  launchedInstaller,
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
      );

  String _formatPublishedDate(String raw) {
    final dt = DateTime.tryParse(raw)?.toLocal();
    if (dt == null) return raw;
    String pad(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${pad(dt.month)}-${pad(dt.day)} ${pad(dt.hour)}:${pad(dt.minute)}';
  }

  Future<void> _handleOneClickUpgrade() async {
    final asset = _matchedAsset;
    if (!widget.backend.supportsInAppUpgrade || asset == null) {
      final fallbackUrl = asset != null
          ? applyGithubMirrorPrefix(asset.url, widget.mirrorPrefix)
          : widget.latest.releaseUrl;
      await widget.backend.openExternalUrl(fallbackUrl);
      if (mounted) {
        Navigator.of(context).pop(UpdateDialogOutcome.openedDownloadPage);
      }
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
        _errorText = dl.error ?? '安装包下载失败，请尝试「前往下载」手动获取。';
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
    final c = ClaudePalette.of(context);
    final asset = _matchedAsset;
    final notes = widget.latest.notes.trim().isEmpty
        ? '包含界面优化、稳定性改进与问题修复，详见 GitHub Release 说明。'
        : widget.latest.notes.trim();
    final progress = (_totalBytes > 0)
        ? (_receivedBytes / _totalBytes).clamp(0.0, 1.0)
        : null;
    final pct = progress != null ? '${(progress * 100).toStringAsFixed(0)}%' : '';

    return Dialog(
      backgroundColor: c.paper,
      elevation: 0,
      shape: claudeSuperellipse(
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
                    child: const ClaudeSparkIcon(size: 42),
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
                            ClaudePill(
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
                  IconButton(
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: _downloading
                        ? null
                        : () =>
                            Navigator.of(context).pop(UpdateDialogOutcome.later),
                    icon: Icon(Icons.close_rounded, size: 18, color: c.meta),
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
                    shape: claudeSuperellipse(
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
                    shape: claudeSuperellipse(
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
                    shape: claudeSuperellipse(
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
                  ClaudeButton(
                    label: '不再提醒本次更新',
                    compact: true,
                    variant: ClaudeBtnVariant.ghost,
                    onPressed: _downloading
                        ? null
                        : () => Navigator.of(context)
                            .pop(UpdateDialogOutcome.skipThisVersion),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ClaudeButton(
                        label: '稍后更新',
                        compact: true,
                        onPressed: _downloading
                            ? null
                            : () => Navigator.of(context)
                                .pop(UpdateDialogOutcome.later),
                      ),
                      ClaudeButton(
                        label: '前往下载',
                        compact: true,
                        leading: const Icon(Icons.open_in_new_rounded),
                        onPressed: _downloading
                            ? null
                            : () async {
                                await widget.backend
                                    .openExternalUrl(widget.latest.releaseUrl);
                                if (context.mounted) {
                                  Navigator.of(context)
                                      .pop(UpdateDialogOutcome.openedDownloadPage);
                                }
                              },
                      ),
                      ClaudeButton(
                        label: _downloading ? '下载中...' : '一键升级',
                        compact: true,
                        variant: ClaudeBtnVariant.clay,
                        loading: _downloading,
                        leading: const Icon(Icons.download_for_offline_rounded),
                        onPressed: _downloading ? null : _handleOneClickUpgrade,
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
