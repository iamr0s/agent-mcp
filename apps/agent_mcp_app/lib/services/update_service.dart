import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

const String kUpdateRepoOwner = 'iamr0s';
const String kUpdateRepoName = 'agent-mcp';
const String kLatestVersionJsonUrl =
    'https://github.com/$kUpdateRepoOwner/$kUpdateRepoName/releases/latest/download/version.json';
const String kLatestGithubApiUrl =
    'https://api.github.com/repos/$kUpdateRepoOwner/$kUpdateRepoName/releases/latest';
const String kReleasesPageUrl =
    'https://github.com/$kUpdateRepoOwner/$kUpdateRepoName/releases';

/// Applies an optional GitHub mirror/accelerator prefix (e.g. `https://gh-proxy.com/`)
/// to GitHub download URLs without mutating non-GitHub URLs.
String applyGithubMirrorPrefix(String rawUrl, String mirrorPrefix) {
  final url = rawUrl.trim();
  final prefix = mirrorPrefix.trim();
  if (url.isEmpty || prefix.isEmpty) return url;
  if (!url.startsWith('https://github.com/') &&
      !url.startsWith('https://objects.githubusercontent.com/')) {
    return url;
  }
  final normalizedPrefix = prefix.endsWith('/') ? prefix : '$prefix/';
  if (url.startsWith(normalizedPrefix)) return url;
  return '$normalizedPrefix$url';
}

/// Compares two SemVer strings (e.g. `v2.4.0+6` vs `2.3.0+5`).
/// Returns `> 0` if [a] is newer than [b], `< 0` if older, `0` if equal.
int compareSemVer(String a, String b) {
  final pa = _parseSemVer(a);
  final pb = _parseSemVer(b);
  if (pa.major != pb.major) return pa.major.compareTo(pb.major);
  if (pa.minor != pb.minor) return pa.minor.compareTo(pb.minor);
  if (pa.patch != pb.patch) return pa.patch.compareTo(pb.patch);
  if (pa.preRelease.isEmpty && pb.preRelease.isNotEmpty) return 1;
  if (pa.preRelease.isNotEmpty && pb.preRelease.isEmpty) return -1;
  if (pa.preRelease != pb.preRelease) {
    return pa.preRelease.compareTo(pb.preRelease);
  }
  if (pa.build > 0 && pb.build > 0 && pa.build != pb.build) {
    return pa.build.compareTo(pb.build);
  }
  return 0;
}

({int major, int minor, int patch, String preRelease, int build}) _parseSemVer(
  String raw,
) {
  var s = raw.trim();
  if (s.startsWith('v') || s.startsWith('V')) {
    s = s.substring(1);
  }
  var build = 0;
  final plusIdx = s.indexOf('+');
  if (plusIdx >= 0) {
    build = int.tryParse(s.substring(plusIdx + 1).trim()) ?? 0;
    s = s.substring(0, plusIdx);
  }
  var preRelease = '';
  final dashIdx = s.indexOf('-');
  if (dashIdx >= 0) {
    preRelease = s.substring(dashIdx + 1).trim();
    s = s.substring(0, dashIdx);
  }
  final parts = s.split('.');
  final major = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 0) : 0;
  final minor = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
  final patch = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
  return (
    major: major,
    minor: minor,
    patch: patch,
    preRelease: preRelease,
    build: build,
  );
}

@immutable
class UpdateAsset {
  final String key;
  final String name;
  final String url;
  final String sha256;
  final int size;

  const UpdateAsset({
    required this.key,
    required this.name,
    required this.url,
    this.sha256 = '',
    this.size = 0,
  });

  factory UpdateAsset.fromJson(String key, Map<dynamic, dynamic> raw) {
    return UpdateAsset(
      key: key,
      name: (raw['name'] ?? '').toString().trim(),
      url: (raw['url'] ?? raw['browser_download_url'] ?? '').toString().trim(),
      sha256: (raw['sha256'] ?? '').toString().trim().toLowerCase(),
      size: int.tryParse('${raw['size'] ?? 0}') ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'name': name,
        'url': url,
        'sha256': sha256,
        'size': size,
      };
}

@immutable
class UpdateInfo {
  final String version;
  final String tag;
  final int build;
  final String publishedAt;
  final String releaseUrl;
  final String notes;
  final Map<String, UpdateAsset> assets;
  final String source; // version_json | github_api

  const UpdateInfo({
    required this.version,
    required this.tag,
    this.build = 0,
    this.publishedAt = '',
    required this.releaseUrl,
    this.notes = '',
    this.assets = const {},
    this.source = 'version_json',
  });

  UpdateAsset? preferredAsset({
    required bool isWindows,
    required bool isAndroid,
    required bool isLinux,
  }) {
    if (isWindows) {
      return assets['windows_sfx'] ?? assets['windows_portable'];
    }
    if (isAndroid) {
      return assets['android_arm64'] ?? assets['android_universal'];
    }
    if (isLinux) {
      return assets['linux_x64_cli'] ?? assets['linux_cli'];
    }
    return null;
  }

