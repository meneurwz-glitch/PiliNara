import 'dart:async' show Completer;
import 'dart:math' as math;
import 'dart:ui' as ui show lerpDouble;

import 'package:get/get.dart' show GetPageRoute;
import 'package:material_ui/material_ui.dart';

const double _cardRadius = 12;
const double _pageRadius = 72;

/// 卡片的封面宽高比，和 `Style.aspectRatio` 一致（16:10）。
///
/// 用它可以从卡片尺寸反推封面在卡片里占的宽度：
///   `min(卡片宽, 卡片高 × _coverAspect)`
/// 垂直卡片（封面满宽）取到卡片宽；水平卡片（封面在左侧、宽度由高度反推）
/// 取到 `卡片高 × _coverAspect`。有这个值，飞行缩放才能"以封面为基准"，
/// 而不是"以整张卡片为基准" —— 后者对水平卡片几乎等于不放大。
const double _coverAspect = 16 / 10;

const Curve _containerCurve = Interval(
  0,
  0.82,
  curve: Curves.easeInOutCubicEmphasized,
);
// 页面浮现 / 飞行卡片淡出。这两条曲线是一组「接力」：页面比卡片早一点开始
// 浮现、也早一点浮现完，于是卡片溶掉的时候下面已经是一张画好的页面，
// 中途不会出现"两头都不在"的空档。
//
// 手感旋钮：把两条曲线整体前移（如 0.28/0.72 与 0.38/0.82）可以让交接更早、
// 卡片"长大"的时间更短；整体后移则卡片撑得更久、扩张感更强。
const Curve _revealCurve = Interval(0.34, 0.78, curve: Curves.easeInOutCubic);
const Curve _flightFadeCurve = Interval(
  0.44,
  0.88,
  curve: Curves.easeInOutCubic,
);
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

