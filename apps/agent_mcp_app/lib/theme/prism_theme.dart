import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'prism_motion.dart';

export 'prism_motion.dart';

/// Unified Modern Geometric UI Sans + Tabular Monospace Typography
const String kFontSerif = 'PrismSans';
const String kFontSans = 'PrismSans';
const String kFontMono = 'JetBrainsMono';

const List<String> kSerifFallback = [
  'NotoSansSC',
  'PingFang SC',
  'HarmonyOS Sans SC',
  'MiSans',
  'Microsoft YaHei UI',
  'Segoe UI',
  'sans-serif',
];

const List<String> kSansFallback = [
  'NotoSansSC',
  'PingFang SC',
  'HarmonyOS Sans SC',
  'MiSans',
  'Microsoft YaHei UI',
  'Segoe UI',
  'sans-serif',
];

const List<String> kMonoFallback = [
  'NotoSansSC',
  'Cascadia Mono',
  'Consolas',
  'SF Mono',
  'Menlo',
  'monospace',
];

/// Continuous-curvature Superellipse shape helper.
RoundedSuperellipseBorder prismSuperellipse(
  double radius, {
  BorderSide side = BorderSide.none,
}) {
  return RoundedSuperellipseBorder(
    borderRadius: BorderRadius.circular(radius),
    side: side,
  );
}

/// Curated 2nd-Dimension Theme Accent Presets (`v3.3.0`).
/// Preset #1 (`indigo`) matches the official Agent MCP Starlight Indigo app icon (`#4F46E5` -> `#312E81`).
enum PrismAccentId {
  indigo,
  jade,
  cobalt,
  terracotta,
  violet,
  obsidian;

  String get key => name;

  static PrismAccentId fromKey(String? raw) {
    final clean = (raw ?? '').trim().toLowerCase();
    for (final v in PrismAccentId.values) {
      if (v.name == clean) return v;
    }
    return PrismAccentId.indigo;
  }
}

class PrismAccentSpec {
  final PrismAccentId id;
  final String label;
  final String badge;
  final Color swatchStart;
  final Color swatchEnd;
  final Color lightPrimary;
  final Color lightHover;
  final Color lightSoftBg;
  final Color lightNavBottom;
  final Color lightNavText;
  final Color darkPrimary;
  final Color darkHover;
  final Color darkSoftBg;
  final Color darkNavTop;
  final Color darkNavBottom;
  final Color darkNavText;

  const PrismAccentSpec({
    required this.id,
    required this.label,
    this.badge = '',
    required this.swatchStart,
    required this.swatchEnd,
    required this.lightPrimary,
    required this.lightHover,
    required this.lightSoftBg,
    required this.lightNavBottom,
    required this.lightNavText,
    required this.darkPrimary,
    required this.darkHover,
    required this.darkSoftBg,
    required this.darkNavTop,
    required this.darkNavBottom,
    required this.darkNavText,
  });

  static const List<PrismAccentSpec> presets = [
    PrismAccentSpec(
      id: PrismAccentId.indigo,
      label: '星芒靛蓝',
      badge: '图标同色',
      swatchStart: Color(0xFF4F46E5),
      swatchEnd: Color(0xFF312E81),
      lightPrimary: Color(0xFF4F46E5),
      lightHover: Color(0xFF4338CA),
      lightSoftBg: Color(0x164F46E5),
      lightNavBottom: Color(0xFFEEF2FF),
      lightNavText: Color(0xFF1E1B4B),
      darkPrimary: Color(0xFF818CF8),
      darkHover: Color(0xFFA5B4FC),
      darkSoftBg: Color(0x246366F1),
      darkNavTop: Color(0xFF202242),
      darkNavBottom: Color(0xFF15172E),
      darkNavText: Color(0xFFEEF2FF),
    ),
    PrismAccentSpec(
      id: PrismAccentId.jade,
      label: '温润青玉',
      swatchStart: Color(0xFF10B981),
      swatchEnd: Color(0xFF047857),
      lightPrimary: Color(0xFF059669),
      lightHover: Color(0xFF047857),
      lightSoftBg: Color(0x1610B981),
      lightNavBottom: Color(0xFFECFDF5),
      lightNavText: Color(0xFF064E3B),
      darkPrimary: Color(0xFF34D399),
      darkHover: Color(0xFF6EE7B7),
      darkSoftBg: Color(0x2234D399),
      darkNavTop: Color(0xFF1C352D),
      darkNavBottom: Color(0xFF12231E),
      darkNavText: Color(0xFFECFDF5),
    ),
    PrismAccentSpec(
      id: PrismAccentId.cobalt,
      label: '深海钴蓝',
      swatchStart: Color(0xFF0EA5E9),
      swatchEnd: Color(0xFF0369A1),
      lightPrimary: Color(0xFF0284C7),
      lightHover: Color(0xFF0369A1),
      lightSoftBg: Color(0x160284C7),
      lightNavBottom: Color(0xFFEFF8FF),
      lightNavText: Color(0xFF0C4A6E),
      darkPrimary: Color(0xFF38BDF8),
      darkHover: Color(0xFF7DD3FC),
      darkSoftBg: Color(0x2238BDF8),
      darkNavTop: Color(0xFF162F42),
      darkNavBottom: Color(0xFF0F202E),
      darkNavText: Color(0xFFF0F9FF),
    ),
    PrismAccentSpec(
      id: PrismAccentId.terracotta,
      label: '陶土暖珀',
      swatchStart: Color(0xFFD97757),
      swatchEnd: Color(0xFF9A3412),
      lightPrimary: Color(0xFFC96442),
      lightHover: Color(0xFFB55332),
      lightSoftBg: Color(0x18C96442),
      lightNavBottom: Color(0xFFFDF2EC),
      lightNavText: Color(0xFF5C2614),
      darkPrimary: Color(0xFFE88B6B),
      darkHover: Color(0xFFF2A68B),
      darkSoftBg: Color(0x24E88B6B),
      darkNavTop: Color(0xFF38221B),
      darkNavBottom: Color(0xFF251612),
      darkNavText: Color(0xFFFFF3EE),
    ),
    PrismAccentSpec(
      id: PrismAccentId.violet,
      label: '极光紫晶',
      swatchStart: Color(0xFF8B5CF6),
      swatchEnd: Color(0xFF5B21B6),
      lightPrimary: Color(0xFF7C3AED),
      lightHover: Color(0xFF6D28D9),
      lightSoftBg: Color(0x167C3AED),
      lightNavBottom: Color(0xFFF5F3FF),
      lightNavText: Color(0xFF3B0764),
      darkPrimary: Color(0xFFC084FC),
      darkHover: Color(0xFFD8B4FE),
      darkSoftBg: Color(0x24A855F7),
      darkNavTop: Color(0xFF2D1D42),
      darkNavBottom: Color(0xFF1D132B),
      darkNavText: Color(0xFFFAF5FF),
    ),
    PrismAccentSpec(
      id: PrismAccentId.obsidian,
      label: '曜石极简',
      swatchStart: Color(0xFF3F3F46),
      swatchEnd: Color(0xFF09090B),
      lightPrimary: Color(0xFF18181B),
      lightHover: Color(0xFF27272A),
      lightSoftBg: Color(0x1218181B),
      lightNavBottom: Color(0xFFF3F3F6),
      lightNavText: Color(0xFF09090B),
      darkPrimary: Color(0xFFF4F4F6),
      darkHover: Color(0xFFFFFFFF),
      darkSoftBg: Color(0x1EF4F4F6),
      darkNavTop: Color(0xFF25252E),
      darkNavBottom: Color(0xFF18181F),
      darkNavText: Color(0xFFFFFFFF),
    ),
  ];

  static PrismAccentSpec of(PrismAccentId id) {
    for (final spec in presets) {
      if (spec.id == id) return spec;
    }
    return presets.first;
  }
}

/// Linear / OrbStack High-Density Architectural Design Tokens.
class PrismPalette {
  final bool isDark;

  /// Primary workspace island canvas
  final Color paper;

  /// Elevated group / modal / popover surface
  final Color paper2;

  Color get popover => paper2;

  /// Hover & secondary interactive surface
  final Color paper3;

  /// Outer architectural frame (sidebar & titlebar rail)
  final Color sidebar;

  /// Subtle recessed input / inline badge well
  final Color recessed;

  /// Primary high-contrast ink
  final Color ink;

  /// Emphasized body ink
  final Color inkSoft;

  /// Secondary label & subtitle text
  final Color muted;

  /// Tertiary metadata & timestamps
  final Color meta;

  /// Crisp 1px structural hairline ("felt, not seen")
  final Color hairline;

  /// Interactive ring border on hover
  final Color ringHover;

  /// High-contrast gallery focal accent (Deep Onyx in light / Pure Alabaster in dark)
  final Color clay;
  final Color clayHover;

  /// Foreground ink guaranteed legible on solid [clay] surfaces.
  Color get onClay =>
      ThemeData.estimateBrightnessForColor(clay) == Brightness.light
          ? const Color(0xFF0A0A0C)
          : Colors.white;

  /// Input & keyboard focus ring
  final Color focusRing;

  final Color sage;
  final Color sageBg;
  final Color danger;
  final Color dangerBg;
  final Color purple;
  final Color purpleBg;
  final Color termBg;
  final Color termFg;

  const PrismPalette({
    required this.isDark,
    required this.paper,
    required this.paper2,
    required this.paper3,
    required this.sidebar,
    required this.recessed,
    required this.ink,
    required this.inkSoft,
    required this.muted,
    required this.meta,
    required this.hairline,
    required this.ringHover,
    required this.clay,
    required this.clayHover,
    required this.focusRing,
    required this.sage,
    required this.sageBg,
    required this.danger,
    required this.dangerBg,
    required this.purple,
    required this.purpleBg,
    required this.termBg,
    required this.termFg,
  });

  static const light = PrismPalette(
    isDark: false,
    paper: Color(0xFFFAFAFB), // Pure gallery alabaster canvas
    paper2: Color(0xFFFFFFFF), // Pure gallery white elevated surface
    paper3: Color(0xFFF1F1F4), // Neutral tactile hover fill
    sidebar: Color(0xFFF3F3F6), // Architectural neutral outer rail
    recessed: Color(0xFFF4F4F6), // Sculpted inset icon & input well
    ink: Color(0xFF111113), // Deep gallery onyx ink
    inkSoft: Color(0xFF27272A),
    muted: Color(0xFF71717A),
    meta: Color(0xFFA1A1AA),
    hairline: Color(0xFFE6E6EA), // Crisp 1px architectural hairline
    ringHover: Color(0x734F46E5),
    clay: Color(0xFF4F46E5), // Default Starlight Indigo (matches App Icon)
    clayHover: Color(0xFF4338CA),
    focusRing: Color(0xFF4F46E5),
    sage: Color(0xFF059669),
    sageBg: Color(0x1610B981),
    danger: Color(0xFFDC2626),
    dangerBg: Color(0x14EF4444),
    purple: Color(0xFF4F46E5),
    purpleBg: Color(0x164F46E5),
    termBg: Color(0xFFF8F8FA),
    termFg: Color(0xFF111113),
  );

  static const dark = PrismPalette(
    isDark: true,
    paper: Color(0xFF0A0A0C), // Deep gallery obsidian canvas
    paper2: Color(0xFF121216), // Elevated onyx card & group surface
    paper3: Color(0xFF1B1B21), // Tactile neutral hover fill
    sidebar: Color(0xFF060608), // Deep space architectural rail
    recessed: Color(0xFF0E0E12), // Sculpted inset code & icon well
    ink: Color(0xFFFAFAFA),
    inkSoft: Color(0xFFD4D4D8),
    muted: Color(0xFF8E8E98),
    meta: Color(0xFF63636E),
    hairline: Color(0xFF222228), // Crisp 1px dark architectural hairline
    ringHover: Color(0x7A818CF8),
    clay: Color(0xFF818CF8), // Luminous Starlight Indigo (matches App Icon)
    clayHover: Color(0xFFA5B4FC),
    focusRing: Color(0xFF818CF8),
    sage: Color(0xFF34D399),
    sageBg: Color(0x2034D399),
    danger: Color(0xFFF87171),
    dangerBg: Color(0x20F87171),
    purple: Color(0xFFA5B4FC),
    purpleBg: Color(0x246366F1),
    termBg: Color(0xFF0D0D11),
    termFg: Color(0xFFECECEF),
  );

  static PrismAccentId _accentId = PrismAccentId.indigo;
  static bool _dynamicEnabled = false;
  static Color? _dynamicLightAccent;
  static Color? _dynamicDarkAccent;

  static PrismAccentId get activeAccentId => _accentId;
  static PrismAccentSpec get activeAccentSpec =>
      PrismAccentSpec.of(_accentId);
  static bool get isDynamicColorEnabled => _dynamicEnabled;

  static void configureAccent(PrismAccentId accent) {
    _accentId = accent;
  }

