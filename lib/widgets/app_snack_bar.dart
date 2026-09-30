import 'package:flutter/material.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/mornye_chrome.dart';

/// Reports a failure to open a local file with a plain Material snackbar.
void showCannotOpenFileSnackBar(BuildContext context, Object error) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        context.l10n.snackbarCannotOpenFile(context.friendlyError(error)),
      ),
    ),
  );
}

/// Transient messages use the same glass as confirmation dialogs in Mornye.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason> showAppSnackBar(
  BuildContext context, {
  required Widget content,
  Duration duration = const Duration(seconds: 4),
  SnackBarBehavior? behavior,
}) {
  final messenger = ScaffoldMessenger.of(context);
  if (!context.isMornye) {
    return messenger.showSnackBar(
      SnackBar(content: content, duration: duration, behavior: behavior),
    );
  }
  final theme = Theme.of(context);
  final reduceMotion = MediaQuery.disableAnimationsOf(context);
  final snackBar = _MornyeSnackBar(
    duration: duration,
    reduceMotion: reduceMotion,
    content: Theme(
      data: theme,
      child: MornyeGlassPanel.overlay(
        radius: 24,
        // Messages have no modal scrim; let more of the page show through.
        tintOpacity: 0.60,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: DefaultTextStyle(
            style: theme.textTheme.bodyMedium!.copyWith(
              color: theme.colorScheme.onSurface,
            ),
            child: content,
          ),
        ),
      ),
    ),
  );
  return messenger.showSnackBar(snackBar);
}

class _MornyeSnackBar extends SnackBar {
  const _MornyeSnackBar({
    required super.content,
    required super.duration,
    required this.reduceMotion,
  }) : super(
         behavior: SnackBarBehavior.floating,
         backgroundColor: Colors.transparent,
         elevation: 0,
         clipBehavior: Clip.none,
         padding: EdgeInsets.zero,
         margin: const EdgeInsets.fromLTRB(20, 8, 20, 12),
         shape: const RoundedRectangleBorder(
           borderRadius: BorderRadius.all(Radius.circular(24)),
         ),
       );

  final bool reduceMotion;

  @override
  SnackBar withAnimation(Animation<double> newAnimation, {Key? fallbackKey}) {
    // Keep the messenger's controller/timer for queuing and dismissal, but
    // replace Material's opacity layer with movement so blur samples the page.
    return SnackBar(
      key: key ?? fallbackKey,
      duration: duration,
      behavior: behavior,
      backgroundColor: backgroundColor,
      elevation: elevation,
      clipBehavior: clipBehavior,
      padding: padding,
      margin: margin,
      shape: shape,
      animation: const AlwaysStoppedAnimation(1),
      content: AnimatedBuilder(
        animation: newAnimation,
        child: content,
        builder: (context, child) => Transform.translate(
          offset: Offset(
            0,
            reduceMotion
                ? 0
                : 8 * (1 - Curves.easeOutCubic.transform(newAnimation.value)),
          ),
          child: child,
        ),
      ),
    );
  }
}
