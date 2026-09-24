import 'dart:async' show Completer;

import 'package:PiliPlus/common/widgets/main_layout.dart';
import 'package:get/get.dart' show GetPageRoute;
import 'package:material_ui/material_ui.dart';

const double _cardRadius = 12;

const double _scrimOpacity = 0.35;

const double _cardLayerOpenHoldUntil = 0.10;
const double _cardLayerOpenFadeEnd = 0.46;
const Curve _cardLayerOpenFadeCurve = Interval(
  _cardLayerOpenHoldUntil,
  _cardLayerOpenFadeEnd,
  curve: Curves.easeOutCubic,
);

const double _cardLayerPortraitOpenHoldUntil = 0.08;
const double _cardLayerPortraitOpenFadeEnd = 0.46;
const Curve _cardLayerPortraitOpenFadeCurve = Interval(
  _cardLayerPortraitOpenHoldUntil,
  _cardLayerPortraitOpenFadeEnd,
  curve: Curves.easeOutCubic,
);

const double _cardLayerCloseHoldUntil = 0.22;
const double _cardLayerCloseFadeEnd = 0.66;
const Curve _cardLayerCloseFadeCurve = Interval(
  _cardLayerCloseHoldUntil,
  _cardLayerCloseFadeEnd,
  curve: Curves.easeOutCubic,
);

const double _portraitFlightExtent = 0.25;

const double _horizontalAspect = 1.35;

bool _isHorizontalFlight(Size card, Size viewport) =>
    card.width >= card.height * _horizontalAspect ||
    viewport.width > viewport.height;

const double _veilFadeEnd = 0.70;
const Curve _veilFadeCurve = Interval(
  0,
  _veilFadeEnd,
  curve: Curves.easeInOut,
);

const double _portraitVeilFadeEnd = 0.50;
const Curve _portraitVeilFadeCurve = Interval(
  0,
  _portraitVeilFadeEnd,
  curve: Curves.easeInOut,
);

const Curve _openCurve = Cubic(0.22, 0.77, 0.08, 1.0);

const Curve _openPortraitCurve = Cubic(0.28, 0.70, 0.12, 1.0);

Curve _openCurveFor(bool horizontal) =>
    horizontal ? _openCurve : _openPortraitCurve;

const Curve _closeCurve = Cubic(0.54, 0.15, 0.68, 0.88);

const double _entryContentReadyAt = 0.88;

const Duration videoPageTransitionDuration = Duration(milliseconds: 350);
const Duration videoPageReverseTransitionDuration = Duration(milliseconds: 280);

const bool _scalePageContent = true;

const double _paintEpsilon = 0.02;

const bool _freezePageWhileFlying = true;

typedef _PendingVideoTransition = ({
  Object tag,
  RenderBox box,
  BuildContext context,
});

_PendingVideoTransition? _pendingVideoTransition;
final _enteringVideoPages = <Object, Completer<bool>>{};

Future<bool> waitForVideoPageEntry(Object? tag) async {
  final entry = _enteringVideoPages[tag];
  if (entry == null) return true;
  return entry.future.timeout(
    const Duration(milliseconds: 1200),
    onTimeout: () => true,
  );
}

Color transitionBackgroundOf(BuildContext context) {
  Color? result;
  context.visitAncestorElements((element) {
    final widget = element.widget;
    final Color? color = switch (widget) {
      Material(:final type, :final color)
          when type != MaterialType.transparency =>
        color ?? Theme.of(element).canvasColor,
      ColoredBox(:final color) => color,
      DecoratedBox(decoration: BoxDecoration(:final color)) => color,
      _ => null,
    };
    if (color != null && color.a == 1) {
      result = color;
      return false;
    }
    return true;
  });
  return result ?? Theme.of(context).scaffoldBackgroundColor;
}

bool hasPendingVideoCardTransition(Object tag) =>
    _pendingVideoTransition?.tag == tag;

void _prepareVideoTransition(Object tag, BuildContext context) {
  final box = context.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    _pendingVideoTransition = (tag: tag, box: box, context: context);
  }
}

