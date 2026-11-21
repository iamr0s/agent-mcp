import 'package:flutter/material.dart';

import '../services/console_backend.dart';
import '../theme/claude_theme.dart';

@immutable
class HostIpOption {
  final String ip;
  final String iface;
  final String kind; // 'loopback' | 'lan' | 'vpn' | 'public' | 'tun_proxy' | 'saved'
  final String label;
  final bool offlineSaved;

  const HostIpOption({
    required this.ip,
    required this.iface,
    required this.kind,
    required this.label,
    this.offlineSaved = false,
  });
}

String classifyIpKindLabel(String ip, [String iface = '']) {
  if (ip == kLoopbackIpv4 || ip.startsWith('127.')) return '本机回环';
  if (ip.startsWith('198.18.')) return '代理 TUN';
  final parts = ip.split('.');
  final p0 = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? -1) : -1;
  final p1 = parts.length > 1 ? (int.tryParse(parts[1]) ?? -1) : -1;
  final lower = iface.toLowerCase();
  if ((p0 == 100 && p1 >= 64 && p1 <= 127) ||
      lower.contains('tailscale') ||
      lower.contains('zerotier') ||
      lower.startsWith('wg')) {
    return '组网 / Tailscale';
  }
  if (p0 == 10 ||
      (p0 == 172 && p1 >= 16 && p1 <= 31) ||
      (p0 == 192 && p1 == 168)) {
    return '局域网';
  }
  return '外部地址';
}

List<HostIpOption> parseHostIpOptions(
  Map<String, dynamic> config,
  List<String> fallbackLanIps,
) {
  final out = <HostIpOption>[];
  final seen = <String>{};

  final rawIfaces = config['network_interfaces'];
  if (rawIfaces is List) {
    for (final item in rawIfaces) {
      if (item is Map) {
        final ip = (item['ip'] ?? '').toString().trim();
        if (ip.isEmpty || !seen.add(ip)) continue;
        final iface = (item['iface'] ?? '').toString().trim();
        final kind = (item['kind'] ?? 'lan').toString().trim();
        final label = (item['label'] ?? classifyIpKindLabel(ip, iface))
            .toString()
            .trim();
        out.add(HostIpOption(ip: ip, iface: iface, kind: kind, label: label));
      }
    }
  }

  if (!seen.contains(kLoopbackIpv4)) {
    seen.add(kLoopbackIpv4);
    out.insert(
      0,
      const HostIpOption(
        ip: kLoopbackIpv4,
        iface: 'lo',
        kind: 'loopback',
        label: '本机回环',
      ),
    );
  }

  for (final rawIp in fallbackLanIps) {
    final ip = rawIp.trim();
    if (ip.isEmpty || !seen.add(ip)) continue;
    final lbl = classifyIpKindLabel(ip);
    final kind = lbl.contains('Tailscale')
        ? 'vpn'
        : (lbl.contains('TUN') ? 'tun_proxy' : 'lan');
    out.add(HostIpOption(ip: ip, iface: '', kind: kind, label: lbl));
  }

  return out;
}

String normalizeUiDirectBaseUrl(String raw) {
  return normalizeRemoteBaseUrl(raw);
}

