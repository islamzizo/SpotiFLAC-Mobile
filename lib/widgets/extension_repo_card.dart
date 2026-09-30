import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/runtime_profile_provider.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/mornye_chrome.dart';

/// Repo cards share the Mornye glass material, including their detail pages.
class ExtensionRepoCard extends ConsumerWidget {
  const ExtensionRepoCard({
    super.key,
    required this.child,
    this.color,
    this.radius = 20,
    this.margin = const EdgeInsets.all(4),
  });

  final Widget child;
  final Color? color;
  final double radius;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!context.isMornye) {
      return Card(
        elevation: 0,
        color: color,
        margin: margin,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        child: child,
      );
    }
    return Padding(
      padding: margin,
      child: MornyeGlass.navigation(
        radius: 24,
        blurEnabled: ref.watch(mornyeBlurEnabledProvider),
        child: Material(color: Colors.transparent, child: child),
      ),
    );
  }
}
