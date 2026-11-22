import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

/// Physics-backed & editorial motion primitives built on native spring physics
/// and Anthropic's calm, tactile design language.
class SpringCurve extends Curve {
  SpringCurve(SpringDescription spring, {required this.seconds})
      : _simulation = SpringSimulation(spring, 0, 1, 0);

  final double seconds;
  final SpringSimulation _simulation;
  late final double _residual = 1.0 - _simulation.x(seconds);

  @override
  double transformInternal(double t) =>
      _simulation.x(t * seconds) + _residual * t;
}

class _ThemeSwitchingScope extends InheritedWidget {
  final bool isSwitching;

  const _ThemeSwitchingScope({
    required this.isSwitching,
    required super.child,
  });

  @override
  bool updateShouldNotify(covariant _ThemeSwitchingScope oldWidget) =>
      oldWidget.isSwitching != isSwitching;
}

abstract final class ClaudeMotion {
  /// Anthropic editorial exponential deceleration (`cubic-bezier(0.16, 1, 0.3, 1)`).
  static const Curve editorialOut = Cubic(0.16, 1.0, 0.3, 1.0);

  /// Anthropic standard token (`cubic-bezier(0.2, 0, 0, 1)`).
  static const Curve standard = Cubic(0.2, 0.0, 0.0, 1.0);

  /// Clean exit curve without sluggish tail.
  static const Curve exitIn = Cubic(0.32, 0.0, 0.67, 0.0);

  /// Snappy tactile spring for sliding pills, switches, and modals.
  static final Curve snappySpring = SpringCurve(
    SpringDescription.withDampingRatio(
      mass: 1.0,
      stiffness: 330.0,
      ratio: 0.84,
    ),
    seconds: 0.38,
  );

  /// Calm, damped spring for structural reveals and panels.
  static final Curve gentleSpring = SpringCurve(
    SpringDescription.withDampingRatio(
      mass: 1.0,
      stiffness: 240.0,
      ratio: 0.90,
    ),
    seconds: 0.42,
  );

  static const Duration fast = Duration(milliseconds: 140);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration medium = Duration(milliseconds: 250);
  static const Duration modal = Duration(milliseconds: 240);
  static const Duration reveal = Duration(milliseconds: 300);

  /// Returns `Duration.zero` when system animations are disabled OR while a
  /// global theme snapshot cross-fade is active (preventing competing
  /// per-widget `AnimatedContainer` color lag underneath the theme transition).
  static Duration duration(BuildContext context, Duration d) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return Duration.zero;
    }
    final scope =
        context.dependOnInheritedWidgetOfExactType<_ThemeSwitchingScope>();
    if (scope != null && scope.isSwitching) {
      return Duration.zero;
    }
    return d;
  }
}

/// Pre-captures the outgoing frame *before* mutating `ThemeMode`, swaps all
/// underlying widget colors instantaneously in 1 pass, and cross-fades / clips
/// smoothly without `debugNeedsPaint` aborts or competing `AnimatedContainer` lag.
class ClaudeThemeCrossFade extends StatefulWidget {
  final ThemeMode themeMode;
  final Brightness platformBrightness;
  final Widget child;

  const ClaudeThemeCrossFade({
    super.key,
    required this.themeMode,
    required this.platformBrightness,
    required this.child,
  });

  /// Captures the clean outgoing frame first, then invokes [applyThemeChange]
  /// and runs a 120Hz single-pass transition.
  static Future<void> runThemeTransition(
    BuildContext context,
    VoidCallback applyThemeChange, {
    Offset? origin,
  }) async {
    final state = context.findAncestorStateOfType<_ClaudeThemeCrossFadeState>();
    if (state == null) {
      applyThemeChange();
      return;
    }
    await state._performTransition(applyThemeChange, origin: origin);
  }

  @override
  State<ClaudeThemeCrossFade> createState() => _ClaudeThemeCrossFadeState();
}