  static void configureDynamicColor({
    required bool enabled,
    Color? lightAccent,
    Color? darkAccent,
  }) {
    _dynamicEnabled = enabled;
    if (lightAccent != null) _dynamicLightAccent = lightAccent;
    if (darkAccent != null) _dynamicDarkAccent = darkAccent;
  }

  static PrismPalette forSpec(PrismAccentSpec spec, {required bool isDark}) {
    if (isDark) {
      return PrismPalette(
        isDark: true,
        paper: dark.paper,
        paper2: dark.paper2,
        paper3: dark.paper3,
        sidebar: dark.sidebar,
        recessed: dark.recessed,
        ink: dark.ink,
        inkSoft: dark.inkSoft,
        muted: dark.muted,
        meta: dark.meta,
        hairline: dark.hairline,
        ringHover: spec.darkPrimary.withValues(alpha: 0.48),
        clay: spec.darkPrimary,
        clayHover: spec.darkHover,
        focusRing: spec.darkPrimary,
        sage: dark.sage,
        sageBg: dark.sageBg,
        danger: dark.danger,
        dangerBg: dark.dangerBg,
        purple: spec.darkPrimary,
        purpleBg: spec.darkSoftBg,
        termBg: dark.termBg,
        termFg: dark.termFg,
      );
    }
    return PrismPalette(
      isDark: false,
      paper: light.paper,
      paper2: light.paper2,
      paper3: light.paper3,
      sidebar: light.sidebar,
      recessed: light.recessed,
      ink: light.ink,
      inkSoft: light.inkSoft,
      muted: light.muted,
      meta: light.meta,
      hairline: light.hairline,
      ringHover: spec.lightPrimary.withValues(alpha: 0.44),
      clay: spec.lightPrimary,
      clayHover: spec.lightHover,
      focusRing: spec.lightPrimary,
      sage: light.sage,
      sageBg: light.sageBg,
      danger: light.danger,
      dangerBg: light.dangerBg,
      purple: spec.lightPrimary,
      purpleBg: spec.lightSoftBg,
      termBg: light.termBg,
      termFg: light.termFg,
    );
  }

  static PrismPalette get activeLight {
    if (_dynamicEnabled && _dynamicLightAccent != null) {
      final a = _dynamicLightAccent!;
      final hover = Color.lerp(a, Colors.black, 0.14)!;
      return PrismPalette(
        isDark: false,
        paper: light.paper,
        paper2: light.paper2,
        paper3: light.paper3,
        sidebar: light.sidebar,
        recessed: light.recessed,
        ink: light.ink,
        inkSoft: light.inkSoft,
        muted: light.muted,
        meta: light.meta,
        hairline: light.hairline,
        ringHover: a.withValues(alpha: 0.45),
        clay: a,
        clayHover: hover,
        focusRing: a,
        sage: light.sage,
        sageBg: light.sageBg,
        danger: light.danger,
        dangerBg: light.dangerBg,
        purple: a,
        purpleBg: a.withValues(alpha: 0.12),
        termBg: light.termBg,
        termFg: light.termFg,
      );
    }
    return forSpec(activeAccentSpec, isDark: false);
  }

  static PrismPalette get activeDark {
    if (_dynamicEnabled && _dynamicDarkAccent != null) {
      final a = _dynamicDarkAccent!;
      final hover = Color.lerp(a, Colors.white, 0.14)!;
      return PrismPalette(
        isDark: true,
        paper: dark.paper,
        paper2: dark.paper2,
        paper3: dark.paper3,
        sidebar: dark.sidebar,
        recessed: dark.recessed,
        ink: dark.ink,
        inkSoft: dark.inkSoft,
        muted: dark.muted,
        meta: dark.meta,
        hairline: dark.hairline,
        ringHover: a.withValues(alpha: 0.48),
        clay: a,
        clayHover: hover,
        focusRing: a,
        sage: dark.sage,
        sageBg: dark.sageBg,
        danger: dark.danger,
        dangerBg: dark.dangerBg,
        purple: a,
        purpleBg: a.withValues(alpha: 0.18),
        termBg: dark.termBg,
        termFg: dark.termFg,
      );
    }
    return forSpec(activeAccentSpec, isDark: true);
  }

  /// Active navigation & optical lens accent tokens (syncs with selected Theme Accent).
  Color get navTint => clay;

  Color get navCapsuleTop {
    if (_dynamicEnabled) {
      return isDark
          ? Color.lerp(const Color(0xFF181920), clay, 0.22)!
          : const Color(0xFFFFFFFF);
    }
    final spec = activeAccentSpec;
    return isDark ? spec.darkNavTop : const Color(0xFFFFFFFF);
  }

  Color get navCapsuleBottom {
    if (_dynamicEnabled) {
      return isDark
          ? Color.lerp(const Color(0xFF101116), clay, 0.14)!
          : Color.lerp(const Color(0xFFFFFFFF), clay, 0.08)!;
    }
    final spec = activeAccentSpec;
    return isDark ? spec.darkNavBottom : spec.lightNavBottom;
  }

  Color get navActiveIcon => clay;

  Color get navActiveText {
    if (_dynamicEnabled) return ink;
    final spec = activeAccentSpec;
    return isDark ? spec.darkNavText : spec.lightNavText;
  }

  int get accentRgb24 =>
      ((clay.r * 255.0).round().clamp(0, 255) << 16) |
      ((clay.g * 255.0).round().clamp(0, 255) << 8) |
      (clay.b * 255.0).round().clamp(0, 255);

  static PrismPalette of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark
        ? activeDark
        : activeLight;
  }

  /// Translucent frosted glass tint for mobile/web floating bars & popovers.
  Color get glassBarTint => isDark
      ? const Color(0xE0121216)
      : const Color(0xECFFFFFF);

  /// Solid architectural outer rail tint.
  Color get micaSidebarTint => sidebar;

  /// Elevated workspace island surface.
  Color get micaCanvasTint => paper;

  /// Theme-adaptive code & inspector surfaces (Gallery Monochrome contrast).
  Color get codeSheet => termBg;
  Color get codeHeader =>
      isDark ? const Color(0xFF15151B) : const Color(0xFFF2F2F5);
  Color get codeGutter =>
      isDark ? const Color(0xFF0B0B0F) : const Color(0xFFF4F4F7);
  Color get codeBorder => hairline;
  Color get diffDelBg =>
      isDark ? const Color(0x2EF85149) : const Color(0xFFFFEBE9);
  Color get diffDelFg =>
      isDark ? const Color(0xFFFFA198) : const Color(0xFFA40E26);
  Color get diffAddBg =>
      isDark ? const Color(0x2E2EA043) : const Color(0xFFE6FFEC);
  Color get diffAddFg =>
      isDark ? const Color(0xFF7EE787) : const Color(0xFF116329);
  Color get diffHunkFg =>
      isDark ? const Color(0xFFA5B4FC) : const Color(0xFF3F3F46);

  /// Specular 1px highlight on floating popovers.
  Color get glassSpecular => isDark
      ? const Color(0x1EFFFFFF)
      : const Color(0xADFFFFFF);

  /// Whisper-subtle neutral gallery elevation shadow.
  List<BoxShadow> get whisperShadow => isDark
      ? const [
          BoxShadow(
            color: Color(0x58000000),
            offset: Offset(0, 4),
            blurRadius: 14,
            spreadRadius: -3,
          ),
          BoxShadow(
            color: Color(0x30000000),
            offset: Offset(0, 1),
            blurRadius: 3,
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x0A000000),
            offset: Offset(0, 4),
            blurRadius: 14,
            spreadRadius: -3,
          ),
          BoxShadow(
            color: Color(0x06000000),
            offset: Offset(0, 1),
            blurRadius: 2.5,
          ),
        ];

  /// Subtle elevated hover shadow for interactive tiles.
  List<BoxShadow> get cardHoverShadow => isDark
      ? const [
          BoxShadow(
            color: Color(0x58000000),
            offset: Offset(0, 6),
            blurRadius: 18,
            spreadRadius: -3,
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x0E000000),
            offset: Offset(0, 5),
            blurRadius: 16,
            spreadRadius: -2,
          ),
        ];

  /// Crisp popover / dropdown menu shadow (Vercel Geist / Raycast elevation).
  List<BoxShadow> get popoverShadow => isDark
      ? const [
          BoxShadow(
            color: Color(0x80000000),
            offset: Offset(0, 10),
            blurRadius: 28,
            spreadRadius: -2,
          ),
          BoxShadow(
            color: Color(0x40000000),
            offset: Offset(0, 2),
            blurRadius: 6,
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x18000000),
            offset: Offset(0, 12),
            blurRadius: 28,
            spreadRadius: -4,
          ),
          BoxShadow(
            color: Color(0x0A000000),
            offset: Offset(0, 2),
            blurRadius: 6,
          ),
        ];
}

/// Modern Geometric Display Sans headline style (replaces legacy literary serif
/// across the entire console for crisp Linear / OrbStack developer aesthetic).
TextStyle serifTitleStyle(
  PrismPalette c, {
  double size = 20,
  FontWeight weight = FontWeight.w600,
  Color? color,
  double height = 1.24,
  bool tabular = true,
}) {
  final effectiveWeight =
      weight.value < FontWeight.w600.value ? FontWeight.w600 : weight;
  return TextStyle(
    fontFamily: kFontSans,
    fontFamilyFallback: kSansFallback,
    fontSize: size,
    fontWeight: effectiveWeight,
    color: color ?? c.ink,
    height: height,
    letterSpacing: size >= 22 ? -0.52 : (size >= 18 ? -0.35 : -0.2),
    fontFeatures: tabular ? const [ui.FontFeature.tabularFigures()] : null,
  );
}

TextStyle sansStyle(
  PrismPalette c, {
  double size = 13.0,
  FontWeight weight = FontWeight.w400,
  Color? color,
  double height = 1.46,
  double? letterSpacing,
  bool tabular = false,
}) {
  return TextStyle(
    fontFamily: kFontSans,
    fontFamilyFallback: kSansFallback,
    fontSize: size,
    fontWeight: weight,
    color: color ?? c.ink,
    height: height,
    letterSpacing: letterSpacing,
    fontFeatures: tabular ? const [ui.FontFeature.tabularFigures()] : null,
  );
}

TextStyle monoStyle(
  PrismPalette c, {
  double size = 12.0,
  Color? color,
  FontWeight weight = FontWeight.w400,
  double height = 1.45,
}) {
  return TextStyle(
    fontFamily: kFontMono,
    fontFamilyFallback: kMonoFallback,
    fontSize: size,
    fontWeight: weight,
    color: color ?? c.inkSoft,
    height: height,
    letterSpacing: -0.15,
    fontFeatures: const [ui.FontFeature.tabularFigures()],
  );
}

ThemeData buildPrismTheme(
  PrismPalette c, {
  bool transparentScaffold = false,
}) {
  final scheme = ColorScheme(
    brightness: c.isDark ? Brightness.dark : Brightness.light,
    primary: c.clay,
    onPrimary: c.onClay,
    secondary: c.sage,
    onSecondary: Colors.white,
    error: c.danger,
    onError: Colors.white,
    surface: c.paper,
    onSurface: c.ink,
  );

  final baseText = TextStyle(
    fontFamily: kFontSans,
    fontFamilyFallback: kSansFallback,
    color: c.ink,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: scheme.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: transparentScaffold ? Colors.transparent : c.paper,
    canvasColor: transparentScaffold ? Colors.transparent : c.paper,
    fontFamily: kFontSans,
    fontFamilyFallback: kSansFallback,
    textTheme: TextTheme(
      displayLarge: serifTitleStyle(c, size: 30),
      headlineMedium: serifTitleStyle(c, size: 22),
      titleLarge: serifTitleStyle(c, size: 17.5),
      titleMedium: baseText.copyWith(fontSize: 14.5, fontWeight: FontWeight.w600),
      bodyLarge: baseText.copyWith(fontSize: 14, height: 1.52),
      bodyMedium: baseText.copyWith(fontSize: 13, height: 1.48),
      bodySmall: baseText.copyWith(fontSize: 12, color: c.muted, height: 1.42),
      labelLarge: baseText.copyWith(fontSize: 12.8, fontWeight: FontWeight.w500),
      labelSmall: baseText.copyWith(
        fontSize: 11.2,
        color: c.muted,
        letterSpacing: 0.1,
      ),
    ),
    dividerColor: c.hairline,
    dividerTheme: DividerThemeData(color: c.hairline, thickness: 1, space: 1),
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    dialogTheme: DialogThemeData(
      backgroundColor: c.paper2,
      elevation: 0,
      shape: prismSuperellipse(
        28,
        side: BorderSide(color: c.hairline.withValues(alpha: 0.72)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.paper2,
      elevation: 8,
      surfaceTintColor: Colors.transparent,
      shape: prismSuperellipse(
        20,
        side: BorderSide(color: c.hairline.withValues(alpha: 0.75)),
      ),
      textStyle: sansStyle(c, size: 12.5, weight: FontWeight.w500),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 340),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5.5),
      decoration: ShapeDecoration(
        color: c.isDark ? const Color(0xF51E2433) : const Color(0xF50F172A),
        shape: StadiumBorder(
          side: BorderSide(
            color: c.isDark ? const Color(0xFF333D54) : const Color(0xFF1E293B),
          ),
        ),
      ),
      textStyle: const TextStyle(
        fontFamily: kFontSans,
        fontFamilyFallback: kSansFallback,
        fontSize: 11.8,
        fontWeight: FontWeight.w500,
        color: Color(0xFFF8FAFC),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.recessed,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10.5),
      hintStyle: TextStyle(
        fontFamily: kFontSans,
        fontFamilyFallback: kSansFallback,
        color: c.meta,
        fontSize: 12.6,
      ),
      // Concentric 14px soft recessed well across all states — zero edge jitter!
      border: WidgetStateInputBorder.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: c.focusRing, width: 1.4),
          );
        }
        if (states.contains(WidgetState.hovered)) {
          return OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: c.ringHover),
          );
        }
        return OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: c.hairline.withValues(alpha: 0.62)),
        );
      }),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.dragged)) {
          return c.muted.withValues(alpha: 0.55);
        }
        return c.muted.withValues(alpha: 0.25);
      }),
      radius: const Radius.circular(99),
      thickness: WidgetStateProperty.all(5),
    ),
  );
}

