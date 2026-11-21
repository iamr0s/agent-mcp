import 'dart:async';

import 'package:agent_mcp_app/main.dart';
import 'package:agent_mcp_app/services/console_backend_interface.dart';
import 'package:agent_mcp_app/theme/claude_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeConsoleBackend extends ConsoleBackend {
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
        'version': '2.0.0',
        'dashboard_mode': false,
      };

  @override
  Future<Map<String, dynamic>> login(String password) async => {'ok': true};

  @override
  Future<void> logout() async {}

  @override
  Future<Map<String, dynamic>> getStatus() async => {
        'running': true,
        'version': '2.0.0',
        'dashboard_mode': false,
        'tunnels': {
          'installed': true,
          'version': '2025.2.1',
          'binary': r'D:\agent_mcp_next\bin\cloudflared.exe',
          'tunnels': {
            'prof-main': {'running': true},
          },
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
      'FlClash-style custom Windows caption controls toggle pin, maximize, minimize, and hide-to-tray',
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
    await tester.pumpAndSettle();

    expect(find.byType(ClaudeCaptionIcon), findsNWidgets(3));
    await tester.tap(find.byTooltip('窗口置顶'));
    await tester.pumpAndSettle();
    expect(pinned, isTrue);

    await tester.tap(find.byTooltip('最大化'));
    await tester.pumpAndSettle();
    expect(maximized, isTrue);

    await tester.tap(find.byTooltip('最小化'));
    await tester.pumpAndSettle();
    expect(minimizedCount, equals(1));

    await tester.tap(find.byTooltip('隐藏到系统托盘（MCP 服务继续运行）'));
    await tester.pumpAndSettle();
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
      expect(find.textContaining('窗口云母与毛玻璃透光'), findsOneWidget);
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

    // Manual collapse button on FlClash floating bottom capsule
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

    // Verify redundant FGS IP copy buttons were removed while profile multi-endpoint copy button exists
    expect(find.text('Android 通知栏常驻服务保活（FlClash 模式）'), findsOneWidget);
    expect(find.text('复制地址'), findsOneWidget);

    // Tap 复制地址 on the multi-endpoint profile -> opens DropMenu with LAN, Tailscale, HTTPS & Copy All!
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
}