class _VideoCardRectTween extends RectTween {
  _VideoCardRectTween({
    required super.begin,
    required super.end,
    this.returning = false,
    this.openCurve = _openCurve,
  });
  final bool returning;

  final Curve openCurve;

  @override
  Rect? lerp(double t) => returning
      ? Rect.lerp(begin, end, _closeCurve.transform(t))
      : Rect.lerp(begin, end, openCurve.transform(t));
}

class VideoPageTransitionRoute<T> extends GetPageRoute<T> {
  VideoPageTransitionRoute({required WidgetBuilder builder, super.settings})
    : super(page: () => Builder(builder: builder));

  bool _gestureCommitted = false;
  AnimationStatusListener? _gestureCompletion;
  final _entryReady = Completer<bool>();
  Object? get _entryTag => (settings.arguments as Map?)?['heroTag'];

  @override
  void install() {
    super.install();
    if (_entryTag case final tag?) _enteringVideoPages[tag] = _entryReady;
    controller
      ?..addStatusListener(_entryStatus)
      ..addListener(_entryProgress);
  }

  void _entryProgress() {
    final animationController = controller;
    if (animationController?.status == AnimationStatus.forward &&
        animationController!.value >= _entryContentReadyAt) {
      _finishEntry(true);
    }
  }

  void _entryStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _finishEntry(true);
  }

  void _finishEntry(bool entered) {
    if (!_entryReady.isCompleted) _entryReady.complete(entered);
  }

  @override
  bool didPop(T? result) {
    final popped = super.didPop(result);
    if (popped) _finishEntry(false);
    return popped;
  }

  @override
  void handleStartBackGesture({double progress = 0.0}) {
    _gestureCommitted = false;
    super.handleStartBackGesture(progress: progress);
  }

  @override
  void handleCommitBackGesture() {
    if (_gestureCommitted || !popGestureInProgress) return;
    _gestureCommitted = true;
    final owner = navigator;
    if (isCurrent) owner?.pop();
    final animationController = controller;
    void finish() {
      if (_gestureCompletion case final listener?) {
        animationController?.removeStatusListener(listener);
        _gestureCompletion = null;
      }
      if (owner?.userGestureInProgress == true) owner!.didStopUserGesture();
    }

    if (animationController?.isAnimating ?? false) {
      _gestureCompletion = (status) {
        if (status == AnimationStatus.dismissed ||
            status == AnimationStatus.completed) {
          finish();
        }
      };
      animationController!.addStatusListener(_gestureCompletion!);
    } else {
      finish();
    }
  }

  @override
  void dispose() {
    _finishEntry(false);
    controller
      ?..removeStatusListener(_entryStatus)
      ..removeListener(_entryProgress);
    if (identical(_enteringVideoPages[_entryTag], _entryReady)) {
      _enteringVideoPages.remove(_entryTag);
    }
    if (_gestureCompletion case final listener?) {
      controller?.removeStatusListener(listener);
    }
    super.dispose();
  }

  @override
  Duration get transitionDuration => videoPageTransitionDuration;

  @override
  Duration get reverseTransitionDuration => videoPageReverseTransitionDuration;

  @override
  DelegatedTransitionBuilder? get delegatedTransition => null;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

class VideoCardHero extends StatefulWidget {
  const VideoCardHero({
    super.key,
    required this.tag,
    required this.surfaceColor,
    required this.child,
    this.preserveChildHeroes = false,
    this.coverKey,
    this.cornerRadius = _cardRadius,
  });

  final Object tag;

  final Color surfaceColor;
  final Widget child;
  final bool preserveChildHeroes;

  final GlobalKey? coverKey;

  final double cornerRadius;

  @override
  State<VideoCardHero> createState() => _VideoCardHeroState();
}

class _VideoCardHeroState extends State<VideoCardHero> {
  Rect? _coverRect;

