import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoColors;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:spotiflac_android/providers/runtime_profile_provider.dart';
import 'package:spotiflac_android/theme/material_expressive.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/native_glass_metrics.dart';

/// One switch style for settings, extension controls and editing sheets.
/// Mornye keeps its wide oval thumb even when glass or motion is disabled.
class AppSwitch extends StatelessWidget {
  const AppSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.adaptive = false,
    this.semanticLabel,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool adaptive;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    if (materialExpressiveEnabled(context)) {
      return MaterialExpressiveScope(
        child: M3ESwitch(
          value: value,
          onChanged: onChanged,
          semanticLabel: semanticLabel,
        ),
      );
    }
    if (!context.isMornye) {
      return adaptive
          ? Switch.adaptive(value: value, onChanged: onChanged)
          : Switch(value: value, onChanged: onChanged);
    }

    return Consumer(
      builder: (context, ref, _) {
        final scheme = Theme.of(context).colorScheme;
        final active = CupertinoColors.systemGreen.resolveFrom(context);
        final enabled = onChanged != null;
        final useGlass =
            enabled &&
            !MediaQuery.disableAnimationsOf(context) &&
            !MediaQuery.highContrastOf(context) &&
            // One shader lens per switch; settings pages show many at once.
            ref.watch(mornyeLiquidGlassProvider);
        final inactive = scheme.brightness == Brightness.dark
            ? const Color(0xff39393d)
            : const Color(0xff8e8e93);

        final Widget control;
        if (useGlass) {
          control = Transform.flip(
            flipX: Directionality.of(context) == TextDirection.rtl,
            child: NativeGlassMetrics(
              child: LiquidGlassSwitch(
                value: value,
                onChanged: onChanged!,
                activeColor: active,
                inactiveColor: inactive,
              ),
            ),
          );
        } else {
          control = Container(
            width: 63,
            height: 28,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: value ? active : inactive,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Align(
              alignment: value
                  ? AlignmentDirectional.centerEnd
                  : AlignmentDirectional.centerStart,
              child: Container(
                width: 37,
                height: 24,
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          );
        }

        return Semantics(
          label: semanticLabel,
          toggled: value,
          enabled: enabled,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: enabled ? () => onChanged!(!value) : null,
                borderRadius: BorderRadius.circular(22),
                // InkWell supplies keyboard activation and an accessible tap
                // action; the glass control owns the inner drag gesture.
                child: ExcludeSemantics(
                  child: SizedBox(
                    width: 71,
                    height: 44,
                    child: Center(child: control),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class AppSwitchListTile extends StatelessWidget {
  const AppSwitchListTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.contentPadding,
    this.adaptive = false,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final Widget title;
  final Widget? subtitle;
  final EdgeInsetsGeometry? contentPadding;
  final bool adaptive;

  @override
  Widget build(BuildContext context) {
    if (!context.isMornye && !materialExpressiveEnabled(context)) {
      return adaptive
          ? SwitchListTile.adaptive(
              value: value,
              onChanged: onChanged,
              title: title,
              subtitle: subtitle,
              contentPadding: contentPadding,
            )
          : SwitchListTile(
              value: value,
              onChanged: onChanged,
              title: title,
              subtitle: subtitle,
              contentPadding: contentPadding,
            );
    }
    return MergeSemantics(
      child: ListTile(
        title: title,
        subtitle: subtitle,
        contentPadding: contentPadding,
        enabled: onChanged != null,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: AppSwitch(value: value, onChanged: onChanged),
      ),
    );
  }
}