class _ClaudeThemeCrossFadeState extends State<ClaudeThemeCrossFade>
    with SingleTickerProviderStateMixin {
  final GlobalKey _repaintKey = GlobalKey();
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 440),
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _disposeSnapshot();
        if (mounted) {
          setState(() => _switching = false);
        }
      }
    });

  ui.Image? _snapshot;
  Offset? _revealOrigin;
  bool _switching = false;
  bool _busyCapturing = false;
  late Brightness _effectiveBrightness = _resolveBrightness(
    widget.themeMode,
    widget.platformBrightness,
  );

  Brightness _resolveBrightness(ThemeMode mode, Brightness platform) {
    return switch (mode) {
      ThemeMode.dark => Brightness.dark,
      ThemeMode.light => Brightness.light,
      ThemeMode.system => platform,
    };
  }

  @override
  void didUpdateWidget(covariant ClaudeThemeCrossFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextBrightness = _resolveBrightness(
      widget.themeMode,
      widget.platformBrightness,
    );
    if (nextBrightness != _effectiveBrightness) {
      _effectiveBrightness = nextBrightness;
      // Fallback for OS-initiated system brightness changes
      if (!_switching && !_busyCapturing) {
        _trySyncCapture();
      }
    }
  }

  Future<void> _performTransition(VoidCallback applyThemeChange, {Offset? origin}) async {
    if (_busyCapturing) {
      applyThemeChange();
      return;
    }
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      applyThemeChange();
      return;
    }

    _busyCapturing = true;
    ui.Image? captured;
    try {
      final boundary = _repaintKey.currentContext?.findRenderObject();
      if (boundary is RenderRepaintBoundary && boundary.hasSize) {
        final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.25);
        if (boundary.debugNeedsPaint) {
          await WidgetsBinding.instance.endOfFrame;
        }
        if (mounted && boundary.hasSize && !boundary.debugNeedsPaint) {
          captured = await boundary.toImage(pixelRatio: dpr);
        }
      }
    } catch (_) {
      captured = null;
    } finally {
      _busyCapturing = false;
    }

    if (!mounted) {
      captured?.dispose();
      return;
    }

    if (captured != null) {
      _disposeSnapshot();
      setState(() {
        _snapshot = captured;
        _revealOrigin = origin;
        _switching = true;
      });
      applyThemeChange();
      unawaited(_ctrl.forward(from: 0.0));
    } else {
      applyThemeChange();
    }
  }

  void _trySyncCapture() {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
    final boundary = _repaintKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary ||
        !boundary.hasSize ||
        boundary.debugNeedsPaint) {
      return;
    }
    try {
      final dpr = MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.25);
      final img = boundary.toImageSync(pixelRatio: dpr);
      _disposeSnapshot();
      _snapshot = img;
      _switching = true;
      unawaited(_ctrl.forward(from: 0.0));
    } catch (_) {}
  }

  void _disposeSnapshot() {
    _snapshot?.dispose();
    _snapshot = null;
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _disposeSnapshot();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ThemeSwitchingScope(
      isSwitching: _switching,
      child: Stack(
        alignment: Alignment.topLeft,
        fit: StackFit.passthrough,
        children: [
          RepaintBoundary(
            key: _repaintKey,
            child: widget.child,
          ),
          if (_snapshot != null)
            Positioned.fill(
              child: IgnorePointer(
                child: LayoutBuilder(
                  builder: (ctx, box) {
                    final size = Size(box.maxWidth, box.maxHeight);
                    final origin = _revealOrigin ?? Offset(size.width - 132, 24);
                    final maxR = [
                      origin.distance,
                      (origin - Offset(size.width, 0)).distance,
                      (origin - Offset(0, size.height)).distance,
                      (origin - Offset(size.width, size.height)).distance,
                    ].reduce(math.max);
                    return AnimatedBuilder(
                      animation: _ctrl,
                      builder: (ctx, child) {
                        final t = const Cubic(0.22, 1.0, 0.36, 1.0)
                            .transform(_ctrl.value);
                        final radius = maxR * t;
                        final ringOpacity = (1.0 - t).clamp(0.0, 1.0) * 0.55;
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipPath(
                              clipper: _CircularCutoutClipper(
                                center: origin,
                                radius: radius,
                              ),
                              child: child,
                            ),
                            CustomPaint(
                              painter: _CircularWaveRingPainter(
                                center: origin,
                                radius: radius,
                                opacity: ringOpacity,
                              ),
                            ),
                          ],
                        );
                      },
                      child: RawImage(
                        image: _snapshot,
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.medium,
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Ensures async button/action indicators stay visible for at least [minDuration]
/// so ultra-fast local operations (5–20ms) feel deliberate rather than glitchy.
Future<T> runWithMinDuration<T>(
  Future<T> Function() task, {
  Duration minDuration = const Duration(milliseconds: 520),
}) async {
  final results = await Future.wait<dynamic>([
    task(),
    Future<void>.delayed(minDuration),
  ]);
  return results[0] as T;
}

/// Keep-Alive Tab Container:
/// - Lazily mounts each tab on first visit and preserves its state, scroll
///   offset, text inputs, and expanded drawers across tab switches.
/// - Disables tickers (`TickerMode(enabled: false)`) and hit-testing on
///   inactive tabs so background tabs cost 0ms per 120Hz frame.
/// - Supports directional slide + fade (`Axis.vertical` for sidebar,
///   `Axis.horizontal` for mobile bottom dock) with a constant widget tree.
class ClaudeKeepAliveTabs extends StatefulWidget {
  final int index;
  final List<Widget> children;
  final Axis axis;

  const ClaudeKeepAliveTabs({
    super.key,
    required this.index,
    required this.children,
    this.axis = Axis.vertical,
  });

  @override
  State<ClaudeKeepAliveTabs> createState() => _ClaudeKeepAliveTabsState();
}

class _ClaudeKeepAliveTabsState extends State<ClaudeKeepAliveTabs>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1.0,
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed && _prevIndex != null) {
        if (mounted) setState(() => _prevIndex = null);
      }
    });

  late List<bool> _visited = List<bool>.generate(
    widget.children.length,
    (i) => i == widget.index,
  );
  int? _prevIndex;
  int _direction = 1;

  @override
  void didUpdateWidget(covariant ClaudeKeepAliveTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_visited.length != widget.children.length) {
      final nextVisited = List<bool>.filled(widget.children.length, false);
      for (var i = 0;
          i < math.min(_visited.length, nextVisited.length);
          i++) {
        nextVisited[i] = _visited[i];
      }
      if (widget.index >= 0 && widget.index < nextVisited.length) {
        nextVisited[widget.index] = true;
      }
      _visited = nextVisited;
    }
    if (widget.index != oldWidget.index) {
      if (widget.index >= 0 && widget.index < _visited.length) {
        _visited[widget.index] = true;
      }
      _direction = widget.index > oldWidget.index ? 1 : -1;
      final d = ClaudeMotion.duration(
        context,
        const Duration(milliseconds: 220),
      );
      if (d == Duration.zero) {
        _prevIndex = null;
        _ctrl.value = 1.0;
      } else {
        _prevIndex = oldWidget.index;
        _ctrl.duration = d;
        unawaited(_ctrl.forward(from: 0.0));
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: Stack(
        alignment: Alignment.topLeft,
        fit: StackFit.expand,
        children: [
          for (var i = 0; i < widget.children.length; i++)
            if (_visited[i])
              _KeepAliveTabLayer(
                key: ValueKey<int>(i),
                animation: _ctrl,
                isActive: i == widget.index,
                isOutgoing: i == _prevIndex,
                direction: _direction,
                axis: widget.axis,
                child: RepaintBoundary(child: widget.children[i]),
              ),
        ],
      ),
    );
  }
}

class _KeepAliveTabLayer extends StatelessWidget {
  final Animation<double> animation;
  final bool isActive;
  final bool isOutgoing;
  final int direction;
  final Axis axis;
  final Widget child;

  const _KeepAliveTabLayer({
    super.key,
    required this.animation,
    required this.isActive,
    required this.isOutgoing,
    required this.direction,
    required this.axis,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final visible = isActive || isOutgoing;
    return Offstage(
      offstage: !visible,
      child: TickerMode(
        enabled: isActive,
        child: IgnorePointer(
          ignoring: !isActive,
          child: AnimatedBuilder(
            animation: animation,
            builder: (ctx, innerChild) {
              double opacity;
              double shift = 0.0;
              if (isActive) {
                final t = animation.isCompleted
                    ? 1.0
                    : ClaudeMotion.editorialOut
                        .transform(animation.value)
                        .clamp(0.0, 1.0);
                opacity = t;
                shift = (1.0 - t) * 0.032 * direction;
              } else if (isOutgoing) {
                final raw = (animation.value / 0.65).clamp(0.0, 1.0);
                final outT = Curves.easeOutCubic.transform(raw);
                opacity = animation.isCompleted
                    ? 0.0
                    : (1.0 - outT).clamp(0.0, 1.0);
                shift = -outT * 0.022 * direction;
              } else {
                opacity = 0.0;
              }
              final offset = axis == Axis.horizontal
                  ? Offset(shift, 0)
                  : Offset(0, shift);
              return FractionalTranslation(
                translation: offset,
                child: Opacity(
                  opacity: opacity,
                  child: innerChild,
                ),
              );
            },
            child: RepaintBoundary(child: child),
          ),
        ),
      ),
    );
  }
}

/// Legacy single-child wrapper preserved for compatibility.
class ClaudePageSwitcher extends StatelessWidget {
  final int index;
  final Widget child;

  const ClaudePageSwitcher({
    super.key,
    required this.index,
    required this.child,
  });

  @override
  Widget build(BuildContext context) => child;
}

/// Pass-through reveal container: page-level transitions are handled once by
/// [ClaudeKeepAliveTabs] so inner sections never double-flash on tab switch.
class ClaudeStaggeredReveal extends StatelessWidget {
  final int index;
  final Widget child;
  final double offsetY;

  const ClaudeStaggeredReveal({
    super.key,
    required this.index,
    required this.child,
    this.offsetY = 8.0,
  });

  @override
  Widget build(BuildContext context) => child;
}

/// High-frame-rate accordion drawer that unmounts hidden subtrees once closed.
class ClaudeCollapsible extends StatefulWidget {
  final bool expanded;
  final WidgetBuilder builder;
  final Duration duration;

  const ClaudeCollapsible({
    super.key,
    required this.expanded,
    required this.builder,
    this.duration = const Duration(milliseconds: 220),
  });

  @override
  State<ClaudeCollapsible> createState() => _ClaudeCollapsibleState();
}

class _ClaudeCollapsibleState extends State<ClaudeCollapsible>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.expanded ? 1.0 : 0.0,
  )..addStatusListener((_) {
      if (mounted) setState(() {});
    });

  @override
  void didUpdateWidget(covariant ClaudeCollapsible oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      final d = ClaudeMotion.duration(context, widget.duration);
      _ctrl.duration = d;
      if (d == Duration.zero) {
        _ctrl.value = widget.expanded ? 1.0 : 0.0;
      } else if (widget.expanded) {
        unawaited(_ctrl.forward());
      } else {
        unawaited(_ctrl.reverse());
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.expanded && _ctrl.isDismissed) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (ctx, child) {
        final t = widget.expanded
            ? ClaudeMotion.editorialOut.transform(_ctrl.value)
            : Curves.easeInCubic.transform(_ctrl.value);
        return ClipRect(
          child: Align(
            alignment: Alignment.topLeft,
            heightFactor: t.clamp(0.0, 1.0),
            child: Opacity(
              opacity: t.clamp(0.0, 1.0),
              child: child,
            ),
          ),
        );
      },
      child: widget.builder(context),
    );
  }
}

/// Pure opacity cross-fade without scale wobble, preventing subpixel text jitter.
class ClaudeFadeBox extends StatelessWidget {
  final Widget child;
  final AlignmentGeometry alignment;
  final Duration duration;

  const ClaudeFadeBox({
    super.key,
    required this.child,
    this.alignment = Alignment.centerLeft,
    this.duration = const Duration(milliseconds: 150),
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: ClaudeMotion.duration(context, duration),
      switchInCurve: ClaudeMotion.editorialOut,
      switchOutCurve: Curves.easeOut,
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        children: [
          ...previous,
          if (current != null) current,
        ],
      ),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: child,
      ),
      child: child,
    );
  }
}