  @override
  Widget build(BuildContext context) {
    final hero = Hero(
      tag: widget.tag,
      curve: Curves.linear,
      reverseCurve: Curves.linear,
      transitionOnUserGestures: true,
      createRectTween: (begin, end) =>
          _VideoCardRectTween(begin: begin, end: end, returning: true),
      flightShuttleBuilder: _buildFlightShuttle,
      child: _CardSurface(
        radius: widget.cornerRadius,
        cardColor: widget.surfaceColor,
        coverReader: () => _coverRect,
        flightChild: widget.preserveChildHeroes ? widget.child : null,
        child: widget.preserveChildHeroes
            ? const SizedBox.expand()
            : widget.child,
      ),
    );
    return Listener(
      onPointerDown: (_) => _prepare(context),
      child: widget.preserveChildHeroes
          ? Stack(
              children: [
                widget.child,
                Positioned.fill(child: IgnorePointer(child: hero)),
              ],
            )
          : hero,
    );
  }

  void _prepare(BuildContext context) {
    _coverRect = _measureCover(context);
    _prepareVideoTransition(widget.tag, context);
  }

  Rect? _measureCover(BuildContext cardContext) {
    final key = widget.coverKey;
    if (key == null) return null;
    final cardBox = cardContext.findRenderObject();
    final coverBox = key.currentContext?.findRenderObject();
    if (cardBox is! RenderBox ||
        coverBox is! RenderBox ||
        !cardBox.hasSize ||
        !coverBox.hasSize) {
      return null;
    }
    final cardOrigin = cardBox.localToGlobal(Offset.zero);
    final rect = coverBox.localToGlobal(Offset.zero) - cardOrigin & coverBox.size;
    return rect.isEmpty ? null : rect;
  }
}

class VideoPageHeroTarget extends StatefulWidget {
  const VideoPageHeroTarget({
    super.key,
    required this.tag,
    required this.surfaceColor,
    required this.child,
  });

  final Object tag;
  final Color surfaceColor;
  final Widget child;

  @override
  State<VideoPageHeroTarget> createState() => _VideoPageHeroTargetState();
}

class _VideoPageHeroTargetState extends State<VideoPageHeroTarget> {
  ModalRoute<dynamic>? _route;
  Animation<double>? _routeAnimation;
  RenderBox? _sourceBox;
  Rect? _sourceRect;
  bool _entryCompleted = false;

  @override
  void initState() {
    super.initState();
    if (hasPendingVideoCardTransition(widget.tag)) {
      _sourceBox = _pendingVideoTransition!.box;
      _sourceRect = _sourceBox!.localToGlobal(Offset.zero) & _sourceBox!.size;
      _pendingVideoTransition = null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_sourceRect == null) return;
    _route = ModalRoute.of(context);
    final animation = _route?.animation;
    if (identical(animation, _routeAnimation)) return;
    _routeAnimation?.removeStatusListener(_handleAnimationStatus);
    _routeAnimation = animation;
    animation?.addStatusListener(_handleAnimationStatus);
    if (animation != null) _handleAnimationStatus(animation.status);
  }

