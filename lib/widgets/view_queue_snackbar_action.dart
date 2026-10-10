import 'package:flutter/material.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/widgets/app_snack_bar.dart';
import 'package:spotiflac_android/services/shell_navigation_service.dart';

SnackBarAction buildViewQueueSnackBarAction(
  BuildContext context, {
  VoidCallback? onViewQueue,
}) {
  return SnackBarAction(
    label: context.l10n.snackbarViewQueue,
    onPressed: onViewQueue ?? () {
      ShellNavigationService.requestTab(ShellTab.library);
    },
  );
}

/// Shared "Added to queue" snackbar with a View action jumping to Library.
void showAddedToQueueSnackBar(
  BuildContext context,
  String trackName, {
  VoidCallback? onViewQueue,
}) {
  if (!context.mounted) return;
  showAppSnackBar(
    context,
    content: Text(context.l10n.snackbarAddedToQueue(trackName)),
    action: buildViewQueueSnackBarAction(
      context,
      onViewQueue: onViewQueue,
    ),
  );
}