/// Continuous-superellipse 1px directional Specular Rim Painter (Linear ProKit / Liquid Glass).
/// Simulates a physical top key-light catching the upper bevel while fading gracefully downward.
class PrismSpecularRimPainter extends CustomPainter {
  final double radius;
  final bool isDark;
  final Color? accentTint;
  final double intensity;

  const PrismSpecularRimPainter({
    required this.radius,
    required this.isDark,
    this.accentTint,
    this.intensity = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;

    if (isDark) {
      final topColor = accentTint != null
          ? Color.lerp(
              const Color(0x36FFFFFF),
              accentTint!.withValues(alpha: 0.42),
              0.42,
            )!
          : Color.fromRGBO(255, 255, 255, (0.18 * intensity).clamp(0.0, 1.0));
      final midColor =
          Color.fromRGBO(255, 255, 255, (0.07 * intensity).clamp(0.0, 1.0));
      final botColor =
          Color.fromRGBO(255, 255, 255, (0.03 * intensity).clamp(0.0, 1.0));

      final path = prismSuperellipse(radius).getOuterPath(rect.deflate(0.5));
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          rect.bottomCenter,
          [topColor, midColor, botColor],
          const [0.0, 0.42, 1.0],
        );
      canvas.drawPath(path, paint);
    } else {
      // Crisp outer structural contour + inner 1px pure-white top specular catchlight
      final outerColor = accentTint != null
          ? Color.lerp(
              const Color(0x160F172A),
              accentTint!.withValues(alpha: 0.28),
              0.5,
            )!
          : const Color(0x140F172A);
      final outerPath =
          prismSuperellipse(radius).getOuterPath(rect.deflate(0.5));
      canvas.drawPath(
        outerPath,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..color = outerColor,
      );

      final innerRadius = (radius - 1.0).clamp(1.0, radius);
      final innerRect = rect.deflate(1.2);
      if (innerRect.width > 2 && innerRect.height > 2) {
        final innerPath = prismSuperellipse(innerRadius).getOuterPath(innerRect);
        final specPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0
          ..shader = ui.Gradient.linear(
            innerRect.topCenter,
            innerRect.bottomCenter,
            [
              Color.fromRGBO(255, 255, 255, (0.95 * intensity).clamp(0.0, 1.0)),
              Color.fromRGBO(255, 255, 255, (0.35 * intensity).clamp(0.0, 1.0)),
              const Color(0x00FFFFFF),
            ],
            const [0.0, 0.38, 1.0],
          );
        canvas.drawPath(innerPath, specPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant PrismSpecularRimPainter oldDelegate) {
    return oldDelegate.radius != radius ||
        oldDelegate.isDark != isDark ||
        oldDelegate.accentTint != accentTint ||
        oldDelegate.intensity != intensity;
  }
}

/// Frosted Glass Chrome Surface — reserved for mobile/web floating bars & popovers.
class PrismGlassBar extends StatelessWidget {
  final Widget child;
  final double blurSigma;
  final Color? tintColor;
  final Border? border;
  final double? borderRadius;
  final EdgeInsetsGeometry? padding;
  final List<BoxShadow>? boxShadow;

  const PrismGlassBar({
    super.key,
    required this.child,
    this.blurSigma = 18.0,
    this.tintColor,
    this.border,
    this.borderRadius,
    this.padding,
    this.boxShadow,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final effectiveTint = tintColor ?? c.glassBarTint;
    final effectiveSigma = kIsWeb ? math.min(blurSigma, 8.0) : blurSigma;

    if (borderRadius != null && borderRadius! > 0) {
      return DecoratedBox(
        decoration: ShapeDecoration(
          shape: prismSuperellipse(borderRadius!),
          shadows: boxShadow,
        ),
        child: ClipRSuperellipse(
          borderRadius: BorderRadius.circular(borderRadius!),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: effectiveSigma,
              sigmaY: effectiveSigma,
            ),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: effectiveTint,
                shape: prismSuperellipse(
                  borderRadius!,
                  side: BorderSide(color: c.hairline),
                ),
              ),
              child: padding != null
                  ? Padding(padding: padding!, child: child)
                  : child,
            ),
          ),
        ),
      );
    }

    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: effectiveSigma,
          sigmaY: effectiveSigma,
        ),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: effectiveTint,
            border: border,
            boxShadow: boxShadow,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Editorial Gravity Page Header (Tracked Monospace Eyebrow + Tight Display Title).
class PrismEditorialPageHeader extends StatelessWidget {
  final String eyebrow;
  final String title;
  final Widget? titleBadge;
  final String? subtitle;
  final Widget? leadingDot;
  final Widget? trailing;

  const PrismEditorialPageHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    this.titleBadge,
    this.subtitle,
    this.leadingDot,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return LayoutBuilder(
      builder: (ctx, box) {
        final narrow = box.maxWidth < 540;
        final titleSize = box.maxWidth < 430 ? 22.0 : 24.0;
        final headerLeft = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (leadingDot != null) ...[
                  leadingDot!,
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    eyebrow.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: kFontMono,
                      fontFamilyFallback: kMonoFallback,
                      fontSize: 10.6,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.35,
                      color: c.meta,
                      height: 1.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 9,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: serifTitleStyle(
                    c,
                    size: titleSize,
                    weight: FontWeight.w700,
                    height: 1.18,
                  ),
                ),
                if (titleBadge != null) titleBadge!,
              ],
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 5),
              Text(
                subtitle!,
                maxLines: narrow ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: sansStyle(c, size: 12.6, color: c.muted, height: 1.4),
              ),
            ],
          ],
        );

        if (trailing == null) return headerLeft;

        if (narrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              headerLeft,
              const SizedBox(height: 12),
              trailing!,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: headerLeft),
            const SizedBox(width: 16),
            trailing!,
          ],
        );
      },
    );
  }
}

/// Linear / OrbStack De-Boxed Hairline Group Container.
/// Replaces heavy nested cards with a crisp 12px-radius container and 1px
/// inset row dividers ("structure felt, not seen").
class PrismListGroup extends StatelessWidget {
  final String? title;
  final String? headerLabel;
  final String? subtitle;
  final Widget? headerTrailing;
  final List<Widget> children;
  final double radius;
  final double dividerIndent;
  final EdgeInsetsGeometry? margin;

  const PrismListGroup({
    super.key,
    this.title,
    this.headerLabel,
    this.subtitle,
    this.headerTrailing,
    required this.children,
    this.radius = 22,
    this.dividerIndent = 18,
    this.margin,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final effTitle = title ?? headerLabel;
    final hasHeader =
        (effTitle != null && effTitle.isNotEmpty) || headerTrailing != null;

    Widget box = CustomPaint(
      foregroundPainter: PrismSpecularRimPainter(
        radius: radius,
        isDark: c.isDark,
        intensity: c.isDark ? 0.72 : 0.90,
      ),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: c.paper2,
          shape: prismSuperellipse(
            radius,
            side: BorderSide(
              color: c.isDark
                  ? c.hairline.withValues(alpha: 0.52)
                  : c.hairline.withValues(alpha: 0.62),
            ),
          ),
          shadows: c.whisperShadow,
        ),
        child: ClipRSuperellipse(
          borderRadius: BorderRadius.circular(radius),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: EdgeInsets.only(left: dividerIndent, right: 16),
                    child: Divider(
                      height: 1,
                      thickness: 0.75,
                      color: c.hairline.withValues(alpha: 0.65),
                    ),
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ),
    );

    if (hasHeader) {
      box = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (effTitle != null && effTitle.isNotEmpty)
                        Text(
                          effTitle,
                          style: sansStyle(
                            c,
                            size: 13.5,
                            weight: FontWeight.w600,
                            color: c.ink,
                          ),
                        ),
                      if (subtitle != null && subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: sansStyle(c, size: 11.8, color: c.muted),
                        ),
                      ],
                    ],
                  ),
                ),
                if (headerTrailing != null) ...[
                  const SizedBox(width: 10),
                  headerTrailing!,
                ],
              ],
            ),
          ),
          box,
        ],
      );
    }

    if (margin != null) {
      return Padding(padding: margin!, child: box);
    }
    return box;
  }
}

/// Standardized macOS / Clash Verge Rev Settings Row inside a [PrismListGroup].
class PrismSettingsRow extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget? bottomChild;
  final VoidCallback? onTap;
  final double stackBreakpoint;
  final bool allowTrailingWrap;

  const PrismSettingsRow({
    super.key,
    this.icon,
    this.iconColor,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.bottomChild,
    this.onTap,
    this.stackBreakpoint = 430,
    this.allowTrailingWrap = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return LayoutBuilder(
      builder: (ctx, box) {
        final stack = allowTrailingWrap &&
            box.maxWidth < stackBreakpoint &&
            trailing != null &&
            trailing is! PrismSwitch &&
            trailing is! Icon;
        final compactRow = box.maxWidth < 400;
        final labelBlock = Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: 12),
            ] else if (icon != null) ...[
              Container(
                width: compactRow ? 36 : 38,
                height: compactRow ? 36 : 38,
                decoration: ShapeDecoration(
                  color: iconColor != null
                      ? iconColor!.withValues(alpha: c.isDark ? 0.16 : 0.10)
                      : c.recessed,
                  shape: prismSuperellipse(
                    13.0,
                    side: BorderSide(
                      color: iconColor != null
                          ? iconColor!.withValues(alpha: 0.22)
                          : c.hairline.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(
                  icon,
                  size: compactRow ? 16.5 : 17.5,
                  color: iconColor ?? c.inkSoft,
                ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: sansStyle(
                      c,
                      size: 13.6,
                      weight: FontWeight.w500,
                      color: c.ink,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty) ...[
                    const SizedBox(height: 2.5),
                    Text(
                      subtitle!,
                      maxLines: box.maxWidth < 460 ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: sansStyle(
                        c,
                        size: 11.8,
                        color: c.muted,
                        height: 1.38,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );

        Widget content = Padding(
          padding: EdgeInsets.symmetric(
            horizontal: compactRow ? 16 : 19,
            vertical: 14.5,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (stack) ...[
                labelBlock,
                if (trailing != null) ...[
                  const SizedBox(height: 9),
                  trailing!,
                ],
              ] else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: labelBlock),
                    if (trailing != null) ...[
                      const SizedBox(width: 12),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: box.maxWidth.isFinite
                              ? (box.maxWidth * 0.56).clamp(84.0, box.maxWidth)
                              : double.infinity,
                        ),
                        child: Align(
                          alignment: Alignment.centerRight,
                          widthFactor: 1.0,
                          child: trailing!,
                        ),
                      ),
                    ],
                  ],
                ),
              if (bottomChild != null) ...[
                const SizedBox(height: 10),
                bottomChild!,
              ],
            ],
          ),
        );

        if (onTap != null) {
          content = Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: onTap,
              hoverColor: c.paper3.withValues(alpha: 0.55),
              child: content,
            ),
          );
        }
        return content;
      },
    );
  }
}

/// Responsive 2-Column / Stacked Form Row shared across modal forms.
class PrismFormRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final Widget child;
  final double labelWidth;
  final double stackBreakpoint;
  final CrossAxisAlignment horizontalAlignment;

  const PrismFormRow({
    super.key,
    required this.label,
    this.subtitle,
    required this.child,
    this.labelWidth = 148,
    this.stackBreakpoint = 460,
    this.horizontalAlignment = CrossAxisAlignment.start,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final compact = constraints.maxWidth < stackBreakpoint;
        final labelBlock = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: sansStyle(
                c,
                size: 13,
                weight: FontWeight.w500,
                color: c.ink,
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                subtitle!,
                style: sansStyle(c, size: 11.6, color: c.muted, height: 1.4),
              ),
            ],
          ],
        );

        if (compact) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                labelBlock,
                const SizedBox(height: 6),
                child,
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 13),
          child: Row(
            crossAxisAlignment: horizontalAlignment,
            children: [
              SizedBox(
                width: labelWidth,
                child: Padding(
                  padding: EdgeInsets.only(
                    top: horizontalAlignment == CrossAxisAlignment.start ? 7 : 0,
                    right: 12,
                  ),
                  child: labelBlock,
                ),
              ),
              Expanded(child: child),
            ],
          ),
        );
      },
    );
  }
}

