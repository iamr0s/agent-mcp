import 'package:flutter/material.dart';

import '../services/console_backend.dart';
import '../theme/prism_theme.dart';

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

int _hostOptionPriority(HostIpOption o) {
  if (o.label.contains('Tailscale') || o.kind == 'vpn') return 0;
  if (o.ip.startsWith('192.168.') || o.ip.startsWith('10.')) return 1;
  if (o.kind == 'lan') return 2;
  if (o.kind == 'loopback' || o.ip == kLoopbackIpv4) return 3;
  if (o.kind == 'tun_proxy') return 5;
  return 4;
}

int _endpointOptionPriority(EndpointCopyOption o) {
  if (o.isCopyAll) return 99;
  if (o.badge == 'HTTPS') return 0;
  if (o.badge == '组网') return 1;
  if (o.badge == '局域网') {
    if (o.url.contains('://192.168.') || o.url.contains('://10.')) return 2;
    return 3;
  }
  if (o.badge == 'HTTP') return 4;
  if (o.badge == '回环') return 5;
  return 6;
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

  out.sort((a, b) => _hostOptionPriority(a).compareTo(_hostOptionPriority(b)));
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
  if (tMode == 'playit') {
    final live = (liveQuickUrl ?? '').trim().replaceAll(RegExp(r'/+$'), '');
    if (live.isNotEmpty) return <String>[live];
    final pHost = (prof['playit_hostname'] ?? '').toString().trim();
    if (pHost.isNotEmpty) {
      final norm = normalizeUiDirectBaseUrl(pHost);
      if (norm.isNotEmpty) return <String>[norm];
    }
    final b = normalizeUiDirectBaseUrl((prof['base_url'] ?? '').toString());
    return b.isNotEmpty ? <String>[b] : const <String>[];
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
      final isExplicitPlainTcpPort =
          clean.toLowerCase().startsWith('http://') &&
              u != null &&
              u.hasPort &&
              u.port != 443;
      if (isExplicitPlainTcpPort) {
        opts.add(
          EndpointCopyOption(
            badge: 'HTTP',
            url: 'http://$stripped$suffix',
            isHighlight: true,
          ),
        );
      } else {
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
  }

  opts.sort(
    (a, b) => _endpointOptionPriority(a).compareTo(_endpointOptionPriority(b)),
  );
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

class EndpointCopyDropButton extends StatelessWidget {
  final String label;
  final List<EndpointCopyOption> options;
  final void Function(EndpointCopyOption option) onSelect;
  final bool useSplitPrimary;
  final String? primaryUrl;
  final VoidCallback? onPrimaryTap;

  const EndpointCopyDropButton({
    super.key,
    this.label = '复制',
    required this.options,
    required this.onSelect,
    this.useSplitPrimary = false,
    this.primaryUrl,
    this.onPrimaryTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    if (options.isEmpty) {
      return PrismButton(
        label: label,
        compact: true,
        variant: useSplitPrimary ? PrismBtnVariant.clay : PrismBtnVariant.neutral,
        leading: const Icon(Icons.copy_rounded),
        onPressed: onPrimaryTap,
      );
    }
    if (options.length == 1) {
      return PrismButton(
        label: label,
        compact: true,
        variant: useSplitPrimary ? PrismBtnVariant.clay : PrismBtnVariant.neutral,
        tooltip: '复制地址',
        leading: const Icon(Icons.copy_rounded),
        onPressed: onPrimaryTap ?? () => onSelect(options.first),
      );
    }

    final actions = <PrismMenuAction>[
      for (final opt in options)
        PrismMenuAction(
          badge: opt.badge,
          label: opt.displayLabel ?? opt.url,
          icon: opt.isCopyAll
              ? Icons.library_add_check_outlined
              : Icons.content_copy_rounded,
          highlight: opt.isHighlight,
          dividerBefore: opt.isCopyAll,
          onSelected: () => onSelect(opt),
        ),
    ];

    if (useSplitPrimary) {
      return PrismSplitButton(
        label: label,
        icon: Icons.copy_rounded,
        variant: PrismBtnVariant.clay,
        onPrimaryPressed: onPrimaryTap ?? () => onSelect(options.first),
        menuActions: actions,
        minMenuWidth: 268,
        maxMenuWidth: 380,
      );
    }

    return PrismActionMenuButton(
      actions: actions,
      tooltip: '选择地址并复制',
      minMenuWidth: 268,
      maxMenuWidth: 380,
      customTrigger: Container(
        height: 31,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: ShapeDecoration(
          color: c.paper2,
          shape: StadiumBorder(
            side: BorderSide(color: c.hairline.withValues(alpha: 0.72)),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.copy_rounded, size: 13.5, color: c.inkSoft),
            const SizedBox(width: 5.5),
            Text(
              label,
              style: sansStyle(
                c,
                size: 12.2,
                weight: FontWeight.w500,
                color: c.inkSoft,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.keyboard_arrow_down_rounded, size: 14.5, color: c.meta),
          ],
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
    final c = PrismPalette.of(context);
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
          duration: PrismMotion.duration(context, PrismMotion.fast),
          curve: PrismMotion.editorialOut,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7.5),
          decoration: ShapeDecoration(
            color: bg,
            shape: StadiumBorder(
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
                  shape: const StadiumBorder(),
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