/// Zero-layout-shift Status Dot:
/// - Always occupies a constant `size + 8` square box whether pulsing or idle
///   (eliminating the 8dp row jump when services or tunnels toggle!).
/// - Isolated inside its own `RepaintBoundary` + `CustomPaint` so breathing
///   ripples never dirty ancestor layouts or list cards.
/// Global shared 120Hz phase clock driving all pulsing [ClaudeStatusDot]s from
/// a single synchronized [Ticker], automatically stopping and disposing the
/// ticker when zero pulsing dots are mounted or when the window is minimized/hidden.
class ClaudePulseClock extends ChangeNotifier implements ValueListenable<double> {
  static final ClaudePulseClock instance = ClaudePulseClock._();
  ClaudePulseClock._();

  static const int _periodUs = 2200000;
  Ticker? _ticker;
  int _subscribers = 0;
  bool _paused = false;
  double _phase = 0.0;

  @override
  double get value => _phase;

  int get activeSubscriberCount => _subscribers;
  bool get isPaused => _paused;
  bool get isTickerRunning => _ticker != null && _ticker!.isActive;

  void subscribe() {
    _subscribers++;
    _syncTicker();
  }

  void unsubscribe() {
    if (_subscribers > 0) _subscribers--;
    _syncTicker();
  }