/// Unified Agent MCP Brand Icon (matches Windows taskbar/tray, macOS dock & Android launcher).
class PrismSparkIcon extends StatelessWidget {
  final double size;
  final Color? color;

  const PrismSparkIcon({super.key, this.size = 18, this.color});

  @override
  Widget build(BuildContext context) {
    if (color != null) {
      return CustomPaint(
        size: Size.square(size),
        painter: _SparkPainter(color!),
      );
    }
    final fallbackColor = PrismPalette.of(context).clay;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: Image.asset(
        'assets/app_icon.png',
        width: size,
        height: size,
        fit: BoxFit.cover,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) => CustomPaint(
          size: Size.square(size),
          painter: _SparkPainter(fallbackColor),
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final Color color;
  const _SparkPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final outer = size.width * 0.46;
    final inner = size.width * 0.12;

    final path = Path()
      ..moveTo(cx, cy - outer)
      ..quadraticBezierTo(cx + inner * 0.6, cy - inner * 0.6, cx + outer, cy)
      ..quadraticBezierTo(cx + inner * 0.6, cy + inner * 0.6, cx, cy + outer)
      ..quadraticBezierTo(cx - inner * 0.6, cy + inner * 0.6, cx - outer, cy)
      ..quadraticBezierTo(cx - inner * 0.6, cy - inner * 0.6, cx, cy - outer)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparkPainter oldDelegate) =>
      oldDelegate.color != color;
}

enum PrismBtnVariant { neutral, clay, ink, danger, ghost }

class PrismButton extends StatefulWidget {
  final String label;
  final Widget? leading;
  final VoidCallback? onPressed;
  final PrismBtnVariant variant;
  final bool compact;
  final bool expand;
  final bool loading;
  final String? tooltip;

  const PrismButton({
    super.key,
    required this.label,
    this.leading,
    this.onPressed,
    this.variant = PrismBtnVariant.neutral,
    this.compact = false,
    this.expand = false,
    this.loading = false,
    this.tooltip,
  });

  @override
  State<PrismButton> createState() => _PrismButtonState();
}

class _PrismButtonState extends State<PrismButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final disabled = widget.onPressed == null || widget.loading;

    Color bg;
    Color fg;
    Color border;
    switch (widget.variant) {
      case PrismBtnVariant.clay:
        bg = _hovered && !disabled ? c.clayHover : c.clay;
        fg = c.onClay;
        border = bg;
      case PrismBtnVariant.ink:
        bg = _hovered && !disabled
            ? (c.isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B))
            : c.ink;
        fg = c.paper2;
        border = bg;
      case PrismBtnVariant.danger:
        bg = _hovered && !disabled ? c.danger.withValues(alpha: 0.88) : c.danger;
        fg = Colors.white;
        border = bg;
      case PrismBtnVariant.ghost:
        bg = _hovered && !disabled
            ? c.paper3.withValues(alpha: 0.85)
            : c.paper3.withValues(alpha: 0.0);
        fg = _hovered && !disabled ? c.ink : c.muted;
        border = _hovered && !disabled
            ? c.hairline
            : c.hairline.withValues(alpha: 0.0);
      case PrismBtnVariant.neutral:
        bg = _hovered && !disabled ? c.paper3 : c.paper2;
        fg = _hovered && !disabled ? c.ink : c.inkSoft;
        border = _hovered && !disabled ? c.ringHover : c.hairline;
    }

    final iconOnly = widget.label.isEmpty && (widget.leading != null || widget.loading);
    final iconSize = widget.compact ? 14.5 : 15.8;
    final effFg = (disabled && !widget.loading) ? fg.withValues(alpha: 0.45) : fg;
    final effBg = (disabled && !widget.loading) ? bg.withValues(alpha: 0.45) : bg;
    final effBorder =
        (disabled && !widget.loading) ? border.withValues(alpha: 0.4) : border;

    final Widget? leadingSlot = (widget.leading != null || widget.loading)
        ? AnimatedSwitcher(
            duration: PrismMotion.duration(
              context,
              const Duration(milliseconds: 160),
            ),
            switchInCurve: PrismMotion.editorialOut,
            switchOutCurve: Curves.easeOut,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.84, end: 1.0).animate(anim),
                child: child,
              ),
            ),
            child: widget.loading
                ? SizedBox(
                    key: const ValueKey('btn-spinner'),
                    width: iconSize,
                    height: iconSize,
                    child: Padding(
                      padding: const EdgeInsets.all(1.0),
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        valueColor: AlwaysStoppedAnimation<Color>(effFg),
                      ),
                    ),
                  )
                : KeyedSubtree(
                    key: const ValueKey('btn-icon'),
                    child: IconTheme(
                      data: IconThemeData(size: iconSize, color: effFg),
                      child: widget.leading!,
                    ),
                  ),
          )
        : null;

    Widget content = AnimatedScale(
      scale: (_pressed && !disabled) ? 0.97 : 1.0,
      duration: PrismMotion.duration(
        context,
        _pressed
            ? const Duration(milliseconds: 75)
            : const Duration(milliseconds: 180),
      ),
      curve: _pressed ? PrismMotion.standard : PrismMotion.snappySpring,
      child: CustomPaint(
        foregroundPainter: widget.variant == PrismBtnVariant.ghost
            ? null
            : PrismSpecularRimPainter(
                radius: 999,
                isDark: c.isDark,
                intensity: widget.variant == PrismBtnVariant.neutral ? 0.65 : 0.42,
              ),
        child: AnimatedContainer(
          duration: PrismMotion.duration(context, PrismMotion.fast),
          curve: PrismMotion.editorialOut,
          height: widget.compact ? 31 : 37,
          width: iconOnly ? (widget.compact ? 31 : 37) : null,
          padding: iconOnly
              ? EdgeInsets.zero
              : EdgeInsets.symmetric(horizontal: widget.compact ? 11.5 : 16),
          decoration: ShapeDecoration(
            color: effBg,
            shape: StadiumBorder(
              side: BorderSide(color: effBorder),
            ),
          ),
          child: Row(
            mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (leadingSlot != null) ...[
                leadingSlot,
                if (widget.label.isNotEmpty) const SizedBox(width: 6),
              ],
              if (widget.label.isNotEmpty)
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: kFontSans,
                      fontFamilyFallback: kSansFallback,
                      fontSize: widget.compact ? 12.2 : 13.0,
                      fontWeight: FontWeight.w500,
                      color: effFg,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    content = MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) {
        if (!disabled) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered || _pressed) {
          setState(() {
            _hovered = false;
            _pressed = false;
          });
        }
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: disabled ? null : (_) => setState(() => _pressed = true),
        onTapUp: disabled ? null : (_) => setState(() => _pressed = false),
        onTapCancel: disabled ? null : () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: content,
      ),
    );

    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      content = Tooltip(message: widget.tooltip!, child: content);
    }
    return content;
  }
}

/// Crisp Surface Container Card with clean 12px default superellipse radius & 1px hairline.
class PrismCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool hoverable;
  final double radius;

  const PrismCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 17),
    this.onTap,
    this.hoverable = false,
    this.radius = 22,
  });

  @override
  State<PrismCard> createState() => _PrismCardState();
}

class _PrismCardState extends State<PrismCard> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final interactive = widget.onTap != null || widget.hoverable;

    Widget card = CustomPaint(
      foregroundPainter: PrismSpecularRimPainter(
        radius: widget.radius,
        isDark: c.isDark,
        intensity: c.isDark ? 0.65 : 0.85,
      ),
      child: AnimatedContainer(
        duration: PrismMotion.duration(context, PrismMotion.fast),
        curve: PrismMotion.editorialOut,
        width: double.infinity,
        padding: widget.padding,
        decoration: ShapeDecoration(
          color: (_hovered && interactive)
              ? Color.lerp(c.paper2, c.paper3, 0.45)
              : c.paper2,
          shape: prismSuperellipse(
            widget.radius,
            side: BorderSide(
              color: (_hovered && interactive)
                  ? c.ringHover
                  : c.hairline.withValues(alpha: c.isDark ? 0.55 : 0.62),
            ),
          ),
          shadows:
              (_hovered && interactive) ? c.cardHoverShadow : c.whisperShadow,
        ),
        child: widget.child,
      ),
    );

    if (widget.onTap != null) {
      card = AnimatedScale(
        scale: _pressed ? 0.992 : 1.0,
        duration: PrismMotion.duration(context, PrismMotion.fast),
        curve: PrismMotion.snappySpring,
        child: card,
      );
    }

    if (!interactive) return card;

    return MouseRegion(
      cursor:
          widget.onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown:
            widget.onTap == null ? null : (_) => setState(() => _pressed = true),
        onTapUp: widget.onTap == null
            ? null
            : (_) => setState(() => _pressed = false),
        onTapCancel: widget.onTap == null
            ? null
            : () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: card,
      ),
    );
  }
}

/// Spring Sliding-Pill Segmented Control (Apple HIG / Fluent 2 equal-width & intrinsic modes, zero half-char clipping).
class PrismSegmented<T> extends StatefulWidget {
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;
  final bool expand;

  const PrismSegmented({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
    this.expand = false,
  });

  @override
  State<PrismSegmented<T>> createState() => _PrismSegmentedState<T>();
}

class _PrismSegmentedState<T> extends State<PrismSegmented<T>> {
  final GlobalKey _rowKey = GlobalKey();
  late List<GlobalKey> _itemKeys =
      List.generate(widget.items.length, (_) => GlobalKey());

