import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/console_backend.dart';
import '../theme/prism_theme.dart';

class PlayitClaimAndDomainCard extends StatefulWidget {
  final ConsoleBackend backend;
  final String profileId;
  final String claimMode; // 'random' | 'custom'
  final ValueChanged<String> onClaimModeChanged;
  final TextEditingController customClaimCtrl;
  final String domainMode; // 'random' | 'custom'
  final ValueChanged<String> onDomainModeChanged;
  final TextEditingController hostnameCtrl;
  final String transportSuffix;
  final bool autoGenerateWhenUnclaimed;
  final ValueChanged<String>? onToast;
  final Future<void> Function()? onStatusChanged;

  const PlayitClaimAndDomainCard({
    super.key,
    required this.backend,
    required this.profileId,
    required this.claimMode,
    required this.onClaimModeChanged,
    required this.customClaimCtrl,
    required this.domainMode,
    required this.onDomainModeChanged,
    required this.hostnameCtrl,
    this.transportSuffix = '/mcp',
    this.autoGenerateWhenUnclaimed = true,
    this.onToast,
    this.onStatusChanged,
  });

  @override
  State<PlayitClaimAndDomainCard> createState() =>
      _PlayitClaimAndDomainCardState();
}

class _PlayitClaimAndDomainCardState extends State<PlayitClaimAndDomainCard> {
  Map<String, dynamic> _component = const <String, dynamic>{};
  Map<String, dynamic> _profileState = const <String, dynamic>{};
  bool _loadingClaim = false;
  bool _syncingDomains = false;
  bool _downloadingBin = false;
  bool _didAutoTrigger = false;
  String _localError = '';
  Timer? _pollTimer;

