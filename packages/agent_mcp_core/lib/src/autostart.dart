import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'logging_utils.dart';

/// Cross-platform OS Login Auto-Start, Silent Tray Launch & Headless Linux `systemd` manager
/// supporting Windows (`HKCU\...\Run`), macOS (`~/Library/LaunchAgents`),
/// Linux Desktop (`~/.config/autostart`), and Headless Linux Servers (`systemd`).
class AutoStartManager {
  static const String _winRegKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _winRegValue = 'AgentMCP';
  static const String _macLabel = 'com.iamr0s.agentmcp';
  static const String _linuxDesktopName = 'agent-mcp.desktop';
  static const String linuxServiceName = 'agent-mcp.service';

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

  /// Resolves the standalone server/CLI binary path for headless daemon installation.
  static String? resolveServerExecutablePath() {
    final execPath = Platform.resolvedExecutable;
    final execBase = p.basenameWithoutExtension(execPath).toLowerCase();
    if (execBase != 'dart' &&
        execBase != 'dartaotruntime' &&
        execBase != 'flutter_tester') {
      final f = File(execPath);
      if (f.existsSync()) return f.absolute.path;
    }
    final root = StoragePaths.instance.rootDir.path;
    final binName = Platform.isWindows ? 'agent-mcp.exe' : 'agent-mcp';
    for (final c in [
      p.join(root, binName),
      p.join(root, 'bin', binName),
    ]) {
      final f = File(c);
      if (f.existsSync()) return f.absolute.path;
    }
    return resolveDesktopExecutablePath();
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

  static File linuxSystemdUnitFile({bool systemWide = false, Directory? baseOverride}) {
    if (baseOverride != null) {
      return File(p.join(baseOverride.path, linuxServiceName));
    }
    if (systemWide) {
      return File('/etc/systemd/system/$linuxServiceName');
    }
    final xdg = Platform.environment['XDG_CONFIG_HOME'];
    final base = (xdg != null && xdg.trim().isNotEmpty)
        ? xdg.trim()
        : p.join(Platform.environment['HOME'] ?? '', '.config');
    return File(p.join(base, 'systemd', 'user', linuxServiceName));
  }

  /// Builds a clean, production-grade `systemd` unit file content for headless Linux servers.
  static String buildSystemdUnitContent({
    required String executablePath,
    required String workingDirectory,
    required String configFilePath,
    bool systemWide = false,
  }) {
    final wantedBy = systemWide ? 'multi-user.target' : 'default.target';
    return '[Unit]\n'
        'Description=Agent MCP Remote Execution Node & Sub-MCP Gateway\n'
        'After=network-online.target\n'
        'Wants=network-online.target\n\n'
        '[Service]\n'
        'Type=simple\n'
        'WorkingDirectory=$workingDirectory\n'
        'Environment="AGENT_MCP_HOME=$workingDirectory"\n'
        'ExecStart="$executablePath" run -c "$configFilePath"\n'
        'Restart=on-failure\n'
        'RestartSec=3\n'
        'KillMode=process\n'
        'LimitNOFILE=65536\n\n'
        '[Install]\n'
        'WantedBy=$wantedBy\n';
  }

  /// Installs and optionally activates `agent-mcp.service` on Linux (`--user` or `--system`).
  static Map<String, dynamic> installLinuxSystemdService({
    bool systemWide = false,
    bool startNow = true,
    Directory? unitDirOverride,
    String? executableOverride,
  }) {
    final exe = executableOverride ?? resolveServerExecutablePath();
    if (exe == null || exe.isEmpty) {
      return {
        'ok': false,
        'error': '未找到已编译的 agent-mcp 可执行文件，请使用编译后的二进制执行安装。',
      };
    }
    final rootDir = StoragePaths.instance.rootDir.absolute.path;
    final cfgPath = StoragePaths.instance.defaultConfigFile.absolute.path;
    final unitFile = linuxSystemdUnitFile(
      systemWide: systemWide,
      baseOverride: unitDirOverride,
    );
    try {
      unitFile.parent.createSync(recursive: true);
      final content = buildSystemdUnitContent(
        executablePath: exe,
        workingDirectory: rootDir,
        configFilePath: cfgPath,
        systemWide: systemWide,
      );
      unitFile.writeAsStringSync(content, flush: true);
    } catch (e) {
      return {
        'ok': false,
        'unit_path': unitFile.path,
        'error': '写入 systemd 单元文件失败: $e',
      };
    }

    var systemctlActive = false;
    String systemctlNote = '';
    if (Platform.isLinux && unitDirOverride == null) {
      try {
        final scopeArgs = systemWide ? <String>[] : <String>['--user'];
        final reload = Process.runSync('systemctl', [...scopeArgs, 'daemon-reload']);
        if (reload.exitCode == 0) {
          final enableArgs = startNow
              ? [...scopeArgs, 'enable', '--now', linuxServiceName]
              : [...scopeArgs, 'enable', linuxServiceName];
          final en = Process.runSync('systemctl', enableArgs);
          systemctlActive = en.exitCode == 0;
          if (!systemctlActive) {
            systemctlNote = '${en.stderr}'.trim();
          }
        } else {
          systemctlNote = '${reload.stderr}'.trim();
        }
      } catch (e) {
        systemctlNote = '$e';
      }
    }

    return {
      'ok': true,
      'mode': systemWide ? 'system' : 'user',
      'unit_path': unitFile.path,
      'executable': exe,
      'working_directory': rootDir,
      'systemctl_started': systemctlActive,
      if (systemctlNote.isNotEmpty) 'note': systemctlNote,
    };
  }

  static Map<String, dynamic> uninstallLinuxSystemdService({
    bool systemWide = false,
    Directory? unitDirOverride,
  }) {
    final unitFile = linuxSystemdUnitFile(
      systemWide: systemWide,
      baseOverride: unitDirOverride,
    );
    if (Platform.isLinux && unitDirOverride == null) {
      try {
        final scopeArgs = systemWide ? <String>[] : <String>['--user'];
        Process.runSync('systemctl', [...scopeArgs, 'disable', '--now', linuxServiceName]);
      } catch (_) {}
    }
    var removed = false;
    if (unitFile.existsSync()) {
      unitFile.deleteSync();
      removed = true;
    }
    if (Platform.isLinux && unitDirOverride == null) {
      try {
        final scopeArgs = systemWide ? <String>[] : <String>['--user'];
        Process.runSync('systemctl', [...scopeArgs, 'daemon-reload']);
      } catch (_) {}
    }
    return {
      'ok': true,
      'removed': removed,
      'unit_path': unitFile.path,
    };
  }

  static Map<String, dynamic> queryLinuxSystemdStatus({bool systemWide = false}) {
    final unitFile = linuxSystemdUnitFile(systemWide: systemWide);
    var activeState = 'unknown';
    var enabledState = unitFile.existsSync() ? 'unit-present' : 'not-installed';
    if (Platform.isLinux) {
      try {
        final scopeArgs = systemWide ? <String>[] : <String>['--user'];
        final act = Process.runSync('systemctl', [...scopeArgs, 'is-active', linuxServiceName]);
        final outAct = '${act.stdout}'.trim();
        if (outAct.isNotEmpty) activeState = outAct;
        final en = Process.runSync('systemctl', [...scopeArgs, 'is-enabled', linuxServiceName]);
        final outEn = '${en.stdout}'.trim();
        if (outEn.isNotEmpty) enabledState = outEn;
      } catch (_) {}
    }
    return {
      'mode': systemWide ? 'system' : 'user',
      'unit_exists': unitFile.existsSync(),
      'unit_path': unitFile.path,
      'active_state': activeState,
      'enabled_state': enabledState,
    };
  }

  static bool? _cachedOsRegistered;
  static bool _probingOsRegistered = false;

  /// Checks whether OS-level login auto-start is currently registered (CLI fallback).
  static bool isOsRegistered() {
    try {
      if (Platform.isWindows) {
        final r = Process.runSync(
          'reg',
          ['query', _winRegKey, '/v', _winRegValue],
          runInShell: false,
        );
        final ok = r.exitCode == 0;
        _cachedOsRegistered = ok;
        return ok;
      }
      if (Platform.isMacOS) {
        final ok = _macPlistFile().existsSync();
        _cachedOsRegistered = ok;
        return ok;
      }
      if (Platform.isLinux) {
        final ok = _linuxDesktopFile().existsSync() ||
            linuxSystemdUnitFile(systemWide: false).existsSync() ||
            linuxSystemdUnitFile(systemWide: true).existsSync();
        _cachedOsRegistered = ok;
        return ok;
      }
    } catch (_) {}
    _cachedOsRegistered = false;
    return false;
  }

  /// Non-blocking async probe so desktop UI status polls never stall on `reg.exe`.
  static Future<bool> refreshOsRegisteredAsync() async {
    if (_probingOsRegistered) return _cachedOsRegistered ?? false;
    _probingOsRegistered = true;
    try {
      if (Platform.isWindows) {
        final r = await Process.run(
          'reg',
          ['query', _winRegKey, '/v', _winRegValue],
          runInShell: false,
        ).timeout(const Duration(seconds: 3));
        final ok = r.exitCode == 0;
        _cachedOsRegistered = ok;
        return ok;
      }
      if (Platform.isMacOS) {
        final ok = await _macPlistFile().exists();
        _cachedOsRegistered = ok;
        return ok;
      }
      if (Platform.isLinux) {
        final ok = await _linuxDesktopFile().exists() ||
            await linuxSystemdUnitFile(systemWide: false).exists() ||
            await linuxSystemdUnitFile(systemWide: true).exists();
        _cachedOsRegistered = ok;
        return ok;
      }
    } catch (_) {} finally {
      _probingOsRegistered = false;
    }
    _cachedOsRegistered ??= false;
    return _cachedOsRegistered!;
  }

  /// Effective `launch_at_startup` flag merging config preference with cached OS state.
  /// Never spawns a synchronous child process on the Flutter UI isolate.
  static bool effectiveLaunchAtStartup(Map<String, dynamic> cfg) {
    if (cfg.containsKey('launch_at_startup')) {
      return cfg['launch_at_startup'] == true;
    }
    if (_cachedOsRegistered != null) {
      return _cachedOsRegistered!;
    }
    unawaited(refreshOsRegisteredAsync());
    return false;
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
        _cachedOsRegistered = false;
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
      _cachedOsRegistered = true;
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

  /// Async variant of [syncWithOs] so UI saves and startup never block on `reg.exe`.
  static Future<Map<String, dynamic>> syncWithOsAsync({
    required bool enabled,
    required bool silentStart,
  }) async {
    try {
      if (!enabled) {
        if (Platform.isWindows) {
          await Process.run(
            'reg',
            ['delete', _winRegKey, '/v', _winRegValue, '/f'],
            runInShell: false,
          ).timeout(const Duration(seconds: 4));
        } else if (Platform.isMacOS) {
          final f = _macPlistFile();
          if (await f.exists()) await f.delete();
        } else if (Platform.isLinux) {
          final f = _linuxDesktopFile();
          if (await f.exists()) await f.delete();
        }
        _cachedOsRegistered = false;
        McpLogger.instance.info(
          '[AUTOSTART] Disabled OS login auto-start (${Platform.operatingSystem})',
        );
        return {'ok': true, 'enabled': false};
      }

      final exe = resolveDesktopExecutablePath();
      if (exe == null || exe.isEmpty) {
        return {
          'ok': false,
          'enabled': true,
          'warning': '尚未找到已编译的桌面端可执行文件，配置已保存，打包后生效。',
        };
      }

      if (Platform.isWindows) {
        final cmdValue = silentStart ? '"$exe" --silent' : '"$exe"';
        final r = await Process.run(
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
        ).timeout(const Duration(seconds: 4));
        if (r.exitCode != 0) {
          return {'ok': false, 'error': '${r.stderr}'.trim()};
        }
      } else {
        return syncWithOs(enabled: enabled, silentStart: silentStart);
      }

      _cachedOsRegistered = true;
      McpLogger.instance.info(
        '[AUTOSTART] Registered OS login auto-start (${Platform.operatingSystem}, silent=$silentStart) -> $exe',
      );
      return {'ok': true, 'enabled': true, 'exe': exe, 'silent': silentStart};
    } catch (e) {
      McpLogger.instance.warning('[AUTOSTART] Failed async OS auto-start sync: $e');
      return {'ok': false, 'error': '$e'};
    }
  }

  static Future<void> syncFromConfigMapAsync(Map<String, dynamic> cfg) async {
    final enabled = cfg['launch_at_startup'] == true;
    final silent = cfg['silent_start'] == true;
    await syncWithOsAsync(enabled: enabled, silentStart: silent);
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
