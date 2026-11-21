import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import 'config.dart';

enum TrayAction { openConsole, startService, stopService, quitApp }

const int _wmTrayCallback = WM_USER + 20;
const int _idOpen = 1001;
const int _idStart = 1002;
const int _idStop = 1003;
const int _idQuit = 1004;

/// Runs a native Win32 System Tray icon on a dedicated background Isolate
/// so `GetMessage` never blocks the async Dart event loop or HTTP server.
class Win32TrayManager {
  Isolate? _isolate;
  SendPort? _cmdPort;
  StreamSubscription<dynamic>? _sub;

  bool get isActive => _isolate != null;

  Future<bool> start({
    required String tooltip,
    String? iconPath,
    required void Function(TrayAction action) onAction,
  }) async {
    if (!Platform.isWindows) return false;
    if (_isolate != null) return true;

    final resolvedIcon = iconPath ?? _locateDefaultIco();
    final receivePort = ReceivePort();
    final readyCompleter = Completer<bool>();

    _sub = receivePort.listen((msg) {
      if (msg is SendPort) {
        _cmdPort = msg;
      } else if (msg == 'ready') {
        if (!readyCompleter.isCompleted) readyCompleter.complete(true);
      } else if (msg == 'failed') {
        if (!readyCompleter.isCompleted) readyCompleter.complete(false);
      } else if (msg is String) {
        switch (msg) {
          case 'open':
            onAction(TrayAction.openConsole);
          case 'start':
            onAction(TrayAction.startService);
          case 'stop':
            onAction(TrayAction.stopService);
          case 'quit':
            onAction(TrayAction.quitApp);
        }
      }
    });

    try {
      _isolate = await Isolate.spawn<_TrayInitArgs>(
        _trayIsolateMain,
        _TrayInitArgs(
          mainSendPort: receivePort.sendPort,
          tooltip: tooltip,
          iconPath: resolvedIcon,
        ),
      );
      return await readyCompleter.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => false,
      );
    } catch (_) {
      await stop();
      return false;
    }
  }

  Future<void> stop() async {
    try {
      _cmdPort?.send('quit');
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await _sub?.cancel();
    _sub = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _cmdPort = null;
  }

  static String? _locateDefaultIco() {
    final root = StoragePaths.instance.rootDir.path;
    final candidates = [
      p.join(root, 'apps', 'agent_mcp_app', 'assets', 'app_icon.ico'),
      p.join(root, 'assets', 'app_icon.ico'),
      p.join(File(Platform.resolvedExecutable).parent.path, 'app_icon.ico'),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }
}

class _TrayInitArgs {
  final SendPort mainSendPort;
  final String tooltip;
  final String? iconPath;

  const _TrayInitArgs({
    required this.mainSendPort,
    required this.tooltip,
    required this.iconPath,
  });
}

void _trayIsolateMain(_TrayInitArgs args) {
  final cmdRecv = ReceivePort();
  args.mainSendPort.send(cmdRecv.sendPort);

  int hwnd = 0;
  final nid = calloc<NOTIFYICONDATA>();

  void removeTrayIcon() {
    if (hwnd != 0) {
      Shell_NotifyIcon(NIM_DELETE, nid);
    }
  }

  int wndProc(int hWnd, int uMsg, int wParam, int lParam) {
    if (uMsg == _wmTrayCallback) {
      if (lParam == WM_LBUTTONUP || lParam == WM_LBUTTONDBLCLK) {
        args.mainSendPort.send('open');
        return 0;
      }
      if (lParam == WM_RBUTTONUP) {
        final hMenu = CreatePopupMenu();
        final pOpen = '打开控制台'.toNativeUtf16();
        final pStart = '启动 MCP 服务'.toNativeUtf16();
        final pStop = '停止 MCP 服务'.toNativeUtf16();
        final pQuit = '完全退出应用'.toNativeUtf16();
        final pt = calloc<POINT>();
        try {
          AppendMenu(hMenu, MF_STRING, _idOpen, pOpen);
          AppendMenu(hMenu, MF_SEPARATOR, 0, ffi.nullptr);
          AppendMenu(hMenu, MF_STRING, _idStart, pStart);
          AppendMenu(hMenu, MF_STRING, _idStop, pStop);
          AppendMenu(hMenu, MF_SEPARATOR, 0, ffi.nullptr);
          AppendMenu(hMenu, MF_STRING, _idQuit, pQuit);

          GetCursorPos(pt);
          SetForegroundWindow(hWnd);
          TrackPopupMenu(
            hMenu,
            TPM_LEFTALIGN | TPM_BOTTOMALIGN,
            pt.ref.x,
            pt.ref.y,
            0,
            hWnd,
            ffi.nullptr,
          );
          PostMessage(hWnd, WM_NULL, 0, 0);
        } finally {
          calloc.free(pOpen);
          calloc.free(pStart);
          calloc.free(pStop);
          calloc.free(pQuit);
          calloc.free(pt);
          DestroyMenu(hMenu);
        }
        return 0;
      }
    } else if (uMsg == WM_COMMAND) {
      final cmdId = wParam & 0xFFFF;
      switch (cmdId) {
        case _idOpen:
          args.mainSendPort.send('open');
        case _idStart:
          args.mainSendPort.send('start');
        case _idStop:
          args.mainSendPort.send('stop');
        case _idQuit:
          removeTrayIcon();
          DestroyWindow(hWnd);
          args.mainSendPort.send('quit');
      }
      return 0;
    } else if (uMsg == WM_DESTROY) {
      removeTrayIcon();
      PostQuitMessage(0);
      return 0;
    }
    return DefWindowProc(hWnd, uMsg, wParam, lParam);
  }

  final callback = ffi.NativeCallable<WNDPROC>.isolateLocal(
    wndProc,
    exceptionalReturn: 0,
  );

  final clsName =
      'AgentMcpNextTray_${pid}_${DateTime.now().millisecondsSinceEpoch}'
          .toNativeUtf16();
  final titlePtr = args.tooltip.toNativeUtf16();
  final wc = calloc<WNDCLASS>();

  try {
    final hInstance = GetModuleHandle(ffi.nullptr);
    wc.ref
      ..lpfnWndProc = callback.nativeFunction
      ..hInstance = hInstance
      ..lpszClassName = clsName;

    RegisterClass(wc);
    // HWND_MESSAGE (-3) isolates the message-only tray window from top-level
    // desktop broadcast storms (WM_SETTINGCHANGE / Security-SPP / IME).
    hwnd = CreateWindowEx(
      0,
      clsName,
      titlePtr,
      0,
      0,
      0,
      0,
      0,
      HWND_MESSAGE,
      0,
      hInstance,
      ffi.nullptr,
    );

    if (hwnd == 0) {
      args.mainSendPort.send('failed');
      return;
    }

    cmdRecv.listen((cmd) {
      if (cmd == 'quit' && hwnd != 0) {
        PostMessage(hwnd, WM_DESTROY, 0, 0);
      }
    });

    int hIcon = 0;
    if (args.iconPath != null && File(args.iconPath!).existsSync()) {
      final icoPtr = args.iconPath!.toNativeUtf16();
      try {
        hIcon = LoadImage(
          0,
          icoPtr,
          IMAGE_ICON,
          0,
          0,
          LR_LOADFROMFILE | LR_DEFAULTSIZE,
        );
      } finally {
        calloc.free(icoPtr);
      }
    }
    if (hIcon == 0) {
      hIcon = LoadIcon(0, IDI_APPLICATION);
    }

    nid.ref
      ..cbSize = ffi.sizeOf<NOTIFYICONDATA>()
      ..hWnd = hwnd
      ..uID = 1
      ..uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP
      ..uCallbackMessage = _wmTrayCallback
      ..hIcon = hIcon
      ..szTip = args.tooltip.length > 120
          ? args.tooltip.substring(0, 120)
          : args.tooltip;

    final added = Shell_NotifyIcon(NIM_ADD, nid);
    args.mainSendPort.send(added != 0 ? 'ready' : 'failed');
    if (added == 0) return;

    final msg = calloc<MSG>();
    try {
      while (GetMessage(msg, 0, 0, 0) > 0) {
        TranslateMessage(msg);
        DispatchMessage(msg);
      }
    } finally {
      calloc.free(msg);
    }
  } finally {
    removeTrayIcon();
    if (hwnd != 0) {
      DestroyWindow(hwnd);
      hwnd = 0;
    }
    UnregisterClass(clsName, GetModuleHandle(ffi.nullptr));
    calloc.free(nid);
    calloc.free(wc);
    calloc.free(clsName);
    calloc.free(titlePtr);
    callback.close();
    cmdRecv.close();
  }
}

/// Opens the Agent MCP Console in either:
/// 1) Compiled native Flutter desktop binary (`agent_mcp_app.exe`), if built;
/// 2) Standalone frameless Edge/Chrome `--app=<url>` window;
/// 3) System default browser fallback.
Future<void> launchConsoleWindow(String url) async {
  if (Platform.isWindows) {
    final root = StoragePaths.instance.rootDir.path;
    final nativeCandidates = [
      p.join(
        root,
        'apps',
        'agent_mcp_app',
        'build',
        'windows',
        'x64',
        'runner',
        'Release',
        'agent_mcp_app.exe',
      ),
      p.join(File(Platform.resolvedExecutable).parent.path, 'agent_mcp_app.exe'),
    ];
    for (final exe in nativeCandidates) {
      if (File(exe).existsSync()) {
        await Process.start(exe, const [], mode: ProcessStartMode.detached);
        return;
      }
    }

    final browserCandidates = <String>[
      r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
      r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? '',
        r'Google\Chrome\Application\chrome.exe',
      ),
    ];
    final profileDir =
        Directory(p.join(StoragePaths.instance.dataDir.path, 'app_window_profile'))
          ..createSync(recursive: true);
    for (final browser in browserCandidates) {
      if (File(browser).existsSync()) {
        await Process.start(
          browser,
          [
            '--app=$url',
            '--window-size=1180,780',
            '--user-data-dir=${profileDir.path}',
          ],
          mode: ProcessStartMode.detached,
        );
        return;
      }
    }

    await Process.run('cmd', ['/c', 'start', '', url]);
    return;
  }

  if (Platform.isMacOS) {
    await Process.run('open', [url]);
    return;
  }

  await Process.run('xdg-open', [url]);
}
