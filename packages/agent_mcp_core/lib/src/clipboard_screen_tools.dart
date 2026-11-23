import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'privileged_exec.dart';
import 'tool_types.dart';

/// Magic prefix recognized by `McpServerEngine._executeToolAudited` to emit
/// native MCP `image` content blocks (`{type: 'image', data: ..., mimeType: ...}`).
const String kMcpStructuredImagePrefix = '__MCP_IMAGE_RESULT__:';

Future<String> _readSystemClipboard() async {
  if (Platform.isWindows) {
    final res = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-STA', '-Command', '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; Get-Clipboard -Raw'],
    ).timeout(const Duration(seconds: 8));
    if (res.exitCode != 0) {
      throw StateError('Get-Clipboard failed: ${res.stderr}');
    }
    return res.stdout.toString();
  }
  if (Platform.isMacOS) {
    final res = await Process.run('pbpaste', const [])
        .timeout(const Duration(seconds: 6));
    return res.stdout.toString();
  }
  if (Platform.isAndroid) {
    if (await PrivilegedExecutor.instance.ensureActiveIfRequested()) {
      final r = await PrivilegedExecutor.instance.procStart(
        command: 'cmd clipboard get-primary-clip 2>/dev/null || service call clipboard 2 i32 1 i64 0',
        cwd: '/data/local/tmp',
      );
      if (r['ok'] == true && r['process_id'] != null) {
        final w = await PrivilegedExecutor.instance.procWait(
          processId: r['process_id'].toString(),
          timeoutMs: 4000,
        );
        return ((w['lines'] as List?) ?? const []).join('\n');
      }
    }
    throw StateError('Android clipboard read requires foreground app or Shizuku/Root.');
  }
  for (final cmd in const [
    ['wl-paste', '--no-newline'],
    ['xclip', '-selection', 'clipboard', '-o'],
    ['xsel', '--clipboard', '--output'],
  ]) {
    try {
      final res = await Process.run(cmd.first, cmd.sublist(1))
          .timeout(const Duration(seconds: 5));
      if (res.exitCode == 0) return res.stdout.toString();
    } catch (_) {}
  }
  throw StateError('No clipboard utility available (install wl-clipboard or xclip).');
}

Future<void> _writeSystemClipboard(String text) async {
  if (Platform.isWindows) {
    final proc = await Process.start('clip.exe', const []);
    // UTF-16LE BOM ensures Windows `clip.exe` preserves Chinese / Unicode characters cleanly!
    final units = text.codeUnits;
    final bytes = <int>[0xFF, 0xFE];
    for (final u in units) {
      bytes.add(u & 0xFF);
      bytes.add((u >> 8) & 0xFF);
    }
    proc.stdin.add(bytes);
    await proc.stdin.close();
    await proc.exitCode.timeout(const Duration(seconds: 6));
    return;
  }
  if (Platform.isMacOS) {
    final proc = await Process.start('pbcopy', const []);
    proc.stdin.add(utf8.encode(text));
    await proc.stdin.close();
    await proc.exitCode.timeout(const Duration(seconds: 6));
    return;
  }
  for (final cmd in const [
    ['wl-copy'],
    ['xclip', '-selection', 'clipboard'],
    ['xsel', '--clipboard', '--input'],
  ]) {
    try {
      final proc = await Process.start(cmd.first, cmd.sublist(1));
      proc.stdin.add(utf8.encode(text));
      await proc.stdin.close();
      final rc = await proc.exitCode.timeout(const Duration(seconds: 5));
      if (rc == 0) return;
    } catch (_) {}
  }
  throw StateError('Failed to write to system clipboard on this platform.');
}

Future<File> _captureDesktopOrAndroidPng({int displayIndex = 0}) async {
  final outDir = Directory(p.join(StoragePaths.instance.cacheDir.path, 'screenshots'))
    ..createSync(recursive: true);
  final outFile = File(
    p.join(outDir.path, 'screen_${DateTime.now().millisecondsSinceEpoch}.png'),
  );

  if (Platform.isWindows) {
    final escapedPath = outFile.path.replaceAll("'", "''");
    final psScript = '''
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public class DpiHelper {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@ -ErrorAction SilentlyContinue
try { [DpiHelper]::SetProcessDPIAware() | Out-Null } catch {}
\$screens = [System.Windows.Forms.Screen]::AllScreens
\$idx = [Math]::Max(0, [Math]::Min($displayIndex, \$screens.Length - 1))
\$bounds = \$screens[\$idx].Bounds
\$bmp = New-Object System.Drawing.Bitmap(\$bounds.Width, \$bounds.Height)
\$g = [System.Drawing.Graphics]::FromImage(\$bmp)
\$g.CopyFromScreen(\$bounds.Location, [System.Drawing.Point]::Empty, \$bounds.Size)
\$bmp.Save('$escapedPath', [System.Drawing.Imaging.ImageFormat]::Png)
\$g.Dispose()
\$bmp.Dispose()
Write-Output "\$(\$bounds.Width)x\$(\$bounds.Height)"
''';
    final res = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-STA', '-Command', psScript],
    ).timeout(const Duration(seconds: 15));
    if (res.exitCode != 0 || !outFile.existsSync()) {
      throw StateError('Windows screen capture failed: ${res.stderr}');
    }
    return outFile;
  }

  if (Platform.isMacOS) {
    final res = await Process.run(
      'screencapture',
      ['-x', '-t', 'png', '-D', '${displayIndex + 1}', outFile.path],
    ).timeout(const Duration(seconds: 12));
    if (res.exitCode != 0 || !outFile.existsSync()) {
      throw StateError('macOS screencapture failed (check Screen Recording permission): ${res.stderr}');
    }
    return outFile;
  }

  if (Platform.isAndroid) {
    if (await PrivilegedExecutor.instance.ensureActiveIfRequested()) {
      const tmpRemote = '/data/local/tmp/agent_mcp_cap.png';
      final startRes = await PrivilegedExecutor.instance.procStart(
        command: 'screencap -p $tmpRemote',
        cwd: '/data/local/tmp',
      );
      if (startRes['ok'] == true) {
        await PrivilegedExecutor.instance.procWait(
          processId: startRes['process_id'].toString(),
          timeoutMs: 8000,
        );
        final bytes = await PrivFs.readBytes(tmpRemote);
        outFile.writeAsBytesSync(bytes, flush: true);
        return outFile;
      }
    }
    throw StateError('Android screen capture requires Shizuku or Root mode enabled.');
  }

  final escaped = outFile.path;
  for (final cmd in [
    ['grim', escaped],
    ['gnome-screenshot', '-f', escaped],
    ['scrot', escaped],
    ['import', '-window', 'root', escaped],
  ]) {
    try {
      final res = await Process.run(cmd.first, cmd.sublist(1))
          .timeout(const Duration(seconds: 10));
      if (res.exitCode == 0 && outFile.existsSync()) return outFile;
    } catch (_) {}
  }
  throw StateError('Linux screenshot requires grim, gnome-screenshot, scrot, or ImageMagick import.');
}