List<String> resolveUiProfileBaseUrls(
  Map<String, dynamic> prof, {
  required int port,
  required String fallbackHost,
  String? liveQuickUrl,
}) {
  final tMode = (prof['tunnel_mode'] ?? 'none').toString().trim().toLowerCase();
  if (tMode == 'quick') {
    final q = (liveQuickUrl ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    return q.isNotEmpty ? <String>[q] : const <String>[];
  }
  if (tMode == 'token') {
    final b = normalizeUiDirectBaseUrl((prof['base_url'] ?? '').toString());
    return b.isNotEmpty ? <String>[b] : const <String>[];
  }

  final urls = <String>[];
  void addUnique(String candidate) {
    final norm = normalizeUiDirectBaseUrl(candidate);
    if (norm.isNotEmpty && !urls.contains(norm)) {
      urls.add(norm);
    }
  }

  final directIps = prof['direct_ips'];
  if (directIps is List) {
    for (final item in directIps) {
      final ip = item.toString().trim();
      if (ip.isEmpty) continue;
      if (ip.contains('://') || ip.contains(':')) {
        addUnique(ip);
      } else {
        addUnique('http://$ip:$port');
      }
    }
  }

  final manualUrls = prof['manual_urls'];
  if (manualUrls is List) {
    for (final item in manualUrls) {
      addUnique(item.toString());
    }
  }

  if (urls.isEmpty) {
    final multi = prof['base_urls'];
    if (multi is List) {
      for (final item in multi) {
        addUnique(item.toString());
      }
    }
  }

  if (urls.isEmpty) {
    final b = (prof['base_url'] ?? '').toString().trim();
    if (b.isNotEmpty) addUnique(b);
  }

  if (urls.isEmpty) {
    final cleanHost = (fallbackHost == '0.0.0.0' ||
            fallbackHost == '::' ||
            fallbackHost.trim().isEmpty)
        ? kLoopbackIpv4
        : fallbackHost.trim();
    urls.add('http://$cleanHost:$port');
  }
  return urls;
}

List<EndpointCopyOption> buildProfileEndpointCopyOptions(
  Map<String, dynamic> prof,
  List<String> baseUrls,
) {
  final tr = (prof['transport'] ?? 'dual').toString().toLowerCase();
  final suffix = tr == 'sse' ? '/sse' : '/mcp';
  final opts = <EndpointCopyOption>[];

  for (final base in baseUrls) {
    final clean = base.replaceAll(RegExp(r'/+$'), '');
    if (clean.isEmpty) continue;
    Uri? u;
    try {
      u = Uri.parse(clean);
    } catch (_) {}
    final host = u?.host ?? '';
    final isIp = RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host) ||
        host == 'localhost';
    if (isIp) {
      final kindLbl = host == 'localhost'
          ? '本机回环'
          : classifyIpKindLabel(host);
      final shortBadge = kindLbl.contains('Tailscale')
          ? '组网'
          : (kindLbl.contains('回环') ? '回环' : '局域网');
      opts.add(
        EndpointCopyOption(
          badge: shortBadge,
          url: '$clean$suffix',
          isHighlight: kindLbl.contains('Tailscale') || kindLbl.contains('局域网'),
        ),
      );
    } else {
      final stripped = clean.replaceFirst(
        RegExp(r'^https?://', caseSensitive: false),
        '',
      );
      opts.add(
        EndpointCopyOption(
          badge: 'HTTPS',
          url: 'https://$stripped$suffix',
          isHighlight: true,
        ),
      );
      opts.add(
        EndpointCopyOption(
          badge: 'HTTP',
          url: 'http://$stripped$suffix',
          isHighlight: false,
        ),
      );
    }
  }

  if (opts.length > 1) {
    final allJoined = opts.map((o) => o.url).join('\n');
    opts.add(
      EndpointCopyOption(
        badge: '全部',
        url: allJoined,
        displayLabel: '复制全部 ${opts.length} 条地址',
        isHighlight: false,
        isCopyAll: true,
      ),
    );
  }
  return opts;
}

@immutable
class EndpointCopyOption {
  final String badge;
  final String url;
  final String? displayLabel;
  final bool isHighlight;
  final bool isCopyAll;

  const EndpointCopyOption({
    required this.badge,
    required this.url,
    this.displayLabel,
    this.isHighlight = false,
    this.isCopyAll = false,
  });
}

class EndpointCopyDropButton extends StatefulWidget {
  final String label;
  final List<EndpointCopyOption> options;
  final void Function(EndpointCopyOption option) onSelect;

  const EndpointCopyDropButton({
    super.key,
    this.label = '复制',
    required this.options,
    required this.onSelect,
  });

  @override
  State<EndpointCopyDropButton> createState() => _EndpointCopyDropButtonState();
}

