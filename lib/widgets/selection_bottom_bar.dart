import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:spotiflac_android/theme/app_tokens.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/mornye_chrome.dart';
import 'package:spotiflac_android/widgets/app_bottom_sheet.dart';
import 'package:spotiflac_android/l10n/l10n.dart';

/// Hosts selection bars above the shell navigation while keeping modal routes
/// above the bar. A raw entry in the root [Overlay] stays above routes pushed
/// later, which made download pickers appear behind the selection toolbar.
class SelectionOverlayHost extends StatefulWidget {
  const SelectionOverlayHost({super.key, required this.child});

  final Widget child;

  static _SelectionOverlayHostState? _maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<_SelectionOverlayHostState>();

  @override
  State<SelectionOverlayHost> createState() => _SelectionOverlayHostState();
}

class _SelectionOverlayHostState extends State<SelectionOverlayHost> {
  SelectionOverlayController? _owner;
  WidgetBuilder? _builder;

  bool owns(SelectionOverlayController owner) =>
      _owner == owner && _builder != null;

  void show(SelectionOverlayController owner, WidgetBuilder builder) {
    _update(() {
      _owner = owner;
      _builder = builder;
    });
  }

  void hide(SelectionOverlayController owner) {
    if (_owner != owner) return;
    _update(() {
      _owner = null;
      _builder = null;
    });
  }

  /// A screen can remove its bar from dispose while Flutter has locked the
  /// tree. Clear ownership immediately, then rebuild after that frame so the
  /// bar cannot outlive the screen or retain its disposed callbacks.
  void _update(VoidCallback change) {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      setState(change);
      return;
    }
    change();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final owner = _owner;
    final builder = _builder;
    // A root modal makes the shell route non-current. Removing the toolbar
    // while that route is covered both prevents visual overlap and avoids the
    // hidden toolbar intercepting taps during the modal transition. The stored
    // builder is kept so the selection returns if the modal is dismissed.
    final routeIsCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        if (routeIsCurrent && owner != null && builder != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: KeyedSubtree(
              key: ObjectKey(owner),
              child: AnimatedSelectionBottomBar(
                child: Material(
                  color: Colors.transparent,
                  child: Builder(builder: builder),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Mounts a selection bar in [SelectionOverlayHost]. Screens rendered outside
/// the main shell (including isolated widget tests) retain a root-overlay
/// fallback.
class SelectionOverlayController {
  OverlayEntry? _entry;
  _SelectionOverlayHostState? _host;
  WidgetBuilder? _builder;

  bool get isVisible => _entry != null || (_host?.owns(this) ?? false);

  /// Shows the bar, or rebuilds it in place when already visible so the
  /// entrance animation does not replay on every selection change.
  void show(BuildContext context, WidgetBuilder builder) {
    if (!TickerMode.valuesOf(context).enabled) {
      hide();
      return;
    }

    _builder = builder;
    final host = SelectionOverlayHost._maybeOf(context);
    if (host != null) {
      _entry?.remove();
      _entry = null;
      if (_host != null && _host != host) {
        _host!.hide(this);
      }
      _host = host;
      host.show(this, builder);
      return;
    }

    _host?.hide(this);
    _host = null;
    if (_entry != null) {
      _entry!.markNeedsBuild();
      return;
    }
    _entry = OverlayEntry(
      builder: (overlayContext) => Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: AnimatedSelectionBottomBar(
          child: Material(
            color: Colors.transparent,
            child: _builder!(overlayContext),
          ),
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  void hide() {
    _host?.hide(this);
    _host = null;
    _entry?.remove();
    _entry = null;
    _builder = null;
  }

  /// Call from the host `State.dispose`; an entry left in the root overlay
  /// outlives the screen that created it.
  void dispose() => hide();
}

/// Entrance animation shared by selection bars mounted in the root overlay.
class AnimatedSelectionBottomBar extends StatefulWidget {
  const AnimatedSelectionBottomBar({super.key, required this.child});

  final Widget child;

  @override
  State<AnimatedSelectionBottomBar> createState() =>
      _AnimatedSelectionBottomBarState();
}

class _AnimatedSelectionBottomBarState extends State<AnimatedSelectionBottomBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(curve);
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(curve);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: SlideTransition(position: _slideAnimation, child: widget.child),
    );
  }
}

/// Shared chrome for the multi-select bottom bar: rounded surface, drag
/// handle, close button, "N selected" header and select-all toggle.
/// The screen-specific action buttons go in [children].
class SelectionBottomBar extends StatelessWidget {
  const SelectionBottomBar({
    super.key,
    required this.selectedCount,
    required this.allSelected,
    required this.onClose,
    required this.onToggleSelectAll,
    required this.bottomPadding,
    required this.children,
    this.allSelectedLabel,
    this.tapToSelectLabel,
  });

  final int selectedCount;
  final bool allSelected;
  final VoidCallback onClose;
  final VoidCallback onToggleSelectAll;
  final double bottomPadding;
  final List<Widget> children;

  /// Overrides the default "All tracks selected" subtitle.
  final String? allSelectedLabel;

  /// Overrides the default "Tap tracks to select" subtitle.
  final String? tapToSelectLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;

    final content = SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, bottomPadding > 0 ? 8 : 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppSheetHandle(),

            Row(
              children: [
                if (context.isMornye)
                  Tooltip(
                    message: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    child: CupertinoButton(
                      color: MornyeTheme.controlFill(context),
                      borderRadius: BorderRadius.circular(28),
                      padding: const EdgeInsets.all(12),
                      onPressed: onClose,
                      child: Icon(
                        CupertinoIcons.xmark,
                        color: colorScheme.onSurface,
                        size: 24,
                      ),
                    ),
                  )
                else
                  IconButton.filledTonal(
                    onPressed: onClose,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    icon: const Icon(Icons.close),
                    style: IconButton.styleFrom(
                      backgroundColor: colorScheme.surfaceContainerHighest,
                    ),
                  ),
                const SizedBox(width: 12),

                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.l10n.selectionSelected(selectedCount),
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        allSelected
                            ? allSelectedLabel ??
                                  context.l10n.selectionAllSelected
                            : tapToSelectLabel ??
                                  context.l10n.downloadedAlbumTapToSelect,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),

                if (context.isMornye)
                  CupertinoButton(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    onPressed: onToggleSelectAll,
                    child: Text(
                      allSelected
                          ? context.l10n.actionDeselect
                          : context.l10n.actionSelectAll,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: colorScheme.primary,
                      ),
                    ),
                  )
                else
                  TextButton.icon(
                    onPressed: onToggleSelectAll,
                    icon: Icon(
                      allSelected ? Icons.deselect : Icons.select_all,
                      size: 20,
                    ),
                    label: Text(
                      allSelected
                          ? context.l10n.actionDeselect
                          : context.l10n.actionSelectAll,
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: colorScheme.primary,
                    ),
                  ),
              ],
            ),

            const SizedBox(height: 12),

            ...children,
          ],
        ),
      ),
    );
    return _SelectionPanelDrag(
      onClose: onClose,
      builder: (scrollController) {
        final boundedContent = ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: SingleChildScrollView(
            controller: scrollController,
            physics: const AlwaysScrollableScrollPhysics(
              parent: ClampingScrollPhysics(),
            ),
            child: content,
          ),
        );
        if (context.isMornye) {
          return MornyeGlassPanel.overlay(child: boundedContent);
        }
        return Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(tokens.radiusSheet),
            ),
            boxShadow: [
              BoxShadow(
                color: colorScheme.shadow.withValues(alpha: 0.15),
                blurRadius: 12,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: boundedContent,
        );
      },
    );
  }
}