/// 转场不再使用任何形式的「衬底」。
///
/// 之前几版（把浅色压黑、或换成毛玻璃）都是在卡片内容之外**另外**画一块色块，
/// 由它从卡片位置扩张到全屏，而卡片内容自己被钉在左上角原地淡出 —— 看起来是
/// "一块颜色长出来"，不是"卡片长大"。
///
/// 现在飞行层直接承载卡片本身（见 [_buildFlightShuttle]）：卡片内容按
/// `BoxFit.fitWidth` 跟着扩张中的矩形一起等比放大。因为卡片的封面是**满宽**的
/// `Style.aspectRatio`（16:10），当矩形宽度长到视口宽度时，封面高度
/// ≈ 视口宽 × 10/16，正好落在详情页播放器该在的位置，标题区则落在播放器下方
/// —— 和详情页的信息区同序。之后由页面淡入接力。
///
/// 没有纯色垫底的另一个好处：扩张过程中圆角之外透出的就是下层页面
/// （首页 / 列表页的原始画面），这正是标准 Hero 的观感，也不再有任何
/// "闪一下白"的可能，因为整个转场里根本不存在一块近白色的底。

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
      // 返回端锚点现在就是视口本身（不再是外扩后的矩形），所以直接用
      // easeInOutCubic 从视口收拢回卡片位置即可。
      ? Rect.lerp(begin, end, Curves.easeInOutCubic.transform(t))
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

  /// 保留参数只为不改动卡片调用点（`VideoCardV` / `VideoCardH` / 最近播放 /
  /// 动态页都还在传）。转场现在已经不再绘制任何衬底色，这个值不参与渲染。
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
    // Hero measures its destination offstage with a fake completed animation.
    // That is not a completed entry and must not enable the full-page exit.
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
            final pageRect = returning
                ? Rect.lerp(viewport, source, contraction)!
                : viewport;
            final clipRect = returning
                ? Offset.zero & pageRect.size
                : Rect.lerp(source, viewport.inflate(_pageRadius), expansion)!;
            // 圆角与飞行层 [_buildFlightShuttle] 保持同一套插值，否则返回时
            // 页面和卡片两层圆角会各走各的、边缘对不齐。
            final radius = ui.lerpDouble(
              _cardRadius,
              _pageRadius,
              returning ? contraction : expansion,
            )!;
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                Positioned.fromRect(
                  key: const ValueKey('video-transition-page-position'),
                  rect: pageRect,
                  child: ClipRRect(
                    key: const ValueKey('video-transition-page-container'),
                    clipper: _PageClipper(clipRect, radius),
                    // 页面直接淡入，不再有任何衬底或面纱：飞行层已经把卡片
                    // 放大到播放器的位置和大小，两者重叠的这段就是交接区。
                    child: FittedBox(
                      fit: BoxFit.fill,
                      child: SizedBox.fromSize(
                        size: size,
                        child: FadeTransition(
                          key: const ValueKey('video-transition-page'),
                          opacity: returning
                              ? AlwaysStoppedAnimation(returnOpacity)
                              : reveal,
                          child: RepaintBoundary(child: child),
                        ),
                      ),
                    ),
                  ),
                ),
                // Anchor 放在视口本身，不再向外扩 [_pageRadius]。
                //
                // 这一点是"封面能不能落在播放器位置"的关键：飞行层的缩放是
                // `fitWidth`（宽度贴合当前矩形），锚点等于视口，卡片才会正好
                // 放大到视口宽度；若锚点像原来那样外扩 72，矩形会变成
                // 视口 + 144，卡片被多放大三十几个百分点，封面就明显比播放器
                // 更大。向外扩只对**页面侧**的圆角裁切有意义（那是
                // [_PageClipper] 自己的事，见上面 clipRect）。
                Positioned.fill(
                  key: const ValueKey('video-transition-hero-position'),
                  child: IgnorePointer(
                    child: Hero(
                      tag: widget.tag,
                      curve: Curves.linear,
                      reverseCurve: Curves.linear,
                      transitionOnUserGestures: true,
                      createRectTween: (begin, end) =>
                          _VideoCardRectTween(begin: begin, end: end),
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

/// 详情页端 Hero 的占位 anchor：它自己不绘制任何东西，飞行期间的全部视觉
/// 都由 [_buildFlightShuttle]（也就是卡片本身）负责。
class _VideoPageSurface extends StatelessWidget {
  const _VideoPageSurface();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _CardSurface extends StatelessWidget {
  const _CardSurface({required this.child, this.flightChild});

  final Widget child;
  final Widget? flightChild;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: const BorderRadius.all(Radius.circular(_cardRadius)),
    child: child,
  );
}

/// 飞行层 = 卡片自己。
///
/// 这是本次改动的核心：不再画任何衬底色块，而是让卡片内容跟着 Hero 的矩形一起
/// 放大。缩放的基准是**封面**（宽度按 `min(卡片宽, 卡片高 × 16/10)` 反推），
/// 于是：
///
///   · 起点：缩放 1:1，画面与静止的卡片逐像素一致，起飞那一帧没有任何跳变；
///   · 终点：封面宽度正好等于视口宽度。卡片封面是满宽的 16:10，所以此时封面
///     高度 ≈ 视口宽 × 10/16 —— 正是详情页播放器该在的位置和大小，封面左上角
///     也钉在屏幕左上角。
///
/// 也就是说"封面长到播放器该在的地方"是几何上算出来的，不是靠叠一层色块蒙
/// 出来的。剩下的只是交接：卡片在 [_flightFadeCurve] 区间淡出，页面在
/// [_revealCurve] 区间淡入（稍早开始、稍早结束）。两者重叠的这段时间里，
/// 卡片封面和页面播放器的位置几乎重合，交叉淡出读起来就是一次无缝接力。
///
/// 圆角之外透出的是下层页面本身（转场期间上层路由不算 opaque，首页仍在绘制），
/// 这就是标准 Hero 的观感。
Widget _buildFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  final returning = direction == HeroFlightDirection.pop;
  final cardContext = returning ? toHeroContext : fromHeroContext;
  final cardHero = cardContext.widget as Hero;
  final renderBox = cardContext.findRenderObject() as RenderBox?;
  final cardSize = renderBox?.size ?? const Size(1, 1);
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
      // 返回走同一条曲线的时间倒数，保证"从哪里来回哪里去"。
      final contraction = Curves.easeInOutCubic.transform(1 - animation.value);
      // 扩张进度：去程与 Hero 的矩形走同一条曲线，回程是它的时间倒数。
      final expansion = returning
          ? 1 - contraction
          : _containerCurve.transform(animation.value);
      // 缩放以**封面**为基准，终点让封面宽度正好等于视口宽度。卡片封面是满宽的
      // 16:10，所以那一刻封面高度 ≈ 视口宽 × 10/16 —— 正是详情页播放器该在的
      // 位置和大小。以"整张卡片"为基准的话，垂直卡片（封面满宽）恰好等价，
      // 但水平卡片（封面只占卡片左侧）宽度本来就接近视口，会几乎不放大。
      final coverWidth = math.min(
        cardSize.width,
        cardSize.height * _coverAspect,
      );
      final viewportWidth =
          MediaQuery.maybeSizeOf(context)?.width ?? cardSize.width;
      final scale = ui.lerpDouble(1, viewportWidth / coverWidth, expansion)!;
      // 飞行的是卡片本身，所以圆角用卡片自己的（[_CardSurface] 的 12），
      // 跟着缩放一起变大 —— 就像把卡片凑近看。这里刻意**不加**外层 ClipRRect：
      // 它的尺寸等于 Hero 的矩形，会对放大的卡片产生一条"人造裁边"。
      // 横向卡片尤其明显：卡片本身比矩形宽（标题会向右铺出屏幕），
      // 那条裁边会正好落在屏幕里，露出一条缝。不裁切时，超出的部分由
      // Overlay 自己的 Clip.hardEdge 收掉，边界正好是屏幕边。
      //
      // 去程由 [_flightFadeCurve] 决定；回程由收缩进度决定 —— Hero 交还给卡片
      // 之前必须已经完全不透明，否则落地会闪一下。
      final opacity = returning
          ? Curves.easeOutCubic.transform(contraction)
          : 1 - _flightFadeCurve.transform(animation.value);
      return Opacity(
        key: ValueKey(
          returning
              ? 'video-transition-return-card'
              : 'video-transition-flight',
        ),
        opacity: opacity,
        // OverflowBox 把 child 从"矩形"的紧约束里解放出来，让卡片仍按自己的
        // 逻辑尺寸（cardSize）布局 —— 文字不重排、图片不重新解码，只是被
        // Transform 整体放大后绘制。左上角对齐意味着封面左上角始终钉住矩形
        // 左上角，这正是"封面长到播放器位置"需要的锚点。
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: 0.0,
          minHeight: 0.0,
          maxWidth: double.infinity,
          maxHeight: double.infinity,
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: cardSize,
              child: RepaintBoundary(child: child),
            ),
          ),
        ),
      );
    },
  );
}


