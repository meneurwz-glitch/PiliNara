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
// 页面浮现。页面比飞行层早一点开始、也早一点结束浮现，于是飞行层消失的时候
// 下面已经是一张画好的页面，中途不会出现"两头都不在"的空档。
//
// 手感旋钮：把它整体前移（如 0.28/0.72）可以让交接更早、卡片"长大"的时间更短；
// 整体后移则卡片撑得更久、扩张感更强。但**不要晚于 [_coverBlackOutCurve] 的
// 起点** —— 黑块淡出时必须已经有一张完整页面等在下面。
const Curve _revealCurve = Interval(0.34, 0.78, curve: Curves.easeInOutCubic);
/// 封面压黑：扩张的后半段把封面亮度一步步压下去，到 0.78 已经是一块纯黑。
///
/// 为什么需要它：卡片封面是 16:10，而详情页播放器一般是 16:9 —— 封面按宽度
/// 飞到视口宽时，比播放器高出约 6% 视口宽。页面浮现的那一刻，多出来的那条边
/// 会被播放页的信息区"顶掉"，看起来就像封面被压缩了一下。让封面在**到位之前
/// 先黑掉**，这一跳就完全发生在一块纯黑内部，读不出尺寸差。
///
/// 黑的对象和播放器占位同色（`video/view.dart` 里播放器区就是
/// `BoxDecoration(color: Colors.black)`），所以"封面黑掉"在观感上就是
/// "播放器先亮起来"，而不是"画面暗了一下"。
///
/// 手感旋钮：想更早开始变暗就把起点前移（如 0.36）；想让压暗更柔和就换
/// `Curves.easeInOutCubic`，想让它"沉"得更晚更突然就换 `Curves.easeInCubic`。
const Curve _coverDimCurve = Interval(0.44, 0.78, curve: Curves.easeInQuad);
/// 黑块淡出：此时页面（[_revealCurve] 的 0.78 起）已经完全就位，让已经黑透的
/// 封面整块淡掉，露出的就是播放页。
///
/// 封面内容全程**不单独淡出** —— 它被上面那层黑完全盖住，跟着黑一起消失。
/// 否则半途中会看到"半透明的封面"和"半透明的页面"叠在一起，出现鬼影。
const Curve _coverBlackOutCurve = Interval(0.80, 1.0, curve: Curves.easeOutQuad);
/// 横向卡片「封面之外的部分」（标题、UP 名、播放量）的淡出曲线。
///
/// 这些内容不参与飞行，就留在卡片原位。它们必须**早于封面盖到自己**之前淡完：
/// 封面是从卡片左上角向右下扩张的，横向卡片里标题正好在封面右边，当扩张进度
/// 约 0.42 时封面右缘就已经扫到标题了。所以这条曲线要比 [_coverDimCurve]
/// 早得多结束（0.04 → 0.42），否则标题会被长大的封面糊住，看不出"淡出"。
const Curve _titleFadeCurve = Interval(
  0.04,
  0.42,
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

  /// 保留参数只为不改动卡片调用点（`VideoCardV` / `VideoCardH` / 最近播放 /
  /// 动态页都还在传）。转场现在已经不再绘制任何衬底色，这个值不参与渲染。
  final Color surfaceColor;
  final Widget child;
  final bool preserveChildHeroes;

  /// 封面 widget 的 key。给了它就进入「只飞封面」模式：转场时只把封面
  /// （在卡片里的那一块）放大送出，卡片其余部分（标题、UP 名、播放量）
  /// 留在卡片原位淡出 —— 横向卡片用它，避免标题被放大后铺出屏幕右侧。
  ///
  /// 不传则整张卡片一起等比放大（垂直卡片的封面本来就满宽，标题区落在
  /// 封面下方，放大后正好接在播放器下面，不需要单独处理）。
  final GlobalKey? coverKey;

  /// 卡片圆角。飞行层不额外裁切，圆角完全由这里决定；横向卡片没有圆角，
  /// 传 0，封面飞出去时才是直角。
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
  const _CardSurface({
    required this.child,
    this.flightChild,
    this.radius = _cardRadius,
    this.coverReader,
  });

  final Widget child;
  final Widget? flightChild;
  final double radius;

  /// 飞行开始时会被调用一次，用来问"封面在卡片里的哪一块"。
  /// 返回空表示整张卡片一起飞。
  final ValueGetter<Rect?>? coverReader;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.all(Radius.circular(radius)),
    child: child,
  );
}

