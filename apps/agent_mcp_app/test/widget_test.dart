import 'dart:async';

import 'package:agent_mcp_app/main.dart';
import 'package:agent_mcp_app/services/console_backend_interface.dart';
import 'package:agent_mcp_app/theme/prism_theme.dart';
import 'package:agent_mcp_app/views/profile_endpoints_helper.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeConsoleBackend extends ConsoleBackend {
  UpdatePreferences updatePrefs = const UpdatePreferences(autoCheckEnabled: false);
  UpdateCheckResult? stubUpdateResult;
  String? launchedInstallerPath;
  String? launchedInstallerAfter;
  bool? launchedInstallerSilent;
  String? openedExternalUrl;

  @override
  bool get isWindowsPlatform => true;

  @override
  bool get supportsInAppUpgrade => true;

  @override
  Future<UpdatePreferences> loadUpdatePreferences() async => updatePrefs;

  @override
  Future<void> saveUpdatePreferences(UpdatePreferences prefs) async { updatePrefs = prefs; }

  @override
  Future<UpdateCheckResult> checkForUpdates({bool manual = false}) async {
    return stubUpdateResult ?? UpdateCheckResult(ok: true, hasUpdate: false, currentVersion: currentAppVersion);
  }

  @override
  Future<UpdateDownloadResult> downloadUpdatePackage(UpdateAsset asset, {void Function(int received, int total)? onProgress, String mirrorPrefix = ''}) async {
    onProgress?.call(asset.size > 0 ? asset.size : 1024, asset.size > 0 ? asset.size : 1024);
    return UpdateDownloadResult(ok: true, filePath: r'C:\Temp\' + asset.name, sha256: asset.sha256, verified: asset.sha256.isNotEmpty);
  }

  @override
  Future<Map<String, dynamic>> launchDownloadedInstaller(String filePath, {bool silent = false, String after = 'gui'}) async {
    launchedInstallerPath = filePath;
    launchedInstallerSilent = silent;
    launchedInstallerAfter = after;
    return const {'ok': true};
  }

  @override
  Future<bool> openExternalUrl(String url) async { openedExternalUrl = url; return true; }

  @override
  bool get supportsNodeSwitching => true;

  final ValueNotifier<DesktopWindowState> _win = ValueNotifier(
    const DesktopWindowState(
      isBackdropSupported: true,
      windowEffect: true,
    ),
  );
  final StreamController<Map<String, dynamic>> _evCtrl =
      StreamController<Map<String, dynamic>>.broadcast();

  Map<String, dynamic> config = {
    'server_name': 'Omen Desktop Mcp',
    'host': '127.0.0.1',
    'port': 8000,
    'auto_start': true,
    'launch_at_startup': true,
    'silent_start': true,
    'window_effect': true,
    'has_password': true,
    'profiles': [
      {
        'id': 'prof-main',
        'name': 'Gemini 主力公网入口',
        'enabled': true,
        'transport': 'dual',
        'tunnel_mode': 'token',
        'base_url': 'https://omen-mcp.iamr0s.de5.net',
        'auth_mode': 'oauth-local',
        'oauth_client_id': 'mcp-client-demo',
        'oauth_client_secret': 'mcp-sec-demo',
        'inherit_permissions': true,
      },
    ],
  };

  @override
  bool get isWebMode => false;

  bool customTitleBar = true;

  @override
  bool get hasCustomTitleBar => customTitleBar;

  @override
  ValueListenable<DesktopWindowState> get windowState => _win;

  @override
  Future<void> init() async {}

  @override
  void recordUnhandledError(Object error, StackTrace stack) {}

  @override
  Future<void> startWindowDrag() async {}

  @override
  Future<void> minimizeWindow() async {}

  @override
  Future<void> toggleMaximizeWindow() async {}

  @override
  Future<void> togglePinWindow() async {}

  int hiddenToTrayCount = 0;
  bool? lastSyncedIsDark;
  int? lastSyncedAccentRgb;

  @override
  Future<void> hideWindowToTray() async {
    hiddenToTrayCount++;
  }

  @override
  Future<void> syncNativeWindowTheme(bool isDark, {int? accentRgb}) async {
    lastSyncedIsDark = isDark;
    if (accentRgb != null) {
      lastSyncedAccentRgb = accentRgb;
    }
  }

  @override
  Future<bool> setWindowEffect(bool enabled) async {
    _win.value = _win.value.copyWith(windowEffect: enabled);
    return enabled;
  }

  @override
  Future<Map<String, dynamic>> checkAuthState() async => {
        'ok': true,
        'authenticated': true,
        'server_name': 'Omen Desktop Mcp',
        'version': '2.3.0',
        'dashboard_mode': false,
      };

  @override
  Future<Map<String, dynamic>> login(String password) async => {'ok': true};

  @override
  Future<void> logout() async {}

  @override
  Future<Map<String, dynamic>> getStatus() async => {
        'running': true,
        'version': '2.3.0',
        'dashboard_mode': false,
        'tunnels': {
          'installed': true,
          'version': '2025.2.1',
          'binary': r'D:\agent_mcp_next\bin\cloudflared.exe',
          'tunnels': {
            'prof-main': {'running': true},
          },
        },
        'exposures': {
          'enabled': config['expose_enabled'] != false,
          'tailscale_enabled': config['expose_tailscale_enabled'] != false,
          'tailscale_mode': config['expose_tailscale_mode'] ?? 'funnel',
          'cloudflared_fallback': true,
          'default_ttl_minutes': 120,
          'tailscale_status': {
            'reachable': true,
            'dns_name': 'omen-pc.taildemo.ts.net',
            'tailscale_ips': ['100.77.167.127'],
          },
          'public_gateway_bases': ['https://omen-mcp.iamr0s.de5.net'],
          'cloudflared_installed': true,
          'active_count': 1,
          'items': [
            {
              'id': 'sh_testDemo123',
              'kind': 'file',
              'label': '产品宣传片预览.mp4',
              'target': r'D:\agent_mcp_tttmp\promo.mp4',
              'scope': 'auto',
              'primary_url': 'https://omen-mcp.iamr0s.de5.net/share/sh_testDemo123',
              'direct_file_url': 'https://omen-mcp.iamr0s.de5.net/share/sh_testDemo123/promo.mp4',
              'public_urls': ['https://omen-mcp.iamr0s.de5.net/share/sh_testDemo123'],
              'tailscale_urls': ['http://100.77.167.127:8000/share/sh_testDemo123'],
              'lan_urls': ['http://192.168.6.205:8000/share/sh_testDemo123'],
              'hit_count': 5,
              'bytes_sent_human': '6.05 MB',
              'remaining_seconds': 7100,
            },
          ],
        },
        'config': config,
      };

  @override
  Future<Map<String, dynamic>> saveConfig(Map<String, dynamic> patch) async {
    config = {...config, ...patch};
    if (patch.containsKey('window_effect')) {
      await setWindowEffect(patch['window_effect'] != false);
    }
    return {'ok': true};
  }

  @override
  Future<Map<String, dynamic>> startService() async => {'ok': true};

  @override
  Future<Map<String, dynamic>> stopService() async => {'ok': true};

  @override
  Future<Map<String, dynamic>> restartService() async => {'ok': true};

  bool emptyLogs = false;

  @override
  Future<List<Map<String, dynamic>>> getLogs() async => emptyLogs
      ? const []
      : [
          {
            'call_id': 'c1',
            'kind': 'ok',
            'status': 'done',
            'badge': '完成',
            'tool': 'list_dir',
            'source': 'Gemini 主力',
            'ms': 12.4,
            'ts': '23:40:01',
            'args': {
              'path': r'D:\agent_mcp_next\apps\agent_mcp_app',
              'max_depth': 2,
            },
            'result': 'lib/\nwindows/',
          },
        ];

  @override
  Future<void> clearLogs() async {}

  @override
  Stream<Map<String, dynamic>> subscribeEvents() => _evCtrl.stream;

  @override
  Future<void> exportLogsFile(String filename, String content) async {}

  @override
  Future<Map<String, dynamic>> checkHealth([String? targetUrl]) async =>
      {'ok': true, 'body': '{"status":"ok"}'};

  @override
  Future<Map<String, dynamic>> getStorage() async => {
        'ok': true,
        'stats': {
          'config': {'bytes': 2048, 'files': 2},
          'data': {'bytes': 16384, 'files': 3},
          'cache': {'bytes': 0, 'files': 0},
          'logs': {'bytes': 8192, 'files': 2},
        },
      };

  @override
  Future<Map<String, dynamic>> cleanStorageTarget(String target) async =>
      {'ok': true, 'message': 'ok'};

  @override
  Future<Map<String, dynamic>> startTunnel(String profileId) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> stopTunnel(String profileId) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> installCloudflared({
    bool force = false,
    bool resume = false,
  }) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> pauseCloudflared() async => {'ok': true};

  @override
  Future<Map<String, dynamic>> cancelCloudflared() async => {'ok': true};

  @override
  Future<Map<String, dynamic>> uninstallCloudflared() async => {'ok': true};

  @override
  Future<Map<String, dynamic>?> pickAndImportCloudflared() async => null;

  @override
  Future<List<Map<String, dynamic>>> listSubMcps() async => [
        {
          'name': 'memory-mcp',
          'enabled': true,
          'transport': 'stdio',
          'command': 'npx',
          'args': ['-y', '@modelcontextprotocol/server-memory'],
          'status': 'ok',
          'tools': [
            {'name': 'read_graph', 'description': 'Reads the knowledge graph'},
            {'name': 'create_entities', 'description': 'Creates new entities'},
          ],
        },
      ];

  @override
  Future<Map<String, dynamic>> upsertSubMcp(
    Map<String, dynamic> entry, {
    String? oldName,
  }) async =>
      {'ok': true, 'entry': entry};

  @override
  Future<Map<String, dynamic>> importSubMcpsJson(String raw) async =>
      {'ok': true, 'count': 1};

  @override
  Future<Map<String, dynamic>> probeSubMcpDraft(
    Map<String, dynamic> draft,
  ) async =>
      {'ok': true, 'tool_count': 2, 'ms': 15};

  @override
  Future<Map<String, dynamic>> toggleSubMcp(String name, bool enabled) async =>
      {'ok': true};

  @override
  Future<Map<String, dynamic>> deleteSubMcp(String name) async => {'ok': true};

  @override
  Future<Map<String, dynamic>> testSubMcp(String name) async =>
      {'ok': true, 'tools': const [], 'ms': 10};

  @override
  void quitDesktopApp() {}
}

