import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'claude_motion.dart';

export 'claude_motion.dart';

const String kFontSerif = 'AnthropicSerif';
const String kFontSans = 'AnthropicSans';
const String kFontMono = 'JetBrainsMono';

const List<String> kSerifFallback = [
  'NotoSerifSC',
  'Georgia',
  'Iowan Old Style',
  'Songti SC',
  'STSong',
  'SimSun',
  'serif',
];

const List<String> kSansFallback = [
  'NotoSansSC',
  'PingFang SC',
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

/// Continuous-curvature Superellipse shape helper (FlClash visual standard).
RoundedSuperellipseBorder claudeSuperellipse(
  double radius, {
  BorderSide side = BorderSide.none,
}) {
  return RoundedSuperellipseBorder(
    borderRadius: BorderRadius.circular(radius),
    side: side,
  );
}

/// Anthropic / Claude Editorial Design Tokens + Frosted Glass / Mica Tokens.
class ClaudePalette {
  final bool isDark;

  /// Primary page canvas (Parchment in light, Near-Black in dark)
  final Color paper;

  /// Elevated card surface (Ivory in light, Warm Charcoal in dark)
  final Color paper2;

  /// Warm Sand / interactive secondary surface
  final Color paper3;

  /// Sidebar & recessed chrome surface
  final Color sidebar;

  /// Recessed input / code inline background
  final Color recessed;

  /// Primary text (Anthropic Near-Black #141413 / Ivory #FAF9F5)
  final Color ink;

  /// Emphasized secondary text (Dark Warm #3D3D3A)
  final Color inkSoft;

  /// Secondary body text (Olive Gray #5E5D59 / Warm Silver #B0AEA5)
  final Color muted;

  /// Tertiary metadata & timestamps (Stone Gray #87867F)
  final Color meta;

  /// Standard 1px warm border (Border Cream / Border Dark)
  final Color hairline;

  /// Interactive ring border on hover (Ring Warm #D1CFC5)
  final Color ringHover;

  /// Brand Terracotta CTA (#C96442 light / #D97757 dark)
  final Color clay;
  final Color clayHover;

  /// Accessibility input focus ring (#3898EC)
  final Color focusRing;

  final Color sage;
  final Color sageBg;
  final Color danger;
  final Color dangerBg;
  final Color purple;
  final Color purpleBg;
  final Color termBg;
  final Color termFg;

  const ClaudePalette({
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

  static const light = ClaudePalette(
    isDark: false,
    paper: Color(0xFFF5F4ED), // Parchment canvas
    paper2: Color(0xFFFAF9F5), // Ivory elevated card
    paper3: Color(0xFFE8E6DC), // Warm Sand interactive fill
    sidebar: Color(0xFFEFEDE4), // Warm Linen sidebar
    recessed: Color(0xFFF2F0E8), // Subtle recessed well
    ink: Color(0xFF141413), // Anthropic Near Black
    inkSoft: Color(0xFF3D3D3A), // Charcoal Warm
    muted: Color(0xFF5E5D59), // Olive Gray
    meta: Color(0xFF87867F), // Stone Gray
    hairline: Color(0xFFE6E4DA), // Border Cream
    ringHover: Color(0xFFCFCDC2), // Ring Warm
    clay: Color(0xFFC96442), // Terracotta Brand
    clayHover: Color(0xFFB55535),
    focusRing: Color(0xFF3898EC),
    sage: Color(0xFF4D7343),
    sageBg: Color(0x1F4D7343),
    danger: Color(0xFFB53333), // Error Crimson
    dangerBg: Color(0x1AB53333),
    purple: Color(0xFF695899),
    purpleBg: Color(0x1E695899),
    termBg: Color(0xFF161614),
    termFg: Color(0xFFEDEAE2),
  );

  static const dark = ClaudePalette(
    isDark: true,
    paper: Color(0xFF141413), // Deep Dark canvas
    paper2: Color(0xFF1E1E1B), // Elevated Charcoal card
    paper3: Color(0xFF2B2A27), // Dark Sand interactive fill
    sidebar: Color(0xFF191816), // Recessed dark sidebar
    recessed: Color(0xFF171614), // Recessed well
    ink: Color(0xFFFAF9F5), // Ivory ink
    inkSoft: Color(0xFFD6D4CB),
    muted: Color(0xFFB0AEA5), // Warm Silver
    meta: Color(0xFF807E77),
    hairline: Color(0xFF2E2D2A), // Border Dark
    ringHover: Color(0xFF46443F),
    clay: Color(0xFFD97757), // Coral Terracotta
    clayHover: Color(0xFFE3886B),
    focusRing: Color(0xFF4BA3F2),
    sage: Color(0xFF8AB06D),
    sageBg: Color(0x288AB06D),
    danger: Color(0xFFE06868),
    dangerBg: Color(0x26E06868),
    purple: Color(0xFFA89AD4),
    purpleBg: Color(0x288F7EC2),
    termBg: Color(0xFF0E0E0C),
    termFg: Color(0xFFEDEAE2),
  );

  static ClaudePalette of(BuildContext context) {
    return Theme.of(context).brightness == Brightness.dark ? dark : light;
  }

  /// Translucent frosted glass tint for fixed bars & floating surfaces.
  Color get glassBarTint => isDark
      ? const Color(0xBF191816) // 75% warm dark charcoal
      : const Color(0xCCF5F4ED); // 80% warm parchment

  /// Translucent sidebar tint when Windows 11 Mica backdrop is active.
  Color get micaSidebarTint => isDark
      ? const Color(0xA8191816) // 66% dark linen over Mica
      : const Color(0xB8EFEDE4); // 72% warm linen over Mica

  /// Translucent main reading pane tint over Mica (keeps text ultra-crisp).
  Color get micaCanvasTint => isDark
      ? const Color(0xEB141413) // 92% deep charcoal
      : const Color(0xEEFAF9F5); // 93% warm ivory/parchment

  /// Specular 1px top/inner highlight on frosted glass surfaces.
  Color get glassSpecular => isDark
      ? const Color(0x18FAF9F5)
      : const Color(0x88FFFFFF);

  /// FlClash sigma-calibrated whisper shadow (`cssBlur -> Skia blurRadius`)
  List<BoxShadow> get whisperShadow => isDark
      ? const [
          BoxShadow(
            color: Color(0x4D000000),
            offset: Offset(0, 4),
            blurRadius: 16,
            spreadRadius: -4,
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x0A141413),
            offset: Offset(0, 1),
            blurRadius: 2,
          ),
          BoxShadow(
            color: Color(0x0D141413),
            offset: Offset(0, 6),
            blurRadius: 18,
            spreadRadius: -4,
          ),
        ];

  /// Subtle elevated hover shadow for interactive superellipse cards
  List<BoxShadow> get cardHoverShadow => isDark
      ? const [
          BoxShadow(
            color: Color(0x66000000),
            offset: Offset(0, 8),
            blurRadius: 22,
            spreadRadius: -3,
          ),
        ]
      : const [
          BoxShadow(
            color: Color(0x10141413),
            offset: Offset(0, 2),
            blurRadius: 4,
          ),
          BoxShadow(
            color: Color(0x18141413),
            offset: Offset(0, 10),
            blurRadius: 24,
            spreadRadius: -4,
          ),
        ];
}

/// Editorial Serif headline style — intentionally capped at weight 500 per Anthropic spec.
TextStyle serifTitleStyle(
  ClaudePalette c, {
  double size = 24,
  FontWeight weight = FontWeight.w500,
  Color? color,
  double height = 1.22,
  bool tabular = true,
}) {
  final cappedWeight =
      weight.value > FontWeight.w600.value ? FontWeight.w500 : weight;
  return TextStyle(
    fontFamily: kFontSerif,
    fontFamilyFallback: kSerifFallback,
    fontSize: size,
    fontWeight: cappedWeight,
    color: color ?? c.ink,
    height: height,
    letterSpacing: size >= 22 ? -0.25 : -0.1,
    fontFeatures: tabular ? const [ui.FontFeature.tabularFigures()] : null,
  );
}

TextStyle sansStyle(
  ClaudePalette c, {
  double size = 13.5,
  FontWeight weight = FontWeight.w400,
  Color? color,
  double height = 1.5,
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
  ClaudePalette c, {
  double size = 12.5,
  Color? color,
  FontWeight weight = FontWeight.w400,
  double height = 1.48,
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

ThemeData buildClaudeTheme(ClaudePalette c) {
  final scheme = ColorScheme(
    brightness: c.isDark ? Brightness.dark : Brightness.light,
    primary: c.clay,
    onPrimary: const Color(0xFFFAF9F5),
    secondary: c.sage,
    onSecondary: const Color(0xFFFAF9F5),
    error: c.danger,
    onError: const Color(0xFFFAF9F5),
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
    scaffoldBackgroundColor: c.paper,
    fontFamily: kFontSans,
    fontFamilyFallback: kSansFallback,
    textTheme: TextTheme(
      displayLarge: serifTitleStyle(c, size: 36),
      headlineMedium: serifTitleStyle(c, size: 25),
      titleLarge: serifTitleStyle(c, size: 19),
      titleMedium: baseText.copyWith(fontSize: 15, fontWeight: FontWeight.w500),
      bodyLarge: baseText.copyWith(fontSize: 14.5, height: 1.58),
      bodyMedium: baseText.copyWith(fontSize: 13.5, height: 1.54),
      bodySmall: baseText.copyWith(fontSize: 12, color: c.muted, height: 1.45),
      labelLarge: baseText.copyWith(fontSize: 13, fontWeight: FontWeight.w500),
      labelSmall: baseText.copyWith(
        fontSize: 11.5,
        color: c.muted,
        letterSpacing: 0.15,
      ),
    ),
    dividerColor: c.hairline,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 380),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: ShapeDecoration(
        color: c.isDark ? const Color(0xF22E2D29) : const Color(0xF223221F),
        shape: claudeSuperellipse(
          9,
          side: BorderSide(
            color: c.isDark ? const Color(0xFF45433E) : const Color(0xFF3A3935),
          ),
        ),
      ),
      textStyle: const TextStyle(
        fontFamily: kFontSans,
        fontFamilyFallback: kSansFallback,
        fontSize: 12,
        color: Color(0xFFFAF9F5),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.recessed,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 13, vertical: 10.5),
      hintStyle: TextStyle(
        fontFamily: kFontSans,
        fontFamilyFallback: kSansFallback,
        color: c.meta,
        fontSize: 13,
      ),
      border: WidgetStateInputBorder.resolveWith((states) {
        if (states.contains(WidgetState.focused)) {
          return OutlineInputBorder(
            borderRadius: BorderRadius.circular(11.5),
            borderSide: BorderSide(color: c.focusRing, width: 1.4),
          );
        }
        if (states.contains(WidgetState.hovered)) {
          return OutlineInputBorder(
            borderRadius: BorderRadius.circular(11.5),
            borderSide: BorderSide(color: c.ringHover),
          );
        }
        return OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: BorderSide(
            color: c.hairline.withValues(alpha: c.isDark ? 0.5 : 0.3),
          ),
        );
      }),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.hovered) ||
            states.contains(WidgetState.dragged)) {
          return c.muted.withValues(alpha: 0.55);
        }
        return c.muted.withValues(alpha: 0.26);
      }),
      radius: const Radius.circular(99),
      thickness: WidgetStateProperty.all(6),
    ),
  );
}

