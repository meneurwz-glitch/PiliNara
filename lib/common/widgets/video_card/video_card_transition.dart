import 'dart:async' show Completer;

import 'package:get/get.dart' show GetPageRoute;
import 'package:material_ui/material_ui.dart';

/// 卡片圆角。转场全程用它 —— 页面从卡片矩形长到全屏时圆角不变，
/// 到位后这 12px 落在屏幕四角上几乎看不出来。
const double _cardRadius = 12;

/// 转场期间「页面之外」（也就是首页那一层）被压暗的强度。
///
/// 展开中的详情页是唯一的亮点，首页退到后面去，视线自然被拉到卡片上。
/// 实测参考效果里这个压暗约 0.3 ~ 0.4（对首页亮度降幅约 30%），
/// 且随展开进度线性加深 —— 起点 0、到位时到满值。
const double _scrimOpacity = 0.35;

/// 横卡专用：详情页之上先盖一层「衬底色」遮罩，随转场进度淡出。
///
/// 为什么只有横卡需要：横卡矩形是横向的（宽 > 高），而详情页是 9:20 竖屏。
/// 用 `BoxFit.cover` 把整页塞进这个横向矩形时，缩放比由**宽度**决定，
/// 页面会被放大到远超矩形高度 —— 起飞那一帧看到的是"详情页顶部被放大的一小块"，
/// 而不是卡片原貌（左封面 + 右标题），这一段内容跳变比竖卡明显得多。
/// 盖一层卡片所在页面的背景色（也就是先前 v2 / v7 衬底方案用的那个颜色），
/// 等页面长得差不多了再露出来，跳变就被藏在这层颜色里。
///
/// 遮罩只铺满**页面矩形本身**（跟着矩形的长大走、跟着卡片圆角裁），
/// 页面之外的首页区域照旧交给上面那层黑幕压暗 —— 若铺满整屏，浅色主题下
/// 开场就是整屏泛白，那是之前专门修掉的问题。
const double _maskHoldUntil = 0.22; // 这段进度内完全不透明，遮住最乱的开场
const double _maskFadeEnd = 0.7; // 到这里遮罩已经全透明
const Curve _maskFadeCurve = Interval(
  _maskHoldUntil,
  _maskFadeEnd,
  curve: Curves.easeOutCubic,
);

/// 卡片宽 / 高 ≥ 这个比值就当横卡。`video_card_h` ≈ 1.8，
/// `video_card_v` ≈ 0.9，中间留了足够余量。
const double _landscapeCardRatio = 1.35;

/// 展开曲线。页面矩形从「卡片矩形」插值到「整个视口」，走的就是这条曲线。
///
/// 手感旋钮：0.82 这个端点决定"多大比例时就已经铺满" —— 调小（如 0.72）会让
/// 展开更早收尾、后半段几乎是静止的；调大到 1.0 则全程都在长大。
const Curve _containerCurve = Interval(
  0,
  0.82,
  curve: Curves.easeInOutCubicEmphasized,
);

// The player decoder is heavier than ordinary page UI. Start it only after
// that UI is visible, but while the card is still completing its expansion.
const double _entryContentReadyAt = 0.62;
const Duration videoPageTransitionDuration = Duration(milliseconds: 400);
const Duration videoPageReverseTransitionDuration = Duration(milliseconds: 320);
/// 一次转场所需要的全部信息：源卡片本体（量起点矩形）、卡片所在页面的
/// 背景色（横卡遮罩用）、以及那个 context（保留给调试用）。
typedef _PendingVideoTransition = ({
  Object tag,
  RenderBox box,
  BuildContext context,
  Color substrate,
});

_PendingVideoTransition? _pendingVideoTransition;
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