/// 从「整张卡片」的裁剪路径里挖掉封面那一块，只留下标题等其余部分。
///
/// 飞行层的做法是同一份卡片画两次：一次放大（封面），一次原地（其余）。
/// 如果原地那份不挖洞，它的封面会和放大后的封面叠在一起、出现重影；
/// 而放大后的封面会向右下扩张，反过来又会盖住标题 —— 只有把封面从
/// 「原地那份」里抠掉，标题才能干净地在原位淡出。
///
/// `PathFillType.evenOdd` 让两个子矩形相交处成为空洞，这正是需要的效果。
class _CardMinusCoverClipper extends CustomClipper<Path> {
  const _CardMinusCoverClipper(this.coverRect);
  final Rect coverRect;

  @override
  Path getClip(Size size) => Path()
    ..fillType = PathFillType.evenOdd
    ..addRect(Offset.zero & size)
    ..addRect(coverRect);

  @override
  bool shouldReclip(_CardMinusCoverClipper oldClipper) =>
      oldClipper.coverRect != coverRect;
}

/// 校验量到的封面矩形还能不能用。
///
/// 列表滚动、卡片复用之后，`_CardSurface.coverReader` 里存的矩形可能已经
/// 不属于当前这张卡片了（放在新卡片上尺寸对不上）。这时宁可退回"整张卡片
/// 一起飞"，也不要用一个错的矩形去裁 —— 退化只是观感打折，裁歪是看得见的错。
Rect? _resolveCoverRect(Rect? rect, Size cardSize) {
  if (rect == null || cardSize.isEmpty) return null;
  if (rect.width <= 0 || rect.height <= 0) return null;
  if (rect.right > cardSize.width + 0.5 ||
      rect.bottom > cardSize.height + 0.5) {
    return null;
  }
  return rect;
}