/// Frosted Glass Chrome Surface — strictly reserved for fixed structural layers
/// (header bar, sticky filter header, bottom status bar, floating toast, and
/// modal sheets) so 120Hz scrolling stays under 2ms/frame.
class ClaudeGlassBar extends StatelessWidget {
  final Widget child;
  final double blurSigma;
  final Color? tintColor;
  final Border? border;
  final double? borderRadius;
  final EdgeInsetsGeometry? padding;
  final List<BoxShadow>? boxShadow;

  const ClaudeGlassBar({
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
    final c = ClaudePalette.of(context);
    final effectiveTint = tintColor ?? c.glassBarTint;
    final effectiveSigma = kIsWeb ? math.min(blurSigma, 8.0) : blurSigma;

    if (borderRadius != null && borderRadius! > 0) {
      return DecoratedBox(
        decoration: ShapeDecoration(
          shape: claudeSuperellipse(borderRadius!),
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
                shape: claudeSuperellipse(
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

/// Responsive 2-Column / Stacked Form Row shared across Setup & Sub-MCP forms.
/// Automatically stacks vertically below [stackBreakpoint] (`460dp`) so narrow
/// mobile/split windows never suffer horizontal `RenderFlex` overflow.
class ClaudeFormRow extends StatelessWidget {
  final String label;
  final String? subtitle;
  final Widget child;
  final double labelWidth;
  final double stackBreakpoint;
  final CrossAxisAlignment horizontalAlignment;

  const ClaudeFormRow({
    super.key,
    required this.label,
    this.subtitle,
    required this.child,
    this.labelWidth = 156,
    this.stackBreakpoint = 460,
    this.horizontalAlignment = CrossAxisAlignment.start,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
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
                size: 13.5,
                weight: FontWeight.w500,
                color: c.ink,
              ),
            ),
            if (subtitle != null && subtitle!.isNotEmpty) ...[
              const SizedBox(height: 2.5),
              Text(
                subtitle!,
                style: sansStyle(c, size: 12, color: c.muted, height: 1.42),
              ),
            ],
          ],
        );

        if (compact) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                labelBlock,
                const SizedBox(height: 8),
                child,
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            crossAxisAlignment: horizontalAlignment,
            children: [
              SizedBox(
                width: labelWidth,
                child: Padding(
                  padding: EdgeInsets.only(
                    top: horizontalAlignment == CrossAxisAlignment.start ? 7 : 0,
                    right: 14,
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

/// Signature 4-point Anthropic Terracotta Sparkle Icon
class ClaudeSparkIcon extends StatelessWidget {
  final double size;
  final Color? color;

  const ClaudeSparkIcon({super.key, this.size = 18, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? ClaudePalette.of(context).clay;
    return CustomPaint(
      size: Size.square(size),
      painter: _SparkPainter(c),
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

enum ClaudeBtnVariant { neutral, clay, ink, danger, ghost }

class ClaudeButton extends StatefulWidget {
  final String label;
  final Widget? leading;
  final VoidCallback? onPressed;
  final ClaudeBtnVariant variant;
  final bool compact;
  final bool expand;
  final bool loading;
  final String? tooltip;

  const ClaudeButton({
    super.key,
    required this.label,
    this.leading,
    this.onPressed,
    this.variant = ClaudeBtnVariant.neutral,
    this.compact = false,
    this.expand = false,
    this.loading = false,
    this.tooltip,
  });

  @override
  State<ClaudeButton> createState() => _ClaudeButtonState();
}

class _ClaudeButtonState extends State<ClaudeButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final disabled = widget.onPressed == null || widget.loading;

    Color bg;
    Color fg;
    Color border;
    switch (widget.variant) {
      case ClaudeBtnVariant.clay:
        bg = _hovered && !disabled ? c.clayHover : c.clay;
        fg = const Color(0xFFFAF9F5);
        border = bg;
      case ClaudeBtnVariant.ink:
        bg = _hovered && !disabled
            ? (c.isDark ? const Color(0xFFE6E3D8) : const Color(0xFF2B2A27))
            : c.ink;
        fg = c.paper;
        border = bg;
      case ClaudeBtnVariant.danger:
        bg = _hovered && !disabled ? c.danger.withValues(alpha: 0.88) : c.danger;
        fg = const Color(0xFFFAF9F5);
        border = bg;
      case ClaudeBtnVariant.ghost:
        // Same-hue 0.0 alpha avoids black-RGB interpolation flash on hover
        bg = _hovered && !disabled
            ? c.paper3.withValues(alpha: 0.72)
            : c.paper3.withValues(alpha: 0.0);
        fg = _hovered && !disabled ? c.ink : c.muted;
        border = _hovered && !disabled
            ? c.hairline
            : c.hairline.withValues(alpha: 0.0);
      case ClaudeBtnVariant.neutral:
        bg = _hovered && !disabled ? c.paper3 : c.paper2;
        fg = c.inkSoft;
        border = _hovered && !disabled ? c.ringHover : c.hairline;
    }

    final radius = widget.compact ? 10.0 : 12.0;
    final iconSize = widget.compact ? 14.5 : 16.0;
    final effFg = (disabled && !widget.loading) ? fg.withValues(alpha: 0.5) : fg;
    final effBg = (disabled && !widget.loading) ? bg.withValues(alpha: 0.45) : bg;
    final effBorder =
        (disabled && !widget.loading) ? border.withValues(alpha: 0.4) : border;

    final Widget? leadingSlot = (widget.leading != null || widget.loading)
        ? AnimatedSwitcher(
            duration: ClaudeMotion.duration(
              context,
              const Duration(milliseconds: 180),
            ),
            switchInCurve: ClaudeMotion.editorialOut,
            switchOutCurve: Curves.easeOut,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.82, end: 1.0).animate(anim),
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
                        strokeWidth: 1.85,
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
      scale: (_pressed && !disabled) ? 0.965 : 1.0,
      duration: ClaudeMotion.duration(
        context,
        _pressed
            ? const Duration(milliseconds: 85)
            : const Duration(milliseconds: 200),
      ),
      curve: _pressed ? ClaudeMotion.standard : ClaudeMotion.snappySpring,
      child: AnimatedContainer(
        duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
        curve: ClaudeMotion.editorialOut,
        height: widget.compact ? 32 : 38,
        padding: EdgeInsets.symmetric(horizontal: widget.compact ? 11.5 : 16),
        decoration: ShapeDecoration(
          color: effBg,
          shape: claudeSuperellipse(
            radius,
            side: BorderSide(color: effBorder),
          ),
        ),
        child: Row(
          mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (leadingSlot != null) ...[
              leadingSlot,
              if (widget.label.isNotEmpty) const SizedBox(width: 6.5),
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
                    fontSize: widget.compact ? 12.5 : 13.5,
                    fontWeight: FontWeight.w500,
                    color: effFg,
                    letterSpacing: 0.05,
                  ),
                ),
              ),
          ],
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

/// Elevated Ivory / Charcoal Superellipse Editorial Card with 1px containment & whisper shadow.
class ClaudeCard extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool hoverable;
  final double radius;

  const ClaudeCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
    this.onTap,
    this.hoverable = false,
    this.radius = 20,
  });

  @override
  State<ClaudeCard> createState() => _ClaudeCardState();
}

class _ClaudeCardState extends State<ClaudeCard> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final interactive = widget.onTap != null || widget.hoverable;

    Widget card = AnimatedContainer(
      duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
      curve: ClaudeMotion.editorialOut,
      width: double.infinity,
      padding: widget.padding,
      decoration: ShapeDecoration(
        color: c.paper2,
        shape: claudeSuperellipse(
          widget.radius,
          side: BorderSide(
            color: (_hovered && interactive)
                ? c.ringHover
                : c.hairline.withValues(alpha: c.isDark ? 0.55 : 0.35),
          ),
        ),
        shadows: (_hovered && interactive) ? c.cardHoverShadow : c.whisperShadow,
      ),
      child: widget.child,
    );

    if (widget.onTap != null) {
      card = AnimatedScale(
        scale: _pressed ? 0.992 : 1.0,
        duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
        curve: ClaudeMotion.snappySpring,
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

/// Spring Sliding-Pill Segmented Control (FlClash superellipse style + narrow-safe scroll).
class ClaudeSegmented<T> extends StatefulWidget {
  final List<(T, String)> items;
  final T value;
  final ValueChanged<T> onChanged;

  const ClaudeSegmented({
    super.key,
    required this.items,
    required this.value,
    required this.onChanged,
  });

  @override
  State<ClaudeSegmented<T>> createState() => _ClaudeSegmentedState<T>();
}

class _ClaudeSegmentedState<T> extends State<ClaudeSegmented<T>> {
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
  void didUpdateWidget(covariant ClaudeSegmented<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items.length != _itemKeys.length) {
      _itemKeys = List.generate(widget.items.length, (_) => GlobalKey());
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

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final pillDur = _animatePill
        ? ClaudeMotion.duration(context, const Duration(milliseconds: 250))
        : Duration.zero;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      child: DecoratedBox(
        decoration: ShapeDecoration(
          color: c.paper3.withValues(alpha: c.isDark ? 0.85 : 0.68),
          shape: claudeSuperellipse(13),
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: IntrinsicWidth(
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                if (_pillLeft != null && _pillWidth != null)
                  AnimatedPositioned(
                    duration: pillDur,
                    curve: ClaudeMotion.snappySpring,
                    left: _pillLeft!,
                    top: 0,
                    bottom: 0,
                    width: _pillWidth!,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: c.paper2,
                        shape: claudeSuperellipse(
                          9,
                          side: BorderSide(
                            color: c.isDark
                                ? c.ringHover
                                : c.hairline.withValues(alpha: 0.9),
                          ),
                        ),
                        shadows: [
                          BoxShadow(
                            color: Colors.black
                                .withValues(alpha: c.isDark ? 0.28 : 0.06),
                            blurRadius: 6,
                            offset: const Offset(0, 1.5),
                          ),
                        ],
                      ),
                    ),
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
      ),
    );
  }
}

class _SegmentTapItem extends StatefulWidget {
  final String label;
  final bool active;
  final bool fallbackHighlight;
  final ClaudePalette palette;
  final VoidCallback onTap;

  const _SegmentTapItem({
    super.key,
    required this.label,
    required this.active,
    required this.fallbackHighlight,
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
          padding: const EdgeInsets.symmetric(horizontal: 11.5, vertical: 5.5),
          decoration: widget.fallbackHighlight
              ? ShapeDecoration(
                  color: c.paper2,
                  shape: claudeSuperellipse(9),
                )
              : null,
          child: Text(
            widget.label,
            maxLines: 1,
            style: TextStyle(
              fontFamily: kFontSans,
              fontFamilyFallback: kSansFallback,
              fontSize: 12.5,
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

class ClaudePill extends StatelessWidget {
  final String text;
  final Widget? leading;
  final Color? fg;
  final Color? bg;
  final Color? border;
  final bool mono;

  const ClaudePill({
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
    final c = ClaudePalette.of(context);
    final effFg = fg ?? c.inkSoft;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: bg ?? c.recessed,
        shape: StadiumBorder(side: BorderSide(color: border ?? c.hairline)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[
              IconTheme(
                data: IconThemeData(size: 12, color: effFg),
                child: leading!,
              ),
              const SizedBox(width: 4.5),
            ],
            Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono
                  ? monoStyle(c, size: 11, color: effFg, weight: FontWeight.w500)
                  : TextStyle(
                      fontFamily: kFontSans,
                      fontFamilyFallback: kSansFallback,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                      color: effFg,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Elastic Thumb-Stretch Toggle Switch (inspired by FlClash `Switch`)
class ClaudeSwitch extends StatefulWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;

  const ClaudeSwitch({super.key, required this.value, this.onChanged});

  @override
  State<ClaudeSwitch> createState() => _ClaudeSwitchState();
}

class _ClaudeSwitchState extends State<ClaudeSwitch>
    with TickerProviderStateMixin {
  late final AnimationController _posCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
    value: widget.value ? 1.0 : 0.0,
  );
  late final AnimationController _pressCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 130),
  );
  bool _hovered = false;

  @override
  void didUpdateWidget(covariant ClaudeSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      final d = ClaudeMotion.duration(
        context,
        const Duration(milliseconds: 250),
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
    final c = ClaudePalette.of(context);
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
              final springPos = ClaudeMotion.snappySpring
                  .transform(_posCtrl.value)
                  .clamp(-0.06, 1.06);
              final linearPos = _posCtrl.value.clamp(0.0, 1.0);
              final pressT =
                  ClaudeMotion.editorialOut.transform(_pressCtrl.value);

              const trackW = 42.0;
              const trackH = 24.0;
              const pad = 2.5;
              final thumbW = 18.0 + 4.0 * pressT;
              const thumbH = 18.0;
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
                            color: const Color(0xFFFAF9F5),
                            shape: const StadiumBorder(),
                            shadows: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.18),
                                blurRadius: 3,
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

/// Tactile Superellipse Checkbox Row with spring bounce
class ClaudeCheckToggle extends StatefulWidget {
  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  const ClaudeCheckToggle({
    super.key,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  @override
  State<ClaudeCheckToggle> createState() => _ClaudeCheckToggleState();
}

class _ClaudeCheckToggleState extends State<ClaudeCheckToggle> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
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
                duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
                curve: ClaudeMotion.snappySpring,
                child: AnimatedContainer(
                  duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
                  curve: ClaudeMotion.editorialOut,
                  width: 18,
                  height: 18,
                  decoration: ShapeDecoration(
                    color: widget.value ? c.clay : c.recessed,
                    shape: claudeSuperellipse(
                      6,
                      side: BorderSide(
                        color: widget.value
                            ? c.clay
                            : (_hovered ? c.muted : c.ringHover),
                        width: 1.35,
                      ),
                    ),
                  ),
                  child: AnimatedSwitcher(
                    duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
                    switchInCurve: ClaudeMotion.snappySpring,
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: child,
                    ),
                    child: widget.value
                        ? const Icon(
                            Icons.check_rounded,
                            key: ValueKey('checked'),
                            size: 13,
                            color: Color(0xFFFAF9F5),
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
                    size: 13,
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

class ClaudePasswordField extends StatefulWidget {
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;

  const ClaudePasswordField({
    super.key,
    required this.controller,
    this.hintText = '',
    this.onSubmitted,
    this.onChanged,
  });

  @override
  State<ClaudePasswordField> createState() => _ClaudePasswordFieldState();
}

class _ClaudePasswordFieldState extends State<ClaudePasswordField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    return TextField(
      controller: widget.controller,
      obscureText: _obscure,
      onSubmitted: widget.onSubmitted,
      onChanged: widget.onChanged,
      style: monoStyle(c, size: 13, color: c.ink),
      decoration: InputDecoration(
        hintText: widget.hintText,
        suffixIconConstraints:
            const BoxConstraints(minWidth: 38, minHeight: 32),
        suffixIcon: IconButton(
          iconSize: 16,
          tooltip: _obscure ? '显示密钥' : '隐藏密钥',
          onPressed: () => setState(() => _obscure = !_obscure),
          icon: ClaudeFadeBox(
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

/// Opens a modal dialog with frosted scrim blur + FlClash spring physics.
Future<T?> showClaudeDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: const Color(0x52141413),
    transitionDuration: ClaudeMotion.duration(context, ClaudeMotion.modal),
    pageBuilder: (ctx, _, __) => SafeArea(child: Builder(builder: builder)),
    transitionBuilder: (ctx, anim, _, child) {
      final isReversing = anim.status == AnimationStatus.reverse;
      final curved = isReversing
          ? Curves.easeInCubic.transform(anim.value)
          : ClaudeMotion.snappySpring.transform(anim.value);
      final opacity = Curves.easeOut.transform(anim.value).clamp(0.0, 1.0);
      final scale = 0.95 + 0.05 * curved;
      final dy = (1.0 - curved) * 8.0;
      final blurSigma = (opacity * 5.0).clamp(0.0, 5.0);

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

Future<bool> showClaudeConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmText = '确定',
  String cancelText = '取消',
  bool destructive = false,
}) async {
  final res = await showClaudeDialog<bool>(
    context: context,
    builder: (ctx) {
      final c = ClaudePalette.of(ctx);
      final compact = MediaQuery.sizeOf(ctx).width < 520;
      return Dialog(
        backgroundColor: c.paper2,
        elevation: 0,
        insetPadding: EdgeInsets.symmetric(
          horizontal: compact ? 16 : 32,
          vertical: 20,
        ),
        shape: claudeSuperellipse(
          22,
          side: BorderSide(color: c.hairline),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 430),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              compact ? 20 : 26,
              22,
              compact ? 20 : 26,
              20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ClaudeSparkIcon(
                      size: 18,
                      color: destructive ? c.danger : c.clay,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(title, style: serifTitleStyle(c, size: 19.5)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  style: sansStyle(c, size: 13.5, height: 1.62, color: c.muted),
                ),
                const SizedBox(height: 22),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    ClaudeButton(
                      label: cancelText,
                      compact: true,
                      onPressed: () => Navigator.of(ctx).pop(false),
                    ),
                    ClaudeButton(
                      label: confirmText,
                      compact: true,
                      variant: destructive
                          ? ClaudeBtnVariant.danger
                          : ClaudeBtnVariant.clay,
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

/// Pixel-aligned 10x10 Windows 11 Caption Glyphs (modeled after FlClash `CaptionIcon`).
enum ClaudeCaptionGlyph { minimize, maximize, restore, close }

class ClaudeCaptionIcon extends StatelessWidget {
  final ClaudeCaptionGlyph glyph;
  final Color color;

  const ClaudeCaptionIcon({
    super.key,
    required this.glyph,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size.square(10.0),
      painter: _ClaudeCaptionGlyphPainter(glyph: glyph, color: color),
    );
  }
}

class _ClaudeCaptionGlyphPainter extends CustomPainter {
  final ClaudeCaptionGlyph glyph;
  final Color color;

  const _ClaudeCaptionGlyphPainter({
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
      case ClaudeCaptionGlyph.minimize:
        final y = (size.height / 2).floorToDouble() + 0.5;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);

      case ClaudeCaptionGlyph.maximize:
        canvas.drawRRect(RRect.fromRectAndRadius(box, corner), paint);

      case ClaudeCaptionGlyph.restore:
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

      case ClaudeCaptionGlyph.close:
        paint.strokeCap = StrokeCap.round;
        canvas.drawLine(box.topLeft, box.bottomRight, paint);
        canvas.drawLine(box.topRight, box.bottomLeft, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ClaudeCaptionGlyphPainter oldDelegate) =>
      oldDelegate.glyph != glyph || oldDelegate.color != color;
}

/// FlClash-style Windows frameless caption controls: Pin + Minimize + Maximize/Restore + Hide-to-Tray.
class ClaudeWindowCaptionActions extends StatelessWidget {
  final bool isMaximized;
  final bool isPinned;
  final VoidCallback onTogglePin;
  final VoidCallback onMinimize;
  final VoidCallback onToggleMaximize;
  final VoidCallback onCloseToTray;

  const ClaudeWindowCaptionActions({
    super.key,
    required this.isMaximized,
    required this.isPinned,
    required this.onTogglePin,
    required this.onMinimize,
    required this.onToggleMaximize,
    required this.onCloseToTray,
  });

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        const SizedBox(width: 4),
        _WinCaptionBtn(
          tooltip: '最小化',
          glyph: ClaudeCaptionGlyph.minimize,
          palette: c,
          onTap: onMinimize,
        ),
        _WinCaptionBtn(
          tooltip: isMaximized ? '向下还原' : '最大化',
          glyph: isMaximized
              ? ClaudeCaptionGlyph.restore
              : ClaudeCaptionGlyph.maximize,
          palette: c,
          onTap: onToggleMaximize,
        ),
        _WinCaptionBtn(
          tooltip: '隐藏到系统托盘（MCP 服务继续运行）',
          glyph: ClaudeCaptionGlyph.close,
          isClose: true,
          palette: c,
          onTap: onCloseToTray,
        ),
      ],
    );
  }
}

class _PinButton extends StatefulWidget {
  final bool isPinned;
  final ClaudePalette palette;
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
          duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
          curve: ClaudeMotion.snappySpring,
          child: AnimatedContainer(
            duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
            width: 30,
            height: 30,
            decoration: ShapeDecoration(
              shape: claudeSuperellipse(9),
              color: active
                  ? c.clay.withValues(alpha: 0.14)
                  : (_hovered ? c.paper3 : c.paper3.withValues(alpha: 0.0)),
            ),
            alignment: Alignment.center,
            child: AnimatedRotation(
              turns: active ? 0.0 : 0.125,
              duration: ClaudeMotion.duration(context, ClaudeMotion.base),
              curve: ClaudeMotion.snappySpring,
              child: Icon(
                active ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                size: 14.5,
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
  final ClaudeCaptionGlyph glyph;
  final bool isClose;
  final ClaudePalette palette;
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
        fg = const Color(0xFFFAF9F5);
      } else if (_hovered) {
        bg = c.danger;
        fg = const Color(0xFFFAF9F5);
      }
    } else {
      if (_pressed) {
        bg = c.ink.withValues(alpha: 0.11);
        fg = c.ink;
      } else if (_hovered) {
        bg = c.ink.withValues(alpha: 0.065);
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
            duration: ClaudeMotion.duration(
              context,
              const Duration(milliseconds: 110),
            ),
            width: 44,
            color: bg,
            alignment: Alignment.center,
            child: ClaudeFadeBox(
              alignment: Alignment.center,
              duration: const Duration(milliseconds: 120),
              child: ClaudeCaptionIcon(
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

class ClaudeDropMenuItem<T> {
  final T value;
  final String label;
  final IconData? icon;
  final String? badge;

  const ClaudeDropMenuItem({
    required this.value,
    required this.label,
    this.icon,
    this.badge,
  });
}

/// Editorial frosted-glass floating DropMenu with hover elevation shadow,
/// spring scale-in physics, and tactile item press feedback.
class ClaudeDropMenu<T> extends StatefulWidget {
  final T value;
  final List<ClaudeDropMenuItem<T>> items;
  final ValueChanged<T> onChanged;
  final IconData? leadingIcon;
  final String? prefixLabel;
  final bool highlightActive;
  final double minMenuWidth;
  final double maxMenuWidth;
  final String? tooltip;

  const ClaudeDropMenu({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.leadingIcon,
    this.prefixLabel,
    this.highlightActive = false,
    this.minMenuWidth = 176,
    this.maxMenuWidth = 280,
    this.tooltip,
  });

  @override
  State<ClaudeDropMenu<T>> createState() => _ClaudeDropMenuState<T>();
}

class _ClaudeDropMenuState<T> extends State<ClaudeDropMenu<T>>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  final OverlayPortalController _portalCtrl = OverlayPortalController();
  late final AnimationController _animCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 210),
    reverseDuration: const Duration(milliseconds: 135),
  );

  bool _open = false;
  bool _hovered = false;
  bool _pressed = false;
  bool _alignRight = false;

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
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
    final renderObj = context.findRenderObject();
    if (renderObj is RenderBox && renderObj.hasSize) {
      final globalX = renderObj.localToGlobal(Offset.zero).dx;
      final screenW = MediaQuery.sizeOf(context).width;
      _alignRight = (globalX + widget.minMenuWidth) > (screenW - 16);
    }
    setState(() => _open = true);
    _portalCtrl.show();
    _animCtrl.forward(from: 0.0);
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

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final selectedItem = widget.items
            .where((x) => x.value == widget.value)
            .firstOrNull ??
        widget.items.first;

    final activeTint = widget.highlightActive;
    final elevated = _hovered || _open;
    final bg = _pressed
        ? c.paper3
        : (_open
            ? c.paper3
            : (activeTint
                ? c.clay.withValues(alpha: c.isDark ? 0.16 : 0.10)
                : (_hovered ? c.paper3 : c.paper2)));
    final borderCol = _open
        ? c.clay
        : (activeTint
            ? c.clay.withValues(alpha: 0.42)
            : (_hovered ? c.ringHover : c.hairline));
    final fgCol = activeTint ? c.clay : (_open ? c.ink : c.inkSoft);

    final menuCurved = CurvedAnimation(
      parent: _animCtrl,
      curve: ClaudeMotion.snappySpring,
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
          scale: _pressed ? 0.96 : (_hovered && !_open ? 1.015 : 1.0),
          duration: ClaudeMotion.duration(
            context,
            _pressed
                ? const Duration(milliseconds: 80)
                : const Duration(milliseconds: 200),
          ),
          curve: _pressed ? ClaudeMotion.standard : ClaudeMotion.snappySpring,
          child: AnimatedContainer(
            duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
            curve: ClaudeMotion.editorialOut,
            height: 33,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: ShapeDecoration(
              color: bg,
              shape: claudeSuperellipse(
                10,
                side: BorderSide(color: borderCol),
              ),
              shadows: elevated && !_pressed
                  ? [
                      BoxShadow(
                        color: Colors.black
                            .withValues(alpha: c.isDark ? 0.32 : 0.09),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                      BoxShadow(
                        color: Colors.black
                            .withValues(alpha: c.isDark ? 0.16 : 0.04),
                        blurRadius: 3,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : const [],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selectedItem.icon != null || widget.leadingIcon != null) ...[
                  Icon(
                    selectedItem.icon ?? widget.leadingIcon,
                    size: 14,
                    color: _open || activeTint ? c.clay : c.muted,
                  ),
                  const SizedBox(width: 6),
                ],
                if (widget.prefixLabel != null &&
                    widget.prefixLabel!.isNotEmpty) ...[
                  Text(
                    '${widget.prefixLabel}: ',
                    style: sansStyle(c, size: 12, color: c.muted),
                  ),
                ],
                Flexible(
                  child: Text(
                    selectedItem.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sansStyle(
                      c,
                      size: 12.5,
                      weight: activeTint ? FontWeight.w600 : FontWeight.w500,
                      color: fgCol,
                    ),
                  ),
                ),
                const SizedBox(width: 3),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0.0,
                  duration: ClaudeMotion.duration(
                    context,
                    const Duration(milliseconds: 180),
                  ),
                  curve: ClaudeMotion.editorialOut,
                  child: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 15.5,
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
          final oc = ClaudePalette.of(overlayCtx);
          final targetAnc =
              _alignRight ? Alignment.bottomRight : Alignment.bottomLeft;
          final followerAnc =
              _alignRight ? Alignment.topRight : Alignment.topLeft;
          final scaleAlign =
              _alignRight ? Alignment.topRight : Alignment.topLeft;

          return Stack(
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
                offset: const Offset(0, 7),
                child: FadeTransition(
                  opacity: _animCtrl.drive(CurveTween(curve: Curves.easeOut)),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.93, end: 1.0)
                        .animate(menuCurved),
                    alignment: scaleAlign,
                    child: Material(
                      type: MaterialType.transparency,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minWidth: widget.minMenuWidth,
                          maxWidth: widget.maxMenuWidth,
                          maxHeight: 310,
                        ),
                        child: ClaudeGlassBar(
                          blurSigma: 22,
                          borderRadius: 14,
                          tintColor: oc.isDark
                              ? const Color(0xF222211E)
                              : const Color(0xF6FAF9F5),
                          padding: const EdgeInsets.all(6),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black
                                  .withValues(alpha: oc.isDark ? 0.52 : 0.16),
                              blurRadius: 26,
                              spreadRadius: 1,
                              offset: const Offset(0, 10),
                            ),
                            BoxShadow(
                              color: Colors.black
                                  .withValues(alpha: oc.isDark ? 0.28 : 0.08),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0; i < widget.items.length; i++) ...[
                                  if (i > 0) const SizedBox(height: 3),
                                  _ClaudeDropMenuTile(
                                    item: widget.items[i],
                                    selected:
                                        widget.items[i].value == widget.value,
                                    onTap: () =>
                                        _selectValue(widget.items[i].value),
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
            ],
          );
        },
        child: trigger,
      ),
    );
  }
}

class _ClaudeDropMenuTile<T> extends StatefulWidget {
  final ClaudeDropMenuItem<T> item;
  final bool selected;
  final VoidCallback onTap;

  const _ClaudeDropMenuTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_ClaudeDropMenuTile<T>> createState() => _ClaudeDropMenuTileState<T>();
}

class _ClaudeDropMenuTileState<T> extends State<_ClaudeDropMenuTile<T>> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final c = ClaudePalette.of(context);
    final sel = widget.selected;
    final bg = _pressed
        ? c.clay.withValues(alpha: c.isDark ? 0.20 : 0.14)
        : (sel
            ? c.clay.withValues(alpha: c.isDark ? 0.14 : 0.09)
            : (_hovered
                ? c.paper3.withValues(alpha: 0.92)
                : c.paper3.withValues(alpha: 0.0)));
    final border = _pressed
        ? c.clay.withValues(alpha: 0.42)
        : (sel
            ? c.clay.withValues(alpha: 0.26)
            : (_hovered ? c.ringHover : c.hairline.withValues(alpha: 0.0)));

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
        child: AnimatedScale(
          scale: _pressed ? 0.975 : 1.0,
          duration: ClaudeMotion.duration(
            context,
            _pressed
                ? const Duration(milliseconds: 75)
                : const Duration(milliseconds: 190),
          ),
          curve: _pressed ? ClaudeMotion.standard : ClaudeMotion.snappySpring,
          child: AnimatedContainer(
            duration: ClaudeMotion.duration(context, ClaudeMotion.fast),
            curve: ClaudeMotion.editorialOut,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: ShapeDecoration(
              color: bg,
              shape: claudeSuperellipse(
                10,
                side: BorderSide(color: border),
              ),
              shadows: (_hovered && !_pressed)
                  ? [
                      BoxShadow(
                        color: Colors.black
                            .withValues(alpha: c.isDark ? 0.24 : 0.06),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ]
                  : const [],
            ),
            child: Row(
              children: [
                if (widget.item.icon != null) ...[
                  Icon(
                    widget.item.icon,
                    size: 14.5,
                    color: sel || _hovered ? c.clay : c.muted,
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    widget.item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: sansStyle(
                      c,
                      size: 12.5,
                      weight: sel ? FontWeight.w600 : FontWeight.w500,
                      color: sel ? c.ink : (_hovered ? c.ink : c.inkSoft),
                    ),
                  ),
                ),
                if (widget.item.badge != null &&
                    widget.item.badge!.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  ClaudePill(
                    text: widget.item.badge!,
                    bg: sel
                        ? c.clay.withValues(alpha: 0.14)
                        : c.recessed,
                    fg: sel ? c.clay : c.muted,
                  ),
                ],
                const SizedBox(width: 6),
                SizedBox(
                  width: 15,
                  child: sel
                      ? Icon(Icons.check_rounded, size: 14.5, color: c.clay)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