  void setPaused(bool paused) {
    if (_paused == paused) return;
    _paused = paused;
    _syncTicker();
  }

  void _onTick(Duration elapsed) {
    _phase = (elapsed.inMicroseconds % _periodUs) / _periodUs;
    notifyListeners();
  }

  void _syncTicker() {
    final shouldRun = _subscribers > 0 && !_paused;
    if (shouldRun) {
      if (_ticker == null) {
        _ticker = Ticker(_onTick)..start();
      } else if (!_ticker!.isActive) {
        _ticker!.start();
      }
    } else {
      if (_ticker != null) {
        _ticker!.stop();
        _ticker!.dispose();
        _ticker = null;
      }
      _phase = 0.0;
    }
  }
}

class ClaudeStatusDot extends StatefulWidget {
  final Color color;
  final bool pulsing;
  final double size;

  const ClaudeStatusDot({
    super.key,
    required this.color,
    this.pulsing = false,
    this.size = 8.0,
  });

  @override
  State<ClaudeStatusDot> createState() => _ClaudeStatusDotState();
}

class _ClaudeStatusDotState extends State<ClaudeStatusDot> {
  bool _subscribed = false;

  void _updateSubscription(bool wantPulse) {
    if (wantPulse && !_subscribed) {
      _subscribed = true;
      ClaudePulseClock.instance.subscribe();
    } else if (!wantPulse && _subscribed) {
      _subscribed = false;
      ClaudePulseClock.instance.unsubscribe();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _updateSubscription(widget.pulsing && !reducedMotion);
  }

  @override
  void didUpdateWidget(covariant ClaudeStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    final reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _updateSubscription(widget.pulsing && !reducedMotion);
  }

  @override
  void dispose() {
    _updateSubscription(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final boxExtent = widget.size + 8.0;
    final reducedMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final effectivePulsing = widget.pulsing && !reducedMotion;
    return RepaintBoundary(
      child: SizedBox(
        width: boxExtent,
        height: boxExtent,
        child: CustomPaint(
          painter: _StatusDotPainter(
            phaseListenable:
                effectivePulsing ? ClaudePulseClock.instance : null,
            color: widget.color,
            dotSize: widget.size,
            pulsing: effectivePulsing,
          ),
        ),
      ),
    );
  }
}

class _StatusDotPainter extends CustomPainter {
  final ValueListenable<double>? phaseListenable;
  final Color color;
  final double dotSize;
  final bool pulsing;

  _StatusDotPainter({
    required this.phaseListenable,
    required this.color,
    required this.dotSize,
    required this.pulsing,
  }) : super(repaint: phaseListenable);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    if (pulsing && phaseListenable != null) {
      final wave = Curves.easeOutCubic.transform(phaseListenable!.value);
      final haloRadius = (dotSize + 8.0 * wave) / 2.0;
      final haloPaint = Paint()
        ..color = color.withValues(alpha: (1.0 - wave) * 0.28)
        ..style = PaintingStyle.fill
        ..isAntiAlias = true;
      canvas.drawCircle(center, haloRadius, haloPaint);
    }

    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.drawCircle(center, dotSize / 2.0, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _StatusDotPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.dotSize != dotSize ||
      oldDelegate.pulsing != pulsing;
}


class _CircularCutoutClipper extends CustomClipper<Path> {
  final Offset center;
  final double radius;

  const _CircularCutoutClipper({required this.center, required this.radius});

  @override
  Path getClip(Size size) {
    final outer = Path()..addRect(Offset.zero & size);
    if (radius <= 0.5) return outer;
    final hole = Path()
      ..addOval(Rect.fromCircle(center: center, radius: radius));
    return Path.combine(PathOperation.difference, outer, hole);
  }

  @override
  bool shouldReclip(covariant _CircularCutoutClipper oldClipper) =>
      oldClipper.radius != radius || oldClipper.center != center;
}

class _CircularWaveRingPainter extends CustomPainter {
  final Offset center;
  final double radius;
  final double opacity;

  const _CircularWaveRingPainter({
    required this.center,
    required this.radius,
    required this.opacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (radius <= 1.0 || opacity <= 0.01) return;
    final paint = Paint()
      ..color = Color.fromRGBO(129, 140, 248, opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant _CircularWaveRingPainter oldDelegate) =>
      oldDelegate.radius != radius || oldDelegate.opacity != opacity;
}

/// Top-left-pinned directional Shared-Axis switcher (Linear / Material Shared Axis).
///
/// Unlike Flutter's default [AnimatedSwitcher], which centers outgoing/incoming
/// children in a [Stack] and causes shorter sub-pages inside a scroll view to
/// float in the middle and snap to `y = 0` on completion, [ClaudeSharedAxisSwitcher]
/// pins outgoing children via [Positioned] at `top: 0, left: 0, right: 0` so:
/// 1. Intrinsic layout height immediately matches the incoming child (zero snap).
/// 2. Outgoing content exits quickly (~85ms) before incoming glides into place,
///    eliminating muddy 50/50 text overlap.
class ClaudeSharedAxisSwitcher extends StatefulWidget {
  final Widget child;
  final Axis axis;
  final bool reverse;
  final Duration duration;
  final double distance;

  const ClaudeSharedAxisSwitcher({
    super.key,
    required this.child,
    this.axis = Axis.vertical,
    this.reverse = false,
    this.duration = const Duration(milliseconds: 220),
    this.distance = 14.0,
  });

  @override
  State<ClaudeSharedAxisSwitcher> createState() =>
      _ClaudeSharedAxisSwitcherState();
}

class _ClaudeSharedAxisSwitcherState extends State<ClaudeSharedAxisSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1.0,
  )..addStatusListener((status) {
      if (status == AnimationStatus.completed && _outgoingChild != null) {
        setState(() => _outgoingChild = null);
      }
    });

  late Widget _currentChild = widget.child;
  Widget? _outgoingChild;
  bool _reverse = false;

  @override
  void didUpdateWidget(covariant ClaudeSharedAxisSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _ctrl.duration = widget.duration;
    }
    if (widget.child.key != _currentChild.key) {
      final effectiveDur = ClaudeMotion.duration(context, widget.duration);
      if (effectiveDur == Duration.zero) {
        _outgoingChild = null;
        _currentChild = widget.child;
        _ctrl.value = 1.0;
        return;
      }
      _outgoingChild = _currentChild;
      _currentChild = widget.child;
      _reverse = widget.reverse;
      _ctrl.duration = effectiveDur;
      _ctrl.forward(from: 0.0);
    } else {
      _currentChild = widget.child;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Offset _axisOffset(double delta) =>
      widget.axis == Axis.vertical ? Offset(0, delta) : Offset(delta, 0);

  @override
  Widget build(BuildContext context) {
    if (_outgoingChild == null || !_ctrl.isAnimating) {
      return _currentChild;
    }

    final sign = _reverse ? -1.0 : 1.0;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _ctrl.value.clamp(0.0, 1.0);
        // Fast outgoing fade (0.0 -> 0.36) so text never ghosts over incoming
        final outProgress = (t / 0.36).clamp(0.0, 1.0);
        final outOpacity = 1.0 - Curves.easeInCubic.transform(outProgress);
        final outShift =
            -sign * widget.distance * 0.45 * Curves.easeIn.transform(outProgress);

        // Smooth incoming glide (0.08 -> 1.0) with editorial deceleration
        final inRaw = ((t - 0.08) / 0.92).clamp(0.0, 1.0);
        final inCurve = ClaudeMotion.editorialOut.transform(inRaw);
        final inOpacity = ((t - 0.06) / 0.68).clamp(0.0, 1.0);
        final inShift = sign * widget.distance * (1.0 - inCurve);

        return Stack(
          alignment: Alignment.topLeft,
          clipBehavior: Clip.none,
          children: [
            if (outOpacity > 0.01 && _outgoingChild != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: outOpacity,
                    child: Transform.translate(
                      offset: _axisOffset(outShift),
                      child: _outgoingChild,
                    ),
                  ),
                ),
              ),
            Opacity(
              opacity: Curves.easeOut.transform(inOpacity),
              child: Transform.translate(
                offset: _axisOffset(inShift),
                child: _currentChild,
              ),
            ),
          ],
        );
      },
    );
  }
}
