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

/// 转场期间叠在详情页**之上**的那层「卡片」什么时候淡掉。
///
/// 这一层画的就是卡片本身，两样东西叠在一起：
///
///   ① **卡片底色**（[_CardSurface.substrateColor]，也就是卡片在列表里背后透出来
///      的那个颜色）铺满整个矩形；
///   ② 卡片内容（封面 + 标题）按宽度等比放大，锚在矩形左上角。
///
/// 矩形不是钉在原地的：它和详情页用**同一条曲线、同一个进度**从「卡片矩形」
/// 长到「整个视口」，所以卡片是跟着页面一起长大、一起往左上角飘的 ——
/// 起飞那一帧看到的就是原卡片（这时矩形正好等于卡片矩形），随后两者一起长。
///
/// 为什么必须垫底色：卡片内容自己往往没有背景（`VideoCardH` 就是一层
/// `Material(type: transparency)`），在列表里靠页面底色透上来才像"一张卡片"。
/// 放大之后矩形比卡片内容高出一大截，多出来的那块要是没有底色，露出的就是
/// 底下的详情页 —— 读起来像"卡片被撕开了一条"。垫上底色之后，多出来的部分
/// 自然成了卡片的背景，接缝读不出来。
///
/// 竖卡和横卡都走这一套。横卡尤其需要：它的矩形是横向的（宽 > 高），
/// 而详情页是 9:20 竖屏，用 `BoxFit.cover` 把整页塞进横向矩形时缩放比由宽度
/// 决定、页面被放大到远超矩形高度，起飞那一帧会变成"详情页顶部被放大的一小块"
/// —— 有这层卡片挡着，那段跳变就读不出来了。
///
/// 时间安排：[_cardLayerHoldUntil] 之前完全不透明（把最乱的开场全遮住），
/// 之后按 [_cardLayerFadeCurve] 渐隐，到 [_cardLayerFadeEnd] 已完全透明。
const double _cardLayerHoldUntil = 0.22;
/// 到这里卡片层已经全透明。
///
/// 注意和 [_containerCurve] 的联动：当前主曲线 70% 时页面只铺到 0.69（不是铺满），
/// 所以这一刻卡片消失后、页面还会继续长大最后 31%。觉得"露得偏早、还能看见边缘
/// 在扩"，把它提到 0.8（那时铺到 0.84）即可。
const double _cardLayerFadeEnd = 0.7;
const Curve _cardLayerFadeCurve = Interval(
  _cardLayerHoldUntil,
  _cardLayerFadeEnd,
  curve: Curves.easeOutCubic,
);

// ─────────────────────────── 曲线调参区 ───────────────────────────
// 整个转场一共四条曲线，按「谁在动」分清楚，改的时候别串味：
//
//   _containerCurve        页面矩形从卡片矩形长到全屏 —— **主曲线**，影响最大
//   _cardLayerFadeCurve    上层卡片（封面 + 标题）的淡出（0.22 ~ 0.70）
//   Curves.easeInOutCubic  返回方向的收拢（见 returning 分支与 _VideoCardRectTween）
//   Curves.linear          Hero 自身的插值（不参与视觉，只为拿进度）
//
// 参数写法与 CSS 的 `cubic-bezier(x1, y1, x2, y2)` 一一对应：
// 控制点固定在 (0,0) 和 (1,1)，四个值就是中间两个控制点。
// ─────────────────────────────────────────────────────────────────

/// 展开曲线（主曲线）。页面矩形从「卡片矩形」插值到「整个视口」，走的就是它。
///
/// 现在用的是一条三次贝塞尔 `cubic-bezier(0.54, 0.15, 0.68, 0.88)`：
///
/// | 时间 | 0.28 | 0.49 | 0.58 | 0.70 | 0.82 | 1.00 |
/// |---|---|---|---|---|---|---|
/// | 进度 | 0.15 | 0.38 | 0.51 | 0.69 | 0.86 | 1.00 |
///
/// 也就是**起步明显蓄力**（前 30% 只走完 15%）、中段最猛、
/// 最后 18% 再收一下尾。全程都在长大，不像上一版（`Interval(0, 0.82)`）
/// 那样 82% 就已经铺满、尾巴停滞。
///
/// 想换手感：直接改这 4 个数即可，或者换回内置曲线，例如
/// `Curves.easeInOutCubicEmphasized` / `Curves.fastOutSlowIn` /
/// `Curves.easeOutCubic`；要「提前铺满」就套一层 `Interval(0, 0.82, curve: ...)`。
const Curve _containerCurve = Cubic(0.54, 0.15, 0.68, 0.88);

