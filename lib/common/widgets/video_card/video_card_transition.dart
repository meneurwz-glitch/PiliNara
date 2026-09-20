import 'dart:async' show Completer;
import 'dart:ui' as ui show lerpDouble;

import 'package:get/get.dart' show GetPageRoute;
import 'package:material_ui/material_ui.dart';

const double _cardRadius = 12;
const double _pageRadius = 72;
const Curve _containerCurve = Interval(
  0,
  0.82,
  curve: Curves.easeInOutCubicEmphasized,
);
// Reveal the destination during the first half of the expansion. This leaves
// an already-painted page in place when the card reaches the viewport instead
// of holding a blank surface until the route settles.
const Curve _revealCurve = Interval(0.18, 0.58, curve: Curves.easeInOutCubic);
// 手感调节旋钮：[_revealCurve] 前移（如 Interval(0.10, 0.46)）可让播放页更早
// 浮现，衬底裸露的时间更短；再配合下面 _buildFlightShuttle 里卡片淡出的
// Interval(0.04, 0.55) 往后挪，交叉淡出就不会出现"两头都不在"的空档。
// The player decoder is heavier than ordinary page UI. Start it only after
// that UI is visible, but while the card is still completing its expansion.
const double _entryContentReadyAt = 0.62;
const Duration videoPageTransitionDuration = Duration(milliseconds: 680);
const Duration videoPageReverseTransitionDuration = Duration(milliseconds: 320);
({Object tag, RenderBox box, BuildContext context})? _pendingVideoTransition;
final _enteringVideoPages = <Object, Completer<bool>>{};

/// Begin decoder setup only after the page is visibly taking over the card.
Future<bool> waitForVideoPageEntry(Object? tag) async =>
    await _enteringVideoPages[tag]?.future ?? true;

/// For transparent cards, use the actual painted ancestor rather than a
/// hard-coded surface role. Opaque cards pass their own Material color.
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

/// 浅色衬底被压成什么颜色。播放页顶部的播放器区就是纯黑（video/view.dart
/// 里 `BoxDecoration(color: Colors.black)`），衬底跟它一致，展开过程看起来
/// 就像"播放器先亮起来"，不会突兀。
const Color _darkSubstrate = Colors.black;

/// 亮度阈值：高于它判为"浅色衬底"，会被压成 [_darkSubstrate]。
/// 0.5 约等于 #BEBEBE：浅色主题的 #FAFAFA / #F3EDF7 / 浅灰卡片底都会被压深，
/// 而深色主题的 #303030（相对亮度≈0.03）原样保留。
const double _lightSubstrateLuminance = 0.5;

/// 转场衬底色修正——打开视频"闪一下白"的根治点。
///
/// 转场是把「卡片内容淡出」和「播放页浮现」叠在同一块衬底上做交叉淡出的：
///   · 卡片内容 `cardOpacity` 在 progress 4% → 55% 就淡完了；
///   · 播放页由 `_revealCurve`(18% → 58%) 的面纱一点点揭出来。
/// 也就是说这段时间画面上唯一的内容就是这块衬底色。
///
/// 而两端传进来的衬底色都取自主题：
///   · 卡片端 = [transitionBackgroundOf]，命中最近的 Material/ColoredBox，
///     即页面画布色；
///   · 播放页端 = `theme.canvasColor`。
/// 浅色主题下 ThemeData.canvasColor 没被改过，走 Flutter 默认值（≈#FAFAFA），
/// 于是 [card] 和 [page] 都是近白 —— `Color.lerp(白, 白, t)` 恒为白，
/// 卡片一淡出就露出一整屏白，这就是"打开视频闪一下白色"。
/// 深色主题下 canvasColor 本就是深色（纯黑主题里 darkenTheme 显式设成
/// Colors.black），所以深色主题看不出问题，Hyper 原版才一直带着这个毛病。
///
/// 处理方式：只在衬底这一层做颜色规整，浅色压深、深色不动。这样 V/H 卡、
/// 最近播放、相关推荐、动态等所有走这套转场的入口一次性都修好，
/// 卡片和播放页本身的外观一个像素都不变（`_CardSurface` / `_VideoPageSurface`
/// 都不画这个颜色，它只出现在转场的飞行衬底和面纱上）。
Color _substrateOf(Color color) =>
    color.computeLuminance() > _lightSubstrateLuminance
    ? _darkSubstrate
    : color;

