import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/console_backend.dart';
import '../theme/prism_theme.dart';
import 'playit_claim_card.dart';

class FirstRunOnboardingDialog extends StatefulWidget {
  final ConsoleBackend backend;
  final Map<String, dynamic> initialConfig;
  final Map<String, dynamic> initialTunnelInfo;
  final Map<String, dynamic> initialExposureSummary;
  final Future<void> Function() onRefreshStatus;
  final ValueChanged<String> onToast;

  const FirstRunOnboardingDialog({
    super.key,
    required this.backend,
    required this.initialConfig,
    required this.initialTunnelInfo,
    required this.initialExposureSummary,
    required this.onRefreshStatus,
    required this.onToast,
  });

  @override
  State<FirstRunOnboardingDialog> createState() =>
      _FirstRunOnboardingDialogState();
}

class _FirstRunOnboardingDialogState extends State<FirstRunOnboardingDialog> {
  final _serverNameCtrl = TextEditingController();
  final _pwdCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();
  final _domainCtrl = TextEditingController();
  final _playitCustomClaimCtrl = TextEditingController();
  final _playitHostCtrl = TextEditingController();

  String _tunnelMode = 'quick';
  String _playitClaimMode = 'random';
  String _playitDomainMode = 'random';
  bool _launchAtStartup = false;
  bool _silentStart = false;
  bool _tsEnabled = true;

  bool _hasSavedPassword = false;
  String _generatedPasswordPreview = '';
  String _validationError = '';

  Map<String, dynamic> _tunnelInfo = <String, dynamic>{};
  Map<String, dynamic> _tsStatus = <String, dynamic>{};

  bool _probingTs = false;
  bool _installingTs = false;
  bool _downloadingCf = false;
  bool _saving = false;
  Timer? _livePollTimer;