/// 飞行层 = 卡片自己。
///
/// 不再画任何衬底色块，而是让卡片内容跟着 Hero 的矩形一起放大。缩放的基准是
/// **封面**，于是起点缩放 1:1（画面与静止的卡片逐像素一致，起飞那一帧没有
/// 任何跳变），终点封面宽度正好等于视口宽度 —— 封面是 16:10，所以那一刻封面
/// 高度 ≈ 视口宽 × 10/16，正是详情页播放器该在的位置和大小，左上角也钉在
/// 屏幕左上角。"封面长到播放器该在的地方"是几何上算出来的，不是靠叠一层色块
/// 蒙出来的。剩下的只是交接，分三步：
///
///   1. 封面在 [_coverDimCurve] 区间被一步步压黑，到位之前已经是一块纯黑
///      —— 和播放器占位同色，所以这一步读起来是"播放器先亮起来"；
///   2. 页面在 [_revealCurve] 区间完成浮现（此时被上面的黑盖着，看不见）；
///   3. 黑透的封面整块在 [_coverBlackOutCurve] 区间淡出，露出的就是播放页。
///
/// 先黑掉再淡出（而不是直接交叉淡出）是为了**藏住尺寸差**：封面 16:10、
/// 播放器一般 16:9，封面到位时比播放器高出约 6% 视口宽，直接切过去会看到
/// 一下轻微收缩。压黑之后，这一点点尺寸变化发生在一块纯黑内部，读不出来。
///
/// 两种模式：
///
///   · **整张卡片一起飞**（默认，垂直卡片用）：卡片是"封面满宽、标题在下方"，
///     放大后封面正对播放器、标题区落在播放器下面，与详情页的信息区同序；
///   · **只飞封面**（传了 [VideoCardHero.coverKey] 时，横向卡片用）：横向卡片的
///     标题在封面右侧，跟着放大会铺出屏幕右边被硬裁掉。所以这里只放大封面，
///     卡片其余部分（标题、UP 名、播放量）留在卡片原位、按 [_titleFadeCurve]
///     先淡出。正文层用 [_CardMinusCoverClipper] 把封面那块挖掉，避免和放大的
///     封面重影。
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
  final cardSurface = cardHero.child as _CardSurface;
  final renderBox = cardContext.findRenderObject() as RenderBox?;
  final cardSize = renderBox?.size ?? const Size(1, 1);
  // 卡片在屏幕上的位置。飞行层的坐标系原点是 Hero 插值矩形的左上角，而矩形
  // 一路上在往屏幕左上角收（`_VideoCardRectTween` 的 lerp），所以这个值要用来
  // 把"留在原位"的那一层补偿回屏幕坐标（见下面 restAt）。
  final cardOrigin = renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
  Widget buildCard() => InheritedTheme.captureAll(
    cardContext,
    Material(
      type: MaterialType.transparency,
      child: cardSurface.flightChild ?? cardSurface,
    ),
  );
  final card = buildCard();
  final coverRect = _resolveCoverRect(cardSurface.coverReader?.call(), cardSize);
  // 只飞封面时要画两份卡片：一份放大送出（封面），一份留在原位淡出（其余）。
  final cardBody = coverRect == null ? null : buildCard();
  return AnimatedBuilder(
    animation: animation,
    // 内层的两份卡片是同一个 Widget 实例、每帧复用（外层节点才随动画重建），
    // 所以不会每帧重建卡片子树。
    builder: (context, _) {
      // 返回走同一条曲线的时间倒数，保证"从哪里来回哪里去"。
      final contraction = Curves.easeInOutCubic.transform(1 - animation.value);
      // 扩张进度：去程与 Hero 的矩形走同一条曲线，回程是它的时间倒数。
      final expansion = returning
          ? 1 - contraction
          : _containerCurve.transform(animation.value);
      // 压暗量：去程在扩张后半段把封面一步步压黑，到位之前已经是纯黑；回程不压
      // —— 收缩回卡片的过程中封面必须是原样，否则落地会从黑色弹回图片。
      final dim = returning ? 0.0 : _coverDimCurve.transform(animation.value);
      // 整层的透明度：回程由收缩进度决定（Hero 交还给卡片之前必须已经完全不
      // 透明，否则落地会闪一下）；去程由 [_coverBlackOutCurve] 决定 —— 封面内容
      // 不再单独淡出，而是先被 [dim] 压黑、再随整块黑一起淡掉。
      final opacity = returning
          ? Curves.easeOutCubic.transform(contraction)
          : 1 - _coverBlackOutCurve.transform(animation.value);
      final viewportWidth =
          MediaQuery.maybeSizeOf(context)?.width ?? cardSize.width;
      final cardAtSize = SizedBox.fromSize(size: cardSize, child: card);
      // 压暗 = 在内容上盖一层黑，只作用到内容自己的不透明像素（`srcATop`），所以
      // 不必操心尺寸和裁切 —— 它跟着封面一起被缩放。`dim` 为 0 时直接把子树原样
      // 返回，回程和转场首尾就不必多建一层图层。
      Widget dimmed(Widget child) => dim <= 0
          ? child
          : ColorFiltered(
              colorFilter: ColorFilter.mode(
                Colors.black.withValues(alpha: dim),
                BlendMode.srcATop,
              ),
              child: child,
            );

      if (coverRect == null) {
        // —— 整张卡片一起放大 ——
        // 以封面为基准，终点让封面宽度正好等于视口宽度。以"整张卡片"为基准的话，
        // 垂直卡片（封面满宽）恰好等价，但横向卡片（封面只占卡片左侧）宽度本来
        // 就接近视口，会几乎不放大。
        final coverWidth = math.min(
          cardSize.width,
          cardSize.height * _coverAspect,
        );
        final scale = ui.lerpDouble(1, viewportWidth / coverWidth, expansion)!;
        // 这里刻意**不加**外层 ClipRRect：它的尺寸等于 Hero 的矩形，会对放大的
        // 卡片产生一条"人造裁边"；超出的部分交给 Overlay 自己的 Clip.hardEdge
        // 收掉，边界正好是屏幕边。圆角由 [_CardSurface] 跟着缩放一起变大。
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
              child: dimmed(RepaintBoundary(child: cardAtSize)),
            ),
          ),
        );
      }

      // —— 只飞封面 ——
      // 封面从"卡片上的那一块"长到"屏幕左上角、铺满视口宽度"；卡片其余部分
      // 不放大、留在原位先淡出。
      final coverScale = ui.lerpDouble(
        1,
        viewportWidth / coverRect.width,
        expansion,
      )!;
      // 封面在卡片里的左/上留白，随扩张收回到 0 —— 于是它的左上角从"卡片里
      // 封面的位置"平滑滑到"屏幕左上角"。
      final coverAt = Offset(
        coverRect.left * (1 - expansion),
        coverRect.top * (1 - expansion),
      );
      // 标题层的坐标系补偿。
      //
      // 飞行层的原点是 Hero 插值矩形的左上角，而这个矩形在去程里从"卡片位置"
      // 一路收到屏幕左上角：局部原点在屏幕上的位置 = cardOrigin × (1 - expansion)。
      // 标题层要的是"在屏幕上站着不动"，所以它的局部位移必须与之互补：
      //     cardOrigin - cardOrigin × (1 - expansion) = cardOrigin × expansion。
      // （封面层不需要这层补偿 —— 它的目标本来就是从卡片上的封面位置移到屏幕
      //   左上角，两个位移正好抵消成 `coverRect.topLeft × (1 - expansion)`。）
      final restAt = Offset(
        cardOrigin.dx * expansion,
        cardOrigin.dy * expansion,
      );
      final bodyOpacity = returning
          ? Curves.easeOutCubic.transform(contraction)
          : 1 - _titleFadeCurve.transform(animation.value);
      return Stack(
        key: ValueKey(
          returning
              ? 'video-transition-return-card'
              : 'video-transition-flight',
        ),
        fit: StackFit.expand,
        clipBehavior: Clip.none,
        children: [
          // ① 标题、UP 名、播放量……：原位原尺寸，先于封面淡完。
          //    挖掉封面那一块，这样它既不会和放大的封面重影，标题也能露出来
          //    让人看见它在淡出（否则会被长大的封面直接盖住）。
          Positioned.fromRect(
            key: const ValueKey('video-transition-flight-body'),
            rect: restAt & cardSize,
            child: Opacity(
              opacity: bodyOpacity,
              child: ClipPath(
                clipper: _CardMinusCoverClipper(coverRect),
                child: RepaintBoundary(
                  child: SizedBox.fromSize(size: cardSize, child: cardBody),
                ),
              ),
            ),
          ),
          // ② 封面：终点宽度正好等于视口宽度，高度 ≈ 视口宽 × 10/16，
          //    正是详情页播放器该在的位置和大小。
          Positioned.fromRect(
            key: const ValueKey('video-transition-flight-cover'),
            rect: coverAt & coverRect.size,
            child: Opacity(
              opacity: opacity,
              child: Transform.scale(
                scale: coverScale,
                alignment: Alignment.topLeft,
                // 只取卡片里封面那一块：
                //   · SizedBox 钉死盒子 = 封面在卡片里的矩形；
                //   · OverflowBox 把卡片从紧约束里解放出来（否则卡片会被压成
                //     封面大小、文字重排，而不是"原样的一块被截出来"）；
                //   · Transform.translate 把卡片左上平移掉封面的左/上偏移，
                //     封面内容就正好落在盒子左上角；
                //   · ClipRect 收掉封面右边多出来的部分。
                child: ClipRect(
                  child: SizedBox.fromSize(
                    size: coverRect.size,
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: 0.0,
                      minHeight: 0.0,
                      maxWidth: double.infinity,
                      maxHeight: double.infinity,
                      child: Transform.translate(
                        offset: -coverRect.topLeft,
                        child: dimmed(RepaintBoundary(child: cardAtSize)),
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


