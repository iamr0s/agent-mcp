import 'package:flutter/material.dart';

import '../services/console_backend.dart';
import '../theme/claude_theme.dart';

class AndroidPrivilegeCard extends StatefulWidget {
  final ConsoleBackend backend;
  final Map<String, dynamic> config;
  final Future<void> Function() onRefreshStatus;
  final ValueChanged<String> onToast;

  const AndroidPrivilegeCard({
    super.key,
    required this.backend,
    required this.config,
    required this.onRefreshStatus,
    required this.onToast,
  });

  @override
  State<AndroidPrivilegeCard> createState() => _AndroidPrivilegeCardState();
}

class _AndroidPrivilegeCardState extends State<AndroidPrivilegeCard> {
  String? _switchingMode;
  bool _requestingPerm = false;

  Map<String, dynamic> get _privStatus {
    final raw = widget.config['privilege_status'];
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return const <String, dynamic>{};
  }

  String get _requestedMode {
    final s = (_privStatus['requested_mode'] ??
            widget.config['android_privilege_mode'] ??
            'none')
        .toString()
        .trim()
        .toLowerCase();
    if (s == 'shizuku' || s == 'root') return s;
    return 'none';
  }

  bool get _mountMaster {
    if (_privStatus.containsKey('mount_master')) {
      return _privStatus['mount_master'] != false;
    }
    return widget.config['android_su_mount_master'] != false;
  }

  Future<void> _selectMode(String mode, {bool? mountMasterOverride}) async {
    if (_switchingMode != null) return;
    final mm = mountMasterOverride ?? _mountMaster;
    setState(() => _switchingMode = mode);
    try {
      final res = await runWithMinDuration(
        () => widget.backend.applyPrivilegeConfig(
          mode: mode,
          mountMaster: mm,
          interactive: true,
        ),
      );
      await widget.onRefreshStatus();
      final priv = res['privilege'] is Map
          ? Map<String, dynamic>.from(res['privilege'] as Map)
          : _privStatus;
      final ready = priv['bridge_ready'] == true;
      final err = (priv['error'] ?? '').toString().trim();
      final label = (priv['effective_label'] ?? '').toString().trim();
      if (mode == 'none') {
        widget.onToast('已切换为普通应用沙盒级别');
      } else if (ready) {
        widget.onToast('已切换执行权限：${label.isNotEmpty ? label : mode}');
      } else if (err.isNotEmpty) {
        widget.onToast(err);
      }
    } finally {
      if (mounted) setState(() => _switchingMode = null);
    }
  }