  @override
  void initState() {
    super.initState();
    final cfg = widget.initialConfig;
    _serverNameCtrl.text =
        (cfg['server_name'] ?? 'Agent MCP').toString().trim();
    _hasSavedPassword = cfg['has_password'] == true;
    _launchAtStartup = cfg['launch_at_startup'] == true;
    _silentStart = cfg['silent_start'] == true;
    _tsEnabled = cfg['expose_tailscale_enabled'] != false;

    final rawProfiles = cfg['profiles'];
    if (rawProfiles is List && rawProfiles.isNotEmpty && rawProfiles.first is Map) {
      final p0 = Map<String, dynamic>.from(rawProfiles.first as Map);
      final m = (p0['tunnel_mode'] ?? 'quick').toString().trim().toLowerCase();
      _tunnelMode = (m == 'quick' ||
              m == 'token' ||
              m == 'playit' ||
              m == 'none')
          ? m
          : 'quick';
      _tokenCtrl.text = (p0['tunnel_token'] ?? '').toString();
      _domainCtrl.text = (p0['base_url'] ?? '').toString();
      _playitClaimMode =
          (p0['playit_claim_mode'] ?? 'random').toString().toLowerCase() ==
                  'custom'
              ? 'custom'
              : 'random';
      _playitCustomClaimCtrl.text =
          (p0['playit_custom_code'] ?? '').toString();
      _playitDomainMode =
          (p0['playit_domain_mode'] ?? 'random').toString().toLowerCase() ==
                  'custom'
              ? 'custom'
              : 'random';
      _playitHostCtrl.text = (p0['playit_hostname'] ?? '').toString();
    } else {
      final cfgMode =
          (cfg['tunnel_mode'] ?? 'quick').toString().trim().toLowerCase();
      _tunnelMode = (cfgMode == 'quick' ||
              cfgMode == 'token' ||
              cfgMode == 'playit' ||
              cfgMode == 'none')
          ? cfgMode
          : 'quick';
    }

    _tunnelInfo = Map<String, dynamic>.from(widget.initialTunnelInfo);
    if (widget.initialExposureSummary['tailscale'] is Map) {
      _tsStatus = Map<String, dynamic>.from(
        widget.initialExposureSummary['tailscale'] as Map,
      );
    }

    unawaited(_refreshTailscale());
    _livePollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_pollRuntimeState());
    });
  }

  @override
  void dispose() {
    _livePollTimer?.cancel();
    _serverNameCtrl.dispose();
    _pwdCtrl.dispose();
    _tokenCtrl.dispose();
    _domainCtrl.dispose();
    _playitCustomClaimCtrl.dispose();
    _playitHostCtrl.dispose();
    super.dispose();
  }

  Future<void> _pollRuntimeState() async {
    if (!mounted) return;
    try {
      final st = await widget.backend.getStatus();
      if (!mounted) return;
      setState(() {
        if (st['tunnels'] is Map) {
          _tunnelInfo = Map<String, dynamic>.from(st['tunnels'] as Map);
        }
        if (st['exposures'] is Map) {
          final exp = st['exposures'] as Map;
          if (exp['tailscale'] is Map) {
            _tsStatus = Map<String, dynamic>.from(exp['tailscale'] as Map);
          }
        }
      });
    } catch (_) {}
  }

  Future<void> _refreshTailscale({bool toast = false}) async {
    if (_probingTs) return;
    setState(() => _probingTs = true);
    try {
      final res = await widget.backend.getTailscaleStatus();
      if (!mounted) return;
      if (res['tailscale'] is Map) {
        setState(() {
          _tsStatus = Map<String, dynamic>.from(res['tailscale'] as Map);
        });
      }
      if (toast) {
        widget.onToast('已刷新 Tailscale 组网检测状态');
      }
    } catch (_) {} finally {
      if (mounted) setState(() => _probingTs = false);
    }
  }

  void _generateStrongPassword() {
    const alphabet =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    final rng = Random.secure();
    final p1 = List.generate(4, (_) => alphabet[rng.nextInt(alphabet.length)])
        .join();
    final p2 = List.generate(4, (_) => alphabet[rng.nextInt(alphabet.length)])
        .join();
    final p3 = List.generate(4, (_) => alphabet[rng.nextInt(alphabet.length)])
        .join();
    final generated = '$p1-$p2-$p3';
    setState(() {
      _pwdCtrl.text = generated;
      _generatedPasswordPreview = generated;
      _validationError = '';
    });
    Clipboard.setData(ClipboardData(text: generated));
    widget.onToast('已随机生成强口令并复制到剪贴板');
  }

  Future<void> _installCloudflared() async {
    if (_downloadingCf) return;
    setState(() => _downloadingCf = true);
    try {
      final res = await widget.backend.installCloudflared();
      if (!mounted) return;
      if (res['ok'] == true) {
        widget.onToast('已启动 Cloudflared 组件下载');
      } else {
        widget.onToast('下载 Cloudflared 失败：${res['error'] ?? '未知错误'}');
      }
      await _pollRuntimeState();
    } finally {
      if (mounted) setState(() => _downloadingCf = false);
    }
  }

  Future<void> _handleInstallTailscale() async {
    if (_installingTs) return;
    setState(() => _installingTs = true);
    try {
      final res = await widget.backend.installTailscaleClient();
      if (!mounted) return;
      final mode = (res['mode'] ?? '').toString();
      if (mode == 'winget') {
        widget.onToast(
          (res['message'] ?? '已调起 winget 安装 Tailscale').toString(),
        );
      } else {
        widget.onToast('已在浏览器打开 Tailscale 官方下载页面');
      }
    } finally {
      if (mounted) setState(() => _installingTs = false);
    }
  }

  Future<void> _openTailscaleDownloadWebsite() async {
    final url = widget.backend.isWindowsPlatform
        ? 'https://tailscale.com/download/windows'
        : (widget.backend.isMacOSPlatform
            ? 'https://tailscale.com/download/mac'
            : (widget.backend.isLinuxPlatform
                ? 'https://tailscale.com/download/linux'
                : 'https://tailscale.com/download'));
    await widget.backend.openExternalUrl(url);
    widget.onToast('已打开 Tailscale 官网下载页');
  }

  Future<void> _skipForNow() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.backend.saveConfig({'onboarding_completed': true});
      await widget.onRefreshStatus();
      if (mounted) {
        Navigator.of(context).pop(false);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _applyAndFinish() async {
    if (_saving) return;
    final enteredPwd = _pwdCtrl.text.trim();
    if (_tunnelMode != 'none' && !_hasSavedPassword && enteredPwd.isEmpty) {
      setState(() {
        _validationError = '启用公网隧道时，请先设置 OAuth 授权密码（或点击右侧“随机生成”），以保护远程控制台与 MCP 端点。';
      });
      return;
    }
    if (_tunnelMode == 'token' && _tokenCtrl.text.trim().isEmpty) {
      setState(() {
        _validationError = 'Token 固定域名模式需要填写 Cloudflare Tunnel Token。';
      });
      return;
    }

    setState(() {
      _validationError = '';
      _saving = true;
    });

    try {
      final curCfg = widget.initialConfig;
      final rawList = (curCfg['profiles'] is List)
          ? List<dynamic>.from(curCfg['profiles'] as List)
          : <dynamic>[];
      final updatedProfiles = <Map<String, dynamic>>[];

      if (rawList.isNotEmpty && rawList.first is Map) {
        for (var i = 0; i < rawList.length; i++) {
          if (rawList[i] is! Map) continue;
          final pm = Map<String, dynamic>.from(rawList[i] as Map);
          if (i == 0 || pm['id'] == 'default') {
            pm['tunnel_mode'] = _tunnelMode;
            pm['tunnel_auto_start'] = true;
            if (_tunnelMode == 'token') {
              pm['tunnel_token'] = _tokenCtrl.text.trim();
              pm['base_url'] = _domainCtrl.text.trim();
            } else if (_tunnelMode == 'playit') {
              pm['playit_claim_mode'] = _playitClaimMode;
              pm['playit_custom_code'] = _playitCustomClaimCtrl.text.trim();
              pm['playit_domain_mode'] = _playitDomainMode;
              pm['playit_hostname'] = _playitHostCtrl.text.trim();
              pm['base_url'] = _playitDomainMode == 'custom'
                  ? _playitHostCtrl.text.trim()
                  : '';
            } else if (_tunnelMode == 'quick') {
              pm['base_url'] = '';
            }
          }
          updatedProfiles.add(pm);
        }
      } else {
        updatedProfiles.add({
          'id': 'default',
          'name': '主入口',
          'enabled': true,
          'transport': 'dual',
          'auth_mode': 'oauth-local',
          'tunnel_mode': _tunnelMode,
          'tunnel_token':
              _tunnelMode == 'token' ? _tokenCtrl.text.trim() : null,
          'playit_claim_mode': _playitClaimMode,
          'playit_custom_code': _playitCustomClaimCtrl.text.trim(),
          'playit_domain_mode': _playitDomainMode,
          'playit_hostname': _playitHostCtrl.text.trim(),
          'base_url': _tunnelMode == 'token'
              ? _domainCtrl.text.trim()
              : (_tunnelMode == 'playit' && _playitDomainMode == 'custom'
                  ? _playitHostCtrl.text.trim()
                  : ''),
          'tunnel_auto_start': true,
          'oauth_allow_all_redirects': false,
          'inherit_permissions': true,
        });
      }

      final patch = <String, dynamic>{
        'server_name': _serverNameCtrl.text.trim().isEmpty
            ? 'Agent MCP'
            : _serverNameCtrl.text.trim(),
        'tunnel_mode': _tunnelMode,
        'profiles': updatedProfiles,
        'expose_tailscale_enabled': _tsEnabled,
        'onboarding_completed': true,
      };
      if (!widget.backend.isWebMode && !widget.backend.isAndroidPlatform) {
        patch['launch_at_startup'] = _launchAtStartup;
        patch['silent_start'] = _silentStart;
      }
      if (enteredPwd.isNotEmpty) {
        patch['oauth_local_password'] = enteredPwd;
      }

      await widget.backend.saveConfig(patch);

      if (_tunnelMode == 'quick' || _tunnelMode == 'token') {
        final cfInstalled = _tunnelInfo['installed'] == true;
        if (!cfInstalled) {
          await widget.backend.installCloudflared();
        }
        await widget.backend.startTunnel('default');
      } else if (_tunnelMode == 'playit') {
        final playitMap = _tunnelInfo['playit'] is Map
            ? Map<String, dynamic>.from(_tunnelInfo['playit'] as Map)
            : const <String, dynamic>{};
        if (playitMap['installed'] != true) {
          await widget.backend.installPlayit();
        }
        await widget.backend.startTunnel('default');
      } else {
        await widget.backend.stopTunnel('default');
      }

      await widget.onRefreshStatus();
      if (mounted) {
        widget.onToast('初始化设置已保存生效');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _validationError = '保存初始化设置失败：$e';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _extractDefaultQuickUrl() {
    final tMap = _tunnelInfo['tunnels'];
    if (tMap is Map && tMap['default'] is Map) {
      final d = tMap['default'] as Map;
      return (d['live_url'] ?? '').toString().trim();
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final cfInstalled = _tunnelInfo['installed'] == true;
    final cfVer = (_tunnelInfo['version'] ?? '').toString().trim();
    final cfInstallMap = _tunnelInfo['install'] is Map
        ? Map<String, dynamic>.from(_tunnelInfo['install'] as Map)
        : const <String, dynamic>{};
    final cfDlActive = cfInstallMap['active'] == true;
    final cfDlPct = int.tryParse('${cfInstallMap['percent'] ?? 0}') ?? 0;
    final liveQuickUrl = _extractDefaultQuickUrl();

    final tsInstalled = _tsStatus['cli_installed'] == true;
    final tsRunning = _tsStatus['daemon_running'] == true;
    final tsDns = (_tsStatus['dns_name'] ?? '').toString().trim();
    final tsIps = ((_tsStatus['tailscale_ips'] as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final tsReachable = tsRunning && (tsIps.isNotEmpty || tsDns.isNotEmpty);

    final lanIps = ((widget.initialConfig['lan_ips'] as List?) ?? const [])
        .map((e) => e.toString().trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final serverPort =
        int.tryParse('${widget.initialConfig['port'] ?? 8000}') ?? 8000;
    final sampleLanUrl = lanIps.isNotEmpty
        ? 'http://${lanIps.first}:$serverPort/mcp'
        : 'http://127.0.0.1:$serverPort/mcp';

    final showDesktopStartup =
        !widget.backend.isWebMode && !widget.backend.isAndroidPlatform;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 740),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
          child: Material(
            color: Colors.transparent,
            child: CustomPaint(
              foregroundPainter: PrismSpecularRimPainter(
                radius: 26,
                isDark: c.isDark,
                intensity: c.isDark ? 0.85 : 0.95,
              ),
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: c.paper,
                  shape: prismSuperellipse(
                    26,
                    side: BorderSide(color: c.hairline),
                  ),
                  shadows: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: c.isDark ? 0.56 : 0.14,
                      ),
                      blurRadius: 42,
                      offset: const Offset(0, 18),
                    ),
                  ],
                ),
                child: ClipRSuperellipse(
                  borderRadius: BorderRadius.circular(26),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Header
                      Container(
                        padding: const EdgeInsets.fromLTRB(24, 20, 20, 16),
                        decoration: BoxDecoration(
                          color: c.paper2,
                          border: Border(
                            bottom: BorderSide(
                              color: c.hairline.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const PrismSparkIcon(size: 38),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        '欢迎使用 Agent MCP',
                                        style: sansStyle(
                                          c,
                                          size: 16.5,
                                          weight: FontWeight.w700,
                                          color: c.ink,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      PrismPill(
                                        text: '初始化设置',
                                        mono: false,
                                        fg: c.clay,
                                        bg: c.clay.withValues(alpha: 0.11),
                                        border: c.clay.withValues(alpha: 0.28),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '完成 OAuth 安全口令、Quick 临时公网隧道与 Tailscale 组网配置，即刻接入 AI 客户端',
                                    style: sansStyle(
                                      c,
                                      size: 12.0,
                                      color: c.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Body
                      Flexible(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // 1. OAuth Password & Server Name
                              PrismListGroup(
                                headerLabel: '1 · 节点名称与 OAuth 授权密码',
                                headerTrailing: PrismPill(
                                  text: (_hasSavedPassword ||
                                          _pwdCtrl.text.trim().isNotEmpty)
                                      ? '口令已就绪'
                                      : '待设置口令',
                                  mono: false,
                                  fg: (_hasSavedPassword ||
                                          _pwdCtrl.text.trim().isNotEmpty)
                                      ? c.sage
                                      : const Color(0xFFD97706),
                                  bg: (_hasSavedPassword ||
                                          _pwdCtrl.text.trim().isNotEmpty)
                                      ? c.sageBg
                                      : const Color(0x1FD97706),
                                ),
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      13,
                                      16,
                                      13,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Row(
                                          children: [
                                            SizedBox(
                                              width: 112,
                                              child: Text(
                                                '服务显示名称',
                                                style: sansStyle(
                                                  c,
                                                  size: 12.6,
                                                  weight: FontWeight.w600,
                                                  color: c.ink,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              child: TextField(
                                                controller: _serverNameCtrl,
                                                style: sansStyle(
                                                  c,
                                                  size: 12.8,
                                                  color: c.ink,
                                                ),
                                                decoration:
                                                    const InputDecoration(
                                                  isDense: true,
                                                  hintText: '例如：Omen Desktop MCP',
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.center,
                                          children: [
                                            SizedBox(
                                              width: 112,
                                              child: Text(
                                                'OAuth 授权密码',
                                                style: sansStyle(
                                                  c,
                                                  size: 12.6,
                                                  weight: FontWeight.w600,
                                                  color: c.ink,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              child: PrismPasswordField(
                                                controller: _pwdCtrl,
                                                hintText: _hasSavedPassword
                                                    ? '已设置密码（留空保持原密码不变）'
                                                    : '设置用于 OAuth 授权与 Web 控制台登录的密码',
                                                onChanged: (_) {
                                                  if (_validationError
                                                      .isNotEmpty) {
                                                    setState(
                                                      () =>
                                                          _validationError = '',
                                                    );
                                                  } else {
                                                    setState(() {});
                                                  }
                                                },
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            PrismButton(
                                              label: '随机生成',
                                              compact: true,
                                              leading: const Icon(
                                                Icons.casino_outlined,
                                              ),
                                              onPressed:
                                                  _generateStrongPassword,
                                            ),
                                          ],
                                        ),
                                        if (_generatedPasswordPreview
                                            .isNotEmpty) ...[
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              Icon(
                                                Icons.check_circle_outline_rounded,
                                                size: 14,
                                                color: c.sage,
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Text(
                                                  '已生成并复制口令：$_generatedPasswordPreview（请妥善保存）',
                                                  style: monoStyle(
                                                    c,
                                                    size: 11.5,
                                                    color: c.inkSoft,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                        const SizedBox(height: 8),
                                        Text(
                                          '已默认开启 OAuth 2.1 回调地址白名单（预置 Claude、Gemini、ChatGPT、Cursor、VS Code 官方回调规则）。',
                                          style: sansStyle(
                                            c,
                                            size: 11.4,
                                            color: c.muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 16),

                              // 2. Primary Entry Tunnel Mode (Default Quick)
                              PrismListGroup(
                                headerLabel: '2 · 主入口公网连接方式',
                                headerTrailing: PrismPill(
                                  text: _tunnelMode == 'quick'
                                      ? (liveQuickUrl.isNotEmpty
                                          ? 'Quick 隧道已连通'
                                          : '默认推荐 · 免配置')
                                      : (_tunnelMode == 'playit'
                                          ? 'Playit 持久地址'
                                          : (_tunnelMode == 'token'
                                              ? '固定域名隧道'
                                              : '局域网 / 组网直连')),
                                  mono: false,
                                  fg: liveQuickUrl.isNotEmpty &&
                                          _tunnelMode == 'quick'
                                      ? c.sage
                                      : c.clay,
                                  bg: liveQuickUrl.isNotEmpty &&
                                          _tunnelMode == 'quick'
                                      ? c.sageBg
                                      : c.clay.withValues(alpha: 0.11),
                                ),
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      13,
                                      16,
                                      13,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        PrismSegmented<String>(
                                          value: _tunnelMode,
                                          items: const [
                                            ('quick', 'Quick 临时（默认）'),
                                            ('playit', 'Playit 持久'),
                                            ('token', 'CF 固定域名'),
                                            ('none', '仅局域网'),
                                          ],
                                          onChanged: (v) => setState(() {
                                            _tunnelMode = v;
                                            _validationError = '';
                                          }),
                                        ),
                                        const SizedBox(height: 12),
                                        if (_tunnelMode == 'quick') ...[
                                          Row(
                                            children: [
                                              Icon(
                                                cfInstalled
                                                    ? Icons.cloud_done_rounded
                                                    : Icons.cloud_download_outlined,
                                                size: 16,
                                                color: cfInstalled
                                                    ? c.sage
                                                    : const Color(0xFFD97706),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  cfInstalled
                                                      ? 'Cloudflared 组件已就绪${cfVer.isNotEmpty ? " (v$cfVer)" : ""} · 自动分配 *.trycloudflare.com 公网 HTTPS 端点'
                                                      : (cfDlActive
                                                          ? '正在下载 Cloudflared 组件 ($cfDlPct%)...'
                                                          : '尚未检测到 Cloudflared 组件，点击右侧按钮一键自动下载'),
                                                  style: sansStyle(
                                                    c,
                                                    size: 12.0,
                                                    color: c.inkSoft,
                                                  ),
                                                ),
                                              ),
                                              if (!cfInstalled) ...[
                                                const SizedBox(width: 8),
                                                PrismButton(
                                                  label: cfDlActive
                                                      ? '下载中 $cfDlPct%'
                                                      : '下载组件',
                                                  compact: true,
                                                  loading:
                                                      _downloadingCf || cfDlActive,
                                                  variant: PrismBtnVariant.clay,
                                                  onPressed: cfDlActive
                                                      ? null
                                                      : _installCloudflared,
                                                ),
                                              ],
                                            ],
                                          ),
                                          if (liveQuickUrl.isNotEmpty) ...[
                                            const SizedBox(height: 10),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 12,
                                                vertical: 8,
                                              ),
                                              decoration: ShapeDecoration(
                                                color: c.paper3,
                                                shape: prismSuperellipse(
                                                  12,
                                                  side: BorderSide(
                                                    color: c.hairline,
                                                  ),
                                                ),
                                              ),
                                              child: Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      '$liveQuickUrl/mcp',
                                                      style: monoStyle(
                                                        c,
                                                        size: 11.8,
                                                        color: c.ink,
                                                      ),
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  PrismButton(
                                                    label: '复制 MCP 地址',
                                                    compact: true,
                                                    leading: const Icon(
                                                      Icons.copy_rounded,
                                                    ),
                                                    onPressed: () {
                                                      Clipboard.setData(
                                                        ClipboardData(
                                                          text:
                                                              '$liveQuickUrl/mcp',
                                                        ),
                                                      );
                                                      widget.onToast(
                                                        '已复制临时公网 MCP 地址：$liveQuickUrl/mcp',
                                                      );
                                                    },
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ] else if (_tunnelMode == 'playit') ...[
                                          PlayitClaimAndDomainCard(
                                            backend: widget.backend,
                                            profileId: 'default',
                                            claimMode: _playitClaimMode,
                                            onClaimModeChanged: (m) => setState(
                                              () => _playitClaimMode = m,
                                            ),
                                            customClaimCtrl:
                                                _playitCustomClaimCtrl,
                                            domainMode: _playitDomainMode,
                                            onDomainModeChanged: (m) =>
                                                setState(
                                              () => _playitDomainMode = m,
                                            ),
                                            hostnameCtrl: _playitHostCtrl,
                                            onToast: widget.onToast,
                                            onStatusChanged: _pollRuntimeState,
                                          ),
                                        ] else if (_tunnelMode == 'token') ...[
                                          PrismPasswordField(
                                            controller: _tokenCtrl,
                                            hintText:
                                                '粘贴 Cloudflare Zero Trust Tunnel Token (eyJh...)',
                                          ),
                                          const SizedBox(height: 10),
                                          TextField(
                                            controller: _domainCtrl,
                                            style: monoStyle(
                                              c,
                                              size: 12.4,
                                              color: c.ink,
                                            ),
                                            decoration: const InputDecoration(
                                              isDense: true,
                                              hintText:
                                                  '绑定的公网 HTTPS 域名，例如 https://mcp.example.com',
                                            ),
                                          ),
                                        ] else ...[
                                          Text(
                                            '当前仅通过本机回环、局域网或 Tailscale 组网访问（示例端点：$sampleLanUrl）。',
                                            style: sansStyle(
                                              c,
                                              size: 12.0,
                                              color: c.muted,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 16),

                              // 3. Tailscale Detection & One-Click Download
                              PrismListGroup(
                                headerLabel: '3 · Tailscale 异地组网与直享（可选推荐）',
                                headerTrailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    PrismPill(
                                      text: tsReachable
                                          ? '已连接 · ${tsIps.isNotEmpty ? tsIps.first : tsDns}'
                                          : (tsInstalled
                                              ? '已安装 · 待登录'
                                              : '未安装'),
                                      mono: false,
                                      fg: tsReachable
                                          ? c.sage
                                          : (tsInstalled
                                              ? const Color(0xFFD97706)
                                              : c.muted),
                                      bg: tsReachable
                                          ? c.sageBg
                                          : (tsInstalled
                                              ? const Color(0x1FD97706)
                                              : c.recessed),
                                    ),
                                    const SizedBox(width: 8),
                                    PrismButton(
                                      label: '重新检测',
                                      compact: true,
                                      loading: _probingTs,
                                      leading: const Icon(
                                        Icons.refresh_rounded,
                                      ),
                                      onPressed: () =>
                                          _refreshTailscale(toast: true),
                                    ),
                                  ],
                                ),
                                children: [
                                  if (!tsInstalled)
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        16,
                                        13,
                                        16,
                                        13,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '安装 Tailscale 后可获得固定 100.x 加密组网 IP 与 *.ts.net 域名，跨网络免端口映射直连多台电脑与手机，并支持一键本地文件/端口直享。',
                                            style: sansStyle(
                                              c,
                                              size: 12.0,
                                              color: c.inkSoft,
                                            ),
                                          ),
                                          const SizedBox(height: 11),
                                          Wrap(
                                            spacing: 8,
                                            runSpacing: 8,
                                            children: [
                                              if (widget
                                                      .backend.isWindowsPlatform &&
                                                  !widget
                                                      .backend.isRemoteNodeActive)
                                                PrismButton(
                                                  label: 'winget 一键安装',
                                                  compact: true,
                                                  loading: _installingTs,
                                                  variant: PrismBtnVariant.clay,
                                                  leading: const Icon(
                                                    Icons.bolt_rounded,
                                                  ),
                                                  onPressed:
                                                      _handleInstallTailscale,
                                                ),
                                              PrismButton(
                                                label: '前往官网下载 Tailscale',
                                                compact: true,
                                                variant: widget.backend
                                                        .isWindowsPlatform
                                                    ? PrismBtnVariant.neutral
                                                    : PrismBtnVariant.clay,
                                                leading: const Icon(
                                                  Icons.open_in_new_rounded,
                                                ),
                                                onPressed:
                                                    _openTailscaleDownloadWebsite,
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    )
                                  else
                                    PrismSettingsRow(
                                      icon: Icons.hub_rounded,
                                      title: '启用 Tailscale 组网与 Funnel 联动',
                                      subtitle: tsReachable
                                          ? '已识别组网节点 ${tsDns.isNotEmpty ? tsDns : tsIps.join(", ")}，支持免公网安全直连'
                                          : '已检测到本机 Tailscale 客户端，登录账号后即可自动识别 100.x 组网地址',
                                      trailing: PrismSwitch(
                                        value: _tsEnabled,
                                        onChanged: (v) =>
                                            setState(() => _tsEnabled = v),
                                      ),
                                    ),
                                ],
                              ),

                              if (showDesktopStartup) ...[
                                const SizedBox(height: 16),
                                PrismListGroup(
                                  headerLabel: '4 · 桌面驻留与开机自启',
                                  children: [
                                    PrismSettingsRow(
                                      icon: Icons.power_settings_new_rounded,
                                      title: '开机自动启动 Agent MCP',
                                      subtitle: '登录系统后自动启动本机 MCP 服务与公网隧道',
                                      trailing: PrismSwitch(
                                        value: _launchAtStartup,
                                        onChanged: (v) => setState(
                                          () => _launchAtStartup = v,
                                        ),
                                      ),
                                    ),
                                    PrismSettingsRow(
                                      icon: Icons.nights_stay_outlined,
                                      title: '启动时静默驻留系统托盘',
                                      subtitle: '后台无打扰运行，随时点击右下角托盘棱镜图标唤出控制台',
                                      trailing: PrismSwitch(
                                        value: _silentStart,
                                        onChanged: (v) =>
                                            setState(() => _silentStart = v),
                                      ),
                                    ),
                                  ],
                                ),
                              ],

                              if (_validationError.isNotEmpty) ...[
                                const SizedBox(height: 14),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 13,
                                    vertical: 10,
                                  ),
                                  decoration: ShapeDecoration(
                                    color: c.danger.withValues(alpha: 0.10),
                                    shape: prismSuperellipse(
                                      13,
                                      side: BorderSide(
                                        color: c.danger.withValues(alpha: 0.35),
                                      ),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.error_outline_rounded,
                                        size: 16,
                                        color: c.danger,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          _validationError,
                                          style: sansStyle(
                                            c,
                                            size: 12.0,
                                            color: c.danger,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),

                      // Footer
                      Container(
                        padding: const EdgeInsets.fromLTRB(20, 13, 20, 15),
                        decoration: BoxDecoration(
                          color: c.paper2,
                          border: Border(
                            top: BorderSide(
                              color: c.hairline.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                        child: Row(
                          children: [
                            PrismButton(
                              label: '稍后设置',
                              variant: PrismBtnVariant.ghost,
                              onPressed: _saving ? null : _skipForNow,
                            ),
                            const Spacer(),
                            PrismButton(
                              label: '保存并完成初始化',
                              variant: PrismBtnVariant.clay,
                              loading: _saving,
                              leading: const Icon(Icons.check_rounded),
                              onPressed: _applyAndFinish,
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
        ),
      ),
    );
  }
}