class _EndpointCopyDropButtonState extends State<EndpointCopyDropButton>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _portalCtrl = OverlayPortalController();
  late final AnimationController _animCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 140),
  );

  bool _open = false;
  bool _hovered = false;
  bool _pressed = false;

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  void _toggleMenu() {
    if (widget.options.isEmpty) return;
    if (widget.options.length == 1) {
      widget.onSelect(widget.options.first);
      return;
    }
    if (_open) {
      _closeMenu();
    } else {
      _openMenu();
    }
  }

  void _openMenu() {
    if (_open) return;
    setState(() => _open = true);
    _portalCtrl.show();
    _animCtrl.forward(from: 0.0);
  }

  Future<void> _closeMenu() async {
    if (!_open) return;
    setState(() => _open = false);
    await _animCtrl.reverse();
    if (mounted && !_open && _portalCtrl.isShowing) {
      _portalCtrl.hide();
    }
  }

  Future<void> _pick(EndpointCopyOption opt) async {
    widget.onSelect(opt);
    await _closeMenu();
  }

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final singleDirect = widget.options.length == 1;
    final triggerElevated = _hovered || _open;
    final triggerBg = _pressed
        ? c.paper3
        : (_open ? c.paper3 : (_hovered ? c.paper3 : c.paper2));
    final triggerBorder =
        _open ? c.clay : (_hovered ? c.ringHover : c.hairline);

    final menuCurved = CurvedAnimation(
      parent: _animCtrl,
      curve: ClaudeMotion.snappySpring,
      reverseCurve: Curves.easeInCubic,
    );

    return CompositedTransformTarget(
      link: _layerLink,
      child: OverlayPortal(
        controller: _portalCtrl,
        overlayChildBuilder: (overlayCtx) {
          final oc = ClaudePalette.of(overlayCtx);
          return Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _closeMenu,
                ),
              ),
              CompositedTransformFollower(
                link: _layerLink,
                showWhenUnlinked: false,
                targetAnchor: Alignment.bottomRight,
                followerAnchor: Alignment.topRight,
                offset: const Offset(0, 7),
                child: FadeTransition(
                  opacity: _animCtrl.drive(CurveTween(curve: Curves.easeOut)),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.92, end: 1.0)
                        .animate(menuCurved),
                    alignment: Alignment.topRight,
                    child: Material(
                      type: MaterialType.transparency,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 256,
                          maxWidth: 360,
                          maxHeight: 320,
                        ),
                        child: ClaudeGlassBar(
                          blurSigma: 22,
                          borderRadius: 14,
                          tintColor: oc.isDark
                              ? const Color(0xF022211E)
                              : const Color(0xF5FAF9F5),
                          padding: const EdgeInsets.all(6),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black
                                  .withValues(alpha: oc.isDark ? 0.50 : 0.16),
                              blurRadius: 26,
                              spreadRadius: 1,
                              offset: const Offset(0, 10),
                            ),
                            BoxShadow(
                              color: Colors.black
                                  .withValues(alpha: oc.isDark ? 0.28 : 0.08),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0;
                                    i < widget.options.length;
                                    i++) ...[
                                  if (i > 0) const SizedBox(height: 4),
                                  _EndpointMenuTile(
                                    option: widget.options[i],
                                    onSelect: () => _pick(widget.options[i]),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
        child: Tooltip(
          message: singleDirect ? '复制入口地址' : '选择地址并复制',
          child: MouseRegion(
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
              onTap: widget.options.isEmpty ? null : _toggleMenu,
              child: AnimatedScale(
                scale: _pressed ? 0.955 : (_hovered && !_open ? 1.015 : 1.0),
                duration: ClaudeMotion.duration(
                  context,
                  _pressed
                      ? const Duration(milliseconds: 80)
                      : const Duration(milliseconds: 200),
                ),
                curve: _pressed
                    ? ClaudeMotion.standard
                    : ClaudeMotion.snappySpring,
                child: AnimatedContainer(
                  duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
                  curve: ClaudeMotion.editorialOut,
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 11),
                  decoration: ShapeDecoration(
                    color: triggerBg,
                    shape: claudeSuperellipse(
                      10,
                      side: BorderSide(color: triggerBorder),
                    ),
                    shadows: triggerElevated && !_pressed
                        ? [
                            BoxShadow(
                              color: Colors.black
                                  .withValues(alpha: c.isDark ? 0.34 : 0.10),
                              blurRadius: 12,
                              offset: const Offset(0, 4),
                            ),
                          ]
                        : const [],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.copy_rounded,
                        size: 13.5,
                        color: _open ? c.clay : c.inkSoft,
                      ),
                      const SizedBox(width: 5.5),
                      Text(
                        widget.label,
                        style: sansStyle(
                          c,
                          size: 12.5,
                          weight: FontWeight.w500,
                          color: _open ? c.ink : c.inkSoft,
                        ),
                      ),
                      if (!singleDirect) ...[
                        const SizedBox(width: 3),
                        AnimatedRotation(
                          turns: _open ? 0.5 : 0.0,
                          duration: ClaudeMotion.duration(
                            context,
                            const Duration(milliseconds: 180),
                          ),
                          curve: ClaudeMotion.editorialOut,
                          child: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 15.5,
                            color: _open ? c.clay : c.muted,
                          ),
                        ),
                      ],
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

class _EndpointMenuTile extends StatefulWidget {
  final EndpointCopyOption option;
  final VoidCallback onSelect;

  const _EndpointMenuTile({
    required this.option,
    required this.onSelect,
  });

  @override
  State<_EndpointMenuTile> createState() => _EndpointMenuTileState();
}

class _EndpointMenuTileState extends State<_EndpointMenuTile> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final opt = widget.option;
    final bg = _pressed
        ? c.clay.withValues(alpha: c.isDark ? 0.18 : 0.12)
        : (_hovered
            ? c.paper3.withValues(alpha: 0.92)
            : c.paper3.withValues(alpha: 0.0));
    final border = _pressed
        ? c.clay.withValues(alpha: 0.40)
        : (_hovered ? c.ringHover : c.hairline.withValues(alpha: 0.0));

    final badgeFg = opt.isCopyAll
        ? c.inkSoft
        : (opt.isHighlight ? c.sage : c.clay);
    final badgeBg = opt.isCopyAll
        ? c.recessed
        : (opt.isHighlight ? c.sageBg : c.clay.withValues(alpha: 0.12));

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
        onTap: widget.onSelect,
        child: AnimatedContainer(
          duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
          curve: ClaudeMotion.editorialOut,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8.5),
          decoration: ShapeDecoration(
            color: bg,
            shape: claudeSuperellipse(
              10,
              side: BorderSide(color: border),
            ),
          ),
          child: Row(
            children: [
              ClaudePill(
                text: opt.badge,
                mono: !opt.isCopyAll,
                fg: badgeFg,
                bg: badgeBg,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  opt.displayLabel ?? opt.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: opt.isCopyAll
                      ? sansStyle(
                          c,
                          size: 12,
                          weight: FontWeight.w500,
                          color: _hovered ? c.ink : c.inkSoft,
                        )
                      : monoStyle(
                          c,
                          size: 11.4,
                          color: _hovered ? c.ink : c.inkSoft,
                        ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                opt.isCopyAll
                    ? Icons.library_add_check_outlined
                    : Icons.content_copy_rounded,
                size: 13.5,
                color: _hovered ? c.clay : c.meta,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SelectableIpChip extends StatefulWidget {
  final HostIpOption option;
  final bool selected;
  final VoidCallback onTap;

  const SelectableIpChip({
    super.key,
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  State<SelectableIpChip> createState() => _SelectableIpChipState();
}

class _SelectableIpChipState extends State<SelectableIpChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final sel = widget.selected;
    final opt = widget.option;
    final isVpnOrLan = opt.kind == 'vpn' || opt.kind == 'lan';

    final bg = sel
        ? (isVpnOrLan
            ? c.sageBg.withValues(alpha: c.isDark ? 0.65 : 0.85)
            : c.clay.withValues(alpha: c.isDark ? 0.18 : 0.11))
        : (_hovered ? c.paper3 : c.recessed);
    final border = sel
        ? (isVpnOrLan ? c.sage : c.clay)
        : (_hovered ? c.ringHover : c.hairline);
    final accent = sel ? (isVpnOrLan ? c.sage : c.clay) : c.muted;

    final tagText = opt.offlineSaved
        ? '已存离线'
        : (opt.iface.isNotEmpty && opt.iface != 'lo'
            ? '${opt.label} · ${opt.iface}'
            : opt.label);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
          curve: ClaudeMotion.editorialOut,
          padding: const EdgeInsets.symmetric(horizontal: 10.5, vertical: 7),
          decoration: ShapeDecoration(
            color: bg,
            shape: claudeSuperellipse(
              11,
              side: BorderSide(color: border, width: sel ? 1.25 : 1.0),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                sel
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                size: 15,
                color: accent,
              ),
              const SizedBox(width: 6.5),
              Text(
                opt.ip,
                style: monoStyle(
                  c,
                  size: 12.2,
                  weight: sel ? FontWeight.w600 : FontWeight.w500,
                  color: sel ? c.ink : c.inkSoft,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5.5,
                  vertical: 1.5,
                ),
                decoration: ShapeDecoration(
                  color: c.paper2.withValues(alpha: 0.88),
                  shape: claudeSuperellipse(6),
                ),
                child: Text(
                  tagText,
                  style: sansStyle(
                    c,
                    size: 10.5,
                    color: opt.offlineSaved ? c.clay : c.meta,
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