  void _toast(String msg) {
    if (widget.onToast != null) {
      widget.onToast!(msg);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_refreshPlayitState(allowAutoGenerate: true));
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1600), (_) {
      unawaited(_pollIfNeeded());
    });
  }

  @override
  void didUpdateWidget(covariant PlayitClaimAndDomainCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profileId != widget.profileId) {
      _didAutoTrigger = false;
      unawaited(_refreshPlayitState(allowAutoGenerate: true));
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _pollIfNeeded() async {
    if (!mounted) return;
    final claimMap = _profileState['claim'] is Map
        ? Map<String, dynamic>.from(_profileState['claim'] as Map)
        : null;
    final instMap = _component['install'] is Map
        ? Map<String, dynamic>.from(_component['install'] as Map)
        : null;
    final claimActive = claimMap != null && claimMap['active'] == true;
    final dlActive = instMap != null && instMap['active'] == true;
    if (claimActive || dlActive) {
      final wasClaimed = _profileState['claimed'] == true;
      await _refreshPlayitState(allowAutoGenerate: false);
      final nowClaimed = _profileState['claimed'] == true;
      if (!wasClaimed && nowClaimed) {
        _toast('Playit 节点认领成功，持久化密钥已生成');
        await widget.onStatusChanged?.call();
      }
    }
  }

  Future<void> _refreshPlayitState({required bool allowAutoGenerate}) async {
    try {
      final res = await widget.backend.getPlayitStatus(widget.profileId);
      if (!mounted) return;
      final comp = res['component'] is Map
          ? Map<String, dynamic>.from(res['component'] as Map)
          : const <String, dynamic>{};
      final prof = res['profile'] is Map
          ? Map<String, dynamic>.from(res['profile'] as Map)
          : const <String, dynamic>{};
      setState(() {
        _component = comp;
        _profileState = prof;
      });

      final claimed = prof['claimed'] == true;
      final existingClaim = prof['claim'] is Map
          ? Map<String, dynamic>.from(prof['claim'] as Map)
          : null;
      final hasActiveClaimUrl = existingClaim != null &&
          (existingClaim['claim_url'] ?? '').toString().isNotEmpty &&
          existingClaim['phase'] != 'error' &&
          existingClaim['phase'] != 'rejected';

      if (allowAutoGenerate &&
          widget.autoGenerateWhenUnclaimed &&
          !_didAutoTrigger &&
          !claimed &&
          !hasActiveClaimUrl &&
          widget.claimMode == 'random') {
        _didAutoTrigger = true;
        await _triggerClaim(openBrowser: false);
      }
    } catch (_) {}
  }

  Future<void> _triggerClaim({required bool openBrowser}) async {
    if (_loadingClaim) return;
    setState(() {
      _loadingClaim = true;
      _localError = '';
    });
    try {
      final res = await widget.backend.startPlayitClaim(
        profileId: widget.profileId,
        claimMode: widget.claimMode,
        customInput: widget.customClaimCtrl.text.trim(),
      );
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() {
          _localError = (res['error'] ?? '生成认领链接失败').toString();
        });
        return;
      }
      await _refreshPlayitState(allowAutoGenerate: false);
      if (res['claimed_immediately'] == true) {
        _toast('已验证密钥并写入持久化 playit.toml');
        await widget.onStatusChanged?.call();
        return;
      }
      final url = (res['claim_url'] ?? '').toString().trim();
      if (openBrowser && url.isNotEmpty) {
        await widget.backend.openExternalUrl(url);
        _toast('已在浏览器打开 Playit 认领页面');
      }
    } finally {
      if (mounted) setState(() => _loadingClaim = false);
    }
  }

  Future<void> _handleResetClaim() async {
    final res = await widget.backend.resetPlayitClaim(widget.profileId);
    if (!mounted) return;
    if (res['ok'] == true) {
      _didAutoTrigger = false;
      _toast((res['message'] ?? '已重置认领密钥').toString());
      await _refreshPlayitState(allowAutoGenerate: false);
      await widget.onStatusChanged?.call();
    } else {
      setState(() {
        _localError = (res['error'] ?? '重置失败').toString();
      });
    }
  }

  Future<void> _handleDownloadPlayit() async {
    if (_downloadingBin) return;
    setState(() => _downloadingBin = true);
    try {
      final res = await widget.backend.installPlayit();
      if (!mounted) return;
      if (res['ok'] == true) {
        _toast((res['message'] ?? '已开始下载 playitd 组件').toString());
      } else {
        setState(() {
          _localError = (res['error'] ?? '下载失败').toString();
        });
      }
      await _refreshPlayitState(allowAutoGenerate: false);
    } finally {
      if (mounted) setState(() => _downloadingBin = false);
    }
  }

  Future<void> _handleSyncDomains() async {
    if (_syncingDomains) return;
    setState(() {
      _syncingDomains = true;
      _localError = '';
    });
    try {
      final res = await widget.backend.syncPlayitEndpoint(
        widget.profileId,
        autoCreate: true,
      );
      if (!mounted) return;
      if (res['ok'] == true) {
        _toast('已同步 Playit 持久隧道与域名信息');
        await _refreshPlayitState(allowAutoGenerate: false);
        await widget.onStatusChanged?.call();
      } else {
        setState(() {
          _localError = (res['error'] ?? '同步失败').toString();
        });
      }
    } finally {
      if (mounted) setState(() => _syncingDomains = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final installed = _component['installed'] == true;
    final binVer = (_component['version'] ?? '').toString().trim();
    final instMap = _component['install'] is Map
        ? Map<String, dynamic>.from(_component['install'] as Map)
        : const <String, dynamic>{};
    final dlActive = instMap['active'] == true;
    final dlPct = int.tryParse('${instMap['percent'] ?? 0}') ?? 0;

    final claimed = _profileState['claimed'] == true;
    final secretPath = (_profileState['secret_path'] ?? '').toString().trim();
    final liveUrl = (_profileState['live_url'] ?? '').toString().trim();
    final domains = ((_profileState['domains'] as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();

    final claimMap = _profileState['claim'] is Map
        ? Map<String, dynamic>.from(_profileState['claim'] as Map)
        : null;
    final claimUrl = (claimMap?['claim_url'] ?? '').toString().trim();
    final claimActive = claimMap?['active'] == true;
    final claimMsg = (claimMap?['message'] ?? '').toString().trim();
    final claimErr = (claimMap?['error'] ?? '').toString().trim();
    final effectiveErr = _localError.isNotEmpty ? _localError : claimErr;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: ShapeDecoration(
        color: c.recessed,
        shape: prismSuperellipse(
          18,
          side: BorderSide(color: c.hairline.withValues(alpha: 0.68)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Daemon & Secret Status Row
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  PrismPill(
                    leading: PrismStatusDot(
                      color: claimed ? c.sage : const Color(0xFFD97706),
                      pulsing: claimActive,
                      size: 6.5,
                    ),
                    text: claimed
                        ? '已认领 · 密钥持久化'
                        : (claimActive ? '等待登录认领...' : '待认领绑定'),
                    mono: false,
                    fg: claimed ? c.sage : const Color(0xFFD97706),
                    bg: claimed ? c.sageBg : const Color(0x1FD97706),
                  ),
                  PrismPill(
                    text: installed
                        ? 'playitd${binVer.isNotEmpty ? " v$binVer" : ""} 已就绪'
                        : (dlActive ? '下载组件 $dlPct%' : '未安装 playitd'),
                    mono: false,
                    fg: installed ? c.inkSoft : c.clay,
                    bg: installed ? c.paper2 : c.clay.withValues(alpha: 0.12),
                  ),
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (!installed)
                    PrismButton(
                      label: dlActive ? '下载中 $dlPct%' : '一键下载 playitd',
                      compact: true,
                      loading: _downloadingBin || dlActive,
                      variant: PrismBtnVariant.clay,
                      leading: const Icon(Icons.download_rounded),
                      onPressed: dlActive ? null : _handleDownloadPlayit,
                    ),
                  if (claimed) ...[
                    PrismButton(
                      label: _syncingDomains ? '同步中...' : '同步地址与域名',
                      compact: true,
                      loading: _syncingDomains,
                      leading: const Icon(Icons.sync_rounded),
                      onPressed: _handleSyncDomains,
                    ),
                    PrismButton(
                      label: '重新认领',
                      compact: true,
                      variant: PrismBtnVariant.ghost,
                      onPressed: _handleResetClaim,
                    ),
                  ],
                ],
              ),
            ],
          ),

          if (secretPath.isNotEmpty) ...[
            const SizedBox(height: 7),
            Text(
              '持久化 Secret 文件：$secretPath',
              style: monoStyle(c, size: 11.2, color: c.meta),
            ),
          ],

          // 2. Claim Panel (when unclaimed)
          if (!claimed) ...[
            const SizedBox(height: 11),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Text(
                  '节点认领方式',
                  style: sansStyle(
                    c,
                    size: 12.2,
                    weight: FontWeight.w600,
                    color: c.ink,
                  ),
                ),
                PrismSegmented<String>(
                  value: widget.claimMode,
                  items: const [
                    ('random', '随机认领链接'),
                    ('custom', '指定认领码 / 密钥'),
                  ],
                  onChanged: (v) {
                    setState(() => _localError = '');
                    widget.onClaimModeChanged(v);
                    if (v == 'random' && claimUrl.isEmpty) {
                      unawaited(_triggerClaim(openBrowser: false));
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (widget.claimMode == 'custom') ...[
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: widget.customClaimCtrl,
                      style: monoStyle(c, size: 12.2, color: c.ink),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '输入偶数位 hex 认领码、认领 URL，或粘贴已有 Secret Key',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PrismButton(
                    label: '生成 / 绑定',
                    compact: true,
                    loading: _loadingClaim,
                    variant: PrismBtnVariant.clay,
                    onPressed: () => _triggerClaim(openBrowser: false),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            if (claimUrl.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(11),
                decoration: ShapeDecoration(
                  color: c.paper2,
                  shape: prismSuperellipse(
                    14,
                    side: BorderSide(color: c.hairline),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(
                      claimUrl,
                      style: monoStyle(
                        c,
                        size: 12.2,
                        weight: FontWeight.w600,
                        color: c.clay,
                      ),
                    ),
                    if (claimMsg.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        claimMsg,
                        style: sansStyle(c, size: 11.6, color: c.muted),
                      ),
                    ],
                    const SizedBox(height: 9),
                    Wrap(
                      spacing: 8,
                      runSpacing: 7,
                      children: [
                        PrismButton(
                          label: '打开浏览器登录认领',
                          compact: true,
                          variant: PrismBtnVariant.clay,
                          leading: const Icon(Icons.open_in_new_rounded),
                          onPressed: () async {
                            await widget.backend.openExternalUrl(claimUrl);
                            _toast('已打开认领页面，登录批准后将自动落盘密钥');
                          },
                        ),
                        PrismButton(
                          label: '复制认领链接',
                          compact: true,
                          leading: const Icon(Icons.copy_rounded),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: claimUrl));
                            _toast('已复制认领链接：$claimUrl');
                          },
                        ),
                        if (widget.claimMode == 'random')
                          PrismButton(
                            label: '换一个认领码',
                            compact: true,
                            loading: _loadingClaim,
                            variant: PrismBtnVariant.ghost,
                            leading: const Icon(Icons.refresh_rounded),
                            onPressed: () => _triggerClaim(openBrowser: false),
                          ),
                      ],
                    ),
                  ],
                ),
              )
            else if (widget.claimMode == 'random')
              PrismButton(
                label: _loadingClaim ? '正在生成认领链接...' : '生成 Playit 认领链接',
                compact: true,
                loading: _loadingClaim,
                variant: PrismBtnVariant.clay,
                leading: const Icon(Icons.link_rounded),
                onPressed: () => _triggerClaim(openBrowser: false),
              ),
          ],

          const SizedBox(height: 12),

          // 3. Persistent Domain / Allocation Mode
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Text(
                '持久化地址策略',
                style: sansStyle(
                  c,
                  size: 12.2,
                  weight: FontWeight.w600,
                  color: c.ink,
                ),
              ),
              PrismSegmented<String>(
                value: widget.domainMode,
                items: const [
                  ('random', '随机持久地址'),
                  ('custom', '指定绑定域名'),
                ],
                onChanged: widget.onDomainModeChanged,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (widget.domainMode == 'custom') ...[
            TextField(
              controller: widget.hostnameCtrl,
              style: monoStyle(c, size: 12.3, color: c.ink),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '填写指定域名，如 mcp.playit.plus 或自有外部域名',
              ),
            ),
            if (domains.isNotEmpty) ...[
              const SizedBox(height: 7),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final dom in domains)
                    PrismButton(
                      label: dom,
                      compact: true,
                      variant: widget.hostnameCtrl.text.trim().toLowerCase() ==
                              dom.toLowerCase()
                          ? PrismBtnVariant.clay
                          : PrismBtnVariant.neutral,
                      onPressed: () {
                        setState(() => widget.hostnameCtrl.text = dom);
                      },
                    ),
                ],
              ),
            ],
            const SizedBox(height: 6),
            Text(
              '提示：绑定 .playit.plus 或外部域名（需 Playit Premium）时，playitd 将自动签发 Let\'s Encrypt HTTPS 证书。',
              style: sansStyle(c, size: 11.4, color: c.muted),
            ),
          ] else ...[
            Text(
              '自动创建或复用指向本机端口的持久地址（如 *.gl.at.ply.gg:端口），重启电脑地址保持不变；免费版为带端口 HTTP 隧道。',
              style: sansStyle(c, size: 11.5, color: c.muted, height: 1.42),
            ),
          ],

          if (liveUrl.isNotEmpty) ...[
            const SizedBox(height: 9),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: ShapeDecoration(
                color: c.paper2,
                shape: prismSuperellipse(
                  12,
                  side: BorderSide(color: c.hairline),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      '$liveUrl${widget.transportSuffix}',
                      style: monoStyle(c, size: 11.8, color: c.ink),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PrismButton(
                    label: '复制地址',
                    compact: true,
                    leading: const Icon(Icons.copy_rounded),
                    onPressed: () {
                      final full = '$liveUrl${widget.transportSuffix}';
                      Clipboard.setData(ClipboardData(text: full));
                      _toast('已复制持久化 MCP 地址：$full');
                    },
                  ),
                ],
              ),
            ),
          ],

          if (effectiveErr.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              effectiveErr,
              style: sansStyle(c, size: 11.6, color: c.danger),
            ),
          ],
        ],
      ),
    );
  }
}
