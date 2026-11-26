import 'package:flutter/widgets.dart';

bool isInstallerLaunchArgs(List<String> args) => false;

Widget buildInstallerWizardApp(List<String> args) => const SizedBox.shrink();

class SixTierInstallDetection {
  final String directory;
  final String sourceCode;
  final String sourceLabel;
  final bool isUpgrade;

  const SixTierInstallDetection({
    required this.directory,
    required this.sourceCode,
    required this.sourceLabel,
    required this.isUpgrade,
  });
}

SixTierInstallDetection resolveSixTierInstallLocation({
  String? explicitDir,
  String? preDetectedDir,
  String? preDetectedSource,
  List<String> Function()? probeRunningExePaths,
  String? Function()? readRegistryInstallDir,
  String? Function()? readAutoStartCommand,
  List<String> Function()? readShortcutTargetPaths,
  bool Function(String dir)? hasInstallSignature,
  String? defaultInstallDir,
}) {
  return SixTierInstallDetection(
    directory: explicitDir ?? preDetectedDir ?? defaultInstallDir ?? '',
    sourceCode: explicitDir != null ? 'explicit' : 'default_dir',
    sourceLabel: explicitDir != null ? '命令行指定目录' : '默认用户目录',
    isUpgrade: false,
  );
}