  double? _pillLeft;
  double? _pillWidth;
  bool _animatePill = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _measure(animate: false));
  }

  @override
  void didUpdateWidget(covariant PrismSegmented<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items.length != _itemKeys.length) {
      _itemKeys = List.generate(widget.items.length, (_) => GlobalKey());
    }
    if (oldWidget.value != widget.value && !_animatePill) {
      _animatePill = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measure(animate: oldWidget.value != widget.value);
    });
  }

  void _measure({required bool animate}) {
    if (!mounted) return;
    final idx = widget.items.indexWhere((e) => e.$1 == widget.value);
    if (idx < 0 || idx >= _itemKeys.length) return;
    final rowBox = _rowKey.currentContext?.findRenderObject() as RenderBox?;
    final itemBox =
        _itemKeys[idx].currentContext?.findRenderObject() as RenderBox?;
    if (rowBox == null ||
        itemBox == null ||
        !rowBox.hasSize ||
        !itemBox.hasSize) {
      return;
    }
    final offset = itemBox.localToGlobal(Offset.zero, ancestor: rowBox);
    final nextLeft = offset.dx;
    final nextWidth = itemBox.size.width;
    if (_pillLeft != nextLeft || _pillWidth != nextWidth) {
      setState(() {
        _animatePill = animate && _pillLeft != null;
        _pillLeft = nextLeft;
        _pillWidth = nextWidth;
      });
    }
  }

  Widget _buildSlidingPill(PrismPalette c, Duration pillDur,
      {required double left, required double width}) {
    return AnimatedPositioned(
      duration: pillDur,
      curve: PrismMotion.snappySpring,
      left: left,
      top: 0,
      bottom: 0,
      width: width,
      child: CustomPaint(
        foregroundPainter: PrismSpecularRimPainter(
          radius: 999,
          isDark: c.isDark,
          accentTint: c.navTint,
          intensity: 0.90,
        ),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [c.navCapsuleTop, c.navCapsuleBottom],
            ),
            shape: const StadiumBorder(),
            shadows: [
              BoxShadow(
                color: Colors.black.withValues(alpha: c.isDark ? 0.34 : 0.06),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final pillDur = _animatePill
        ? PrismMotion.duration(context, const Duration(milliseconds: 220))
        : Duration.zero;
    final activeIdx =
        widget.items.indexWhere((e) => e.$1 == widget.value).clamp(
              0,
              widget.items.isEmpty ? 0 : widget.items.length - 1,
            );

    return LayoutBuilder(
      builder: (ctx, box) {
        final totalChars =
            widget.items.fold<int>(0, (acc, e) => acc + e.$2.length);
        final estimatedIntrinsic =
            totalChars * 12.6 + widget.items.length * 20.0 + 8.0;
        final forceEqualWidth = widget.expand ||
            (box.hasBoundedWidth &&
                box.maxWidth.isFinite &&
                estimatedIntrinsic > box.maxWidth);

        if (forceEqualWidth && box.hasBoundedWidth && box.maxWidth.isFinite) {
          final innerW = (box.maxWidth - 6.0).clamp(40.0, box.maxWidth);
          final count = widget.items.isEmpty ? 1 : widget.items.length;
          final slotW = innerW / count;
          final eqPillLeft = activeIdx * slotW;
          final eqDur = PrismMotion.duration(
            context,
            const Duration(milliseconds: 220),
          );

          return DecoratedBox(
            decoration: ShapeDecoration(
              color: c.isDark ? c.recessed : c.paper3.withValues(alpha: 0.85),
              shape: StadiumBorder(
                side: BorderSide(color: c.hairline.withValues(alpha: 0.65)),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(3.0),
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  _buildSlidingPill(
                    c,
                    eqDur,
                    left: eqPillLeft,
                    width: slotW,
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < widget.items.length; i++)
                        Expanded(
                          child: _SegmentTapItem(
                            label: widget.items[i].$2,
                            active: widget.items[i].$1 == widget.value,
                            fallbackHighlight: false,
                            compactPad: slotW < 76,
                            palette: c,
                            onTap: () {
                              _animatePill = true;
                              widget.onChanged(widget.items[i].$1);
                            },
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }

        return DecoratedBox(
          decoration: ShapeDecoration(
            color: c.isDark ? c.recessed : c.paper3.withValues(alpha: 0.85),
            shape: StadiumBorder(
              side: BorderSide(color: c.hairline.withValues(alpha: 0.65)),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(3.0),
            child: IntrinsicWidth(
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  if (_pillLeft != null && _pillWidth != null)
                    _buildSlidingPill(
                      c,
                      pillDur,
                      left: _pillLeft!,
                      width: _pillWidth!,
                    ),
                  Row(
                    key: _rowKey,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < widget.items.length; i++)
                        _SegmentTapItem(
                          key: _itemKeys[i],
                          label: widget.items[i].$2,
                          active: widget.items[i].$1 == widget.value,
                          fallbackHighlight: _pillWidth == null &&
                              widget.items[i].$1 == widget.value,
                          palette: c,
                          onTap: () => widget.onChanged(widget.items[i].$1),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SegmentTapItem extends StatefulWidget {
  final String label;
  final bool active;
  final bool fallbackHighlight;
  final bool compactPad;
  final PrismPalette palette;
  final VoidCallback onTap;

  const _SegmentTapItem({
    super.key,
    required this.label,
    required this.active,
    required this.fallbackHighlight,
    this.compactPad = false,
    required this.palette,
    required this.onTap,
  });

  @override
  State<_SegmentTapItem> createState() => _SegmentTapItemState();
}

class _SegmentTapItemState extends State<_SegmentTapItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Container(
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(
            horizontal: widget.compactPad ? 6 : 12,
            vertical: 6,
          ),
          decoration: widget.fallbackHighlight
              ? ShapeDecoration(
                  color: c.isDark ? c.paper3 : c.paper2,
                  shape: const StadiumBorder(),
                )
              : null,
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: kFontSans,
              fontFamilyFallback: kSansFallback,
              fontSize: widget.compactPad ? 11.5 : 12.0,
              fontWeight: widget.active ? FontWeight.w600 : FontWeight.w500,
              color: widget.active
                  ? c.ink
                  : (_hovered ? c.inkSoft : c.muted),
            ),
          ),
        ),
      ),
    );
  }
}

class PrismPill extends StatelessWidget {
  final String text;
  final Widget? leading;
  final Color? fg;
  final Color? bg;
  final Color? border;
  final bool mono;

  const PrismPill({
    super.key,
    required this.text,
    this.leading,
    this.fg,
    this.bg,
    this.border,
    this.mono = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final effFg = fg ?? c.inkSoft;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: bg ?? c.recessed,
        shape: StadiumBorder(
          side: BorderSide(color: border ?? c.hairline.withValues(alpha: 0.70)),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[
              IconTheme(
                data: IconThemeData(size: 11.5, color: effFg),
                child: leading!,
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono
                    ? monoStyle(
                        c,
                        size: 10.8,
                        color: effFg,
                        weight: FontWeight.w500,
                      )
                    : TextStyle(
                        fontFamily: kFontSans,
                        fontFamilyFallback: kSansFallback,
                        fontSize: 11.2,
                        fontWeight: FontWeight.w500,
                        color: effFg,
                        fontFeatures: const [ui.FontFeature.tabularFigures()],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Elastic Thumb-Stretch Toggle Switch.
class PrismSwitch extends StatefulWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const PrismSwitch({super.key, required this.value, this.onChanged});

  @override
  State<PrismSwitch> createState() => _PrismSwitchState();
}

class _PrismSwitchState extends State<PrismSwitch>
    with TickerProviderStateMixin {
  late final AnimationController _posCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 230),
    value: widget.value ? 1.0 : 0.0,
  );
  late final AnimationController _pressCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
  );
  bool _hovered = false;

  @override
  void didUpdateWidget(covariant PrismSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      final d = PrismMotion.duration(
        context,
        const Duration(milliseconds: 230),
      );
      _posCtrl.duration = d;
      if (d == Duration.zero) {
        _posCtrl.value = widget.value ? 1.0 : 0.0;
      } else if (widget.value) {
        unawaited(_posCtrl.forward());
      } else {
        unawaited(_posCtrl.reverse());
      }
    }
  }

  @override
  void dispose() {
    _posCtrl.dispose();
    _pressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final disabled = widget.onChanged == null;

    return RepaintBoundary(
      child: MouseRegion(
        cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) {
          setState(() => _hovered = false);
          unawaited(_pressCtrl.reverse());
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: disabled ? null : (_) => _pressCtrl.forward(),
          onTapUp: disabled
              ? null
              : (_) {
                  unawaited(_pressCtrl.reverse());
                  widget.onChanged!(!widget.value);
                },
          onTapCancel: disabled ? null : () => _pressCtrl.reverse(),
          child: AnimatedBuilder(
            animation: Listenable.merge([_posCtrl, _pressCtrl]),
            builder: (ctx, _) {
              final springPos = PrismMotion.snappySpring
                  .transform(_posCtrl.value)
                  .clamp(-0.06, 1.06);
              final linearPos = _posCtrl.value.clamp(0.0, 1.0);
              final pressT =
                  PrismMotion.editorialOut.transform(_pressCtrl.value);

              const trackW = 38.0;
              const trackH = 22.0;
              const pad = 2.0;
              final thumbW = 16.5 + 3.5 * pressT;
              const thumbH = 16.5;
              final maxTravel = trackW - pad * 2 - thumbW;
              final thumbLeft =
                  pad + (maxTravel * springPos).clamp(-1.0, maxTravel + 1.0);

              final trackColor = Color.lerp(
                _hovered ? c.ringHover.withValues(alpha: 0.55) : c.paper3,
                c.clay,
                linearPos,
              )!;
              final borderColor = Color.lerp(
                _hovered ? c.ringHover : c.hairline,
                c.clay,
                linearPos,
              )!;

              return Opacity(
                opacity: disabled ? 0.45 : 1.0,
                child: Container(
                  width: trackW,
                  height: trackH,
                  decoration: ShapeDecoration(
                    color: trackColor,
                    shape: StadiumBorder(side: BorderSide(color: borderColor)),
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: thumbLeft,
                        top: (trackH - thumbH) / 2 - 1,
                        width: thumbW,
                        height: thumbH,
                        child: DecoratedBox(
                          decoration: ShapeDecoration(
                            color: Color.lerp(Colors.white, c.onClay, linearPos)!,
                            shape: const StadiumBorder(),
                            shadows: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 2.5,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Tactile Superellipse Checkbox Row with spring bounce.
class PrismCheckToggle extends StatefulWidget {
  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  const PrismCheckToggle({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  @override
  State<PrismCheckToggle> createState() => _PrismCheckToggleState();
}

class _PrismCheckToggleState extends State<PrismCheckToggle> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onChanged(!widget.value);
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: _pressed ? 0.88 : 1.0,
                duration: PrismMotion.duration(context, PrismMotion.fast),
                curve: PrismMotion.snappySpring,
                child: AnimatedContainer(
                  duration: PrismMotion.duration(context, PrismMotion.fast),
                  curve: PrismMotion.editorialOut,
                  width: 17,
                  height: 17,
                  decoration: ShapeDecoration(
                    color: widget.value ? c.clay : c.recessed,
                    shape: prismSuperellipse(
                      5.5,
                      side: BorderSide(
                        color: widget.value
                            ? c.clay
                            : (_hovered ? c.muted : c.ringHover),
                        width: 1.3,
                      ),
                    ),
                  ),
                  child: AnimatedSwitcher(
                    duration: PrismMotion.duration(context, PrismMotion.fast),
                    switchInCurve: PrismMotion.snappySpring,
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: child,
                    ),
                    child: widget.value
                        ? Icon(
                            Icons.check_rounded,
                            key: const ValueKey('checked'),
                            size: 12.5,
                            color: c.onClay,
                          )
                        : const SizedBox.shrink(key: ValueKey('unchecked')),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.label,
                  style: sansStyle(
                    c,
                    size: 12.8,
                    color: _hovered ? c.ink : c.inkSoft,
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

class PrismPasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;

  const PrismPasswordField({
    super.key,
    required this.controller,
    this.hintText = '',
    this.onSubmitted,
    this.onChanged,
  });

  @override
  State<PrismPasswordField> createState() => _PrismPasswordFieldState();
}

class _PrismPasswordFieldState extends State<PrismPasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return TextField(
      controller: widget.controller,
      obscureText: _obscure,
      onSubmitted: widget.onSubmitted,
      onChanged: widget.onChanged,
      style: monoStyle(c, size: 12.6, color: c.ink),
      decoration: InputDecoration(
        hintText: widget.hintText,
        suffixIconConstraints:
            const BoxConstraints(minWidth: 36, minHeight: 30),
        suffixIcon: IconButton(
          iconSize: 15.5,
          tooltip: _obscure ? '显示密钥' : '隐藏密钥',
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: PrismFadeBox(
            alignment: Alignment.center,
            child: Icon(
              _obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              key: ValueKey(_obscure),
              color: c.muted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a modal dialog with cool obsidian scrim blur + critically-damped spring physics.
Future<T?> showPrismDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: const Color(0x59080B12),
    transitionDuration: PrismMotion.duration(context, PrismMotion.modal),
    pageBuilder: (ctx, _, __) => SafeArea(child: Builder(builder: builder)),
    transitionBuilder: (ctx, anim, _, child) {
      final isReversing = anim.status == AnimationStatus.reverse;
      final curved = isReversing
          ? Curves.easeInCubic.transform(anim.value)
          : PrismMotion.snappySpring.transform(anim.value);
      final opacity = Curves.easeOut.transform(anim.value).clamp(0.0, 1.0);
      final scale = 0.96 + 0.04 * curved;
      final dy = (1.0 - curved) * 6.0;
      final blurSigma = (opacity * 4.0).clamp(0.0, 4.0);

      return BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: FadeTransition(
          opacity: AlwaysStoppedAnimation(opacity),
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Transform.scale(
              scale: scale,
              child: child,
            ),
          ),
        ),
      );
    },
  );
}

Future<bool> showPrismConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = '确定',
  String cancelText = '取消',
  bool destructive = false,
}) async {
  final res = await showPrismDialog<bool>(
    context: context,
    builder: (ctx) {
      final c = PrismPalette.of(ctx);
      final compact = MediaQuery.sizeOf(ctx).width < 520;
      return Dialog(
        backgroundColor: c.paper2,
        elevation: 0,
        insetPadding: EdgeInsets.symmetric(
          horizontal: compact ? 16 : 32,
          vertical: 20,
        ),
        shape: prismSuperellipse(
          28,
          side: BorderSide(color: c.hairline.withValues(alpha: 0.72)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 20 : 24,
              22,
              compact ? 20 : 24,
              20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: ShapeDecoration(
                        color: destructive
                            ? c.dangerBg
                            : c.clay.withValues(alpha: 0.12),
                        shape: prismSuperellipse(13),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        destructive
                            ? Icons.warning_amber_rounded
                            : Icons.info_outline_rounded,
                        size: 16,
                        color: destructive ? c.danger : c.clay,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(title, style: serifTitleStyle(c, size: 16.5)),
                    ),
                  ],
                ),
                const SizedBox(height: 11),
                Text(
                  message,
                  style: sansStyle(c, size: 13.0, height: 1.56, color: c.muted),
                ),
                const SizedBox(height: 18),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PrismButton(
                      label: cancelText,
                      compact: true,
                      onPressed: () => Navigator.of(ctx).pop(false),
                    ),
                    PrismButton(
                      label: confirmText,
                      compact: true,
                      variant: destructive
                          ? PrismBtnVariant.danger
                          : PrismBtnVariant.clay,
                      onPressed: () => Navigator.of(ctx).pop(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
  return res ?? false;
}

/// Pixel-aligned 10x10 Windows 11 Caption Glyphs.
enum PrismCaptionGlyph { minimize, maximize, restore, close }

class PrismCaptionIcon extends StatelessWidget {
  final PrismCaptionGlyph glyph;
  final Color color;

  const PrismCaptionIcon({
    super.key,
    required this.glyph,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(10.0),
      painter: _PrismCaptionGlyphPainter(glyph: glyph, color: color),
    );
  }
}

class _PrismCaptionGlyphPainter extends CustomPainter {
  final PrismCaptionGlyph glyph;
  final Color color;

  const _PrismCaptionGlyphPainter({
    required this.glyph,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.05
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;
    const corner = Radius.circular(1.2);
    final box = (Offset.zero & size).deflate(0.5);

    switch (glyph) {
      case PrismCaptionGlyph.minimize:
        final y = (size.height / 2).floorToDouble() + 0.5;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);

      case PrismCaptionGlyph.maximize:
        canvas.drawRRect(RRect.fromRectAndRadius(box, corner), paint);

      case PrismCaptionGlyph.restore:
        const offset = 2.0;
        final front = Rect.fromLTRB(
          box.left,
          box.top + offset,
          box.right - offset,
          box.bottom,
        );
        final back = front.shift(const Offset(offset, -offset));
        canvas.drawRRect(RRect.fromRectAndRadius(front, corner), paint);
        canvas.save();
        canvas.clipRect(front.inflate(0.55), clipOp: ui.ClipOp.difference);
        canvas.drawRRect(RRect.fromRectAndRadius(back, corner), paint);
        canvas.restore();

      case PrismCaptionGlyph.close:
        paint.strokeCap = StrokeCap.round;
        canvas.drawLine(box.topLeft, box.bottomRight, paint);
        canvas.drawLine(box.topRight, box.bottomLeft, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PrismCaptionGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}

/// Windows 11 frameless caption controls: Hide-to-Tray + Pin + Minimize + Maximize/Restore + Close-to-Tray.
class PrismWindowCaptionActions extends StatelessWidget {
  final bool isMaximized;
  final bool isPinned;
  final VoidCallback onTogglePin;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onCloseToTray;
  final VoidCallback? onHideToTray;

  const PrismWindowCaptionActions({
    super.key,
    required this.isMaximized,
    required this.isPinned,
    required this.onTogglePin,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onCloseToTray,
    this.onHideToTray,
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Tooltip(
            message: '收起到系统托盘（后台运行）',
            child: _TrayQuickButton(
              palette: c,
              onTap: onHideToTray ?? onCloseToTray,
            ),
          ),
        ),
        const SizedBox(width: 2),
        Center(
          child: Tooltip(
            message: isPinned ? '取消窗口置顶' : '窗口置顶',
            child: _PinButton(
              isPinned: isPinned,
              palette: c,
              onTap: onTogglePin,
            ),
          ),
        ),
        const SizedBox(width: 2),
        _WinCaptionBtn(
          tooltip: '最小化',
          glyph: PrismCaptionGlyph.minimize,
          palette: c,
          onTap: onMinimize,
        ),
        _WinCaptionBtn(
          tooltip: isMaximized ? '向下还原' : '最大化',
          glyph: isMaximized
              ? PrismCaptionGlyph.restore
              : PrismCaptionGlyph.maximize,
          palette: c,
          onTap: onToggleMaximize,
        ),
        _WinCaptionBtn(
          tooltip: '隐藏到系统托盘（MCP 服务继续运行）',
          glyph: PrismCaptionGlyph.close,
          isClose: true,
          palette: c,
          onTap: onCloseToTray,
        ),
      ],
    );
  }
}

class _TrayQuickButton extends StatefulWidget {
  final PrismPalette palette;
  final VoidCallback onTap;

  const _TrayQuickButton({
    required this.palette,
    required this.onTap,
  });

  @override
  State<_TrayQuickButton> createState() => _TrayQuickButtonState();
}

class _TrayQuickButtonState extends State<_TrayQuickButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.90 : 1.0,
          duration: PrismMotion.duration(context, PrismMotion.fast),
          curve: PrismMotion.snappySpring,
          child: AnimatedContainer(
            key: const ValueKey('caption-hide-to-tray-btn'),
            duration: PrismMotion.duration(context, PrismMotion.fast),
            width: 28,
            height: 26,
            decoration: ShapeDecoration(
              color: _hovered
                  ? (c.isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.05))
                  : Colors.transparent,
              shape: const StadiumBorder(),
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.system_update_alt_rounded,
              size: 13.5,
              color: _hovered ? c.clay : c.muted,
            ),
          ),
        ),
      ),
    );
  }
}

class _PinButton extends StatefulWidget {
  final bool isPinned;
  final PrismPalette palette;
  final VoidCallback onTap;

  const _PinButton({
    required this.isPinned,
    required this.palette,
    required this.onTap,
  });

  @override
  State<_PinButton> createState() => _PinButtonState();
}

class _PinButtonState extends State<_PinButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.palette;
    final active = widget.isPinned;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onTap();
        },
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.90 : 1.0,
          duration: PrismMotion.duration(context, PrismMotion.fast),
          curve: PrismMotion.snappySpring,
          child: AnimatedContainer(
            duration: PrismMotion.duration(context, PrismMotion.fast),
            width: 28,
            height: 28,
            decoration: ShapeDecoration(
              shape: prismSuperellipse(7.5),
              color: active
                  ? c.clay.withValues(alpha: 0.14)
                  : (_hovered ? c.paper3 : c.paper3.withValues(alpha: 0.0)),
            ),
            alignment: Alignment.center,
            child: AnimatedRotation(
              turns: active ? 0.0 : 0.125,
              duration: PrismMotion.duration(context, PrismMotion.base),
              curve: PrismMotion.snappySpring,
              child: Icon(
                active ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 14,
                color: active ? c.clay : (_hovered ? c.ink : c.muted),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WinCaptionBtn extends StatefulWidget {
  final String tooltip;
  final PrismCaptionGlyph glyph;
  final bool isClose;
  final PrismPalette palette;
  final VoidCallback onTap;

  const _WinCaptionBtn({
    required this.tooltip,
    required this.glyph,
    this.isClose = false,
    required this.palette,
    required this.onTap,
  });

  @override
  State<_WinCaptionBtn> createState() => _WinCaptionBtnState();
}

class _WinCaptionBtnState extends State<_WinCaptionBtn> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.palette;

    Color bg = widget.isClose
        ? c.danger.withValues(alpha: 0.0)
        : c.ink.withValues(alpha: 0.0);
    Color fg = c.inkSoft;
    if (widget.isClose) {
      if (_pressed) {
        bg = c.danger.withValues(alpha: 0.85);
        fg = Colors.white;
      } else if (_hovered) {
        bg = c.danger;
        fg = Colors.white;
      }
    } else {
      if (_pressed) {
        bg = c.ink.withValues(alpha: 0.10);
        fg = c.ink;
      } else if (_hovered) {
        bg = c.ink.withValues(alpha: 0.06);
        fg = c.ink;
      }
    }

    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() {
          _hovered = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) {
            setState(() => _pressed = false);
            widget.onTap();
          },
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: PrismMotion.duration(
              context,
              const Duration(milliseconds: 110),
            ),
            width: 42,
            color: bg,
            alignment: Alignment.center,
            child: PrismFadeBox(
              alignment: Alignment.center,
              duration: const Duration(milliseconds: 120),
              child: PrismCaptionIcon(
                key: ValueKey(widget.glyph),
                glyph: widget.glyph,
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// Unified Popover, DropMenu v2, ActionMenu & SplitButton System
// (shadcn/ui + Raycast + Linear 4-edge auto-flip & keyboard navigation)
// ============================================================================

class PrismDropMenuItem<T> {
  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;
  final String? badge;
  final String? shortcut;
  final bool destructive;
  final bool dividerBefore;
  final String? groupLabel;

  const PrismDropMenuItem({
    required this.value,
    required this.label,
    this.subtitle,
    this.icon,
    this.badge,
    this.shortcut,
    this.destructive = false,
    this.dividerBefore = false,
    this.groupLabel,
  });
}

/// High-craft Linear / shadcn Select & DropMenu with 4-edge viewport auto-flip,
/// keyboard navigation (Esc / Up / Down / Enter), optional inline search,
/// section dividers, and pure Cool Porcelain / Deep Obsidian surface.
class PrismDropMenu<T> extends StatefulWidget {
  final T value;
  final List<PrismDropMenuItem<T>> items;
  final ValueChanged<T> onChanged;
  final IconData? leadingIcon;
  final String? prefixLabel;
  final bool highlightActive;
  final double minMenuWidth;
  final double maxMenuWidth;
  final String? tooltip;
  final bool? searchable;
  final bool expandTrigger;

  const PrismDropMenu({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.leadingIcon,
    this.prefixLabel,
    this.highlightActive = false,
    this.minMenuWidth = 184,
    this.maxMenuWidth = 300,
    this.tooltip,
    this.searchable,
    this.expandTrigger = false,
  });

  @override
  State<PrismDropMenu<T>> createState() => _PrismDropMenuState<T>();
}

class _PrismDropMenuState<T> extends State<PrismDropMenu<T>>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _portalCtrl = OverlayPortalController();
  final FocusNode _menuFocus = FocusNode(debugLabel: 'PrismDropMenuFocus');
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  late final AnimationController _animCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 175),
    reverseDuration: const Duration(milliseconds: 120),
  );

  bool _open = false;
  bool _hovered = false;
  bool _pressed = false;
  bool _alignRight = false;
  bool _flipUp = false;
  double _availMaxHeight = 320;
  int _kbIndex = -1;

  @override
  void dispose() {
    _animCtrl.dispose();
    _menuFocus.dispose();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  List<PrismDropMenuItem<T>> get _filteredItems {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return widget.items;
    return widget.items.where((it) {
      return it.label.toLowerCase().contains(q) ||
          (it.subtitle?.toLowerCase().contains(q) ?? false) ||
          (it.badge?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  void _toggleMenu() {
    if (_open) {
      _closeMenu();
    } else {
      _openMenu();
    }
  }

  void _openMenu() {
    if (_open || widget.items.isEmpty) return;
    _searchCtrl.clear();
    final renderObj = context.findRenderObject();
    final screen = MediaQuery.sizeOf(context);
    if (renderObj is RenderBox && renderObj.hasSize) {
      final pos = renderObj.localToGlobal(Offset.zero);
      final sz = renderObj.size;
      _alignRight = (pos.dx + widget.minMenuWidth) > (screen.width - 14);
      final spaceBelow = screen.height - (pos.dy + sz.height) - 16;
      final spaceAbove = pos.dy - 16;
      final estHeight = math.min(320.0, widget.items.length * 36.0 + 24.0);
      _flipUp = spaceBelow < estHeight && spaceAbove > spaceBelow;
      _availMaxHeight =
          math.max(140.0, math.min(340.0, _flipUp ? spaceAbove : spaceBelow));
    }
    _kbIndex = widget.items.indexWhere((x) => x.value == widget.value);
    setState(() => _open = true);
    _portalCtrl.show();
    _animCtrl.forward(from: 0.0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _open) {
        _menuFocus.requestFocus();
      }
    });
  }

  Future<void> _closeMenu() async {
    if (!_open) return;
    setState(() => _open = false);
    await _animCtrl.reverse();
    if (mounted && !_open && _portalCtrl.isShowing) {
      _portalCtrl.hide();
    }
  }

  Future<void> _selectValue(T val) async {
    widget.onChanged(val);
    await _closeMenu();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final list = _filteredItems;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _closeMenu();
      return KeyEventResult.handled;
    }
    if (list.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _kbIndex = (_kbIndex + 1) % list.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _kbIndex = _kbIndex <= 0 ? list.length - 1 : _kbIndex - 1;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        _kbIndex >= 0 &&
        _kbIndex < list.length) {
      _selectValue(list[_kbIndex].value);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final selectedItem = widget.items
            .where((x) => x.value == widget.value)
            .firstOrNull ??
        widget.items.first;

    final activeTint = widget.highlightActive;
    final bg = _pressed || _open
        ? c.paper3
        : (activeTint
            ? c.clay.withValues(alpha: c.isDark ? 0.16 : 0.09)
            : (_hovered ? c.paper3 : c.paper2));
    final borderCol = _open
        ? c.clay
        : (activeTint
            ? c.clay.withValues(alpha: 0.38)
            : (_hovered ? c.ringHover : c.hairline));
    final fgCol = activeTint ? c.clay : (_open ? c.ink : c.inkSoft);

    final menuCurved = CurvedAnimation(
      parent: _animCtrl,
      curve: PrismMotion.editorialOut,
      reverseCurve: Curves.easeInCubic,
    );

    Widget trigger = MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: _toggleMenu,
        child: AnimatedScale(
          scale: _pressed ? 0.975 : 1.0,
          duration: PrismMotion.duration(
            context,
            const Duration(milliseconds: 90),
          ),
          child: AnimatedContainer(
            duration: PrismMotion.duration(context, PrismMotion.fast),
            curve: PrismMotion.editorialOut,
            height: 31,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: ShapeDecoration(
              color: bg,
              shape: StadiumBorder(
                side: BorderSide(color: borderCol),
              ),
            ),
            child: Row(
              mainAxisSize:
                  widget.expandTrigger ? MainAxisSize.max : MainAxisSize.min,
              children: [
                if (selectedItem.icon != null || widget.leadingIcon != null) ...[
                  Icon(
                    selectedItem.icon ?? widget.leadingIcon,
                    size: 13.5,
                    color: _open || activeTint ? c.clay : c.muted,
                  ),
                  const SizedBox(width: 5.5),
                ],
                if (widget.prefixLabel != null &&
                    widget.prefixLabel!.isNotEmpty) ...[
                  Text(
                    '${widget.prefixLabel}: ',
                    style: sansStyle(c, size: 11.8, color: c.muted),
                  ),
                ],
                Flexible(
                  fit: widget.expandTrigger ? FlexFit.tight : FlexFit.loose,
                  child: Text(
                    selectedItem.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sansStyle(
                      c,
                      size: 12.2,
                      weight: activeTint ? FontWeight.w600 : FontWeight.w500,
                      color: fgCol,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0.0,
                  duration: PrismMotion.duration(
                    context,
                    const Duration(milliseconds: 160),
                  ),
                  curve: PrismMotion.editorialOut,
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 14.5,
                    color: _open || activeTint ? c.clay : c.meta,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null && widget.tooltip!.isNotEmpty) {
      trigger = Tooltip(message: widget.tooltip!, child: trigger);
    }

    return CompositedTransformTarget(
      link: _layerLink,
      child: OverlayPortal(
        controller: _portalCtrl,
        overlayChildBuilder: (overlayCtx) {
          final oc = PrismPalette.of(overlayCtx);
          final screenW = MediaQuery.sizeOf(overlayCtx).width;
          final effMaxW = math.min(widget.maxMenuWidth, screenW - 24);
          final effMinW = math.min(widget.minMenuWidth, effMaxW);
          final showSearch =
              widget.searchable ?? (widget.items.length >= 8);
          final filtered = _filteredItems;

          final targetAnc = _flipUp
              ? (_alignRight ? Alignment.topRight : Alignment.topLeft)
              : (_alignRight ? Alignment.bottomRight : Alignment.bottomLeft);
          final followerAnc = _flipUp
              ? (_alignRight ? Alignment.bottomRight : Alignment.bottomLeft)
              : (_alignRight ? Alignment.topRight : Alignment.topLeft);
          final scaleAlign = followerAnc;
          final offset = Offset(0, _flipUp ? -5 : 5);

          return Focus(
            focusNode: _menuFocus,
            onKeyEvent: _handleKey,
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _closeMenu,
                  ),
                ),
                CompositedTransformFollower(
                  link: _layerLink,
                  showWhenUnlinked: false,
                  targetAnchor: targetAnc,
                  followerAnchor: followerAnc,
                  offset: offset,
                  child: FadeTransition(
                    opacity: _animCtrl.drive(CurveTween(curve: Curves.easeOut)),
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.95, end: 1.0)
                          .animate(menuCurved),
                      alignment: scaleAlign,
                      child: Material(
                        type: MaterialType.transparency,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: effMinW,
                            maxWidth: effMaxW,
                            maxHeight: _availMaxHeight,
                          ),
                          child: DecoratedBox(
                            decoration: ShapeDecoration(
                              color: oc.paper2,
                              shape: prismSuperellipse(
                                20,
                                side: BorderSide(
                                  color: oc.hairline.withValues(alpha: 0.72),
                                ),
                              ),
                              shadows: oc.popoverShadow,
                            ),
                            child: ClipRSuperellipse(
                              borderRadius: BorderRadius.circular(20),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (showSearch) ...[
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        8,
                                        7,
                                        8,
                                        5,
                                      ),
                                      child: SizedBox(
                                        height: 29,
                                        child: TextField(
                                          controller: _searchCtrl,
                                          onChanged: (_) =>
                                              setState(() => _kbIndex = 0),
                                          style: sansStyle(oc, size: 12),
                                          decoration: InputDecoration(
                                            hintText: '筛选选项...',
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            prefixIcon: Icon(
                                              Icons.search_rounded,
                                              size: 13.5,
                                              color: oc.meta,
                                            ),
                                            prefixIconConstraints:
                                                const BoxConstraints(
                                              minWidth: 26,
                                              minHeight: 24,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    Divider(height: 1, color: oc.hairline),
                                  ],
                                  Flexible(
                                    child: Scrollbar(
                                      controller: _scrollCtrl,
                                      child: SingleChildScrollView(
                                        controller: _scrollCtrl,
                                        padding: const EdgeInsets.all(4.5),
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            if (filtered.isEmpty)
                                              Padding(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  vertical: 14,
                                                  horizontal: 10,
                                                ),
                                                child: Text(
                                                  '无匹配项',
                                                  textAlign: TextAlign.center,
                                                  style: sansStyle(
                                                    oc,
                                                    size: 12,
                                                    color: oc.meta,
                                                  ),
                                                ),
                                              ),
                                            for (var i = 0;
                                                i < filtered.length;
                                                i++) ...[
                                              if (filtered[i].dividerBefore &&
                                                  i > 0)
                                                Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    vertical: 4,
                                                    horizontal: 4,
                                                  ),
                                                  child: Divider(
                                                    height: 1,
                                                    color: oc.hairline,
                                                  ),
                                                )
                                              else if (i > 0)
                                                const SizedBox(height: 1.5),
                                              if (filtered[i].groupLabel !=
                                                  null)
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.fromLTRB(
                                                    8,
                                                    4,
                                                    8,
                                                    3,
                                                  ),
                                                  child: Text(
                                                    filtered[i].groupLabel!,
                                                    style: sansStyle(
                                                      oc,
                                                      size: 10.8,
                                                      weight: FontWeight.w600,
                                                      color: oc.meta,
                                                    ),
                                                  ),
                                                ),
                                              _PrismDropMenuTile<T>(
                                                item: filtered[i],
                                                selected: filtered[i].value ==
                                                    widget.value,
                                                kbHighlighted: i == _kbIndex,
                                                onHover: () {
                                                  if (_kbIndex != i) {
                                                    setState(
                                                      () => _kbIndex = i,
                                                    );
                                                  }
                                                },
                                                onTap: () => _selectValue(
                                                  filtered[i].value,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
        child: trigger,
      ),
    );
  }
}

class _PrismDropMenuTile<T> extends StatefulWidget {
  final PrismDropMenuItem<T> item;
  final bool selected;
  final bool kbHighlighted;
  final VoidCallback onHover;
  final VoidCallback onTap;

  const _PrismDropMenuTile({
    required this.item,
    required this.selected,
    this.kbHighlighted = false,
    required this.onHover,
    required this.onTap,
  });

  @override
  State<_PrismDropMenuTile<T>> createState() => _PrismDropMenuTileState<T>();
}

class _PrismDropMenuTileState<T> extends State<_PrismDropMenuTile<T>> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final sel = widget.selected;
    final activeHover = _hovered || widget.kbHighlighted;
    final isDanger = widget.item.destructive;

    final Color bg;
    if (isDanger) {
      bg = (_pressed || activeHover)
          ? c.dangerBg
          : c.dangerBg.withValues(alpha: 0.0);
    } else if (_pressed) {
      bg = c.clay.withValues(alpha: c.isDark ? 0.18 : 0.11);
    } else if (activeHover) {
      bg = c.paper3;
    } else if (sel) {
      bg = c.clay.withValues(alpha: c.isDark ? 0.12 : 0.07);
    } else {
      bg = c.paper3.withValues(alpha: 0.0);
    }

    final fgColor = isDanger
        ? c.danger
        : (sel ? c.ink : (activeHover ? c.ink : c.inkSoft));
    final iconColor = isDanger
        ? c.danger
        : (sel ? c.clay : (activeHover ? c.inkSoft : c.muted));

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) {
        setState(() => _hovered = true);
        widget.onHover();
      },
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7.5),
          decoration: ShapeDecoration(
            color: bg,
            shape: prismSuperellipse(12),
          ),
          child: Row(
            children: [
              if (widget.item.icon != null) ...[
                Icon(widget.item.icon, size: 14.5, color: iconColor),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.item.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: sansStyle(
                        c,
                        size: 12.4,
                        weight: sel ? FontWeight.w600 : FontWeight.w500,
                        color: fgColor,
                      ),
                    ),
                    if (widget.item.subtitle != null &&
                        widget.item.subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 1),
                      Text(
                        widget.item.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(c, size: 10.8, color: c.meta),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.item.badge != null &&
                  widget.item.badge!.isNotEmpty) ...[
                const SizedBox(width: 8),
                PrismPill(
                  text: widget.item.badge!,
                  bg: sel ? c.clay.withValues(alpha: 0.14) : c.recessed,
                  fg: sel ? c.clay : c.muted,
                ),
              ],
              if (widget.item.shortcut != null &&
                  widget.item.shortcut!.isNotEmpty) ...[
                const SizedBox(width: 8),
                Text(
                  widget.item.shortcut!,
                  style: monoStyle(c, size: 10.5, color: c.meta),
                ),
              ],
              if (!isDanger) ...[
                const SizedBox(width: 5),
                SizedBox(
                  width: 14,
                  child: sel
                      ? Icon(Icons.check_rounded, size: 14, color: c.clay)
                      : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Action entry for [PrismActionMenuButton] (`⋯` row context menus) and [PrismSplitButton].
class PrismMenuAction {
  final String label;
  final String? subtitle;
  final String? badge;
  final IconData? icon;
  final VoidCallback? _onSelected;
  final VoidCallback? _onTap;
  final bool destructive;
  final bool dividerBefore;
  final bool highlight;

  VoidCallback get onSelected => _onSelected ?? _onTap ?? _noop;
  static void _noop() {}

  const PrismMenuAction({
    required this.label,
    this.subtitle,
    this.badge,
    this.icon,
    VoidCallback? onSelected,
    VoidCallback? onTap,
    this.destructive = false,
    this.dividerBefore = false,
    this.highlight = false,
  })  : _onSelected = onSelected,
        _onTap = onTap;
}

/// Compact `⋯` (or custom trigger) Popover Action Menu with 4-edge auto-flip & Esc support.
class PrismActionMenuButton extends StatefulWidget {
  final List<PrismMenuAction> actions;
  final IconData icon;
  final Widget? leading;
  final String? label;
  final String tooltip;
  final double minMenuWidth;
  final double maxMenuWidth;
  final Widget? customTrigger;

  const PrismActionMenuButton({
    super.key,
    required this.actions,
    this.icon = Icons.more_horiz_rounded,
    this.leading,
    this.label,
    this.tooltip = '更多操作',
    this.minMenuWidth = 176,
    this.maxMenuWidth = 320,
    this.customTrigger,
  });

  @override
  State<PrismActionMenuButton> createState() => _PrismActionMenuButtonState();
}

class _PrismActionMenuButtonState extends State<PrismActionMenuButton>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _portalCtrl = OverlayPortalController();
  final FocusNode _focus = FocusNode(debugLabel: 'PrismActionMenuFocus');
  late final AnimationController _animCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 170),
    reverseDuration: const Duration(milliseconds: 115),
  );

  bool _open = false;
  bool _hovered = false;
  bool _alignRight = true;
  bool _flipUp = false;
  double _availMaxHeight = 320;

  @override
  void dispose() {
    _animCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _openMenu() {
    if (_open || widget.actions.isEmpty) return;
    final renderObj = context.findRenderObject();
    final screen = MediaQuery.sizeOf(context);
    if (renderObj is RenderBox && renderObj.hasSize) {
      final pos = renderObj.localToGlobal(Offset.zero);
      final sz = renderObj.size;
      _alignRight = (pos.dx + widget.minMenuWidth) > (screen.width - 16) ||
          pos.dx > screen.width * 0.45;
      if (_alignRight && (pos.dx + sz.width) < widget.minMenuWidth + 12) {
        _alignRight = false;
      }
      final spaceBelow = screen.height - (pos.dy + sz.height) - 16;
      final spaceAbove = pos.dy - 16;
      final estHeight = math.min(320.0, widget.actions.length * 38.0 + 16.0);
      _flipUp = spaceBelow < estHeight && spaceAbove > spaceBelow;
      _availMaxHeight =
          math.max(140.0, math.min(340.0, _flipUp ? spaceAbove : spaceBelow));
    }
    setState(() => _open = true);
    _portalCtrl.show();
    _animCtrl.forward(from: 0.0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _open) _focus.requestFocus();
    });
  }

  Future<void> _closeMenu() async {
    if (!_open) return;
    setState(() => _open = false);
    await _animCtrl.reverse();
    if (mounted && !_open && _portalCtrl.isShowing) {
      _portalCtrl.hide();
    }
  }

  Future<void> _runAction(PrismMenuAction action) async {
    await _closeMenu();
    action.onSelected();
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final curved = CurvedAnimation(
      parent: _animCtrl,
      curve: PrismMotion.editorialOut,
      reverseCurve: Curves.easeInCubic,
    );

    Widget trigger = widget.customTrigger ??
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Container(
            height: 31,
            width: (widget.label == null || widget.label!.isEmpty) ? 31 : null,
            padding: (widget.label == null || widget.label!.isEmpty)
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 11),
            decoration: ShapeDecoration(
              color: (widget.label != null && widget.label!.isNotEmpty)
                  ? ((_open || _hovered) ? c.paper3 : c.paper2)
                  : ((_open || _hovered)
                      ? c.paper3
                      : c.paper3.withValues(alpha: 0.0)),
              shape: StadiumBorder(
                side: BorderSide(
                  color: _open
                      ? c.clay
                      : ((widget.label != null && widget.label!.isNotEmpty)
                          ? (_hovered ? c.ringHover : c.hairline)
                          : (_hovered
                              ? c.hairline
                              : c.hairline.withValues(alpha: 0.0))),
                ),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (widget.leading != null)
                  widget.leading!
                else
                  Icon(
                    widget.icon,
                    size: 16,
                    color: _open ? c.clay : (_hovered ? c.ink : c.muted),
                  ),
                if (widget.label != null && widget.label!.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(
                    widget.label!,
                    style: sansStyle(
                      c,
                      size: 12.2,
                      weight: FontWeight.w500,
                      color: _open ? c.ink : c.inkSoft,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Icon(
                    _open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 14,
                    color: c.muted,
                  ),
                ],
              ],
            ),
          ),
        );

    trigger = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _open ? _closeMenu() : _openMenu(),
      child: Tooltip(message: widget.tooltip, child: trigger),
    );

    return CompositedTransformTarget(
      link: _layerLink,
      child: OverlayPortal(
        controller: _portalCtrl,
        overlayChildBuilder: (overlayCtx) {
          final oc = PrismPalette.of(overlayCtx);
          final screenW = MediaQuery.sizeOf(overlayCtx).width;
          final effMaxW = math.min(widget.maxMenuWidth, screenW - 24);
          final effMinW = math.min(widget.minMenuWidth, effMaxW);

          final targetAnc = _flipUp
              ? (_alignRight ? Alignment.topRight : Alignment.topLeft)
              : (_alignRight ? Alignment.bottomRight : Alignment.bottomLeft);
          final followerAnc = _flipUp
              ? (_alignRight ? Alignment.bottomRight : Alignment.bottomLeft)
              : (_alignRight ? Alignment.topRight : Alignment.topLeft);

          return Focus(
            focusNode: _focus,
            onKeyEvent: (_, ev) {
              if (ev is KeyDownEvent &&
                  ev.logicalKey == LogicalKeyboardKey.escape) {
                _closeMenu();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _closeMenu,
                  ),
                ),
                CompositedTransformFollower(
                  link: _layerLink,
                  showWhenUnlinked: false,
                  targetAnchor: targetAnc,
                  followerAnchor: followerAnc,
                  offset: Offset(0, _flipUp ? -5 : 5),
                  child: FadeTransition(
                    opacity: _animCtrl.drive(CurveTween(curve: Curves.easeOut)),
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.95, end: 1.0)
                          .animate(curved),
                      alignment: followerAnc,
                      child: Material(
                        type: MaterialType.transparency,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: effMinW,
                            maxWidth: effMaxW,
                            maxHeight: _availMaxHeight,
                          ),
                          child: DecoratedBox(
                            decoration: ShapeDecoration(
                              color: oc.paper2,
                              shape: prismSuperellipse(
                                20,
                                side: BorderSide(
                                  color: oc.hairline.withValues(alpha: 0.72),
                                ),
                              ),
                              shadows: oc.popoverShadow,
                            ),
                            child: ClipRSuperellipse(
                              borderRadius: BorderRadius.circular(20),
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.all(4.5),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    for (var i = 0;
                                        i < widget.actions.length;
                                        i++) ...[
                                      if (widget.actions[i].dividerBefore &&
                                          i > 0)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 4,
                                            horizontal: 4,
                                          ),
                                          child: Divider(
                                            height: 1,
                                            color: oc.hairline,
                                          ),
                                        )
                                      else if (i > 0)
                                        const SizedBox(height: 1.5),
                                      _ActionMenuTile(
                                        action: widget.actions[i],
                                        onTap: () =>
                                            _runAction(widget.actions[i]),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
        child: trigger,
      ),
    );
  }
}

class _ActionMenuTile extends StatefulWidget {
  final PrismMenuAction action;
  final VoidCallback onTap;

  const _ActionMenuTile({required this.action, required this.onTap});

  @override
  State<_ActionMenuTile> createState() => _ActionMenuTileState();
}

class _ActionMenuTileState extends State<_ActionMenuTile> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final a = widget.action;
    final Color bg;
    if (a.destructive) {
      bg = (_hovered || _pressed) ? c.dangerBg : Colors.transparent;
    } else if (_pressed) {
      bg = c.clay.withValues(alpha: 0.14);
    } else if (_hovered) {
      bg = c.paper3;
    } else if (a.highlight) {
      bg = c.clay.withValues(alpha: c.isDark ? 0.10 : 0.05);
    } else {
      bg = Colors.transparent;
    }

    final fg = a.destructive
        ? c.danger
        : (a.highlight ? c.clay : (_hovered ? c.ink : c.inkSoft));

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7.5),
          decoration: ShapeDecoration(
            color: bg,
            shape: prismSuperellipse(12),
          ),
          child: Row(
            children: [
              if (a.icon != null) ...[
                Icon(
                  a.icon,
                  size: 14.5,
                  color: a.destructive
                      ? c.danger
                      : (a.highlight ? c.clay : c.muted),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        if (a.badge != null && a.badge!.isNotEmpty) ...[
                          PrismPill(
                            text: a.badge!,
                            mono: false,
                            fg: a.highlight ? c.clay : c.inkSoft,
                            bg: a.highlight
                                ? c.clay.withValues(alpha: 0.14)
                                : c.recessed,
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            a.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: sansStyle(
                              c,
                              size: 12.3,
                              weight: a.highlight
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: fg,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (a.subtitle != null && a.subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        a.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoStyle(c, size: 11, color: c.muted),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// shadcn/ui Split Button (`[ Primary Action | ▾ ]`).
/// Clicking the left body executes [onPrimaryPressed]; clicking the right chevron
/// opens the 4-edge auto-flipping Popover of [menuActions].
class PrismSplitButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Widget? leading;
  final VoidCallback? onPrimaryPressed;
  final List<PrismMenuAction> menuActions;
  final PrismBtnVariant variant;
  final double minMenuWidth;
  final double maxMenuWidth;
  final String menuTooltip;

  const PrismSplitButton({
    super.key,
    required this.label,
    this.icon,
    this.leading,
    required this.onPrimaryPressed,
    required this.menuActions,
    this.variant = PrismBtnVariant.neutral,
    this.minMenuWidth = 248,
    this.maxMenuWidth = 360,
    this.menuTooltip = '更多选项',
  });

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    if (menuActions.length <= 1) {
      return PrismButton(
        label: label,
        compact: true,
        variant: variant,
        leading: leading ?? (icon != null ? Icon(icon) : null),
        onPressed: onPrimaryPressed,
      );
    }

    final isClay = variant == PrismBtnVariant.clay;
    final bg = isClay ? c.clay : c.paper2;
    final fg = isClay ? c.onClay : c.inkSoft;
    final border = isClay ? c.clay : c.hairline;
    final sepColor = isClay
        ? c.onClay.withValues(alpha: 0.22)
        : c.hairline;

    return DecoratedBox(
      decoration: ShapeDecoration(
        color: bg,
        shape: StadiumBorder(side: BorderSide(color: border)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: SizedBox(
          height: 31,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onPrimaryPressed,
                  hoverColor: isClay
                      ? Colors.black.withValues(alpha: 0.12)
                      : c.paper3,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (leading != null) ...[
                          IconTheme(
                            data: IconThemeData(size: 13.5, color: fg),
                            child: leading!,
                          ),
                          const SizedBox(width: 5.5),
                        ] else if (icon != null) ...[
                          Icon(icon, size: 13.5, color: fg),
                          const SizedBox(width: 5.5),
                        ],
                        Text(
                          label,
                          style: sansStyle(
                            c,
                            size: 12.2,
                            weight: FontWeight.w500,
                            color: fg,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Container(width: 1, height: 30, color: sepColor),
              PrismActionMenuButton(
                actions: menuActions,
                tooltip: menuTooltip,
                minMenuWidth: minMenuWidth,
                maxMenuWidth: maxMenuWidth,
                customTrigger: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    width: 25,
                    height: 30,
                    alignment: Alignment.center,
                    child: Icon(
                      Icons.keyboard_arrow_down_rounded,
                      size: 15,
                      color: fg,
                    ),
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

/// Precision single-line hairline list row with smooth hover-reveal secondary actions.
class PrismHoverRevealRow extends StatefulWidget {
  final Widget leading;
  final Widget? secondaryActions;
  final Widget? primaryAction;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final bool showDivider;
  final bool highlighted;

  const PrismHoverRevealRow({
    super.key,
    required this.leading,
    this.secondaryActions,
    this.primaryAction,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.showDivider = true,
    this.highlighted = false,
  });

  @override
  State<PrismHoverRevealRow> createState() => _PrismHoverRevealRowState();
}

class _PrismHoverRevealRowState extends State<PrismHoverRevealRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    final alwaysShowSecondary = MediaQuery.sizeOf(context).width < 760;
    final reveal = _hovered || alwaysShowSecondary;

    final rowBg = widget.highlighted
        ? c.clay.withValues(alpha: c.isDark ? 0.14 : 0.08)
        : (_hovered
            ? c.paper3.withValues(alpha: c.isDark ? 0.55 : 0.65)
            : Colors.transparent);

    return MouseRegion(
      onEnter: (_) {
        if (!_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: widget.showDivider
              ? Border(
                  bottom: BorderSide(color: c.hairline.withValues(alpha: 0.85)),
                )
              : null,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            hoverColor: Colors.transparent,
            splashColor: c.clay.withValues(alpha: 0.08),
            child: AnimatedContainer(
              duration: PrismMotion.duration(
                context,
                const Duration(milliseconds: 120),
              ),
              curve: Curves.easeOutCubic,
              padding: widget.padding,
              color: rowBg,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: widget.leading),
                  if (widget.secondaryActions != null) ...[
                    const SizedBox(width: 8),
                    AnimatedOpacity(
                      duration: PrismMotion.duration(
                        context,
                        const Duration(milliseconds: 130),
                      ),
                      opacity: reveal ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !reveal,
                        child: widget.secondaryActions!,
                      ),
                    ),
                  ],
                  if (widget.primaryAction != null) ...[
                    const SizedBox(width: 6),
                    widget.primaryAction!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal scroll container with edge-fade affordance & desktop chevron controls.
class PrismScrollHintRow extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;

  const PrismScrollHintRow({
    super.key,
    required this.child,
    this.padding,
  });

  @override
  State<PrismScrollHintRow> createState() => _PrismScrollHintRowState();
}

class _PrismScrollHintRowState extends State<PrismScrollHintRow> {
  final ScrollController _ctrl = ScrollController();
  bool _canLeft = false;
  bool _canRight = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_syncHints);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncHints());
  }

  @override
  void dispose() {
    _ctrl.removeListener(_syncHints);
    _ctrl.dispose();
    super.dispose();
  }

  void _syncHints() {
    if (!mounted || !_ctrl.hasClients) return;
    final pos = _ctrl.position;
    final left = pos.pixels > 4;
    final right = pos.pixels < pos.maxScrollExtent - 4;
    if (left != _canLeft || right != _canRight) {
      setState(() {
        _canLeft = left;
        _canRight = right;
      });
    }
  }

  void _nudge(double delta) {
    if (!_ctrl.hasClients) return;
    final target =
        (_ctrl.offset + delta).clamp(0.0, _ctrl.position.maxScrollExtent);
    _ctrl.animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = PrismPalette.of(context);
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _syncHints();
        return false;
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          SingleChildScrollView(
            controller: _ctrl,
            scrollDirection: Axis.horizontal,
            padding: widget.padding,
            child: widget.child,
          ),
          if (_canLeft)
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: () => _nudge(-140),
                child: Container(
                  width: 26,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        c.paper.withValues(alpha: 0.96),
                        c.paper.withValues(alpha: 0.0),
                      ],
                    ),
                  ),
                  alignment: Alignment.centerLeft,
                  child: Icon(
                    Icons.chevron_left_rounded,
                    size: 16,
                    color: c.muted,
                  ),
                ),
              ),
            ),
          if (_canRight)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: GestureDetector(
                onTap: () => _nudge(140),
                child: Container(
                  width: 28,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        c.paper.withValues(alpha: 0.0),
                        c.paper.withValues(alpha: 0.96),
                      ],
                    ),
                  ),
                  alignment: Alignment.centerRight,
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: c.clay,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
