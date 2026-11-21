import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'logging_utils.dart';

/// Cross-platform OS Login Auto-Start & Silent Tray Launch manager
/// supporting Windows (`HKCU\...\Run`), macOS (`~/Library/LaunchAgents`),
/// and Linux (`~/.config/autostart` XDG Desktop Entry).
class AutoStartManager {
  static const String _winRegKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _winRegValue = 'AgentMCP';
  static const String _macLabel = 'com.iamr0s.agentmcp';
  static const String _linuxDesktopName = 'agent-mcp.desktop';

  /// Resolves the native desktop executable path for the current OS,
  /// whether invoked from inside the compiled Flutter app or CLI/server.
  static String? resolveDesktopExecutablePath() {
    final execPath = Platform.resolvedExecutable;
    final execBase = p.basenameWithoutExtension(execPath).toLowerCase();
    if (execBase != 'dart' &&
        execBase != 'dartaotruntime' &&
        execBase != 'flutter_tester') {
      final f = File(execPath);
      if (f.existsSync()) return f.absolute.path;
    }

    final root = StoragePaths.instance.rootDir.path;
    final candidates = <String>[
      if (Platform.isWindows) ...[
        p.join(root, 'dist', 'windows', 'agent_mcp_app.exe'),
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
      ] else if (Platform.isMacOS) ...[
        p.join(
          root,
          'dist',
          'macos',
          'agent_mcp_app.app',
          'Contents',
          'MacOS',
          'agent_mcp_app',
        ),
        p.join(
          root,
          'apps',
          'agent_mcp_app',
          'build',
          'macos',
          'Build',
          'Products',
          'Release',
          'agent_mcp_app.app',
          'Contents',
          'MacOS',
          'agent_mcp_app',
        ),
      ] else if (Platform.isLinux) ...[
        p.join(root, 'dist', 'linux', 'agent_mcp_app'),
        p.join(
          root,
          'apps',
          'agent_mcp_app',
          'build',
          'linux',
          'x64',
          'release',
          'bundle',
          'agent_mcp_app',
        ),
      ],
    ];

    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) return f.absolute.path;
    }
    return null;
  }

  static File _macPlistFile() {
    final home = Platform.environment['HOME'] ?? '';
    return File(p.join(home, 'Library', 'LaunchAgents', '$_macLabel.plist'));
  }

  static File _linuxDesktopFile() {
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    final base = (xdg != null && xdg.trim().isNotEmpty)
        ? xdg.trim()
        : p.join(Platform.environment['HOME'] ?? '', '.config');
    return File(p.join(base, 'autostart', _linuxDesktopName));
  }

  /// Checks whether OS-level login auto-start is currently registered.
  static bool isOsRegistered() {
    try {
      if (Platform.isWindows) {
        final r = Process.runSync(
          'reg',
          ['query', _winRegKey, '/v', _winRegValue],
          runInShell: false,
        );
        return r.exitCode == 0;
      }
      if (Platform.isMacOS) {
        return _macPlistFile().existsSync();
      }
      if (Platform.isLinux) {
        return _linuxDesktopFile().existsSync();
      }
    } catch (_) {}
    return false;
  }

  /// Effective `launch_at_startup` flag merging config preference with OS state.
  static bool effectiveLaunchAtStartup(Map<String, dynamic> cfg) {
    if (cfg.containsKey('launch_at_startup')) {
      return cfg['launch_at_startup'] == true;
    }
    return isOsRegistered();
  }

  /// Applies `launch_at_startup` + `silent_start` to the underlying OS login
  /// mechanism (Registry Run on Windows, LaunchAgents on macOS, XDG on Linux).
  static Map<String, dynamic> syncWithOs({
    required bool enabled,
    required bool silentStart,
  }) {
    try {
      if (!enabled) {
        if (Platform.isWindows) {
          Process.runSync(
            'reg',
            ['delete', _winRegKey, '/v', _winRegValue, '/f'],
            runInShell: false,
          );
        } else if (Platform.isMacOS) {
          final f = _macPlistFile();
          if (f.existsSync()) f.deleteSync();
        } else if (Platform.isLinux) {
          final f = _linuxDesktopFile();
          if (f.existsSync()) f.deleteSync();
        }
        McpLogger.instance.info(
          '[AUTOSTART] Disabled OS login auto-start (${Platform.operatingSystem})',
        );
        return {'ok': true, 'enabled': false};
      }

      final exe = resolveDesktopExecutablePath();
      if (exe == null || exe.isEmpty) {
        McpLogger.instance.warning(
          '[AUTOSTART] Desktop binary not found yet; saved preference in config.',
        );
        return {
          'ok': false,
          'enabled': true,
          'warning': '尚未找到已编译的桌面端可执行文件，配置已保存，打包后生效。',
        };
      }

      if (Platform.isWindows) {
        final cmdValue = silentStart ? '"$exe" --silent' : '"$exe"';
        final r = Process.runSync(
          'reg',
          [
            'add',
            _winRegKey,
            '/v',
            _winRegValue,
            '/t',
            'REG_SZ',
            '/d',
            cmdValue,
            '/f',
          ],
          runInShell: false,
        );
        if (r.exitCode != 0) {
          return {'ok': false, 'error': '${r.stderr}'.trim()};
        }
      } else if (Platform.isMacOS) {
        final plist = _macPlistFile();
        plist.parent.createSync(recursive: true);
        final workDir = File(exe).parent.path;
        final silentArg =
            silentStart ? '\n    <string>--silent</string>' : '';
        plist.writeAsStringSync(
          '<?xml version="1.0" encoding="UTF-8"?>\n'
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
          '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
          '<plist version="1.0">\n'
          '<dict>\n'
          '  <key>Label</key>\n'
          '  <string>$_macLabel</string>\n'
          '  <key>ProgramArguments</key>\n'
          '  <array>\n'
          '    <string>${_xmlEscape(exe)}</string>$silentArg\n'
          '  </array>\n'
          '  <key>WorkingDirectory</key>\n'
          '  <string>${_xmlEscape(workDir)}</string>\n'
          '  <key>RunAtLoad</key>\n'
          '  <true/>\n'
          '  <key>ProcessType</key>\n'
          '  <string>Interactive</string>\n'
          '</dict>\n'
          '</plist>\n',
          flush: true,
        );
      } else if (Platform.isLinux) {
        final desktop = _linuxDesktopFile();
        desktop.parent.createSync(recursive: true);
        final workDir = File(exe).parent.path;
        final execLine = silentStart ? '"$exe" --silent' : '"$exe"';
        desktop.writeAsStringSync(
          '[Desktop Entry]\n'
          'Type=Application\n'
          'Version=1.0\n'
          'Name=Agent MCP Console\n'
          'Comment=Agent MCP Desktop Server & Sub-MCP Gateway\n'
          'Path=$workDir\n'
          'Exec=$execLine\n'
          'Terminal=false\n'
          'StartupNotify=false\n'
          'X-GNOME-Autostart-enabled=true\n',
          flush: true,
        );
      }

      McpLogger.instance.info(
        '[AUTOSTART] Registered OS login auto-start (${Platform.operatingSystem}, silent=$silentStart) -> $exe',
      );
      return {'ok': true, 'enabled': true, 'exe': exe, 'silent': silentStart};
    } catch (e) {
      McpLogger.instance.warning('[AUTOSTART] Failed to sync OS auto-start: $e');
      return {'ok': false, 'error': '$e'};
    }
  }

  static void syncFromConfigMap(Map<String, dynamic> cfg) {
    final enabled = cfg['launch_at_startup'] == true;
    final silent = cfg['silent_start'] == true;
    syncWithOs(enabled: enabled, silentStart: silent);
  }

  static String _xmlEscape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}