  static UpdateInfo? tryParseVersionJson(Map<dynamic, dynamic> raw) {
    final verRaw = (raw['version'] ?? raw['tag'] ?? '').toString().trim();
    if (verRaw.isEmpty) return null;
    final cleanVer = verRaw.startsWith('v') || verRaw.startsWith('V')
        ? verRaw.substring(1)
        : verRaw;
    final tag = (raw['tag'] ?? 'v$cleanVer').toString().trim();
    final releaseUrl = (raw['release_url'] ??
            'https://github.com/$kUpdateRepoOwner/$kUpdateRepoName/releases/tag/$tag')
        .toString()
        .trim();
    final parsedAssets = <String, UpdateAsset>{};
    final rawAssets = raw['assets'];
    if (rawAssets is Map) {
      for (final entry in rawAssets.entries) {
        if (entry.value is Map) {
          final a = UpdateAsset.fromJson(
            entry.key.toString(),
            entry.value as Map,
          );
          if (a.url.isNotEmpty) {
            parsedAssets[a.key] = a;
          }
        }
      }
    }
    return UpdateInfo(
      version: cleanVer,
      tag: tag,
      build: int.tryParse('${raw['build'] ?? 0}') ?? 0,
      publishedAt: (raw['published_at'] ?? '').toString().trim(),
      releaseUrl: releaseUrl,
      notes: (raw['notes'] ?? '').toString().trim(),
      assets: parsedAssets,
      source: 'version_json',
    );
  }

  static UpdateInfo? tryParseGithubApi(Map<dynamic, dynamic> raw) {
    final tag = (raw['tag_name'] ?? '').toString().trim();
    if (tag.isEmpty) return null;
    final cleanVer =
        tag.startsWith('v') || tag.startsWith('V') ? tag.substring(1) : tag;
    final releaseUrl =
        (raw['html_url'] ?? '$kReleasesPageUrl/tag/$tag').toString().trim();
    final parsedAssets = <String, UpdateAsset>{};
    final rawAssets = raw['assets'];
    if (rawAssets is List) {
      for (final item in rawAssets) {
        if (item is! Map) continue;
        final name = (item['name'] ?? '').toString().trim();
        final url = (item['browser_download_url'] ?? '').toString().trim();
        if (name.isEmpty || url.isEmpty) continue;
        final lower = name.toLowerCase();
        String? key;
        if (lower.endsWith('-windows-x64-sfx.exe') ||
            (lower.contains('windows') && lower.endsWith('.exe'))) {
          key = 'windows_sfx';
        } else if (lower.contains('windows') && lower.endsWith('-portable.zip')) {
          key = 'windows_portable';
        } else if (lower.contains('windows') && lower.endsWith('-cli.zip')) {
          key = 'windows_cli';
        } else if (lower.contains('android') &&
            lower.contains('arm64') &&
            lower.endsWith('.apk')) {
          key = 'android_arm64';
        } else if (lower.contains('android') &&
            lower.contains('armeabi') &&
            lower.endsWith('.apk')) {
          key = 'android_armv7';
        } else if (lower.contains('android') &&
            lower.contains('x86_64') &&
            lower.endsWith('.apk')) {
          key = 'android_x86_64';
        } else if (lower.contains('android') && lower.endsWith('.apk')) {
          key = 'android_universal';
        } else if (lower.contains('linux-arm64') && lower.endsWith('.tar.gz')) {
          key = 'linux_arm64_cli';
        } else if (lower.contains('linux') && lower.endsWith('.tar.gz')) {
          key = 'linux_x64_cli';
        } else if (lower.contains('macos') && lower.endsWith('.tar.gz')) {
          key = 'macos_arm64_cli';
        }
        if (key != null) {
          parsedAssets[key] = UpdateAsset(
            key: key,
            name: name,
            url: url,
            size: int.tryParse('${item['size'] ?? 0}') ?? 0,
          );
        }
      }
    }
    return UpdateInfo(
      version: cleanVer,
      tag: tag,
      publishedAt: (raw['published_at'] ?? '').toString().trim(),
      releaseUrl: releaseUrl,
      notes: (raw['body'] ?? '').toString().trim(),
      assets: parsedAssets,
      source: 'github_api',
    );
  }
}

@immutable
class UpdatePreferences {
  final bool autoCheckEnabled;
  final int checkIntervalHours;
  final String skippedVersion;
  final String lastCheckedAtIso;
  final String mirrorPrefix;

  const UpdatePreferences({
    this.autoCheckEnabled = true,
    this.checkIntervalHours = 12,
    this.skippedVersion = '',
    this.lastCheckedAtIso = '',
    this.mirrorPrefix = '',
  });

  DateTime? get lastCheckedAt =>
      lastCheckedAtIso.isEmpty ? null : DateTime.tryParse(lastCheckedAtIso);