Color _transitionSurface(Color card, Color page, double expansion) =>
    Color.lerp(_substrateOf(card), _substrateOf(page), expansion)!;

bool hasPendingVideoCardTransition(Object tag) =>
    _pendingVideoTransition?.tag == tag;

// Keep only geometry: tapping no longer captures or filters a full-screen image.
void _prepareVideoTransition(Object tag, BuildContext context) {
  final box = context.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    _pendingVideoTransition = (
      tag: tag,
      box: box,
      context: context,
    );
  }
}

class _VideoCardRectTween extends RectTween {
  _VideoCardRectTween({
    required super.begin,
    required super.end,
    this.returning = false,
  });
  final bool returning;

  @override
  Rect? lerp(double t) => returning
      // The page anchor is enlarged for entry corners; the mounted page
      // contracts from the actual viewport on return.
      ? Rect.lerp(
          begin?.deflate(_pageRadius),
          end,
          Curves.easeInOutCubic.transform(t),
        )
      : Rect.lerp(begin, end, _containerCurve.transform(t));
}

/// Retain GetX's playback/controller lifecycle, replacing only the visuals.
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
    // Listen to the real controller, not Hero's offstage proxy animation. The
    // decoder begins only after the revealed page UI has taken over, but before
    // the card finishes its final expansion.
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
    // didPop already reverses from the current progress. The SDK's default
    // commit restarts reverse(from: upperBound), replaying our visible shrink.
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

class VideoCardHero extends StatelessWidget {
  const VideoCardHero({
    super.key,
    required this.tag,
    required this.surfaceColor,
    required this.child,
    this.preserveChildHeroes = false,
  });

  final Object tag;
  final Color surfaceColor;
  final Widget child;
  final bool preserveChildHeroes;