/// Keep only geometry: tapping no longer captures or filters a full-screen image.
void _prepareVideoTransition(Object tag, BuildContext context) {
  final box = context.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    _pendingVideoTransition = (
      tag: tag,
      box: box,
      context: context,
      // 卡片所在页面的背景色 —— 先前 v2 / v7 衬底方案用的就是这个颜色
      // （`transitionBackgroundOf` 命中最近的 Material 的 color，浅色主题下
      // 通常就是 canvasColor ≈ #FAFAFA）。在这里、也就是手指按下时量一次：
      // 详情页构建时卡片已经被 Hero 摘掉 child，那时再遍历它的祖先树不安全。
      substrate: transitionBackgroundOf(context),
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

  /// 卡片所在页面的背景色。**当前转场不使用它** —— 现在整页从卡片矩形缩放
  /// 展开，没有任何衬底。保留参数只为不改动卡片调用点（`VideoCardV` /
  /// `VideoCardH` / 最近播放 / 动态页都还在传）。
  final Color surfaceColor;
  final Widget child;
  final bool preserveChildHeroes;

  /// 封面 widget 的 key。**当前转场不使用它** —— 既然页面是整体缩放的，
  /// 就没有"只飞封面"那条路径了。保留是为了让卡片端（`video_card_v.dart` /
  /// `video_card_h.dart`）一行都不用改。
  final GlobalKey? coverKey;

  /// 卡片圆角。卡片自身仍按它裁圆角。
  final double cornerRadius;

  @override
  State<VideoCardHero> createState() => _VideoCardHeroState();
}

class _VideoCardHeroState extends State<VideoCardHero> {
  /// 封面相对卡片左上角的矩形，在按下时量一次。
  /// 不用 setState：飞行层是在转场开始后通过 [_CardSurface.coverReader]
  /// 读它的，不需要触发重建。
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
        substrateColor: widget.surfaceColor,
        coverReader: () => _coverRect,
        flightChild: widget.preserveChildHeroes ? widget.child : null,
        child: widget.preserveChildHeroes
            ? const SizedBox.expand()
            : widget.child,
      ),
    );
    return Listener(
      onPointerDown: (_) => _prepare(context),
      // Dynamic cards contain independent image-preview Heroes. Keep the card
      // flight anchor as their sibling, never an enclosing Hero.
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

  /// 量出封面在卡片内的矩形。卡片本体和封面都还在树上（此时还没开始转场），
  /// 所以直接读各自的 RenderBox 就够了，不必依赖卡片实现里写死的 padding。
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

  /// 横卡遮罩用的颜色：卡片所在页面的背景色（按下时量好的那份）。
  /// 量不到时退回页面端传进来的 `surfaceColor`。
  late final Color _substrate;

  @override
  void initState() {
    super.initState();
    final pending = hasPendingVideoCardTransition(widget.tag)
        ? _pendingVideoTransition
        : null;
    _substrate = pending?.substrate ?? widget.surfaceColor;
    if (pending != null) {
      _sourceBox = pending.box;
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
            // 页面矩形：去程从「卡片矩形」插值到「整个视口」，回程反过来。
            //
            // 这是整套转场里唯一在动的东西：详情页以卡片的位置和大小起步，
            // 一路长到铺满屏幕。因为页面内容是用 `BoxFit.cover` 缩放进这个
            // 矩形的，文字和图片都跟着一起放大 —— 读起来就是"卡片本身长成了
            // 详情页"，而不是拿一个窗口去揭开一张本来就全尺寸的页面。
            final pageRect = returning
                ? Rect.lerp(viewport, source, contraction)!
                : Rect.lerp(source, viewport, expansion)!;
            // 横卡才盖衬底遮罩（判据用源卡片的宽高比，卡片文件无需改动）。
            //
            // 用 `animation.value`（时间轴进度）而不是上面那条展开曲线：要求就是
            // "进行到 70% 时遮罩透明"，直接对齐时间轴最直观，回程时 value 反向
            // 递减、遮罩重新出现，收回到卡片时正好重新盖满，两边对称。
            final maskAlpha = source.width >= source.height * _landscapeCardRatio
                ? 1 - _maskFadeCurve.transform(animation.value)
                : 0.0;
            return Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.none,
              children: [
                // 压暗层：页面之外（首页那一层）盖一层黑，随展开进度加深。
                // 展开中的详情页因此成为画面上唯一的亮点。
                //
                // 用 [expansion]（而不是回程的 contraction）是因为它在两个方向
                // 上都是"展开程度"：去程 0 → 1、回程 1 → 0，所以同一行代码在
                // 进入和退出时都正确 —— 返回一开始页面是全屏、首页本该最暗，
                // 那时 expansion 正好是 1。
                Positioned.fill(
                  key: const ValueKey('video-transition-scrim'),
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: Colors.black.withValues(
                        alpha: _scrimOpacity * expansion,
                      ),
                    ),
                  ),
                ),
                // 详情页本体。圆角保持卡片圆角不变 —— 它是"一张卡片"这件事
                // 在整段动画里唯一不变的线索。
                Positioned.fromRect(
                  key: const ValueKey('video-transition-page-position'),
                  rect: pageRect,
                  child: ClipRRect(
                    key: const ValueKey('video-transition-page-container'),
                    borderRadius: const BorderRadius.all(
                      Radius.circular(_cardRadius),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        FittedBox(
                          // cover = 等比缩放到填满矩形，多出来的部分裁掉。
                          // 用 fill 会把页面拉变形（卡片矩形接近方形、视口是 9:20），
                          // 用 contain 则会在矩形里留出空白边。
                          fit: BoxFit.cover,
                          alignment: Alignment.topCenter,
                          child: SizedBox.fromSize(
                            size: size,
                            child: RepaintBoundary(child: child),
                          ),
                        ),
                        // 横卡：衬底色遮罩，压在页面之上、随矩形长大、跟圆角一起裁。
                        // 放进 ClipRRect 内部（而不是 Stack 最外层）是关键 ——
                        // 这样它天然贴着页面矩形的边界和圆角，不会盖到页面之外的
                        // 首页区域上去。
                        if (maskAlpha > 0.002)
                          Positioned.fill(
                            key: const ValueKey('video-transition-card-mask'),
                            child: IgnorePointer(
                              child: ColoredBox(
                                color: _substrate.withValues(alpha: maskAlpha),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                // Hero 的锚点铺满视口。它的 child（[_VideoPageSurface]）什么都不
                // 画，在这个转场里只承担两件事：让 Hero 机制把源卡片的 child
                // 摘掉（否则原卡片会和展开中的页面叠在一起），以及提供转场
                // 进度。全部视觉由上面那个会动的页面矩形完成。
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

/// 详情页端 Hero 的占位 anchor：它自己不绘制任何东西。这个转场的全部视觉
/// 都由 [_VideoPageHeroTargetState] 里那个会动的页面矩形完成。
class _VideoPageSurface extends StatelessWidget {
  const _VideoPageSurface();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _CardSurface extends StatelessWidget {
  const _CardSurface({
    required this.child,
    required this.substrateColor,
    this.flightChild,
    this.radius = _cardRadius,
    this.coverReader,
  });

  final Widget child;
  final Widget? flightChild;
  final double radius;

  /// 卡片所在页面的背景色。**当前转场不使用**（已经没有标题衬底了），
  /// 保留只为不改动卡片的调用点。
  final Color substrateColor;

  /// 封面在卡片里的矩形读取器。**当前转场不使用**，保留同上。
  final ValueGetter<Rect?>? coverReader;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.all(Radius.circular(radius)),
    child: child,
  );
}

/// 飞行层现在是**空的**。
///
/// 这个转场里没有任何东西在"飞"：详情页自己从卡片矩形长到全屏（见
/// [_VideoPageHeroTargetState] 里的 `pageRect`）。Hero 在这里只做两件事 ——
/// 把源卡片的 child 摘掉（换成同尺寸的占位盒，否则原卡片会和展开中的页面
/// 叠在一起），以及提供转场进度。
///
/// 所以 shuttle 返回一个零尺寸的空盒子。这一点是必须的：飞行层位于 Overlay，
/// z 序在页面路由**之上**，它只要画任何东西都会盖住正在展开的页面。
///
/// 起飞那一帧为什么看不出跳变：`pageRect` 的起点就是卡片矩形，展开中的页面
/// 正好压在卡片原来的位置上；而详情页顶部的播放器占位显示的又是这张卡片的
/// 封面。两件事叠起来，视觉上就是"封面直接长成了播放器"，不需要额外的
/// 交接层。
Widget _buildFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) => const SizedBox.shrink();
