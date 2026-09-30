import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:spotiflac_android/providers/runtime_profile_provider.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/native_glass_metrics.dart';

class MornyeSegmentedControl extends ConsumerWidget {
  const MornyeSegmentedControl({
    super.key,
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
  });

  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final blur =
        !MediaQuery.highContrastOf(context) &&
        ref.watch(mornyeBlurEnabledProvider);
    final animate = !MediaQuery.disableAnimationsOf(context);
    // At 0% clarity the material is opaque; drop the shader pill as
    // MornyeGlass drops its lens.
    final clear = MornyeTheme.glassClarityOf(context) > 0;
    final height = MediaQuery.textScalerOf(context).scale(15) + 36;
    if (!blur || !animate || !clear || !ref.watch(mornyeLiquidGlassProvider)) {
      // The Impeller tab bar ignores its pill mode and always runs its shader
      // passes. Without blur or motion, draw the resting segments directly.
      return _plainSegments(context, blur: blur, height: height);
    }
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final visualLabels = rtl ? labels.reversed.toList() : labels;
    int logicalIndex(int index) => rtl ? labels.length - 1 - index : index;
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: height + 16,
        child: MediaQuery.removePadding(
          context: context,
          removeBottom: true,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 8,
                  height: height,
                  child: _MornyeGlassSurface(
                    blurEnabled: blur,
                    radius: height / 2,
                    child: const SizedBox.expand(),
                  ),
                ),
                NativeGlassMetrics(
                  child: LiquidGlassTabBar.withImpeller(
                    width: constraints.maxWidth,
                    height: height,
                    margin: const EdgeInsets.only(bottom: 8),
                    itemPadding: 4,
                    selectedIndex: logicalIndex(selectedIndex),
                    onChanged: (index) => onChanged(logicalIndex(index)),
                    style: const LiquidGlassStyle(
                      shape: LiquidGlassShape.continuousRoundedRectangle(
                        cornerRadius: 32,
                        borderWidth: 0,
                        lightIntensity: 0,
                      ),
                      appearance: LiquidGlassAppearance(),
                      refraction: LiquidGlassRefraction(
                        distortion: 0,
                        chromaticAberration: 0,
                      ),
                    ),
                    pillStyle: const LiquidGlassTabPillStyle(
                      mode: LiquidGlassPillMode.impellerOnly,
                      animated: true,
                    ),
                    itemStyle: LiquidGlassTabItemStyle(
                      selectedColor: scheme.onSurface,
                      unselectedColor: scheme.onSurface,
                      iconSize: 0,
                      iconLabelGap: 0,
                      labelFontSize: 15,
                    ),
                    items: [
                      for (final label in visualLabels)
                        LiquidGlassTabBarItem(
                          label: label,
                          iconBuilder: (_, _) => const SizedBox.shrink(),
                          labelBuilder: (context, state) => Text(
                            label,
                            textDirection: rtl
                                ? TextDirection.rtl
                                : TextDirection.ltr,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurface,
                              fontWeight: state.selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _plainSegments(
    BuildContext context, {
    required bool blur,
    required double height,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selectionFill = scheme.onSurface.withValues(
      alpha: scheme.brightness == Brightness.dark ? 0.12 : 0.08,
    );
    final radius = BorderRadius.circular(height / 2);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        height: height,
        child: _MornyeGlassSurface(
          blurEnabled: blur,
          radius: height / 2,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Row(
              children: [
                for (var index = 0; index < labels.length; index++)
                  Expanded(
                    child: Semantics(
                      button: true,
                      selected: index == selectedIndex,
                      child: Material(
                        color: index == selectedIndex
                            ? selectionFill
                            : Colors.transparent,
                        borderRadius: radius,
                        child: InkWell(
                          borderRadius: radius,
                          onTap: () => onChanged(index),
                          child: Center(
                            child: Text(
                              labels[index],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: index == selectedIndex
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The bounded, translucent chrome used by Mornye's tab accessory. Blur is
/// limited to the control itself and follows the app's device performance gate.
class MornyeGlassPanel extends ConsumerWidget {
  const MornyeGlassPanel({
    super.key,
    required this.child,
    this.radius = 32,
    this.firstInGroup = true,
    this.lastInGroup = true,
    this.strongTint = false,
    this.tintOpacity,
    this.tintColor,
    this.backdropFilter,
    this.blurEnabled = true,
  });

  /// Shared glass material for confirmation dialogs and floating sheets.
  const MornyeGlassPanel.overlay({
    super.key,
    required this.child,
    this.radius = 32,
    this.firstInGroup = true,
    this.lastInGroup = true,
    this.tintOpacity = 0.78,
    this.tintColor,
    this.backdropFilter,
    this.blurEnabled = true,
  }) : strongTint = false;

  final Widget child;
  final double radius;
  final bool firstInGroup;
  final bool lastInGroup;
  final bool strongTint;
  final double? tintOpacity;
  final Color? tintColor;
  final ImageFilter? backdropFilter;

  /// Disable backdrop sampling for surfaces that scroll over a plain page.
  final bool blurEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blur =
        blurEnabled &&
        !MediaQuery.highContrastOf(context) &&
        ref.watch(mornyeBlurEnabledProvider);
    return MornyeGlass.navigation(
      radius: radius,
      firstInGroup: firstInGroup,
      lastInGroup: lastInGroup,
      strongTint: strongTint,
      tintOpacity: tintOpacity,
      tintColor: tintColor,
      backdropFilter: backdropFilter,
      blurEnabled: blur,
      child: Material(color: Colors.transparent, child: child),
    );
  }
}

class MornyeGlass extends StatelessWidget {
  const MornyeGlass({
    super.key,
    required this.child,
    required this.blurEnabled,
    this.radius = 32,
    this.strongTint = false,
    this.tintOpacity,
    this.tintColor,
    this.backdropFilter,
  }) : _useLens = true,
       firstInGroup = true,
       lastInGroup = true;

  /// Shares the navigation bar's tint, blur and visible outer rim.
  const MornyeGlass.navigation({
    super.key,
    required this.child,
    required this.blurEnabled,
    this.radius = 32,
    this.firstInGroup = true,
    this.lastInGroup = true,
    this.strongTint = false,
    this.tintOpacity,
    this.tintColor,
    this.backdropFilter,
  }) : _useLens = false;

  final Widget child;
  final bool blurEnabled;
  final double radius;
  final bool _useLens;
  final bool firstInGroup;
  final bool lastInGroup;

  /// Keeps floating controls readable over arbitrary album artwork.
  final bool strongTint;

  /// Base tint before applying the user's glass clarity preference.
  final double? tintOpacity;
  final Color? tintColor;
  final ImageFilter? backdropFilter;

  @override
  Widget build(BuildContext context) {
    final clarity = MornyeTheme.glassClarityOf(context);
    final useGlass =
        _useLens &&
        blurEnabled &&
        clarity > 0 &&
        !MediaQuery.highContrastOf(context);
    Widget lens(Widget child) => Consumer(
      // Mid-range Android keeps the frosted surface but not the shader lens.
      builder: (context, ref, child) =>
          ref.watch(mornyeLiquidGlassProvider) ? _liquidLens(child!) : child!,
      child: child,
    );
    return _MornyeGlassSurface(
      blurEnabled: blurEnabled,
      radius: radius,
      firstInGroup: firstInGroup,
      lastInGroup: lastInGroup,
      strongTint: strongTint,
      tintOpacity: tintOpacity,
      tintColor: tintColor,
      backdropFilter: backdropFilter,
      child: useGlass ? lens(child) : child,
    );
  }

  Widget _liquidLens(Widget child) => Builder(
    builder: (context) => NativeGlassMetrics(
      child: LiquidGlassLens(
        style: LiquidGlassStyle(
          shape: LiquidGlassShape.continuousRoundedRectangle(
            cornerRadius: radius,
            // The shared rim owns directional highlights, including
            // surfaces without a lens. Avoid a second specular border.
            borderWidth: 0,
            lightIntensity: 0,
          ),
          appearance: const LiquidGlassAppearance(
            color: Colors.transparent,
            // The surface already blurs the backdrop. Refracting that
            // frosted result needs no second Gaussian blur pass.
            blur: LiquidGlassBlur(),
          ),
          refraction: const LiquidGlassRefraction(
            distortion: 0.02,
            distortionWidth: 8,
            chromaticAberration: 0,
          ),
        ),
        // Only the shader uses window metrics; responsive content and
        // decoded artwork retain the surrounding tablet layout scale.
        child: MediaQuery(data: MediaQuery.of(context), child: child),
      ),
    ),
  );
}

/// Keep the capsule legible independently of the shader renderer. The liquid
/// lens adds refraction above this frosted base, never above bare page text.
class _MornyeGlassSurface extends StatelessWidget {
  static final _backdropBlur = ImageFilter.blur(sigmaX: 18, sigmaY: 18);
  // Reduce luminance without flattening the backdrop's color differences.
  // Subtract 35% of Rec.709 luma from every channel: white is bounded at 0.65,
  // while colored artwork stays visible without per-frame pixel readback.
  static final _darkBackdrop = ImageFilter.compose(
    outer: const ColorFilter.matrix([
      0.92559,
      -0.25032,
      -0.02527,
      0,
      0,
      -0.07441,
      0.74968,
      -0.02527,
      0,
      0,
      -0.07441,
      -0.25032,
      0.97473,
      0,
      0,
      0,
      0,
      0,
      1,
      0,
    ]),
    inner: _backdropBlur,
  );

  const _MornyeGlassSurface({
    required this.child,
    required this.blurEnabled,
    this.radius = 32,
    this.firstInGroup = true,
    this.lastInGroup = true,
    this.strongTint = false,
    this.tintOpacity,
    this.tintColor,
    this.backdropFilter,
  });

  final Widget child;
  final bool blurEnabled;
  final double radius;
  final bool firstInGroup;
  final bool lastInGroup;
  final bool strongTint;
  final double? tintOpacity;
  final Color? tintColor;
  final ImageFilter? backdropFilter;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clarity = MornyeTheme.glassClarityOf(context);
    final useBlur =
        blurEnabled && clarity > 0 && !MediaQuery.highContrastOf(context);
    final dark = scheme.brightness == Brightness.dark;
    final shape = BorderRadius.vertical(
      top: firstInGroup ? Radius.circular(radius) : Radius.zero,
      bottom: lastInGroup ? Radius.circular(radius) : Radius.zero,
    );
    // A translucent white tint must not become solid white behind light
    // text when accessibility or the device profile disables blur.
    final baseTint = (tintColor ?? scheme.surfaceContainerHigh).withValues(
      alpha: (tintOpacity ?? (strongTint ? 0.80 : 0.60)) * (dark ? 0.82 : 0.88),
    );
    final tint = useBlur
        ? Color.alphaBlend(
            scheme.surfaceContainerHigh.withValues(alpha: 1 - clarity),
            baseTint,
          )
        : scheme.surfaceContainerHigh;
    final surface = DecoratedBox(
      decoration: BoxDecoration(color: tint, borderRadius: shape),
      child: child,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: firstInGroup && lastInGroup
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: dark ? 0.14 : 0.08),
                  blurRadius: 12,
                  // Clear glass keeps its tint; the shadow belongs outside
                  // the panel, not underneath its translucent center.
                  blurStyle: BlurStyle.outer,
                  offset: const Offset(0, 3),
                ),
              ]
            : null,
      ),
      child: CustomPaint(
        foregroundPainter: _MornyeGlassRim(
          shape: shape,
          firstInGroup: firstInGroup,
          lastInGroup: lastInGroup,
          illuminated: useBlur,
        ),
        child: ClipRRect(
          borderRadius: shape,
          child: useBlur
              ? BackdropFilter(
                  filter:
                      backdropFilter ?? (dark ? _darkBackdrop : _backdropBlur),
                  child: surface,
                )
              : surface,
        ),
      ),
    );
  }
}

/// Static, axis-aligned highlights: bright upper/lower inner edges and a thin
/// shadow at the sides. No offscreen layer, extra blur, or per-frame readback.
class _MornyeGlassRim extends CustomPainter {
  const _MornyeGlassRim({
    required this.shape,
    required this.firstInGroup,
    required this.lastInGroup,
    required this.illuminated,
  });

  final BorderRadius shape;
  final bool firstInGroup;
  final bool lastInGroup;
  final bool illuminated;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bounds = Offset.zero & size;
    final outline = shape.toRRect(
      Rect.fromLTRB(
        0,
        firstInGroup ? 0 : -2,
        size.width,
        lastInGroup ? size.height : size.height + 2,
      ),
    );
    canvas.save();
    canvas.clipRect(bounds);
    canvas.drawRRect(
      outline.deflate(0.25),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = Colors.black.withValues(alpha: 0.22),
    );
    if (illuminated) {
      canvas.drawRRect(
        outline.deflate(0.9),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            stops: const [0, 0.18, 0.5, 0.82, 1],
            colors: [
              firstInGroup ? const Color(0x99ffffff) : Colors.transparent,
              const Color(0x18ffffff),
              const Color(0x30000000),
              const Color(0x18ffffff),
              lastInGroup ? const Color(0x80ffffff) : Colors.transparent,
            ],
          ).createShader(bounds),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MornyeGlassRim oldDelegate) =>
      shape != oldDelegate.shape ||
      firstInGroup != oldDelegate.firstInGroup ||
      lastInGroup != oldDelegate.lastInGroup ||
      illuminated != oldDelegate.illuminated;
}

/// A searchable category uses the same material as the navigation capsule.
class MornyeFilterChip extends ConsumerWidget {
  const MornyeFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.blurEnabled = true,
    this.glass = true,
    this.tonal = true,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool blurEnabled;
  final bool glass;
  final bool tonal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final content = Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      child: Material(
        color: !glass && !tonal
            ? Colors.transparent
            : selected
            ? scheme.primary.withValues(alpha: 0.12)
            : glass
            ? Colors.transparent
            : MornyeTheme.controlFill(context, enabled: onTap != null),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                ],
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: selected ? scheme.primary : scheme.onSurface,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!glass) {
      return ClipRRect(borderRadius: BorderRadius.circular(24), child: content);
    }
    return MornyeGlass.navigation(
      radius: 24,
      blurEnabled: blurEnabled && ref.watch(mornyeBlurEnabledProvider),
      child: content,
    );
  }
}

class MornyeTabBar extends StatelessWidget {
  const MornyeTabBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.blurEnabled,
    this.liquidGlass = true,
    this.hiddenIconIndices = const {},
  });

  /// Shader capsule and travelling pill; otherwise the frosted row below.
  final bool liquidGlass;

  /// Whether the bar renders the shader capsule. Overlays aligned with its
  /// icons must use the same decision. At 0% clarity the material is opaque,
  /// so the shader pill is dropped as MornyeGlass drops its lens.
  static bool usesLiquidGlass(
    BuildContext context, {
    required bool blurEnabled,
    required bool liquidGlass,
  }) =>
      blurEnabled &&
      liquidGlass &&
      MornyeTheme.glassClarityOf(context) > 0 &&
      !MediaQuery.disableAnimationsOf(context) &&
      !MediaQuery.highContrastOf(context);

  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final bool blurEnabled;
  // The active and Search icons move independently while the capsule folds.
  final Set<int> hiddenIconIndices;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final selectionFill = scheme.onSurface.withValues(
      alpha: scheme.brightness == Brightness.dark ? 0.12 : 0.08,
    );
    final inactiveIconColor = scheme.onSurface;
    if (usesLiquidGlass(
      context,
      blurEnabled: blurEnabled,
      liquidGlass: liquidGlass,
    )) {
      return LayoutBuilder(
        builder: (context, constraints) => SizedBox(
          // Leave room above and below for the travelling pill to lift and
          // stretch; its shader must not be clipped to the resting capsule.
          height: 80,
          child: MediaQuery.removePadding(
            context: context,
            removeBottom: true,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 8,
                  height: 64,
                  child: _MornyeGlassSurface(
                    blurEnabled: blurEnabled,
                    strongTint: true,
                    tintOpacity: MornyeTheme.navigationOpacity(context),
                    child: const SizedBox.expand(),
                  ),
                ),
                NativeGlassMetrics(
                  child: LiquidGlassTabBar.withImpeller(
                    width: constraints.maxWidth,
                    height: 64,
                    margin: const EdgeInsets.only(bottom: 8),
                    selectedIndex: selectedIndex < 0 ? 0 : selectedIndex,
                    onChanged: onSelected,
                    style: LiquidGlassTabBar.defaultStyle.copyWith(
                      // The frosted base owns the subtle outline. Disable the
                      // package's default specular rim around the whole capsule.
                      shape: const LiquidGlassShape.continuousRoundedRectangle(
                        cornerRadius: 32,
                        borderWidth: 0,
                        lightIntensity: 0,
                      ),
                      // The sibling surface already supplies tint and blur. Keep
                      // the lens clear so the moving pill can refract the icons.
                      appearance: const LiquidGlassAppearance(),
                      refraction: const LiquidGlassRefraction(
                        distortion: 0,
                        chromaticAberration: 0,
                      ),
                    ),
                    itemStyle: LiquidGlassTabItemStyle(
                      selectedColor: scheme.primary,
                      unselectedColor: scheme.onSurface,
                      iconSize: 25,
                      labelFontSize: 11,
                    ),
                    pillStyle: LiquidGlassTabPillStyle(
                      mode: LiquidGlassPillMode.impellerOnly,
                      show: selectedIndex >= 0,
                      color: selectionFill,
                      animated: true,
                      // Keep the moving refractive pill, without stacking the
                      // package's second magnifier lens beneath it.
                      magnifierPill: const LiquidGlassTabMagnifierPillStyle(
                        enabled: false,
                      ),
                    ),
                    items: [
                      for (final (index, destination) in destinations.indexed)
                        LiquidGlassTabBarItem(
                          label: destination.label,
                          iconBuilder: (context, icon) => IconTheme(
                            data: IconThemeData(
                              size: icon.size,
                              color: icon.selected && selectedIndex >= 0
                                  ? scheme.primary
                                  : inactiveIconColor,
                            ),
                            child: Opacity(
                              opacity: hiddenIconIndices.contains(index)
                                  ? 0
                                  : 1,
                              child: destination.icon,
                            ),
                          ),
                          labelBuilder: (context, label) => Text(
                            destination.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  fontSize: label.textStyle.fontSize,
                                  fontWeight: FontWeight.w600,
                                  color: selectedIndex < 0
                                      ? scheme.onSurface
                                      : label.textStyle.color,
                                ),
                          ),
                        ),
                    ],
                  ),
                ),
                // With no selected tab the package still needs an internal
                // index; handle taps here so
                // returning to that index (Home) is not swallowed as a re-tap.
                if (selectedIndex < 0)
                  Positioned(
                    left: 6,
                    right: 6,
                    bottom: 8,
                    height: 64,
                    child: Row(
                      children: [
                        for (
                          var index = 0;
                          index < destinations.length;
                          index++
                        )
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => onSelected(index),
                              child: const SizedBox.expand(),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return MornyeGlass.navigation(
      blurEnabled: blurEnabled,
      strongTint: true,
      tintOpacity: MornyeTheme.navigationOpacity(context),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Row(
          children: [
            for (var index = 0; index < destinations.length; index++)
              Expanded(
                child: Semantics(
                  selected: index == selectedIndex,
                  button: true,
                  label: destinations[index].label,
                  excludeSemantics: true,
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(28),
                      onTap: () => onSelected(index),
                      child: AnimatedContainer(
                        duration: MediaQuery.disableAnimationsOf(context)
                            ? Duration.zero
                            : const Duration(milliseconds: 220),
                        constraints: const BoxConstraints(minHeight: 54),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: index == selectedIndex
                              ? selectionFill
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconTheme(
                              data: IconThemeData(
                                size: 25,
                                color: index == selectedIndex
                                    ? scheme.primary
                                    : inactiveIconColor,
                              ),
                              // Keep tab selection quiet, as in Mornye. Badges
                              // stay live without the Material bounce/spin.
                              child: Opacity(
                                opacity: hiddenIconIndices.contains(index)
                                    ? 0
                                    : 1,
                                child: destinations[index].icon,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              destinations[index].label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.labelSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: index == selectedIndex
                                        ? scheme.primary
                                        : scheme.onSurface,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