  @override
  Widget build(BuildContext context) {
    final hero = Hero(
      tag: tag,
      curve: Curves.linear,
      reverseCurve: Curves.linear,
      transitionOnUserGestures: true,
      createRectTween: (begin, end) =>
          _VideoCardRectTween(begin: begin, end: end, returning: true),
      flightShuttleBuilder: _buildFlightShuttle,
      child: _CardSurface(
        color: surfaceColor,
        flightChild: preserveChildHeroes ? child : null,
        child: preserveChildHeroes ? const SizedBox.expand() : child,
      ),
    );
    return Listener(
      onPointerDown: (_) => _prepareVideoTransition(tag, context),
      // Dynamic cards contain independent image-preview Heroes. Keep the card
      // flight anchor as their sibling, never an enclosing Hero.
      child: preserveChildHeroes
          ? Stack(
              children: [
                child,
                Positioned.fill(child: IgnorePointer(child: hero)),
              ],
            )
          : hero,
    );
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
  Color? _sourceColor;
  BuildContext? _sourceContext;
  bool _entryCompleted = false;

  @override
  void initState() {
    super.initState();
    if (hasPendingVideoCardTransition(widget.tag)) {
      _sourceBox = _pendingVideoTransition!.box;
      _sourceContext = _pendingVideoTransition!.context;
      _sourceColor = (_sourceContext!.widget as VideoCardHero).surfaceColor;
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
    // Hero measures its destination offstage with a fake completed animation.
    // That is not a completed entry and must not enable the full-page exit.
    if (status == AnimationStatus.completed && _route?.offstage == false) {
      _entryCompleted = true;
    }
    if (status == AnimationStatus.reverse && _sourceContext?.mounted == true) {
      _sourceColor = (_sourceContext!.widget as VideoCardHero).surfaceColor;
    }
    final box = _sourceBox;
    if (status == AnimationStatus.reverse &&
        box != null &&
        box.attached &&
        box.hasSize) {
      _sourceRect = box.localToGlobal(Offset.zero) & box.size;
    }
    // PiliNara: the native Miuix backdrop-sampling pause lives in the Android
    // Kotlin layer of Hyper-PiliPlus and is unavailable here, so it is omitted.
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
        final reveal = CurveTween(curve: _revealCurve).animate(animation);
        return AnimatedBuilder(
          animation: animation,
          child: widget.child,
          builder: (context, child) {
            // Interactive updates can report "forward" even while their value
            // decreases. Keep the return composition until the gesture settles.
            final reversing =
                animation.status == AnimationStatus.reverse ||
                (ModalRoute.of(context)?.popGestureInProgress ?? false);
            // Flutter diverts an unfinished push by reversing its existing
            // Hero tween/shuttle. The page must retrace that same entry too,
            // not start a second contraction from an assumed full-screen page.
            final returning = reversing && _entryCompleted;
            final box = context.findRenderObject();
            final origin = box is RenderBox && box.hasSize
                ? box.localToGlobal(Offset.zero)
                : Offset.zero;
            final source = _sourceRect!.shift(-origin);
            final expansion = _containerCurve.transform(animation.value);
            final contraction = Curves.easeInOutCubic.transform(
              1 - animation.value,
            );
            // Fade with the actual shrink, never before movement starts.
            // A stronger ease-out makes return content disappear earlier.
            final returnOpacity =
                1 - Curves.easeOutCubic.transform(contraction);
            final surfaceColor = _transitionSurface(
              _sourceColor!,
              widget.surfaceColor,
              returning ? 1 - contraction : expansion,
            );
            final pageRect = returning
                ? Rect.lerp(viewport, source, contraction)!
                : viewport;
            final clipRect = returning
                ? Offset.zero & pageRect.size
                : Rect.lerp(source, viewport.inflate(_pageRadius), expansion)!;
            final radius = returning
                ? _cardRadius * contraction
                : ui.lerpDouble(_cardRadius, _pageRadius, expansion)!;
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                if (!reversing && animation.status != AnimationStatus.completed)
                  Positioned.fill(
                    key: const ValueKey('video-transition-dim-position'),
                    child: IgnorePointer(
                      child: ColoredBox(
                        key: const ValueKey('video-transition-dim'),
                        color: Colors.black.withValues(alpha: 0.16 * expansion),
                      ),
                    ),
                  ),
                Positioned.fromRect(
                  key: const ValueKey('video-transition-page-position'),
                  rect: pageRect,
                  child: ClipRRect(
                    key: const ValueKey('video-transition-page-container'),
                    clipper: _PageClipper(clipRect, radius),
                    child: ColoredBox(
                      key: const ValueKey('video-transition-surface'),
                      // Keep the interpolated surface underneath fading content
                      // and match the Hero color throughout the entry handoff.
                      color: surfaceColor,
                      child: FittedBox(
                        fit: BoxFit.fill,
                        child: SizedBox.fromSize(
                          size: size,
                          child: FadeTransition(
                            key: const ValueKey('video-transition-page'),
                            opacity: returning
                                ? AlwaysStoppedAnimation(returnOpacity)
                                : const AlwaysStoppedAnimation(1),
                            // Paint the page from the first frame. A simple
                            // surface veil reveals it without bringing a whole
                            // page opacity layer online halfway through entry.
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                RepaintBoundary(child: child),
                                IgnorePointer(
                                  child: ColoredBox(
                                    key: const ValueKey(
                                      'video-transition-page-veil',
                                    ),
                                    color: surfaceColor.withValues(
                                      alpha: returning ? 0 : 1 - reveal.value,
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
                Positioned(
                  key: const ValueKey('video-transition-hero-position'),
                  left: -_pageRadius,
                  top: -_pageRadius,
                  right: -_pageRadius,
                  bottom: -_pageRadius,
                  child: IgnorePointer(
                    child: Hero(
                      tag: widget.tag,
                      curve: Curves.linear,
                      reverseCurve: Curves.linear,
                      transitionOnUserGestures: true,
                      createRectTween: (begin, end) =>
                          _VideoCardRectTween(begin: begin, end: end),
                      flightShuttleBuilder: _buildFlightShuttle,
                      child: _VideoPageSurface(color: widget.surfaceColor),
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

class _PageClipper extends CustomClipper<RRect> {
  const _PageClipper(this.rect, this.radius);
  final Rect rect;
  final double radius;

  @override
  RRect getClip(Size size) =>
      RRect.fromRectAndRadius(rect, Radius.circular(radius));

  @override
  bool shouldReclip(_PageClipper oldClipper) =>
      rect != oldClipper.rect || radius != oldClipper.radius;
}

class _VideoPageSurface extends StatelessWidget {
  const _VideoPageSurface({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _CardSurface extends StatelessWidget {
  const _CardSurface({
    required this.color,
    required this.child,
    this.flightChild,
  });
  final Color color;
  final Widget child;
  final Widget? flightChild;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: const BorderRadius.all(Radius.circular(_cardRadius)),
    child: child,
  );
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
  final cardHero = cardContext.widget as Hero;
  final pageSurface = (pageContext.widget as Hero).child as _VideoPageSurface;
  final renderBox = cardContext.findRenderObject() as RenderBox?;
  final cardSize = renderBox?.size ?? const Size(1, 1);
  final cardSurface = (cardHero.child as _CardSurface).color;
  final card = InheritedTheme.captureAll(
    cardContext,
    Material(
      type: MaterialType.transparency,
      child: (cardHero.child as _CardSurface).flightChild ?? cardHero.child,
    ),
  );
  return AnimatedBuilder(
    animation: animation,
    child: card,
    builder: (context, child) {
      if (returning) {
        final contraction = Curves.easeInOutCubic.transform(
          1 - animation.value,
        );
        // Complement the mounted page's fade. Card content is already fully
        // visible before Hero hands it back to the source widget.
        return ClipRRect(
          key: const ValueKey('video-transition-return-card'),
          borderRadius: BorderRadius.circular(_cardRadius * contraction),
          child: Align(
            alignment: Alignment.topLeft,
            child: Opacity(
              key: const ValueKey('video-transition-return-card-opacity'),
              opacity: Curves.easeOutCubic.transform(contraction),
              child: SizedBox.fromSize(
                size: cardSize,
                child: RepaintBoundary(child: child),
              ),
            ),
          ),
        );
      }
      final progress = _containerCurve.transform(animation.value);
      final radius = ui.lerpDouble(_cardRadius, _pageRadius, progress)!;
      // 卡片内容的淡出区间（旋钮）：后移成 0.16 ~ 0.62 可让封面多撑一会儿，
      // 衬底就不会在页面浮现之前先"光"出来。
      final cardOpacity =
          1 -
          const Interval(
            0.04,
            0.55,
            curve: Curves.easeInOutCubic,
          ).transform(progress);
      return ClipRRect(
        key: const ValueKey('video-transition-flight'),
        borderRadius: BorderRadius.all(Radius.circular(radius)),
        child: Opacity(
          opacity: 1 - _revealCurve.transform(animation.value),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(
                key: const ValueKey('video-transition-flight-surface'),
                color: _transitionSurface(
                  cardSurface,
                  pageSurface.color,
                  progress,
                ),
              ),
              if (cardOpacity > 0)
                Align(
                  alignment: Alignment.topLeft,
                  child: Opacity(
                    opacity: cardOpacity,
                    child: SizedBox.fromSize(
                      size: cardSize,
                      child: RepaintBoundary(child: child),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}