  bool isCheckDue([DateTime? now]) {
    if (!autoCheckEnabled) return false;
    final last = lastCheckedAt;
    if (last == null) return true;
    final current = now ?? DateTime.now().toUtc();
    return current.difference(last.toUtc()) >=
        Duration(hours: checkIntervalHours.clamp(1, 720));
  }

  UpdatePreferences copyWith({
    bool? autoCheckEnabled,
    int? checkIntervalHours,
    String? skippedVersion,
    String? lastCheckedAtIso,
    String? mirrorPrefix,
  }) {
    return UpdatePreferences(
      autoCheckEnabled: autoCheckEnabled ?? this.autoCheckEnabled,
      checkIntervalHours: checkIntervalHours ?? this.checkIntervalHours,
      skippedVersion: skippedVersion ?? this.skippedVersion,
      lastCheckedAtIso: lastCheckedAtIso ?? this.lastCheckedAtIso,
      mirrorPrefix: mirrorPrefix ?? this.mirrorPrefix,
    );
  }

  Map<String, dynamic> toJson() => {
        'auto_check_enabled': autoCheckEnabled,
        'check_interval_hours': checkIntervalHours,
        'skipped_version': skippedVersion,
        'last_checked_at': lastCheckedAtIso,
        'mirror_prefix': mirrorPrefix,
      };

  factory UpdatePreferences.fromJson(Map<dynamic, dynamic> raw) {
    final hours = int.tryParse('${raw['check_interval_hours'] ?? 12}') ?? 12;
    return UpdatePreferences(
      autoCheckEnabled: raw['auto_check_enabled'] != false,
      checkIntervalHours: hours.clamp(1, 720),
      skippedVersion: (raw['skipped_version'] ?? '').toString().trim(),
      lastCheckedAtIso: (raw['last_checked_at'] ?? '').toString().trim(),
      mirrorPrefix: (raw['mirror_prefix'] ?? '').toString().trim(),
    );
  }
}

@immutable
class UpdateCheckResult {
  final bool ok;
  final bool hasUpdate;
  final bool skipped;
  final String currentVersion;
  final UpdateInfo? latest;
  final String? error;

  const UpdateCheckResult({
    required this.ok,
    this.hasUpdate = false,
    this.skipped = false,
    required this.currentVersion,
    this.latest,
    this.error,
  });
}

@immutable
class UpdateDownloadResult {
  final bool ok;
  final String? filePath;
  final String? sha256;
  final bool verified;
  final String? error;

  const UpdateDownloadResult({
    required this.ok,
    this.filePath,
    this.sha256,
    this.verified = false,
    this.error,
  });
}

class UpdateService {
  static Future<UpdateCheckResult> checkLatest({
    required String currentVersion,
    String mirrorPrefix = '',
    String skippedVersion = '',
    bool manual = false,
    http.Client? client,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final ownClient = client == null;
    final httpClient = client ?? http.Client();
    try {
      UpdateInfo? latest;
      String? lastError;

      try {
        final primaryUrl =
            applyGithubMirrorPrefix(kLatestVersionJsonUrl, mirrorPrefix);
        final res = await httpClient.get(
          Uri.parse(primaryUrl),
          headers: const {
            'Accept': 'application/json',
            'User-Agent': 'Agent-MCP-Updater',
          },
        ).timeout(timeout);
        if (res.statusCode >= 200 && res.statusCode < 300) {
          final decoded = jsonDecode(utf8.decode(res.bodyBytes));
          if (decoded is Map) {
            latest = UpdateInfo.tryParseVersionJson(decoded);
          }
        } else {
          lastError = 'version.json HTTP ${res.statusCode}';
        }
      } catch (e) {
        lastError = 'version.json: $e';
      }

      if (latest == null) {
        try {
          final res = await httpClient.get(
            Uri.parse(kLatestGithubApiUrl),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Agent-MCP-Updater',
            },
          ).timeout(timeout);
          if (res.statusCode >= 200 && res.statusCode < 300) {
            final decoded = jsonDecode(utf8.decode(res.bodyBytes));
            if (decoded is Map) {
              latest = UpdateInfo.tryParseGithubApi(decoded);
            }
          } else {
            lastError = 'GitHub API HTTP ${res.statusCode}';
          }
        } catch (e) {
          lastError = 'GitHub API: $e';
        }
      }

      if (latest == null) {
        return UpdateCheckResult(
          ok: false,
          currentVersion: currentVersion,
          error: lastError ?? '无法获取最新版本信息',
        );
      }

      final cmp = compareSemVer(latest.version, currentVersion);
      final isNewer = cmp > 0;
      final isSkipped = !manual &&
          isNewer &&
          skippedVersion.isNotEmpty &&
          compareSemVer(latest.version, skippedVersion) == 0;

      return UpdateCheckResult(
        ok: true,
        hasUpdate: isNewer,
        skipped: isSkipped,
        currentVersion: currentVersion,
        latest: latest,
      );
    } finally {
      if (ownClient) {
        httpClient.close();
      }
    }
  }
}