// The player decoder is heavier than ordinary page UI. Start it only after
// that UI is visible, but while the card is still completing its expansion.
const double _entryContentReadyAt = 0.62;
const Duration videoPageTransitionDuration = Duration(milliseconds: 400);
const Duration videoPageReverseTransitionDuration = Duration(milliseconds: 320);
/// 一次转场所需要的全部信息：源卡片本体（量起点矩形）和那个 context。
///
/// 注意这里**不存卡片 widget、也不存截图**：上层那层卡片是从 Hero 的
/// flight shuttle 里拿的（见 [_buildFlightShuttle]），按下这一刻只需要几何。
typedef _PendingVideoTransition = ({
  Object tag,
  RenderBox box,
  BuildContext context,
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

// ────────────────────────── 这一版转场长什么样 ──────────────────────────
//
// 两层同时动，各管一半：
//
//   ① 详情页自己长大。`pageRect` 从「卡片矩形」插值到「整个视口」，页面内容用
//      `BoxFit.cover` 缩放进这个矩形 —— 所以文字和图片是跟着一起放大的，读起来
//      是"卡片长成了详情页"，而不是拿一个窗口去揭开一张本来就全尺寸的页面。
//
//   ② 卡片本体盖在页面**之上**（飞行层，见 [_buildFlightShuttle]），走的也是
//      `pageRect` 那一条：同样的两个端点、同一条曲线、同一个进度 —— 卡片跟着
//      页面一起放大、一起往左上角移，随进度淡出。它负责把"页面矩形刚越过卡片
//      位置、里面显示的是详情页顶部被放大的一小块"这一段藏起来。竖卡横卡一视
//      同仁 —— 横卡矩形是横向的，那一段跳变最明显，最需要这层。
//
// 用卡片本体而不是一块纯色：颜色只能蒙住形状，蒙不住内容；横卡上"左封面 +
// 标题"和"被放大的详情页顶部"差得远，只有把卡片原样盖着才读不出切换。卡片
// 内容自己不带背景，所以底色由这一层补上（[_FlightCardLayer] 里的 `ColoredBox`），
// 放大后多出来的那块就成了卡片的背景。顺带也就没有了浅色主题下满屏泛白那一类
// 问题 —— 底色只铺在页面矩形之内，而矩形是从卡片那一格长出来的。

bool hasPendingVideoCardTransition(Object tag) =>
    _pendingVideoTransition?.tag == tag;

/// Keep only geometry: tapping no longer captures or filters a full-screen image.
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

  /// 卡片底色（卡片所在页面背后透出来的那个颜色）。
  ///
  /// 转场期间用来把上层那张卡片的底铺满 —— 卡片内容自己往往不带背景
  /// （`VideoCardH` 就是一层透明的 Material），在列表里靠页面底色透上来才像
  /// "一张卡片"，放大之后多出来的那块也得继续是这个颜色。
  final Color surfaceColor;
  final Widget child;
  final bool preserveChildHeroes;

  /// 封面 widget 的 key。**当前转场不使用它** —— 现在没有"只飞封面"那条路径，
  /// 整张卡片一起淡。保留是为了让卡片端（`video_card_v.dart` /
  /// `video_card_h.dart`）一行都不用改。
  final GlobalKey? coverKey;

  /// 卡片圆角。卡片自身仍按它裁圆角。
  final double cornerRadius;

  @override
  State<VideoCardHero> createState() => _VideoCardHeroState();
}

class _VideoCardHeroState extends State<VideoCardHero> {
  /// 封面相对卡片左上角的矩形。**当前转场不使用**（留着是因为卡片端还在传
  /// `coverKey`，量一次不影响什么，将来要恢复"只飞封面"直接就能用）。
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

  /// 量出封面在卡片内的矩形。
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
            // 这是转场里唯一在动的几何：详情页以卡片的位置和大小起步，
            // 一路长到铺满屏幕。因为页面内容是用 `BoxFit.cover` 缩放进这个
            // 矩形的，文字和图片都跟着一起放大 —— 读起来就是"卡片本身长成了
            // 详情页"，而不是拿一个窗口去揭开一张本来就全尺寸的页面。
            //
            // 页面之上那一层卡片在飞行层里，由 [_buildFlightShuttle] 负责 ——
            // 它按**同一条曲线、同一组端点**算出自己的矩形（见 [_FlightCardLayer]），
            // 所以两边永远是同一个矩形、同一时刻，卡片跟着页面一起长大。
            // 改这里的写法时，那边要一起改（两处用的是同一个 `_containerCurve`）。
            final pageRect = returning
                ? Rect.lerp(viewport, source, contraction)!
                : Rect.lerp(source, viewport, expansion)!;
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
                // 详情页本体。圆角保持卡片圆角不变 —— 它是"这是一张卡片"这件事
                // 在整段动画里唯一不变的线索。
                Positioned.fromRect(
                  key: const ValueKey('video-transition-page-position'),
                  rect: pageRect,
                  child: ClipRRect(
                    key: const ValueKey('video-transition-page-container'),
                    borderRadius: const BorderRadius.all(
                      Radius.circular(_cardRadius),
                    ),
                    child: FittedBox(
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
                  ),
                ),
                // Hero 的锚点铺满视口。它的 child（[_VideoPageSurface]）什么都不
                // 画，在这个转场里只承担两件事：让 Hero 机制把源卡片的 child
                // 摘掉（否则原卡片会和展开中的页面叠在一起），以及提供转场
                // 进度 —— 飞行层的卡片就是靠它的 shuttle 画出来的。
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

/// 详情页端 Hero 的占位 anchor：它自己不绘制任何东西。
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

  /// 卡片底色。飞行层拿它把放大后的卡片垫满（见 [_FlightCardLayer]）。
  final Color substrateColor;

  /// 封面在卡片里的矩形读取器。**当前转场不使用**，保留是因为卡片端还在传
  /// `coverKey`，量一次不费什么，将来要恢复"只飞封面"直接就能用。
  final ValueGetter<Rect?>? coverReader;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.all(Radius.circular(radius)),
    child: child,
  );
}

/// 飞行层 = **卡片本体 + 卡片底色**，跟着详情页一起放大、一起移动。
///
/// 页面那边（[_VideoPageHeroTargetState]）把矩形从「卡片矩形」插值到「整个视口」；
/// 这一层走的是同一条路 —— 同样的两个端点、同一条 [_containerCurve]、同一个进度。
/// 两边因此永远重合：卡片不会钉在原地等页面长大，也不会比页面快一步或慢半拍。
///
/// 两个端点是**量**出来的（源卡片矩形、详情页矩形），进度直接取详情页那条路由的
/// 动画 —— 就是页面自己用的那个 `Animation` 对象，所以既不依赖 Hero 内部用哪条
/// 曲线，也不存在"页面用路由动画、卡片用飞行层动画"这种代差。
Widget _buildFlightShuttle(
  BuildContext flightContext,
  Animation<double> animation,
  HeroFlightDirection direction,
  BuildContext fromHeroContext,
  BuildContext toHeroContext,
) {
  // 回程时 from/to 互换：卡片始终是"另一头"。
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
  // 卡片复用、列表回收之后这个盒子可能已经不在树上了，这时不画，退回"只有页面"
  // 的老样子 —— 观感打折总比画飞了好。详情页那头量不到同理：少了终点，"长到哪"
  // 就无从谈起。
  if (cardBox is! RenderBox || !cardBox.hasSize || cardBox.size.isEmpty) {
    return const SizedBox.shrink();
  }
  if (pageBox is! RenderBox || !pageBox.hasSize || pageBox.size.isEmpty) {
    return const SizedBox.shrink();
  }
  return _FlightCardLayer(
    // 进度取详情页那条路由的动画（Hero 给的那个只当兜底）：和页面用的是同一个
    // 对象、同一帧同一个值，卡片层和页面因此永远对得上。
    animation: ModalRoute.of(pageContext)?.animation ?? animation,
    flightContext: flightContext,
    returning: returning,
    // 两端都以屏幕坐标量，飞行层内部再减掉 Hero 插值矩形的原点换算过去。
    cardRect: cardBox.localToGlobal(Offset.zero) & cardBox.size,
    viewportRect: pageBox.localToGlobal(Offset.zero) & pageBox.size,
    substrateColor: cardSurface.substrateColor,
    radius: cardSurface.radius,
    card: InheritedTheme.captureAll(
      cardContext,
      Material(
        type: MaterialType.transparency,
        child: cardSurface.flightChild ?? cardSurface,
      ),
    ),
  );
}

/// 跟着页面一起长大的那层卡片。
///
/// 里面画两样：
///
///   · **底色**铺满整个矩形（`ColoredBox`）—— 卡片内容放大后矩形比它高出一大截，
///     多出来的那块必须是卡片自己的背景色，否则露出的就是详情页，穿帮；
///   · **卡片内容**按宽度等比放大（`rect.width / 卡片宽`）、锚在左上角 ——
///     它的左右边缘因此始终贴着矩形的左右边缘（也就是详情页的左右边缘），
///     整段动画读起来就是"这张卡片被拉大成详情页"。
///
/// 卡片内容先按**原尺寸**（`cardRect.size`）布局、再整体缩放，而不是直接把放大后的
/// 尺寸喂给它：卡片排版是跟着宽度走的，直接塞一个大宽度进去，封面比例、标题换行
/// 都会变，那就不是"同一张卡片放大"了。
class _FlightCardLayer extends StatefulWidget {
  const _FlightCardLayer({
    required this.animation,
    required this.flightContext,
    required this.returning,
    required this.cardRect,
    required this.viewportRect,
    required this.substrateColor,
    required this.radius,
    required this.card,
  });

  final Animation<double> animation;
  final BuildContext flightContext;

  /// true = 回程，几何走页面那条 `returning` 分支的曲线。
  final bool returning;

  /// 源卡片在屏幕上的矩形（起点）。
  final Rect cardRect;

  /// 详情页在屏幕上的矩形（终点，通常就是整个视口）。
  final Rect viewportRect;

  /// 卡片底色。
  final Color substrateColor;

  /// 卡片圆角。
  final double radius;

  final Widget card;

  @override
  State<_FlightCardLayer> createState() => _FlightCardLayerState();
}

class _FlightCardLayerState extends State<_FlightCardLayer> {
  /// 第一帧先不画。
  ///
  /// 飞行层的盒子要等父级 Stack 走完一次 layout，`localToGlobal` 才读得到它被
  /// 摆在哪儿（偏移量是 layout 阶段写进 parentData 的），第一帧量出来是屏幕原点，
  /// 会把卡片层整体画偏一张卡片的距离、闪一下。等一帧再画，这点延迟看不出来 ——
  /// 那一帧里页面的展开量还不到 2%，矩形基本压在卡片原来那一格上。
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
    // Hero 把 shuttle 缓存起来当 `AnimatedBuilder.child` 用（`shuttle ??= ...`），
    // 所以它只会被建一次 —— 每一帧的重建必须由这里自己的 AnimatedBuilder 负责，
    // 否则卡片层会停在第一帧的透明度和位置上不动。
    return AnimatedBuilder(
      animation: widget.animation,
      child: widget.card,
      builder: (context, child) {
        // 进度 = 详情页路由动画的值：去程 0 → 1，回程 1 → 0。
        final progress = widget.animation.value;
        // 不透明度跟进度走，去程回程共用一行 —— 同一条曲线在两边都自动是
        // "从有到无"的方向。
        final alpha = 1 - _cardLayerFadeCurve.transform(progress);
        if (!_measured || alpha <= 0.002) return const SizedBox.shrink();
        // 矩形：和 [_VideoPageHeroTargetState] 里那条 `pageRect` 是同一套算法 ——
        // 同一组端点、同一条曲线、同一个进度。页面长到哪，卡片就长到哪。
        //
        // 去程（含"中途被打断、倒着放回去"那种）用主曲线往前插值；
        // 回程用页面 returning 分支那条 easeInOutCubic 收回去。
        final rect = widget.returning
            ? Rect.lerp(
                widget.viewportRect,
                widget.cardRect,
                Curves.easeInOutCubic.transform(1 - progress),
              )!
            : Rect.lerp(
                widget.cardRect,
                widget.viewportRect,
                _containerCurve.transform(progress),
              )!;
        final box = widget.flightContext.findRenderObject();
        final flightOrigin = box is RenderBox && box.hasSize
            ? box.localToGlobal(Offset.zero)
            : Offset.zero;
        // 卡片内容放大到与矩形同宽 —— 系数就是宽度比，所以左右边缘永远贴着矩形。
        final scale = rect.width / widget.cardRect.width;
        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.none,
          children: [
            Positioned.fromRect(
              key: const ValueKey('video-transition-card-layer'),
              rect: rect.shift(-flightOrigin),
              child: Opacity(
                opacity: alpha,
                child: ClipRRect(
                  borderRadius: BorderRadius.all(
                    Radius.circular(widget.radius),
                  ),
                  child: ColoredBox(
                    // 卡片底色铺满整个矩形：卡片内容自己不带背景，靠这一层才
                    // 重新变回"一张卡片"，多出来的那块也成了它的背景。
                    color: widget.substrateColor,
                    child: OverflowBox(
                      // `Positioned.fromRect` 给的是紧约束，直接把固定尺寸的卡片
                      // 塞进去会被压成矩形大小；先解约束再缩放。
                      alignment: Alignment.topLeft,
                      minWidth: 0,
                      minHeight: 0,
                      maxWidth: double.infinity,
                      maxHeight: double.infinity,
                      child: Transform.scale(
                        scale: scale,
                        alignment: Alignment.topLeft,
                        child: SizedBox.fromSize(
                          size: widget.cardRect.size,
                          child: child,
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
    );
  }
}