  void _handleAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _route?.offstage == false) {
      _entryCompleted = true;
    }
    final box = _sourceBox;
    if (status == AnimationStatus.reverse &&
        box != null &&
        box.attached &&
        box.hasSize) {
      _sourceRect = box.localToGlobal(Offset.zero) & box.size;
    }
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_handleAnimationStatus);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animation = _routeAnimation;
    if (_sourceRect == null || animation == null) return widget.child;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final viewport = Offset.zero & size;
        final pageContent = SizedBox.fromSize(
          size: size,
          child: RepaintBoundary(child: widget.child),
        );
        return AnimatedBuilder(
          animation: animation,
          child: pageContent,
          builder: (context, child) {
            final reversing =
                animation.status == AnimationStatus.reverse ||
                (_route?.popGestureInProgress ?? false);
            final returning = reversing && _entryCompleted;
            final box = context.findRenderObject();
            final origin = box is RenderBox && box.hasSize
                ? box.localToGlobal(Offset.zero)
                : Offset.zero;
            final source = _sourceRect!.shift(-origin);
            final horizontal = _isHorizontalFlight(_sourceRect!.size, size);
            final openCurve = _openCurveFor(horizontal);
            final expansion = openCurve.transform(animation.value);
            final contraction = _closeCurve.transform(
              1 - animation.value,
            );
            final pageRect = returning
                ? Rect.lerp(viewport, source, contraction)!
                : Rect.lerp(source, viewport, expansion)!;
            final scrimAlpha = _scrimOpacity * expansion;
            final ticking =
                !_freezePageWhileFlying ||
                animation.status == AnimationStatus.completed;
            final pageContentChild = TickerMode(
              enabled: ticking,
              child: child!,
            );
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  key: const ValueKey('video-transition-scrim'),
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: scrimAlpha > _paintEpsilon
                          ? _ScrimPainter(
                              rect: pageRect,
                              color: Colors.black.withValues(alpha: scrimAlpha),
                            )
                          : null,
                    ),
                  ),
                ),
                Positioned.fromRect(
                  key: const ValueKey('video-transition-page-position'),
                  rect: pageRect,
                  child: ClipRRect(
                    key: const ValueKey('video-transition-page-container'),
                    borderRadius: const BorderRadius.all(
                      Radius.circular(_cardRadius),
                    ),
                    child: _scalePageContent
                        ? FittedBox(
                            fit: BoxFit.cover,
                            alignment: Alignment.topCenter,
                            child: pageContentChild,
                          )
                        : OverflowBox(
                            alignment: Alignment.topCenter,
                            minWidth: 0,
                            minHeight: 0,
                            maxWidth: double.infinity,
                            maxHeight: double.infinity,
                            child: pageContentChild,
                          ),
                  ),
                ),
                Positioned.fill(
                  key: const ValueKey('video-transition-hero-position'),
                  child: IgnorePointer(
                    child: Hero(
                      tag: widget.tag,
                      curve: Curves.linear,
                      reverseCurve: Curves.linear,
                      transitionOnUserGestures: true,
                      createRectTween: (begin, end) => _VideoCardRectTween(
                        begin: begin,
                        end: end,
                        openCurve: openCurve,
                      ),
                      flightShuttleBuilder: _buildFlightShuttle,
                      child: const _VideoPageSurface(),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

class _VideoPageSurface extends StatelessWidget {
  const _VideoPageSurface();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _ScrimPainter extends CustomPainter {
  const _ScrimPainter({required this.rect, required this.color});

  final Rect rect;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final width = size.width;
    final height = size.height;
    final left = _clamp(rect.left - _cardRadius, 0, width);
    final right = _clamp(rect.right + _cardRadius, 0, width);
    final top = _clamp(rect.top - _cardRadius, 0, height);
    final bottom = _clamp(rect.bottom + _cardRadius, 0, height);
    if (right <= left || bottom <= top) {
      canvas.drawRect(Offset.zero & size, paint);
      return;
    }
    if (top > 0) {
      canvas.drawRect(Rect.fromLTRB(0, 0, width, top), paint);
    }
    if (bottom < height) {
      canvas.drawRect(Rect.fromLTRB(0, bottom, width, height), paint);
    }
    if (left > 0) {
      canvas.drawRect(Rect.fromLTRB(0, top, left, bottom), paint);
    }
    if (right < width) {
      canvas.drawRect(Rect.fromLTRB(right, top, width, bottom), paint);
    }
  }

  static double _clamp(double value, double min, double max) =>
      value < min ? min : (value > max ? max : value);

  @override
  bool shouldRepaint(_ScrimPainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.color != color;
}

class _CardSurface extends StatelessWidget {
  const _CardSurface({
    required this.child,
    required this.cardColor,
    this.flightChild,
    this.radius = _cardRadius,
    this.coverReader,
  });

  final Widget child;
  final Widget? flightChild;
  final double radius;

  final Color cardColor;

  final ValueGetter<Rect?>? coverReader;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.all(Radius.circular(radius)),
    child: child,
  );
}

class _NavShape {
  const _NavShape(this.rect, this.radius);

  final Rect rect;

  final double radius;

  _NavShape shift(Offset delta) => _NavShape(rect.shift(delta), radius);
}

const double _navCutInflate = 2;

_NavShape? _bottomNavShape(BuildContext context) {
  RenderBox? navBox;
  double? layoutWidth;
  context.visitAncestorElements((element) {
    if (element.widget is! MainLayout) return true;
    final renderObject = element.renderObject;
    if (renderObject is SlottedContainerRenderObjectMixin<MainType, RenderBox>) {
      final RenderObject? layoutBox = renderObject;
      if (layoutBox is RenderBox && layoutBox.hasSize) {
        layoutWidth = layoutBox.size.width;
      }
      final nav = renderObject.childForSlot(MainType.bottomNav);
      if (nav != null && nav.attached && nav.hasSize) {
        navBox = nav;
      }
    }
    return false;
  });
  final box = navBox;
  if (box == null) return null;

  var rect = box.localToGlobal(Offset.zero) & box.size;
  final width = layoutWidth;
  final floating = width != null && rect.width < width - 0.5;
  if (floating) {
    rect = _visualBarRect(box, rect);
  }
  return _NavShape(
    rect.inflate(_navCutInflate),
    floating ? rect.height / 2 : 0.0,
  );
}

Rect _visualBarRect(RenderBox box, Rect rect) {
  var current = box;
  for (var depth = 0; depth < 4; depth++) {
    RenderBox? only;
    var count = 0;
    current.visitChildren((child) {
      count++;
      if (child is RenderBox) only = child;
    });
    final child = only;
    if (count != 1 || child == null || !child.attached || !child.hasSize) break;
    final childRect = child.localToGlobal(Offset.zero) & child.size;
    final shrunk =
        childRect.width < rect.width - 0.5 ||
        childRect.height < rect.height - 0.5;
    final grew =
        childRect.width > rect.width + 0.5 ||
        childRect.height > rect.height + 0.5;
    if (!shrunk || grew) break;
    rect = childRect;
    current = child;
  }
  return rect;
}

Widget _buildFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final returning = direction == HeroFlightDirection.pop;
  final cardContext = returning ? toHeroContext : fromHeroContext;
  final pageContext = returning ? fromHeroContext : toHeroContext;
  final cardHero = cardContext.widget;
  if (cardHero is! Hero || cardHero.child is! _CardSurface) {
    return const SizedBox.shrink();
  }
  final cardSurface = cardHero.child as _CardSurface;
  final cardBox = cardContext.findRenderObject();
  final pageBox = pageContext.findRenderObject();
  if (cardBox is! RenderBox || !cardBox.hasSize || cardBox.size.isEmpty) {
    return const SizedBox.shrink();
  }
  if (pageBox is! RenderBox || !pageBox.hasSize || pageBox.size.isEmpty) {
    return const SizedBox.shrink();
  }
  final bottomNav = returning ? _bottomNavShape(cardContext) : null;
  return _FlightCardLayer(
    animation: ModalRoute.of(pageContext)?.animation ?? animation,
    flightContext: flightContext,
    returning: returning,
    cardRect: cardBox.localToGlobal(Offset.zero) & cardBox.size,
    viewportRect: pageBox.localToGlobal(Offset.zero) & pageBox.size,
    bottomNav: bottomNav,
    cardColor: cardSurface.cardColor,
    radius: cardSurface.radius,
    card: InheritedTheme.captureAll(
      cardContext,
      Material(
        type: MaterialType.transparency,
        child: RepaintBoundary(
          child: SizedBox.fromSize(
            size: cardBox.size,
            child: cardSurface.flightChild ?? cardSurface.child,
          ),
        ),
      ),
    ),
  );
}

class _FlightCardLayer extends StatefulWidget {
  const _FlightCardLayer({
    required this.animation,
    required this.flightContext,
    required this.returning,
    required this.cardRect,
    required this.viewportRect,
    this.bottomNav,
    required this.cardColor,
    required this.radius,
    required this.card,
  });

  final Animation<double> animation;
  final BuildContext flightContext;

  final bool returning;

  final Rect cardRect;

  final Rect viewportRect;

  final _NavShape? bottomNav;

  final Color cardColor;

  final double radius;

  final Widget card;

  @override
  State<_FlightCardLayer> createState() => _FlightCardLayerState();
}

class _FlightCardLayerState extends State<_FlightCardLayer> {
  late final BorderRadius _radius = BorderRadius.all(
    Radius.circular(widget.radius),
  );

  bool _measured = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _measured = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.animation,
      child: widget.card,
      builder: (context, child) {
        final progress = widget.animation.value;
        final horizontal = _isHorizontalFlight(
          widget.cardRect.size,
          widget.viewportRect.size,
        );
        final fadeCurve = widget.returning
            ? _cardLayerCloseFadeCurve
            : (horizontal
                  ? _cardLayerOpenFadeCurve
                  : _cardLayerPortraitOpenFadeCurve);
        final veilFadeCurve = horizontal
            ? _veilFadeCurve
            : _portraitVeilFadeCurve;
        final cardAlpha = 1 - fadeCurve.transform(progress);
        final veilAlpha = widget.returning
            ? 0.0
            : 1 - veilFadeCurve.transform(progress);
        if (!_measured ||
            (cardAlpha <= _paintEpsilon && veilAlpha <= _paintEpsilon)) {
          return const SizedBox.shrink();
        }
        final openProgress = _openCurveFor(horizontal).transform(progress);
        final flightProgress = horizontal
            ? openProgress
            : openProgress * _portraitFlightExtent;
        final rect = widget.returning
            ? Rect.lerp(
                widget.viewportRect,
                widget.cardRect,
                _closeCurve.transform(1 - progress),
              )!
            : Rect.lerp(widget.cardRect, widget.viewportRect, flightProgress)!;
        final box = widget.flightContext.findRenderObject();
        final flightOrigin = box is RenderBox && box.hasSize
            ? box.localToGlobal(Offset.zero)
            : Offset.zero;
        final localRect = rect.shift(-flightOrigin);
        final scale = rect.width / widget.cardRect.width;
        final nav = widget.bottomNav?.shift(-flightOrigin);
        final content = Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            Positioned.fromRect(
              key: const ValueKey('video-transition-card-layer'),
              rect: localRect,
              child: ClipRRect(
                borderRadius: _radius,
                child: Stack(
                  fit: StackFit.expand,
                  clipBehavior: Clip.none,
                  children: [
                    if (veilAlpha > _paintEpsilon)
                      Positioned.fill(
                        key: const ValueKey('video-transition-card-veil'),
                        child: IgnorePointer(
                          child: ColoredBox(
                            color: widget.cardColor.withValues(
                              alpha: veilAlpha,
                            ),
                          ),
                        ),
                      ),
                    if (cardAlpha > _paintEpsilon)
                      Positioned.fill(
                        child: Opacity(
                          opacity: cardAlpha,
                          child: ColoredBox(
                            color: widget.cardColor,
                            child: OverflowBox(
                              alignment: Alignment.topLeft,
                              minWidth: 0,
                              minHeight: 0,
                              maxWidth: double.infinity,
                              maxHeight: double.infinity,
                              child: Transform.scale(
                                scale: scale,
                                alignment: Alignment.topLeft,
                                filterQuality: FilterQuality.low,
                                child: child,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        );
        if (nav == null) {
          return content;
        }
        if (nav.radius <= 0) {
          return ClipRect(
            clipper: _BottomBarClipper(nav.rect.top),
            child: content,
          );
        }
        return ClipPath(
          clipper: _BottomNavHoleClipper(nav),
          child: content,
        );
      },
    );
  }
}

class _BottomBarClipper extends CustomClipper<Rect> {
  const _BottomBarClipper(this.bottom);

  final double bottom;

  @override
  Rect getClip(Size size) {
    final raw = bottom;
    final clamped = raw < 0
        ? 0.0
        : (raw > size.height ? size.height : raw);
    return Rect.fromLTRB(0, 0, size.width, clamped);
  }

  @override
  bool shouldReclip(_BottomBarClipper oldClipper) =>
      oldClipper.bottom != bottom;
}

class _BottomNavHoleClipper extends CustomClipper<Path> {
  const _BottomNavHoleClipper(this.nav);

  final _NavShape nav;

  @override
  Path getClip(Size size) {
    final maxRadius = nav.rect.shortestSide / 2;
    final radius = nav.radius < maxRadius ? nav.radius : maxRadius;
    return Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(
        RRect.fromRectAndRadius(nav.rect, Radius.circular(radius)),
      );
  }

  @override
  bool shouldReclip(_BottomNavHoleClipper oldClipper) =>
      oldClipper.nav.rect != nav.rect || oldClipper.nav.radius != nav.radius;
}