void main() {
  testWidgets(
      'Superellipse theme, frosted glass bar, segmented pill, switch, and status dot zero-jitter box',
      (tester) async {
    var tab = 'ALL';
    var toggled = false;
    var expanded = false;
    var pulsing = false;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (ctx, setState) {
          return MaterialApp(
            theme: buildPrismTheme(PrismPalette.light),
            home: Scaffold(
              body: Center(
                child: PrismGlassBar(
                  borderRadius: 16,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PrismStatusDot(
                        key: const ValueKey('status-dot'),
                        color: Colors.green,
                        pulsing: pulsing,
                        size: 8.0,
                      ),
                      PrismButton(
                        label: '启动服务',
                        variant: PrismBtnVariant.clay,
                        onPressed: () => setState(() {
                          expanded = !expanded;
                          pulsing = !pulsing;
                        }),
                      ),
                      PrismSegmented<String>(
                        value: tab,
                        items: const [
                          ('ALL', '全部'),
                          ('TOOL', '工具'),
                          ('ERR', '异常'),
                        ],
                        onChanged: (v) => setState(() => tab = v),
                      ),
                      PrismSwitch(
                        value: toggled,
                        onChanged: (v) => setState(() => toggled = v),
                      ),
                      PrismCollapsible(
                        expanded: expanded,
                        builder: (_) => const Text('展开详情面板'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));

    final idleSize = tester.getSize(find.byKey(const ValueKey('status-dot')));
    expect(idleSize, equals(const Size(16, 16)));

    await tester.tap(find.text('启动服务'));
    await tester.pump(const Duration(milliseconds: 350));
    final pulsingSize =
        tester.getSize(find.byKey(const ValueKey('status-dot')));
    // Zero layout jump between idle and pulsing states!
    expect(pulsingSize, equals(const Size(16, 16)));
    expect(find.text('展开详情面板'), findsOneWidget);
  });

  testWidgets(
      'Custom Windows 11 caption controls toggle pin, maximize, minimize, and hide-to-tray',
      (tester) async {
    var pinned = false;
    var maximized = false;
    var minimizedCount = 0;
    var closedToTrayCount = 0;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (ctx, setState) {
          return MaterialApp(
            theme: buildPrismTheme(PrismPalette.light),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  height: 46,
                  child: PrismWindowCaptionActions(
                    isPinned: pinned,
                    isMaximized: maximized,
                    onTogglePin: () => setState(() => pinned = !pinned),
                    onMinimize: () => minimizedCount++,
                    onToggleMaximize: () =>
                        setState(() => maximized = !maximized),
                    onCloseToTray: () => closedToTrayCount++,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(PrismCaptionIcon), findsNWidgets(3));
    await tester.tap(find.byTooltip('窗口置顶'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(pinned, isTrue);

    await tester.tap(find.byTooltip('最大化'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(maximized, isTrue);

    await tester.tap(find.byTooltip('最小化'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(minimizedCount, equals(1));

    await tester.tap(find.byTooltip('隐藏到系统托盘（MCP 服务继续运行）'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(closedToTrayCount, equals(1));
  });

  for (final vp in const [
    Size(360, 780),
    Size(520, 720),
    Size(1280, 820),
  ]) {
    testWidgets(
        'Full ConsoleShellScreen renders all 3 keep-alive tabs cleanly with zero overflow at ${vp.width.toInt()}x${vp.height.toInt()}',
        (tester) async {
      tester.view.physicalSize = vp;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final backend = _FakeConsoleBackend();
      await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);

      // Switch to Sub-MCP tab
      final subLabel = vp.width < 700 ? '子 MCP' : '子 MCP 网关';
      if (vp.width >= 960 || vp.width < 700) {
        await tester.tap(find.text(subLabel));
      } else {
        await tester.tap(find.byTooltip('子 MCP 网关'));
      }
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.takeException(), isNull);
      expect(find.text('memory-mcp'), findsOneWidget);

      // Switch to Setup tab
      if (vp.width >= 960 || vp.width < 700) {
        await tester.tap(find.text('服务配置').last);
      } else {
        await tester.tap(find.byTooltip('服务配置'));
      }
      await tester.pump(const Duration(milliseconds: 450));
      expect(tester.takeException(), isNull);
      if (vp.width < 700) {
        await tester.tap(find.text('基础与外观'));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.textContaining('窗口云母与毛玻璃透光'), findsNothing);
      expect(find.text('基础服务与全局密码'), findsOneWidget);
    });
  }

  testWidgets(
      'v2.8 Architectural docked mobile bottom bar, header service menu, semantic args, and empty-page wheel hide',
      (tester) async {
    tester.view.physicalSize = const Size(600, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final backend = _FakeConsoleBackend();
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);

    // Semantic parameter formatting: '深度 2' rather than raw 'max_depth'
    expect(find.textContaining('max_depth'), findsNothing);
    expect(find.textContaining('深度 2'), findsOneWidget);

    // Docked architectural bottom bar spans edge-to-edge with 4 tabs (zero detached collapse circle)
    expect(find.byTooltip('收起底栏'), findsNothing);
    expect(find.byTooltip('MCP 服务运行控制'), findsOneWidget);
    expect(tester.getCenter(find.text('调用流')).dy, lessThan(760));

    // Tap mobile header service control menu -> shows start/stop & restart actions
    await tester.tap(find.byTooltip('MCP 服务运行控制'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('停止 MCP 服务'), findsOneWidget);
    expect(find.text('平滑重启服务'), findsOneWidget);
    // Dismiss menu
    await tester.tapAt(const Offset(12, 120));
    await tester.pump(const Duration(milliseconds: 200));

    // Clear logs so feed is completely empty (maxScrollExtent == 0), then test mouse wheel scroll-to-hide
    backend.emptyLogs = true;
    await tester.tap(find.text('清空'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('暂无匹配的活动记录'), findsOneWidget);

    // Emit discrete desktop mouse wheel down over empty feed -> hides docked bottom bar smoothly!
    final center = tester.getCenter(find.text('暂无匹配的活动记录'));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(tester.getCenter(find.text('调用流')).dy, greaterThan(760));
    expect(tester.getCenter(find.byTooltip('展开导航栏')).dy, lessThan(760));

    // Restore via subtle bottom pill
    await tester.tap(find.byTooltip('展开导航栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(tester.getCenter(find.text('调用流')).dy, lessThan(760));

    // Wheel down then wheel up restores chrome smoothly even when page is empty!
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.getCenter(find.text('调用流')).dy, greaterThan(760));

    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(tester.getCenter(find.text('调用流')).dy, lessThan(760));
  });

  test('normalizeRemoteBaseUrl strips /mcp and /dashboard suffixes and infers scheme', () {
    expect(
      normalizeRemoteBaseUrl('omen-mcp.iamr0s.de5.net/mcp'),
      equals('https://omen-mcp.iamr0s.de5.net'),
    );
    expect(
      normalizeRemoteBaseUrl('100.88.12.5:8000/dashboard/'),
      equals('http://100.88.12.5:8000'),
    );
    expect(
      normalizeRemoteBaseUrl('https://mcp.example.com/sub/dashboard/api'),
      equals('https://mcp.example.com/sub'),
    );
  });

  testWidgets(
      'Android immersive status bar & display cutout invasion keeps safe boundaries in portrait and landscape',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
      tester.view.resetViewPadding();
    });

    final backend = _FakeConsoleBackend()..customTitleBar = false;

    // 1. Portrait with 42dp punch-hole camera status bar + 20dp gesture pill
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewPadding = const FakeViewPadding(top: 42, bottom: 20);
    tester.view.padding = const FakeViewPadding(top: 42, bottom: 20);

    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);

    // At rest, page heading sits safely below the floating (46 + 42 = 88dp) glass header
    final headingTopAtRest = tester.getTopLeft(find.text('活动与调用流')).dy;
    expect(headingTopAtRest, greaterThanOrEqualTo(88.0));

    // Scrollable viewport itself starts at y == 0.0 so scrolling cards invade behind status bar & cutout!
    final scrollRect = tester.getRect(find.byType(CustomScrollView).first);
    expect(scrollRect.top, equals(0.0));
    expect(scrollRect.bottom, equals(915.0));

    // 2. Landscape with 42dp left camera cutout + 28dp status bar + 16dp gesture bar
    tester.view.physicalSize = const Size(915, 412);
    tester.view.viewPadding =
        const FakeViewPadding(left: 42, top: 28, right: 0, bottom: 16);
    tester.view.padding =
        const FakeViewPadding(left: 42, top: 28, right: 0, bottom: 16);
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);

    // Sidebar chevron button stays safely right of the 42dp left camera cutout
    final sidebarToggleLeft =
        tester.getTopLeft(find.byIcon(Icons.chevron_left_rounded)).dx;
    expect(sidebarToggleLeft, greaterThanOrEqualTo(42.0));
  });

  testWidgets(
      'Android privilege card switches Shizuku/Root modes and omits redundant FGS IP chips',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final backend = _FakeConsoleBackend()
      ..customTitleBar = false
      ..config = {
        'server_name': 'Android MCP',
        'host': '127.0.0.1',
        'hosts': ['127.0.0.1'],
        'port': 8000,
        'host_os': 'android',
        'lan_ips': ['192.168.31.102', '100.77.167.127'],
        'network_interfaces': [
          {'ip': '127.0.0.1', 'iface': 'lo', 'kind': 'loopback', 'label': '本机回环'},
          {'ip': '192.168.31.102', 'iface': 'wlan0', 'kind': 'lan', 'label': '局域网'},
          {'ip': '100.77.167.127', 'iface': 'tailscale0', 'kind': 'vpn', 'label': '组网 / Tailscale'},
        ],
        'android_privilege_mode': 'none',
        'privilege_status': {
          'supported': true,
          'requested_mode': 'none',
          'active_mode': 'none',
          'bridge_ready': false,
          'effective_uid': 10350,
          'effective_label': '普通沙盒 (UID 10350)',
          'shizuku_installed': true,
          'shizuku_running': true,
          'shizuku_authorized': true,
          'shizuku_uid': 2000,
          'root_managers': [
            {'package': 'me.weishu.kernelsu', 'name': 'KernelSU'},
          ],
        },
        'profiles': [
          {
            'id': 'prof-direct',
            'name': '手机直连入口',
            'enabled': true,
            'transport': 'dual',
            'tunnel_mode': 'none',
            'direct_ips': ['192.168.31.102', '100.77.167.127'],
            'manual_urls': ['https://phone-mcp.example.com'],
            'auth_mode': 'none',
            'inherit_permissions': true,
          },
        ],
      };

    tester.view.physicalSize = const Size(1280, 1200);
    tester.view.devicePixelRatio = 1.0;

    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 450));

    // Switch to Setup tab
    await tester.tap(find.text('服务配置').first);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);

    // Verify Android Privilege Card is displayed with Shizuku ADB (UID 2000) & KernelSU badges
    expect(find.text('Android 运行权限级别'), findsOneWidget);
    expect(find.text('ADB (UID 2000)'), findsOneWidget);
    expect(find.text('KernelSU'), findsOneWidget);

    // Verify redundant FGS IP copy buttons were removed while profile multi-endpoint copy button exists under 接入入口
    expect(find.text('通知栏常驻保活与快捷启停'), findsOneWidget);

    await tester.tap(find.text('接入入口 (1)'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('复制地址'), findsOneWidget);

    // Tap 复制地址 on the multi-endpoint profile -> opens DropMenu with LAN, Tailscale, HTTPS & Copy All!
    await tester.ensureVisible(find.text('复制地址'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('复制地址'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('http://192.168.31.102:8000/mcp'), findsWidgets);
    expect(find.text('http://100.77.167.127:8000/mcp'), findsWidgets);
    expect(find.text('https://phone-mcp.example.com/mcp'), findsOneWidget);
    expect(find.textContaining('复制全部'), findsOneWidget);

    // Dismiss menu and open ProfileEditDialog to verify multi-IP chips
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('编辑').first);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('本机网卡 IP'), findsOneWidget);
    expect(find.text('选局域网与组网'), findsOneWidget);
  });

  testWidgets(
      'Exposure & Share 4th tab renders active links, multi-channel copy menu, and Tailscale settings switches',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend();
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);

    // Switch to 4th feature tab ("外网与分享")
    await tester.tap(find.text('外网与分享'));
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);

    expect(find.text('外网映射与链接分享'), findsOneWidget);
    expect(find.text('产品宣传片预览.mp4'), findsOneWidget);
    expect(
      find.text('https://omen-mcp.iamr0s.de5.net/share/sh_testDemo123'),
      findsOneWidget,
    );

    // Open New Share modal and verify port/file/dir segmented controls
    await tester.tap(find.text('新建外网分享'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('新建外网映射与分享'), findsOneWidget);
    expect(find.text('单个文件'), findsWidgets);
    expect(find.text('文件夹 / 静态网站'), findsOneWidget);
    expect(find.text('本地端口转发'), findsOneWidget);
    await tester.tap(find.text('文件夹 / 静态网站'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('文件夹目录共享'), findsOneWidget);
    expect(find.text('静态网站目录'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump(const Duration(milliseconds: 300));

    // Switch to Setup tab and verify Tailscale & Exposure master switches under 外网与隧道
    await tester.tap(find.text('服务配置'));
    await tester.pump(const Duration(milliseconds: 450));
    await tester.tap(find.text('外网与隧道'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('Tailscale 与外网分享设置'), findsOneWidget);
    expect(
      find.text('允许外网分享与 AI 自动映射 (manage_expose)'),
      findsOneWidget,
    );
    expect(find.text('启用 Tailscale 组网与 Funnel 联动'), findsOneWidget);

    // Verify Security & All-Expanded sub-tabs also render cleanly
    await tester.tap(find.text('权限与维护'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('全局默认权限与日志'), findsOneWidget);
    expect(find.text('存储与维护'), findsOneWidget);
    await tester.tap(find.text('全部展开'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('基础服务与全局密码'), findsOneWidget);
    expect(find.text('传输、鉴权与权限入口'), findsOneWidget);
  });

  testWidgets(
      'Desktop Activity Split Inspector previews rich tool output without jumping and toggles inline mode',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    tester.view.physicalSize = const Size(1440, 920);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend();
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);

    // Wide desktop defaults to Docked Split Inspector ("分栏预览")
    expect(find.text('分栏预览'), findsOneWidget);
    expect(find.text('行内展开'), findsOneWidget);
    expect(find.textContaining('lib/'), findsOneWidget);

    // Toggle to Inline Accordion ("行内展开") and back to Split ("分栏预览")
    await tester.tap(find.text('行内展开'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('分栏预览'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('lib/'), findsOneWidget);
  });

  testWidgets(
      'v2.2 P0-6: Shared PrismPulseClock multiplexes pulsing status dots and auto-sleeps when window hidden',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend();
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 450));

    expect(PrismPulseClock.instance.activeSubscriberCount, greaterThanOrEqualTo(1));
    expect(PrismPulseClock.instance.isTickerRunning, isTrue);

    // Hide window to system tray -> shared 120Hz ticker stops immediately (0% idle GPU)
    backend._win.value = backend._win.value.copyWith(isVisible: false);
    await tester.pump();
    expect(PrismPulseClock.instance.isPaused, isTrue);
    expect(PrismPulseClock.instance.isTickerRunning, isFalse);

    // Restore window -> shared ticker resumes smoothly
    backend._win.value = backend._win.value.copyWith(isVisible: true);
    await tester.pump();
    expect(PrismPulseClock.instance.isPaused, isFalse);
    expect(PrismPulseClock.instance.isTickerRunning, isTrue);
  });

  testWidgets(
      'v2.2 P1-2 & P1-4: Drag-and-drop opens pre-filled Share dialog with PIN/burn-after-download & Tailscale/LAN endpoint priority',
      (tester) async {
    // 1. Verify HTTPS -> Tailscale 100.x -> Primary LAN 192.168.x -> Loopback priority sorting
    final sorted = buildProfileEndpointCopyOptions(
      const {
        'id': 'p-sort',
        'name': '多网卡排序测试',
        'transport': 'dual',
      },
      const [
        'http://127.0.0.1:8778',
        'http://192.168.1.20:8778',
        'http://100.88.10.5:8778',
        'https://edge.example.com',
      ],
    );
    expect(sorted.first.url, equals('https://edge.example.com/mcp'));
    expect(sorted[1].url, equals('http://100.88.10.5:8778/mcp'));
    expect(sorted[2].url, equals('http://192.168.1.20:8778/mcp'));
    expect(sorted[sorted.length - 2].url, equals('http://127.0.0.1:8778/mcp'));
    expect(sorted.last.isCopyAll, isTrue);

    // 2. Verify desktop/web file drop switches to Share tab and pre-fills mode + PIN/quota controls
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend();
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 450));

    backend.emitDroppedFiles([r'D:\demo\optics_lab.html']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);

    // Dialog auto-opens on Exposure tab with dropped HTML path and progressive-disclosure default summary
    expect(find.text('新建外网映射与分享'), findsOneWidget);
    expect(find.text(r'D:\demo\optics_lab.html'), findsOneWidget);
    expect(find.textContaining('默认策略：智能优选'), findsOneWidget);
    expect(find.text('高级保护'), findsOneWidget);

    // Switch mode to single file and expand progressive-disclosure protection drawer to verify "1次即焚"
    await tester.tap(find.text('单个文件').last);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('高级保护'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('1次即焚'), findsOneWidget);
  });

  testWidgets(
      'v2.3 Swiss Craft UI: Ctrl+K command palette routes direct port/path share & static site offers dual HTML/folder pickers',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend();
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 450));

    expect(find.text('Ctrl K'), findsOneWidget);
    await tester.tap(find.text('Ctrl K'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('输入指令，或直接粘贴路径 / 端口号回车秒享…'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, '5173');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('立即转发本地端口 :5173（支持 WebSocket HMR）'), findsOneWidget);
    await tester.tap(find.text('立即转发本地端口 :5173（支持 WebSocket HMR）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('新建外网映射与分享'), findsOneWidget);

    await tester.tap(find.text('静态网页'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('选 HTML 文件'), findsOneWidget);
    expect(find.text('选网站文件夹'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'v2.4 App Updater: SemVer/version.json parsing, periodic toggle, 4-action dialog & one-click upgrade launch',
      (tester) async {
    expect(compareSemVer('2.10.0', '2.3.0'), greaterThan(0));
    expect(compareSemVer('v2.4.0+6', '2.4.0+5'), greaterThan(0));
    expect(compareSemVer('2.4.0', '2.4.0-beta.1'), greaterThan(0));
    expect(
      applyGithubMirrorPrefix(
        'https://github.com/iamr0s/agent-mcp/releases/latest/download/version.json',
        'https://gh-proxy.com',
      ),
      equals('https://gh-proxy.com/https://github.com/iamr0s/agent-mcp/releases/latest/download/version.json'),
    );
    final parsed = UpdateInfo.tryParseVersionJson({
      'version': '9.9.0',
      'tag': 'v9.9.0',
      'build': 7,
      'published_at': '2026-11-22T12:00:00Z',
      'release_url': 'https://github.com/iamr0s/agent-mcp/releases/tag/v9.9.0',
      'notes': '- 新增自动更新与智能安装器',
      'assets': {
        'windows_sfx': {
          'name': 'AgentMCP-v9.9.0-windows-x64-sfx.exe',
          'url': 'https://github.com/iamr0s/agent-mcp/releases/download/v9.9.0/AgentMCP-v9.9.0-windows-x64-sfx.exe',
          'sha256': 'deadbeef',
          'size': 49000000,
        },
      },
    });
    expect(parsed, isNotNull);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend();
    backend.stubUpdateResult = UpdateCheckResult(ok: true, hasUpdate: true, currentVersion: '2.4.0', latest: parsed);
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 450));

    await tester.tap(find.text('Ctrl K'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('检查应用更新 (GitHub Releases)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('不再提醒本次更新'), findsOneWidget);
    expect(find.text('稍后更新'), findsOneWidget);
    expect(find.text('前往下载'), findsOneWidget);
    expect(find.text('一键升级'), findsOneWidget);

    await tester.tap(find.text('不再提醒本次更新'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(backend.updatePrefs.skippedVersion, equals('9.9.0'));

    expect(find.text('新版本 v9.9.0'), findsOneWidget);
    await tester.tap(find.text('新版本 v9.9.0'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('一键升级'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(backend.launchedInstallerPath, contains('AgentMCP-v9.9.0-windows-x64-sfx.exe'));
    expect(backend.launchedInstallerAfter, equals('gui'));
    expect(backend.launchedInstallerSilent, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'v2.6 Linear/OrbStack UI: SplitButton, 4-edge searchable DropMenu, ListGroup & floating unsaved bar',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1.0;

    var primaryCount = 0;
    var selectedMenuAction = '';
    var selectedTool = 'ALL';

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (ctx, setState) {
          return MaterialApp(
            theme: buildPrismTheme(PrismPalette.dark),
            home: Scaffold(
              body: Stack(
                children: [
                  Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: PrismListGroup(
                        headerLabel: '控件测试组',
                        children: [
                          PrismSettingsRow(
                            title: '分体复制按钮',
                            subtitle: '左段直击复制，右段打开多通道菜单',
                            trailing: PrismSplitButton(
                              label: '复制主链接',
                              leading: const Icon(Icons.copy_rounded),
                              onPrimaryPressed: () =>
                                  setState(() => primaryCount++),
                              menuActions: [
                                PrismMenuAction(
                                  label: 'Tailscale 直连',
                                  badge: '100.x',
                                  onTap: () => setState(
                                    () => selectedMenuAction = 'ts',
                                  ),
                                ),
                                PrismMenuAction(
                                  label: '局域网地址',
                                  badge: 'LAN',
                                  onTap: () => setState(
                                    () => selectedMenuAction = 'lan',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: PrismDropMenu<String>(
                        value: selectedTool,
                        searchable: true,
                        items: [
                          const PrismDropMenuItem(
                            value: 'ALL',
                            label: '全部工具',
                          ),
                          for (var i = 1; i <= 10; i++)
                            PrismDropMenuItem(
                              value: 'tool_$i',
                              label: 'mcp_tool_$i',
                            ),
                        ],
                        onChanged: (v) => setState(() => selectedTool = v),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    // 1. Primary SplitButton click triggers primary action directly
    await tester.tap(find.text('复制主链接'));
    await tester.pump(const Duration(milliseconds: 150));
    expect(primaryCount, equals(1));

    // 2. Right chevron of SplitButton opens Popover menu
    await tester.tap(find.byTooltip('更多选项'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Tailscale 直连'), findsOneWidget);
    await tester.tap(find.text('Tailscale 直连'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(selectedMenuAction, equals('ts'));

    // 3. Bottom-right searchable DropMenu flips upward & aligns right inside viewport
    await tester.tap(find.text('全部工具'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('筛选选项...'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'tool_9');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('mcp_tool_9'), findsOneWidget);
    expect(find.text('mcp_tool_2'), findsNothing);
    await tester.tap(find.text('mcp_tool_9'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(selectedTool, equals('tool_9'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'v2.7 De-Forming & Shared-Axis Motion: zero raw TextFields on Setup load, inline edit drawer, 1-click sidebar v2.7.0 About jump, and top-pinned sub-page switch',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend();
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);

    // 1. Sidebar exposes un-hidden v3.2.1 About & Update entry directly on main shell
    expect(find.text('关于与更新'), findsOneWidget);
    expect(find.text('v3.4.0'), findsOneWidget);
    await tester.tap(find.text('v3.4.0'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);

    // Lands directly on ServiceSetupPage -> dedicated '关于与更新' Hero & Update Center
    expect(find.text('GitHub Releases'), findsOneWidget);
    expect(find.text('立即检查更新'), findsOneWidget);
    expect(find.text('更新策略与下载通道'), findsOneWidget);

    // 2. Switch to '基础与外观' and verify top-pinned Shared-Axis motion (zero vertical center snap!)
    await tester.tap(find.text('基础与外观'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final midAnimTop =
        tester.getTopLeft(find.byKey(const ValueKey('setup-sec-basic'))).dy;
    await tester.pump(const Duration(milliseconds: 250));
    final settledTop =
        tester.getTopLeft(find.byKey(const ValueKey('setup-sec-basic'))).dy;
    // Incoming pane glides smoothly within ~14px of top rather than centering at y > 200px!
    expect((midAnimTop - settledTop).abs(), lessThan(18.0));

    // 3. Zero raw TextFields exposed on Setup load (Read-First calm aesthetic)
    expect(find.byType(TextField), findsNothing);
    expect(find.text('未启用前缀'), findsOneWidget);
    expect(find.text('127.0.0.1:8000'), findsOneWidget);
    expect(find.text('已设密码保护'), findsOneWidget);

    // Tapping a single row smoothly expands ONLY that row's inline editor
    await tester.tap(find.text('MCP 服务名称'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Omen Studio v2.7');
    await tester.pump();
    await tester.tap(find.text('保存'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(backend.config['server_name'], equals('Omen Studio v2.7'));
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'v2.8 Narrow 360x780 Precision: single-line chevrons, zero pencil icons, equal-width 4-segment share modal, and 2D horizontal code sheet + 1-line write banner',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend()..customTitleBar = false;
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);

    // Emit a create_file call with long Dart lines + 1-line receipt
    backend._evCtrl.add({
      'call_id': 'c_write_1',
      'kind': 'ok',
      'status': 'done',
      'badge': '完成',
      'tool': 'create_file',
      'source': 'Gemini Web',
      'ms': 18.2,
      'ts': '14:20:01',
      'args': {
        'path': r'D:\carplay\carplay-research\carvex_ui\lib\pages\settings_page.dart',
        'content':
            "import '../bridge/carvex_bridge_controller.dart';\nclass SettingsPage extends StatefulWidget {\n  final CarvexBridgeController controller;\n}",
      },
      'result':
          r'Written 15234 bytes (371 lines) to D:\carplay\carplay-research\carvex_ui\lib\pages\settings_page.dart.',
    });
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.text('写入文件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);
    expect(find.text('写入内容 · 4 行'), findsOneWidget);
    expect(find.text('左右滑动'), findsOneWidget);
    expect(
      find.textContaining('Written 15234 bytes (371 lines)'),
      findsOneWidget,
    );

    // Verify Centered Liquid Jade Lens Dock sits surrounded by generous negative space & floats above bottom
    final callFlowTabRect = tester.getRect(find.text('调用流').last);
    expect(callFlowTabRect.left, greaterThan(24.0));
    expect(callFlowTabRect.bottom, lessThan(770.0));

    // Navigate to ServiceSetupPage at 360px and verify Level-1 chevron does NOT wrap below title!
    await tester.tap(find.text('服务配置').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);
    final aboutRowTitleCenter = tester.getCenter(find.text('关于与更新'));
    final aboutBadgeCenter = tester.getCenter(find.text('v3.4.0'));
    // Right badge sits to the right of title on the same horizontal row, never dropped underneath!
    expect(aboutBadgeCenter.dx, greaterThan(aboutRowTitleCenter.dx + 40));

    // Enter 基础与外观 -> verify zero cheap pencil icons, crisp 1-line micro-subtitles, and single-line right-aligned values
    await tester.tap(find.text('基础与外观'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(find.text('多设备同时接入时防止工具重名'), findsOneWidget);
    final prefixTitleCenter = tester.getCenter(find.text('工具名前缀'));
    final prefixPillCenter = tester.getCenter(find.text('未启用前缀'));
    expect(prefixPillCenter.dx, greaterThan(prefixTitleCenter.dx + 60));
    expect((prefixTitleCenter.dy - prefixPillCenter.dy).abs(), lessThan(18.0));

    // Switch to Exposure tab and open Share dialog via file drop -> verify 2x2 Bento Mode Grid & zero right-edge overflow at 360px!
    backend.emitDroppedFiles([r'D:\demo\folder_share']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    for (final segLabel in const ['端口映射', '单个文件', '文件夹', '静态网页']) {
      final rect = tester.getRect(find.text(segLabel).last);
      expect(rect.left, greaterThanOrEqualTo(0.0));
      expect(rect.right, lessThanOrEqualTo(360.0));
    }
    expect(
      tester.getRect(find.text('端口映射').last).top,
      lessThan(tester.getRect(find.text('文件夹').last).top - 24.0),
    );
    expect(find.text('粘贴路径'), findsOneWidget);
  });

  testWidgets(
      'v3.1.0 Liquid Jade Lens Finger-Tracking & Level-2 Full-Screen Parallax Back + 4-Tier PopScope',
      (tester) async {
    Future<void> pumpFrames([int count = 16]) async {
      await tester.pump();
      for (var i = 0; i < count; i++) {
        await tester.pump(const Duration(milliseconds: 28));
      }
    }

    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend()..customTitleBar = false;
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);

    // 1. Verify Liquid Jade Lens Pill starts aligned with Tab 0 ('调用流')
    final lensFinder = find.byKey(const ValueKey('mobile-liquid-jade-lens'));
    final dockFinder = find.byKey(const ValueKey('mobile-liquid-jade-dock'));
    expect(lensFinder, findsOneWidget);
    expect(dockFinder, findsOneWidget);
    final lensStartCenterX = tester.getCenter(lensFinder).dx;
    final dockRect = tester.getRect(dockFinder);
    expect(lensStartCenterX, lessThan(dockRect.left + dockRect.width * 0.30));

    // 2. Finger-drag the Liquid Jade Lens continuously across the dock from Tab 0 -> Tab 3 ('服务配置')
    final dragGesture = await tester.startGesture(
      Offset(dockRect.left + 44.0, dockRect.center.dy),
    );
    await pumpFrames(3);
    // Move halfway across the dock -> lens tracks finger smoothly in mid-bar!
    await dragGesture.moveTo(Offset(dockRect.center.dx, dockRect.center.dy));
    await pumpFrames(4);
    final lensMidDragX = tester.getCenter(lensFinder).dx;
    expect(lensMidDragX, greaterThan(lensStartCenterX + 60.0));
    expect(lensMidDragX, lessThan(dockRect.right - 60.0));

    // Continue dragging onto Slot 3 ('服务配置') and release
    await dragGesture.moveTo(
      Offset(dockRect.right - 36.0, dockRect.center.dy),
    );
    await pumpFrames(4);
    await dragGesture.up();
    await pumpFrames(18);
    expect(tester.takeException(), isNull);

    // Landed on '服务配置' Level-1 directory; lens settled on rightmost slot
    final lensSlot3X = tester.getCenter(lensFinder).dx;
    expect(lensSlot3X, greaterThan(dockRect.left + dockRect.width * 0.70));
    expect(find.text('基础与外观'), findsOneWidget);

    // 3. Drill into Level-2 subpage ('基础与外观') -> verify top-left Header Jade Back Pill appears
    await tester.tap(find.text('基础与外观'));
    await pumpFrames(16);
    expect(
      find.byKey(const ValueKey('header-jade-back-pill')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('setup-sec-basic')), findsOneWidget);

    // 4. Short rightward swipe (< 20% width) cancels cleanly and stays on Level-2
    const subpageCenter = Offset(110.0, 320.0);
    final cancelSwipe = await tester.startGesture(subpageCenter);
    await cancelSwipe.moveBy(const Offset(42.0, 0.0));
    await pumpFrames(2);
    await cancelSwipe.up();
    await pumpFrames(14);
    expect(find.byKey(const ValueKey('setup-sec-basic')), findsOneWidget);

    // 5. Full-screen rightward swipe-back (> 35% width from content middle, not just edge) pops Level-2 -> Level-1!
    final commitSwipe = await tester.startGesture(const Offset(80.0, 340.0));
    await commitSwipe.moveBy(const Offset(24.0, 0.0));
    await tester.pump(const Duration(milliseconds: 16));
    await commitSwipe.moveBy(const Offset(80.0, 0.0));
    await tester.pump(const Duration(milliseconds: 16));
    await commitSwipe.moveBy(const Offset(80.0, 0.0));
    await tester.pump(const Duration(milliseconds: 16));
    await commitSwipe.up();
    await pumpFrames(16);
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('header-jade-back-pill')),
      findsNothing,
    );
    expect(find.text('关于与更新'), findsOneWidget);

    // 6. Test 4-Tier System Back Chain: Inline Editor -> Level-2 Subpage -> Level-1 -> Root Tab 0 ('调用流')
    await tester.tap(find.text('基础与外观'));
    await pumpFrames(16);
    await tester.tap(find.text('MCP 服务名称'));
    await pumpFrames(14);
    expect(find.byType(TextField), findsOneWidget);

    // Tier A: System back collapses inline editor first without leaving Level-2
    await tester.binding.handlePopRoute();
    await pumpFrames(14);
    expect(find.byType(TextField), findsNothing);
    expect(find.byKey(const ValueKey('setup-sec-basic')), findsOneWidget);

    // Tier B: System back pops Level-2 subpage back to Level-1 directory
    await tester.binding.handlePopRoute();
    await pumpFrames(16);
    expect(
      find.byKey(const ValueKey('header-jade-back-pill')),
      findsNothing,
    );
    expect(find.text('关于与更新'), findsOneWidget);

    // Bonus check: Re-tapping active '服务配置' tab on bottom dock also pops Level-2 -> Level-1!
    await tester.tap(find.text('基础与外观'));
    await pumpFrames(16);
    expect(
      find.byKey(const ValueKey('header-jade-back-pill')),
      findsOneWidget,
    );
    await tester.tap(find.text('服务配置').last);
    await pumpFrames(16);
    expect(
      find.byKey(const ValueKey('header-jade-back-pill')),
      findsNothing,
    );

    // Tier C: System back on non-home root tab glides Liquid Jade Lens smoothly back to Tab 0 ('调用流')
    await tester.binding.handlePopRoute();
    await pumpFrames(22);
    final lensReturnedX = tester.getCenter(lensFinder).dx;
    expect(lensReturnedX, lessThan(dockRect.left + dockRect.width * 0.30));
  });

  testWidgets(
      'v3.2.0 Concentric Large-Radius & Sculpted Jade Capsule Unification across desktop stage, buttons, cards & modals',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend();
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);

    // 1. Verify action buttons ('清空') & segmented strip ('全部') use 999px StadiumBorder capsules
    final clearBtnBox = tester.widget<DecoratedBox>(
      find.ancestor(
        of: find.text('清空'),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is ShapeDecoration &&
              (w.decoration as ShapeDecoration).shape is StadiumBorder,
        ),
      ).first,
    );
    expect(
      (clearBtnBox.decoration as ShapeDecoration).shape,
      isA<StadiumBorder>(),
    );

    final segOuterBox = tester.widget<DecoratedBox>(
      find.ancestor(
        of: find.text('全部'),
        matching: find.byWidgetPredicate(
          (w) =>
              w is DecoratedBox &&
              w.decoration is ShapeDecoration &&
              (w.decoration as ShapeDecoration).shape is StadiumBorder,
        ),
      ).first,
    );
    expect(
      (segOuterBox.decoration as ShapeDecoration).shape,
      isA<StadiumBorder>(),
    );

    // 2. Verify Share Creation Modal uses concentric 28px RoundedSuperellipseBorder
    backend.emitDroppedFiles([r'D:\demo\concentric_share']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(tester.takeException(), isNull);
    final shareDialog = tester.widget<Dialog>(find.byType(Dialog).last);
    expect(shareDialog.shape, isA<RoundedSuperellipseBorder>());
    final shareShape = shareDialog.shape! as RoundedSuperellipseBorder;
    expect(
      shareShape.borderRadius,
      equals(BorderRadius.circular(28)),
    );
  });

  testWidgets(
      'v3.2.1 Desktop Zero-Jitter Scroll: top header, sidebar, and 24px gallery stage never collapse or shift on wheel/drag scroll',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend();
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);

    // Switch to ServiceSetupPage ('服务配置' -> 'all' so content scrolls vertically)
    await tester.tap(find.text('服务配置').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('全部展开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final cmdBtnBefore = tester.getRect(find.text('Ctrl K'));
    final sidebarNavBefore = tester.getRect(find.text('关于与更新').first);
    final setupRailBefore = tester.getRect(find.text('基础与外观').first);

    // Emit downward & upward mouse wheel scrolls across multiple frames
    final scrollTarget = tester.getCenter(find.text('基础服务与全局密码'));
    final pointer = TestPointer(7, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(scrollTarget));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 240)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getRect(find.text('Ctrl K')), equals(cmdBtnBefore));
      expect(
        tester.getRect(find.text('关于与更新').first),
        equals(sidebarNavBefore),
      );
      expect(
        tester.getRect(find.text('基础与外观').first),
        equals(setupRailBefore),
      );
    }

    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -240)));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.getRect(find.text('Ctrl K')), equals(cmdBtnBefore));
      expect(
        tester.getRect(find.text('关于与更新').first),
        equals(sidebarNavBefore),
      );
      expect(
        tester.getRect(find.text('基础与外观').first),
        equals(setupRailBefore),
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'v3.3.0 Prism Design System: 2D Light/Dark x 6-Accent Theme Engine (Default Icon Indigo), Tray Quick Action, and Zero Duplicate Back Buttons',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      PrismPalette.configureAccent(PrismAccentId.indigo);
    });

    // 1. Desktop (760x820 — previously caught in <820 drill-down) uses 2-pane Setup with ZERO back buttons
    tester.view.physicalSize = const Size(760, 820);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend();
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);

    // Default theme #1 matches App Icon Starlight Indigo (#4F46E5 -> 0x4F46E5)
    expect(PrismPalette.activeAccentSpec.id, equals(PrismAccentId.indigo));
    expect(PrismPalette.activeLight.clay, equals(const Color(0xFF4F46E5)));
    expect(PrismPalette.activeDark.clay, equals(const Color(0xFF818CF8)));
    expect(backend.lastSyncedAccentRgb, equals(0x4F46E5));

    // Desktop caption bar includes explicit Hide-to-Tray quick button
    final trayQuickBtn = find.byKey(const ValueKey('caption-hide-to-tray-btn'));
    expect(trayQuickBtn, findsOneWidget);
    await tester.tap(trayQuickBtn);
    await tester.pump(const Duration(milliseconds: 200));
    expect(backend.hiddenToTrayCount, equals(1));

    // Switch to Setup page at 760px desktop width (icon-rail sidebar) -> zero duplicate or stray back buttons!
    await tester.tap(find.byTooltip('服务配置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('header-jade-back-pill')), findsNothing);
    expect(find.byKey(const ValueKey('setup-mobile-back-btn')), findsNothing);
    expect(find.text('外观明暗与主题色调'), findsOneWidget);

    // 2. Switch Accent Theme in Setup ('温润青玉' jade) & Dark Mode -> persists to config & syncs tray RGB
    await tester.ensureVisible(find.byKey(const ValueKey('accent-chip-jade')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const ValueKey('accent-chip-jade')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(PrismPalette.activeAccentSpec.id, equals(PrismAccentId.jade));
    expect(backend.config['accent_theme'], equals('jade'));
    expect(backend.lastSyncedAccentRgb, equals(0x059669));

    // Switch to Dark Mode ('暗色模式') -> active palette updates to Dark Jade (#34D399 -> 0x34D399)
    await tester.ensureVisible(find.text('暗色模式'));
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.text('暗色模式'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(backend.config['theme_mode'], equals('dark'));
    expect(backend.lastSyncedIsDark, isTrue);
    expect(backend.lastSyncedAccentRgb, equals(0x34D399));

    // 3. Narrow Mobile viewport (390x844) -> drill into Level-2 shows ONLY top header back pill, NEVER bottom duplicate!
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('基础与外观').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byKey(const ValueKey('header-jade-back-pill')), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-mobile-back-btn')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'v3.4.0 Point-of-Click Theme Ripple Origin & Multi-Platform macOS/Linux GUI Asset Resolution',
      (tester) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      PrismPalette.configureAccent(PrismAccentId.indigo);
    });
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1.0;

    final backend = _FakeConsoleBackend();
    await tester.pumpWidget(AgentMcpConsoleApp(backend: backend));
    await tester.pump(const Duration(milliseconds: 450));
    expect(tester.takeException(), isNull);

    // Navigate to ServiceSetupPage -> 基础与外观
    await tester.tap(find.text('服务配置').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final shellCtx = tester.element(find.byType(Scaffold).first);

    // 1. Click '陶土暖珀' swatch in lower-middle Setup pane -> wave origin MUST match exact swatch tap center, NOT top-right!
    final terracottaFinder =
        find.byKey(const ValueKey('accent-chip-terracotta'));
    await tester.ensureVisible(terracottaFinder);
    await tester.pump(const Duration(milliseconds: 120));
    final swatchTapPos = tester.getCenter(terracottaFinder);
    await tester.tapAt(swatchTapPos);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final originFromSwatch = PrismThemeCrossFade.debugLastRevealOrigin(shellCtx);
    expect(originFromSwatch, isNotNull);
    expect((originFromSwatch! - swatchTapPos).distance, lessThan(2.5));
    expect(originFromSwatch.dy, greaterThan(200.0));

    // 2. Click '暗色模式' segmented pill -> wave origin MUST match exact segmented pill tap center!
    final darkPillFinder = find.text('暗色模式');
    await tester.ensureVisible(darkPillFinder);
    await tester.pump(const Duration(milliseconds: 120));
    final darkTapPos = tester.getCenter(darkPillFinder);
    await tester.tapAt(darkTapPos);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final originFromSegment =
        PrismThemeCrossFade.debugLastRevealOrigin(shellCtx);
    expect(originFromSegment, isNotNull);
    expect((originFromSegment! - darkTapPos).distance, lessThan(2.5));

    // 3. Click top-bar sun icon -> wave origin matches top-bar sun button tap center!
    final sunBtnFinder = find.byTooltip('切换至浅色模式');
    final sunTapPos = tester.getCenter(sunBtnFinder);
    await tester.tapAt(sunTapPos);
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    final originFromSun = PrismThemeCrossFade.debugLastRevealOrigin(shellCtx);
    expect(originFromSun, isNotNull);
    expect((originFromSun! - sunTapPos).distance, lessThan(2.5));
    expect(originFromSun.dy, lessThan(60.0));

    // 4. Verify UpdateInfo.preferredAsset resolves macOS DMG (ARM64 + Intel) & Linux GTK3 GUI (x64 + ARM64)
    final parsed = UpdateInfo.tryParseGithubApi({
      'tag_name': 'v3.4.0',
      'html_url': 'https://github.com/iamr0s/agent-mcp/releases/tag/v3.4.0',
      'body': '## 更新亮点\n- 全新同心折射棱镜图标与全平台 GUI 发布',
      'assets': [
        {
          'name': 'AgentMCP-v3.4.0-windows-x64-sfx.exe',
          'browser_download_url': 'https://example.com/win.exe',
          'size': 28000000,
        },
        {
          'name': 'AgentMCP-v3.4.0-macos-arm64.dmg',
          'browser_download_url': 'https://example.com/mac-arm64.dmg',
          'size': 32000000,
        },
        {
          'name': 'AgentMCP-v3.4.0-macos-x64.dmg',
          'browser_download_url': 'https://example.com/mac-x64.dmg',
          'size': 33000000,
        },
        {
          'name': 'AgentMCP-v3.4.0-linux-x64-gui.tar.gz',
          'browser_download_url': 'https://example.com/linux-x64-gui.tar.gz',
          'size': 26000000,
        },
        {
          'name': 'AgentMCP-v3.4.0-linux-arm64-gui.tar.gz',
          'browser_download_url': 'https://example.com/linux-arm64-gui.tar.gz',
          'size': 25000000,
        },
      ],
    })!;

    expect(
      parsed
          .preferredAsset(
            isWindows: false,
            isAndroid: false,
            isLinux: false,
            isMacOS: true,
            cpuArch: 'arm64',
          )
          ?.name,
      equals('AgentMCP-v3.4.0-macos-arm64.dmg'),
    );
    expect(
      parsed
          .preferredAsset(
            isWindows: false,
            isAndroid: false,
            isLinux: false,
            isMacOS: true,
            cpuArch: 'x64',
          )
          ?.name,
      equals('AgentMCP-v3.4.0-macos-x64.dmg'),
    );
    expect(
      parsed
          .preferredAsset(
            isWindows: false,
            isAndroid: false,
            isLinux: true,
            cpuArch: 'x64',
          )
          ?.name,
      equals('AgentMCP-v3.4.0-linux-x64-gui.tar.gz'),
    );
    expect(
      parsed
          .preferredAsset(
            isWindows: false,
            isAndroid: false,
            isLinux: true,
            cpuArch: 'arm64',
          )
          ?.name,
      equals('AgentMCP-v3.4.0-linux-arm64-gui.tar.gz'),
    );
    expect(tester.takeException(), isNull);
  });
}