  Future<void> _requestShizukuAuth() async {
    if (_requestingPerm) return;
    setState(() => _requestingPerm = true);
    try {
      final res = await widget.backend.requestShizukuPermission();
      await widget.onRefreshStatus();
      final priv = res['privilege'] is Map
          ? Map<String, dynamic>.from(res['privilege'] as Map)
          : _privStatus;
      if (priv['bridge_ready'] == true) {
        widget.onToast(
          'Shizuku 授权成功：${priv['effective_label'] ?? '特权已连接'}',
        );
      } else {
        final err = (priv['error'] ?? '').toString().trim();
        if (err.isNotEmpty) widget.onToast(err);
      }
    } finally {
      if (mounted) setState(() => _requestingPerm = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final st = _privStatus;
    final reqMode = _requestedMode;
    final bridgeReady = st['bridge_ready'] == true;
    final activeMode = (st['active_mode'] ?? 'none').toString();
    final effectiveUid = int.tryParse('${st['effective_uid'] ?? -1}') ?? -1;
    final effectiveLabel = (st['effective_label'] ??
            (reqMode == 'none' ? '普通沙盒' : '等待特权就绪'))
        .toString();
    final errText = (st['error'] ?? '').toString().trim();

    final shizukuInstalled = st['shizuku_installed'] == true;
    final shizukuRunning = st['shizuku_running'] == true;
    final shizukuAuthorized = st['shizuku_authorized'] == true;
    final shizukuUid = int.tryParse('${st['shizuku_uid'] ?? -1}') ?? -1;
    final shizukuVer = int.tryParse('${st['shizuku_version'] ?? -1}') ?? -1;

    final rootManagers = ((st['root_managers'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => Map<String, String>.from(
              m.map((k, v) => MapEntry(k.toString(), v.toString())),
            ))
        .toList();

    final canLaunchLocalApps =
        widget.backend.isAndroidPlatform && !widget.backend.isRemoteNodeActive;

    final isDegraded = reqMode != 'none' && !bridgeReady;
    final statusColor = bridgeReady
        ? c.sage
        : (isDegraded ? c.clay : c.muted);
    final statusBg = bridgeReady
        ? c.sageBg
        : (isDegraded ? c.clay.withValues(alpha: 0.12) : c.paper2);

    final shizukuBadge = shizukuRunning
        ? (shizukuAuthorized
            ? (shizukuUid == 0
                ? 'Root (UID 0)'
                : (shizukuUid == 2000 ? 'ADB (UID 2000)' : '已授权'))
            : '待授权')
        : (shizukuInstalled ? '未激活' : '未安装');

    final rootBadge = bridgeReady && activeMode == 'root'
        ? 'UID 0 已连接'
        : (rootManagers.isNotEmpty
            ? rootManagers.map((m) => m['name'] ?? '').join(' / ')
            : 'UID 0');

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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Android 运行权限级别',
                    style: serifTitleStyle(c, size: 18),
                  ),
                ],
              ),
              ClaudePill(
                leading: ClaudeStatusDot(
                  color: statusColor,
                  pulsing: bridgeReady,
                  size: 7,
                ),
                text: isDegraded ? '等待授权 · 暂驻沙盒' : effectiveLabel,
                mono: false,
                fg: statusColor,
                bg: statusBg,
                border: isDegraded ? c.clay.withValues(alpha: 0.28) : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '按需选择手机本地工具的执行权限：平时管共享文件或远控电脑选「普通沙盒」即可；需要抓系统日志、管理安装包或跨目录排障时，点选 Shizuku 或 Root SU 一键提权。',
            style: sansStyle(c, size: 12.8, color: c.muted, height: 1.54),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (ctx, box) {
              final cols = box.maxWidth < 560 ? 1 : 3;
              const gap = 10.0;
              final tileW = (box.maxWidth - gap * (cols - 1)) / cols;

              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  SizedBox(
                    width: tileW,
                    child: _AuthorizerModeTile(
                      title: '普通沙盒',
                      badge: 'App UID',
                      subtitle: '零额外授权，开箱即用。适合读写共享目录，或把手机当成多台电脑的随身遥控器',
                      icon: Icons.shield_outlined,
                      selected: reqMode == 'none',
                      activeReady: reqMode == 'none',
                      loading: _switchingMode == 'none',
                      onTap: () => _selectMode('none'),
                    ),
                  ),
                  SizedBox(
                    width: tileW,
                    child: _AuthorizerModeTile(
                      title: 'Shizuku',
                      badge: shizukuBadge,
                      subtitle:
                          '免 Root 解锁无线调试级能力：先启动 Shizuku 再点此授权，即可跑 pm / dumpsys / logcat',
                      icon: Icons.bolt_rounded,
                      selected: reqMode == 'shizuku',
                      activeReady: bridgeReady && activeMode == 'shizuku',
                      loading: _switchingMode == 'shizuku',
                      onTap: () => _selectMode('shizuku'),
                    ),
                  ),
                  SizedBox(
                    width: tileW,
                    child: _AuthorizerModeTile(
                      title: 'Root SU',
                      badge: rootBadge,
                      subtitle:
                          '最高系统权限（支持 KernelSU / APatch / Magisk）：首次点允许后常驻生效，免重复弹窗',
                      icon: Icons.terminal_rounded,
                      selected: reqMode == 'root',
                      activeReady: bridgeReady && activeMode == 'root',
                      loading: _switchingMode == 'root',
                      onTap: () => _selectMode('root'),
                    ),
                  ),
                ],
              );
            },
          ),
          ClaudeCollapsible(
            expanded: reqMode != 'none',
            builder: (_) => Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(13),
                decoration: ShapeDecoration(
                  color: c.recessed,
                  shape: claudeSuperellipse(
                    13,
                    side: BorderSide(
                      color: isDegraded
                          ? c.clay.withValues(alpha: 0.34)
                          : c.hairline,
                    ),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (reqMode == 'root') ...[
                      ClaudeCheckToggle(
                        value: _mountMaster,
                        label: '全局挂载命名空间 (--mount-master，推荐开启以访问全局挂载点)',
                        onChanged: (v) =>
                            _selectMode('root', mountMasterOverride: v),
                      ),
                      const SizedBox(height: 10),
                    ],
                    if (bridgeReady) ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.verified_rounded,
                            size: 16,
                            color: c.sage,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              effectiveUid == 0
                                  ? 'Root SU (UID 0) 已就绪：AI 可直接读写 /sdcard、Android/data、/data/local/tmp、/data/adb 并执行系统级终端命令。'
                                  : 'Shizuku (UID $effectiveUid) 已就绪：AI 可直接访问 /sdcard、Android/data、/data/local/tmp 并执行 pm / dumpsys / am 等调试命令。',
                              style: sansStyle(
                                c,
                                size: 12.2,
                                color: c.inkSoft,
                                height: 1.48,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ] else if (errText.isNotEmpty) ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 16,
                            color: c.clay,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              errText,
                              style: sansStyle(
                                c,
                                size: 12.2,
                                color: c.clay,
                                height: 1.48,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (reqMode == 'shizuku' && shizukuVer > 0) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Shizuku 服务版本: v$shizukuVer · 状态: ${shizukuAuthorized ? "已授权" : "未授权"}',
                        style: monoStyle(c, size: 11.5, color: c.meta),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (reqMode == 'shizuku') ...[
                          if (canLaunchLocalApps &&
                              shizukuRunning &&
                              !shizukuAuthorized)
                            ClaudeButton(
                              label: _requestingPerm ? '请求中...' : '授权 Shizuku',
                              compact: true,
                              loading: _requestingPerm,
                              variant: ClaudeBtnVariant.clay,
                              leading: const Icon(Icons.vpn_key_outlined),
                              onPressed: _requestShizukuAuth,
                            ),
                          ClaudeButton(
                            label: _switchingMode == 'shizuku'
                                ? '连接中...'
                                : '检测并重连',
                            compact: true,
                            loading: _switchingMode == 'shizuku',
                            leading: const Icon(Icons.refresh_rounded),
                            onPressed: () => _selectMode('shizuku'),
                          ),
                          if (canLaunchLocalApps && shizukuInstalled)
                            ClaudeButton(
                              label: '打开 Shizuku',
                              compact: true,
                              leading: const Icon(Icons.open_in_new_rounded),
                              onPressed: () async {
                                final ok = await widget.backend
                                    .openPrivilegeManagerApp('shizuku');
                                if (!ok) {
                                  widget.onToast('未能打开 Shizuku 应用');
                                }
                              },
                            ),
                        ],
                        if (reqMode == 'root') ...[
                          ClaudeButton(
                            label: _switchingMode == 'root'
                                ? '请求 Root 中...'
                                : (bridgeReady ? '重新握手验证' : '检测并连接 Root'),
                            compact: true,
                            loading: _switchingMode == 'root',
                            variant: bridgeReady
                                ? ClaudeBtnVariant.neutral
                                : ClaudeBtnVariant.clay,
                            leading: const Icon(Icons.refresh_rounded),
                            onPressed: () => _selectMode('root'),
                          ),
                          if (canLaunchLocalApps)
                            for (final mgr in rootManagers)
                              ClaudeButton(
                                label: '打开 ${mgr['name']} 授权',
                                compact: true,
                                leading: const Icon(Icons.open_in_new_rounded),
                                onPressed: () async {
                                  final pkg = mgr['package'] ?? '';
                                  final ok = await widget.backend
                                      .openPrivilegeManagerApp(pkg);
                                  if (!ok) {
                                    widget.onToast('未能打开 ${mgr['name']}');
                                  }
                                },
                              ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthorizerModeTile extends StatefulWidget {
  final String title;
  final String badge;
  final String subtitle;
  final IconData icon;
  final bool selected;
  final bool activeReady;
  final bool loading;
  final VoidCallback onTap;

  const _AuthorizerModeTile({
    required this.title,
    required this.badge,
    required this.subtitle,
    required this.icon,
    required this.selected,
    required this.activeReady,
    required this.loading,
    required this.onTap,
  });

  @override
  State<_AuthorizerModeTile> createState() => _AuthorizerModeTileState();
}

class _AuthorizerModeTileState extends State<_AuthorizerModeTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final sel = widget.selected;
    final borderColor = sel
        ? (widget.activeReady ? c.sage : c.clay)
        : (_hovered ? c.ringHover : c.hairline);
    final bg = sel
        ? (widget.activeReady
            ? c.sageBg.withValues(alpha: c.isDark ? 0.55 : 0.72)
            : c.clay.withValues(alpha: c.isDark ? 0.14 : 0.08))
        : (_hovered ? c.paper3 : c.recessed);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.loading ? null : widget.onTap,
        child: AnimatedContainer(
          duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
          curve: ClaudeMotion.editorialOut,
          padding: const EdgeInsets.all(13),
          decoration: ShapeDecoration(
            color: bg,
            shape: claudeSuperellipse(
              14,
              side: BorderSide(
                color: borderColor,
                width: sel ? 1.35 : 1.0,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    widget.icon,
                    size: 16.5,
                    color: sel
                        ? (widget.activeReady ? c.sage : c.clay)
                        : c.inkSoft,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      widget.title,
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
                  if (widget.loading)
                    SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        valueColor: AlwaysStoppedAnimation<Color>(c.clay),
                      ),
                    )
                  else
                    ClaudePill(
                      text: widget.badge,
                      mono: false,
                      fg: sel
                          ? (widget.activeReady ? c.sage : c.clay)
                          : c.muted,
                      bg: c.paper2,
                    ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                widget.subtitle,
                style: sansStyle(
                  c,
                  size: 11.8,
                  color: c.muted,
                  height: 1.44,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}