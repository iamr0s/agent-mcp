import 'dart:async';

import 'package:agent_mcp_app/main.dart';
import 'package:agent_mcp_app/services/console_backend_interface.dart';
import 'package:agent_mcp_app/theme/claude_theme.dart';
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

  @override
  Future<void> hideWindowToTray() async {}

  @override
  Future<void> syncNativeWindowTheme(bool isDark) async {}

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
            theme: buildClaudeTheme(ClaudePalette.light),
            home: Scaffold(
              body: Center(
                child: ClaudeGlassBar(
                  borderRadius: 16,
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ClaudeStatusDot(
                        key: const ValueKey('status-dot'),
                        color: Colors.green,
                        pulsing: pulsing,
                        size: 8.0,
                      ),
                      ClaudeButton(
                        label: '启动服务',
                        variant: ClaudeBtnVariant.clay,
                        onPressed: () => setState(() {
                          expanded = !expanded;
                          pulsing = !pulsing;
                        }),
                      ),
                      ClaudeSegmented<String>(
                        value: tab,
                        items: const [
                          ('ALL', '全部'),
                          ('TOOL', '工具'),
                          ('ERR', '异常'),
                        ],
                        onChanged: (v) => setState(() => tab = v),
                      ),
                      ClaudeSwitch(
                        value: toggled,
                        onChanged: (v) => setState(() => toggled = v),
                      ),
                      ClaudeCollapsible(
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
            theme: buildClaudeTheme(ClaudePalette.light),
            home: Scaffold(
              body: Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  height: 46,
                  child: ClaudeWindowCaptionActions(
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

    expect(find.byType(ClaudeCaptionIcon), findsNWidgets(3));
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
      if (vp.width < 820) {
        await tester.tap(find.text('基础与外观'));
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(find.textContaining('窗口云母与毛玻璃透光'), findsNothing);
      expect(find.text('基础服务与全局密码'), findsOneWidget);
    });
  }

  testWidgets(
      'Floating bottom nav collapse/restore, surrounding pass-through, semantic args, and empty-page wheel hide',
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

    // Manual collapse button on floating bottom capsule
    expect(find.byTooltip('收起底栏'), findsOneWidget);
    expect(tester.getCenter(find.byTooltip('收起底栏')).dy, lessThan(760));

    // Verify surrounding left/right margins of the floating capsule do NOT intercept hits
    final navBox = tester.getRect(find.byTooltip('收起底栏'));
    expect(navBox.right, lessThan(520)); // Centered maxWidth: 420 leaves side margins

    await tester.tap(find.byTooltip('收起底栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(tester.getCenter(find.byTooltip('收起底栏')).dy, greaterThan(760));
    expect(tester.getCenter(find.byTooltip('展开导航栏')).dy, lessThan(760));

    // Restore via mini pill at bottom edge
    await tester.tap(find.byTooltip('展开导航栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(tester.getCenter(find.byTooltip('收起底栏')).dy, lessThan(760));

    // Clear logs so feed is completely empty (maxScrollExtent == 0), then test mouse wheel scroll-to-hide
    backend.emptyLogs = true;
    await tester.tap(find.text('清空'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('暂无匹配的活动记录'), findsOneWidget);

    // Emit discrete desktop mouse wheel down over empty feed -> hides floating bottom bar!
    final center = tester.getCenter(find.text('暂无匹配的活动记录'));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(tester.getCenter(find.byTooltip('收起底栏')).dy, greaterThan(760));

    // Wheel up restores chrome smoothly even when page is empty!
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -120)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(tester.getCenter(find.byTooltip('收起底栏')).dy, lessThan(760));
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
      'v2.2 P0-6: Shared ClaudePulseClock multiplexes pulsing status dots and auto-sleeps when window hidden',
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

    expect(ClaudePulseClock.instance.activeSubscriberCount, greaterThanOrEqualTo(1));
    expect(ClaudePulseClock.instance.isTickerRunning, isTrue);

    // Hide window to system tray -> shared 120Hz ticker stops immediately (0% idle GPU)
    backend._win.value = backend._win.value.copyWith(isVisible: false);
    await tester.pump();
    expect(ClaudePulseClock.instance.isPaused, isTrue);
    expect(ClaudePulseClock.instance.isTickerRunning, isFalse);

    // Restore window -> shared ticker resumes smoothly
    backend._win.value = backend._win.value.copyWith(isVisible: true);
    await tester.pump();
    expect(ClaudePulseClock.instance.isPaused, isFalse);
    expect(ClaudePulseClock.instance.isTickerRunning, isTrue);
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
    expect(find.text('安全提取码与限次保护（可选）'), findsOneWidget);

    // Switch mode to single file and expand progressive-disclosure protection drawer to verify "1次即焚"
    await tester.tap(find.text('单个视频 / 文件'));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.text('安全提取码与限次保护（可选）'));
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

    await tester.tap(find.text('静态网站 / HTML'));
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
      'version': '2.9.0',
      'tag': 'v2.9.0',
      'build': 7,
      'published_at': '2026-11-22T12:00:00Z',
      'release_url': 'https://github.com/iamr0s/agent-mcp/releases/tag/v2.9.0',
      'notes': '- 新增自动更新与智能安装器',
      'assets': {
        'windows_sfx': {
          'name': 'AgentMCP-v2.9.0-windows-x64-sfx.exe',
          'url': 'https://github.com/iamr0s/agent-mcp/releases/download/v2.9.0/AgentMCP-v2.9.0-windows-x64-sfx.exe',
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
    expect(backend.updatePrefs.skippedVersion, equals('2.9.0'));

    expect(find.text('新版本 v2.9.0'), findsOneWidget);
    await tester.tap(find.text('新版本 v2.9.0'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('一键升级'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));

    expect(backend.launchedInstallerPath, contains('AgentMCP-v2.9.0-windows-x64-sfx.exe'));
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
            theme: buildClaudeTheme(ClaudePalette.dark),
            home: Scaffold(
              body: Stack(
                children: [
                  Align(
                    alignment: Alignment.topLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: ClaudeListGroup(
                        headerLabel: '控件测试组',
                        children: [
                          ClaudeSettingsRow(
                            title: '分体复制按钮',
                            subtitle: '左段直击复制，右段打开多通道菜单',
                            trailing: ClaudeSplitButton(
                              label: '复制主链接',
                              leading: const Icon(Icons.copy_rounded),
                              onPrimaryPressed: () =>
                                  setState(() => primaryCount++),
                              menuActions: [
                                ClaudeMenuAction(
                                  label: 'Tailscale 直连',
                                  badge: '100.x',
                                  onTap: () => setState(
                                    () => selectedMenuAction = 'ts',
                                  ),
                                ),
                                ClaudeMenuAction(
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
                      child: ClaudeDropMenu<String>(
                        value: selectedTool,
                        searchable: true,
                        items: [
                          const ClaudeDropMenuItem(
                            value: 'ALL',
                            label: '全部工具',
                          ),
                          for (var i = 1; i <= 10; i++)
                            ClaudeDropMenuItem(
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

    // 1. Sidebar exposes un-hidden v2.7.0 About & Update entry directly on main shell
    expect(find.text('关于与更新'), findsOneWidget);
    expect(find.text('v2.7.0'), findsOneWidget);
    await tester.tap(find.text('v2.7.0'));
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
}