void registerClipboardAndScreenTools(
  RegisterToolFn registerTool,
  ServerConfig config,
) {
  registerTool(
    name: 'manage_clipboard',
    description:
        'Read or write UTF-8 text on the host system clipboard across Windows, macOS, Linux, and Android.',
    annotations: safeWriteAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': ['read', 'write'],
          'description': "Use 'read' to inspect clipboard text or 'write' to copy text.",
        },
        'text': {
          'type': 'string',
          'description': "Text to write when action='write'.",
        },
      },
      'required': ['action'],
    },
    handler: (args) async {
      final policy = getEffectivePolicy(config);
      if (!policy.allowClipboardScreen) {
        return "Error: Clipboard & screen tools are disabled for profile '${policy.profileName}'.";
      }
      final action = (args['action'] ?? 'read').toString().trim().toLowerCase();
      if (action == 'read') {
        try {
          final txt = await _readSystemClipboard();
          return txt.isEmpty ? '(clipboard is empty or non-text)' : txt;
        } catch (e) {
          return 'Error: $e';
        }
      }
      if (action == 'write') {
        if (policy.readOnly) {
          return "Error: Read-only mode is enabled for profile '${policy.profileName}'.";
        }
        final text = (args['text'] ?? '').toString();
        try {
          await _writeSystemClipboard(text);
          return 'Copied ${text.length} characters to host clipboard.';
        } catch (e) {
          return 'Error: $e';
        }
      }
      return "Error: Unsupported clipboard action '$action' (expected 'read' or 'write').";
    },
  );

  registerTool(
    name: 'capture_screen',
    description:
        'Capture a live PNG screenshot of the host display (or save to a file) and return it directly as a multimodal MCP image.',
    annotations: readOnlyAnn,
    inputSchema: {
      'type': 'object',
      'properties': {
        'display_index': {
          'type': 'integer',
          'description': 'Zero-based monitor index (default 0 = primary monitor).',
          'default': 0,
        },
        'save_path': {
          'type': 'string',
          'description': 'Optional target file path to also save a copy of the PNG.',
        },
      },
    },
    handler: (args) async {
      final policy = getEffectivePolicy(config);
      if (!policy.allowClipboardScreen) {
        return "Error: Clipboard & screen tools are disabled for profile '${policy.profileName}'.";
      }
      final displayIndex = int.tryParse('${args['display_index'] ?? 0}') ?? 0;
      final savePathRaw = (args['save_path'] ?? '').toString().trim();
      try {
        final pngFile = await _captureDesktopOrAndroidPng(displayIndex: displayIndex);
        final bytes = pngFile.readAsBytesSync();
        String? savedTo;
        if (savePathRaw.isNotEmpty) {
          if (policy.readOnly) {
            return "Error: Read-only mode forbids saving screenshot to '$savePathRaw'.";
          }
          final resolved = normalizePath(savePathRaw, policy.effectiveRoots);
          final err = checkAccess(resolved, config);
          if (err != null) return 'Error: $err';
          final dst = File(resolved);
          dst.parent.createSync(recursive: true);
          dst.writeAsBytesSync(bytes, flush: true);
          savedTo = dst.path;
        }
        final payload = {
          'mimeType': 'image/png',
          'data': base64Encode(bytes),
          'bytes': bytes.length,
          'display_index': displayIndex,
          'temp_path': pngFile.path,
          if (savedTo != null) 'saved_path': savedTo,
        };
        try {
          if (savedTo == null) pngFile.deleteSync();
        } catch (_) {}
        return '$kMcpStructuredImagePrefix${jsonEncode(payload)}';
      } catch (e) {
        return 'Error: $e';
      }
    },
  );
}