/// Shares the scrollable's gesture: downward motion at its top pulls the whole
/// surface instead of bouncing the header inside a stationary glass panel.
class _SelectionPanelDrag extends StatefulWidget {
  const _SelectionPanelDrag({required this.onClose, required this.builder});

  final VoidCallback onClose;
  final Widget Function(ScrollController) builder;

  @override
  State<_SelectionPanelDrag> createState() => _SelectionPanelDragState();
}

class _SelectionPanelDragState extends State<_SelectionPanelDrag>
    with SingleTickerProviderStateMixin {
  late final AnimationController _offset = AnimationController.unbounded(
    vsync: this,
  );
  late final _SelectionPanelScrollController _scroll =
      _SelectionPanelScrollController(_drag, _settle);
  bool _closing = false;

  double _drag(double delta) {
    if (_closing) return 0;
    _offset.stop();
    final previous = _offset.value;
    _offset.value = (previous + delta).clamp(0.0, double.infinity);
    return delta - (_offset.value - previous);
  }

  bool _settle(double velocity) {
    if (_closing) return true;
    if (_offset.value == 0) return false;
    final height = context.size?.height ?? 0;
    _closing =
        velocity > 700 ||
        (velocity >= -700 && _offset.value >= (height * 0.25).clamp(64, 120));
    _animateToRest(_closing ? height : 0);
    return true;
  }

  Future<void> _animateToRest(double target) async {
    try {
      await _offset
          .animateTo(
            target,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          )
          .orCancel;
      if (mounted && _closing) widget.onClose();
    } on TickerCanceled {
      // Another drag or route disposal can interrupt the settling animation.
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _offset,
    builder: (_, child) =>
        Transform.translate(offset: Offset(0, _offset.value), child: child),
    child: widget.builder(_scroll),
  );
}

class _SelectionPanelScrollController extends ScrollController {
  _SelectionPanelScrollController(this.dragPanel, this.settlePanel);

  final double Function(double) dragPanel;
  final bool Function(double) settlePanel;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) => _SelectionPanelScrollPosition(
    physics: physics,
    context: context,
    oldPosition: oldPosition,
    dragPanel: dragPanel,
    settlePanel: settlePanel,
  );
}

class _SelectionPanelScrollPosition extends ScrollPositionWithSingleContext {
  _SelectionPanelScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.dragPanel,
    required this.settlePanel,
  });

  final double Function(double) dragPanel;
  final bool Function(double) settlePanel;

  @override
  void applyUserOffset(double delta) {
    // Scroll back to the top before handing any remaining drag to the panel.
    if (delta > 0 && pixels > minScrollExtent) {
      final scrollDelta = delta.clamp(0.0, pixels - minScrollExtent);
      super.applyUserOffset(scrollDelta);
      delta -= scrollDelta;
    }
    final remaining = dragPanel(delta);
    if (remaining != 0) super.applyUserOffset(remaining);
  }

  @override
  void goBallistic(double velocity) {
    final movingPanel = settlePanel(-velocity);
    super.goBallistic(movingPanel ? 0 : velocity);
  }
}
