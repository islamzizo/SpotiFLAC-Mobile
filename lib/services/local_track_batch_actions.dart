import 'package:flutter/material.dart';
import 'package:spotiflac_android/widgets/app_alert_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/utils/re_enrich_result.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/local_library_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/batch_metadata_re_enrich.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/services/local_track_redownload_service.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/ffmpeg_reenrich.dart';
import 'package:spotiflac_android/utils/lyrics_metadata_helper.dart';
import 'package:spotiflac_android/widgets/batch_progress_dialog.dart';
import 'package:spotiflac_android/widgets/re_enrich_field_dialog.dart';
import 'package:spotiflac_android/widgets/re_enrich_review_sheet.dart';

Future<void> queueLocalTracksAsFlac(
  BuildContext context,
  WidgetRef ref,
  List<LocalLibraryItem> selected, {
  required bool Function() isActive,
  required VoidCallback onComplete,
}) async {
  if (selected.isEmpty) {
    return;
  }

  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (ctx) => AppAlertDialog(
      title: Text(context.l10n.queueFlacAction),
      content: Text(context.l10n.queueFlacConfirmMessage(selected.length)),
      actions: [
        AppDialogAction(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(context.l10n.dialogCancel),
        ),
        AppDialogAction(
          filled: true,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(context.l10n.queueFlacAction),
        ),
      ],
    ),
  );

  if (confirmed != true || !context.mounted || !isActive()) {
    return;
  }

  final settings = ref.read(settingsProvider);
  final extensionState = ref.read(extensionProvider);
  final includeExtensions =
      settings.useExtensionProviders &&
      extensionState.extensions.any(
        (ext) => ext.enabled && ext.hasMetadataProvider,
      );
  final targetService = LocalTrackRedownloadService.preferredFlacService(
    settings,
    extensionState,
  );
  if (targetService.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.extensionsNoDownloadProvider)),
    );
    return;
  }
  final targetQuality =
      LocalTrackRedownloadService.preferredFlacQualityForService(
        targetService,
        extensionState,
      );

  final total = selected.length;

  var cancelled = false;
  BatchProgressDialog.show(
    context: context,
    title: context.l10n.queueFlacAction,
    total: total,
    icon: Icons.queue_music,
    onCancel: () {
      cancelled = true;
      BatchProgressDialog.dismiss(context);
    },
  );

  final matches = await matchLocalTracksForFlac(
    selected,
    resolve: (item) => LocalTrackRedownloadService.resolveBestMatch(
      item,
      includeExtensions: includeExtensions,
    ),
    shouldStop: () => cancelled || !context.mounted || !isActive(),
    onProgress: (index, item) =>
        BatchProgressDialog.update(current: index + 1, detail: item.trackName),
  );
  final matchedTracks = matches.tracks;
  final skippedCount = matches.skipped;

  if (!context.mounted || !isActive()) {
    return;
  }

  if (!cancelled) {
    BatchProgressDialog.dismiss(context);
  }

  if (matchedTracks.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.queueFlacNoReliableMatches)),
    );
    return;
  }

  ref
      .read(downloadQueueProvider.notifier)
      .addMultipleToQueue(
        matchedTracks,
        targetService,
        qualityOverride: targetQuality,
      );

  final summary = skippedCount == 0
      ? context.l10n.snackbarAddedTracksToQueue(matchedTracks.length)
      : context.l10n.queueFlacQueuedWithSkipped(
          matchedTracks.length,
          skippedCount,
        );

  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(summary)));
  onComplete();
}

Future<void> reEnrichLocalTracks(
  BuildContext context,
  WidgetRef ref,
  List<LocalLibraryItem> selected, {
  required bool Function() isActive,
  required Future<void> Function() onSelectionHide,
  required VoidCallback onSelectionRestore,
  required VoidCallback onComplete,
  Future<void> Function()? refreshLibrary,
}) async {
  if (selected.isEmpty) return;
  // Capture a stable route context before a caller removes its overlay.
  context = Navigator.of(context, rootNavigator: true).context;
  await onSelectionHide();
  if (!context.mounted || !isActive()) return;
  final selection = await showReEnrichFieldDialog(
    context,
    selectedCount: selected.length,
  );

  if (selection == null || !context.mounted || !isActive()) {
    // Cancelled — restore selection mode (IDs are still intact).
    if (context.mounted && isActive()) onSelectionRestore();
    return;
  }

  final runner = BatchReEnrichRunner(
    beginPhase: () async {
      final settings = ref.read(settingsProvider);
      await ref
          .read(settingsProvider.notifier)
          .syncLyricsSettingsToBackend(settings: settings);
      return settings;
    },
  );
  var cancelled = false;
  BatchProgressDialog.show(
    context: context,
    title: selection.usesManualValues
        ? context.l10n.trackReEnrichPreparing
        : context.l10n.trackReEnrichSearching,
    total: selected.length,
    icon: selection.usesManualValues ? Icons.edit_note : Icons.manage_search,
    onCancel: () {
      cancelled = true;
      BatchProgressDialog.dismiss(context);
    },
  );

  final previews = await runner.preview(
    selected,
    selection,
    shouldStop: () => cancelled || !context.mounted || !isActive(),
    onProgress: (index, item) => BatchProgressDialog.update(
      current: index + 1,
      detail: '${item.trackName} - ${item.artistName}',
    ),
  );

  if (!context.mounted || !isActive()) return;
  if (!cancelled) BatchProgressDialog.dismiss(context);
  if (cancelled) {
    onSelectionRestore();
    return;
  }

  if (previews.isEmpty) {
    onSelectionRestore();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.trackReEnrichNoChanges)),
    );
    return;
  }

  final confirmed = await showReEnrichReviewSheet(context, previews: previews);
  if (!confirmed || !context.mounted || !isActive()) {
    if (context.mounted && isActive()) onSelectionRestore();
    return;
  }

  final total = previews.length;
  cancelled = false;
  BatchProgressDialog.show(
    context: context,
    title: context.l10n.trackReEnrichProgress,
    total: total,
    icon: Icons.auto_fix_high,
    onCancel: () {
      cancelled = true;
      BatchProgressDialog.dismiss(context);
    },
  );

  final lyricsSummary = ReEnrichLyricsSummary();
  final successCount = await runner.apply(
    previews,
    onResult: lyricsSummary.add,
    shouldStop: () => cancelled || !context.mounted || !isActive(),
    onProgress: (index, item) => BatchProgressDialog.update(
      current: index + 1,
      detail: '${item.trackName} - ${item.artistName}',
    ),
  );

  if (!context.mounted || !isActive()) return;
  if (!cancelled) BatchProgressDialog.dismiss(context);

  if (refreshLibrary != null) {
    await refreshLibrary();
  } else {
    try {
      if (!ref.read(localLibraryProvider).isScanning) {
        await ref.read(localLibraryProvider.notifier).scanAllSources();
      } else {
        await ref.read(localLibraryProvider.notifier).reloadFromStorage();
      }
    } catch (_) {
      await ref.read(localLibraryProvider.notifier).reloadFromStorage();
    }
  }

  if (!context.mounted || !isActive()) return;
  onComplete();

  ScaffoldMessenger.of(context).clearSnackBars();
  final summary = lyricsSummary.message(context.l10n, successCount, total);
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(summary)));
}

/// Runs a batch against one settings snapshot per phase. Dependencies are
/// injectable so cancellation, dispatch, and partial failure can be verified
/// without writing media files or opening dialogs.
class BatchReEnrichRunner {
  final Future<AppSettings> Function() beginPhase;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) reEnrich;
  final Future<void> Function({
    required String audioFilePath,
    required Map<String, dynamic> reEnrichResult,
  })
  writeSidecar;
  final Future<bool> Function({
    required LocalLibraryItem item,
    required Map<String, dynamic> result,
    required String artistTagMode,
  })
  applyFfmpeg;

  BatchReEnrichRunner({
    required this.beginPhase,
    this.reEnrich = PlatformBridge.reEnrichFile,
    this.writeSidecar = writeReEnrichSidecarLrc,
    this.applyFfmpeg = applyFfmpegReEnrichResult,
  });

  Future<List<BatchReEnrichPreview>> preview(
    List<LocalLibraryItem> items,
    ReEnrichFieldSelection selection, {
    required bool Function() shouldStop,
    required void Function(int, LocalLibraryItem) onProgress,
  }) async {
    if (shouldStop()) return [];
    final settings = await beginPhase();
    final previews = <BatchReEnrichPreview>[];
    for (var index = 0; index < items.length; index++) {
      if (shouldStop()) break;
      final item = items[index];
      onProgress(index, item);
      final fields = selection.updateFieldsFor(item);
      if (fields.isEmpty) continue;
      if (selection.usesManualValues) {
        final preview = buildManualBatchReEnrichPreview(item, selection);
        if (preview != null) previews.add(preview);
        continue;
      }
      try {
        final result = await reEnrich(
          buildBatchReEnrichRequest(
            item: item,
            settings: settings,
            updateFields: fields,
            previewOnly: true,
          ),
        );
        final rawMetadata = result['enriched_metadata'];
        if (result['method'] != 'preview' || rawMetadata is! Map) continue;
        final metadata = rawMetadata.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        final changes = buildReEnrichMetadataChanges(item, metadata, fields);
        if (changes.isEmpty) continue;
        previews.add(
          BatchReEnrichPreview(
            item: item,
            updateFields: fields,
            enrichedMetadata: metadata,
            changes: changes,
          ),
        );
      } catch (_) {
        // A failed lookup must not prevent review of other tracks.
      }
    }
    return previews;
  }

  Future<int> apply(
    List<BatchReEnrichPreview> previews, {
    required bool Function() shouldStop,
    required void Function(int, LocalLibraryItem) onProgress,
    void Function(Map<String, dynamic>)? onResult,
  }) async {
    if (shouldStop()) return 0;
    // Settings may have changed while the review sheet was open.
    final settings = await beginPhase();
    var successes = 0;
    for (var index = 0; index < previews.length; index++) {
      if (shouldStop()) break;
      final preview = previews[index];
      onProgress(index, preview.item);
      try {
        final result = await reEnrich(
          buildBatchReEnrichRequest(
            item: preview.item,
            settings: settings,
            updateFields: preview.updateFields,
            resolvedMetadata: preview.enrichedMetadata,
          ),
        );
        switch (result['method']) {
          case 'native':
            await writeSidecar(
              audioFilePath: preview.item.filePath,
              reEnrichResult: result,
            );
            successes++;
            onResult?.call(result);
          case 'ffmpeg':
            if (await applyFfmpeg(
              item: preview.item,
              result: result,
              artistTagMode: settings.artistTagMode,
            )) {
              successes++;
              onResult?.call(result);
            }
        }
      } catch (_) {
        // Keep successful files and continue with the rest of the selection.
      }
    }
    return successes;
  }
}

/// Cancellation stops further matching and retains reliable matches already
/// resolved, matching the queue action's existing partial-completion behavior.
Future<({List<Track> tracks, int skipped})> matchLocalTracksForFlac(
  List<LocalLibraryItem> items, {
  required Future<LocalTrackRedownloadResolution> Function(LocalLibraryItem)
  resolve,
  required bool Function() shouldStop,
  required void Function(int, LocalLibraryItem) onProgress,
}) async {
  final tracks = <Track>[];
  var skipped = 0;
  for (var index = 0; index < items.length; index++) {
    if (shouldStop()) break;
    onProgress(index, items[index]);
    try {
      final resolution = await resolve(items[index]);
      if (resolution.canQueue && resolution.match != null) {
        tracks.add(resolution.match!);
      } else {
        skipped++;
      }
    } catch (_) {
      skipped++;
    }
  }
  return (tracks: tracks, skipped: skipped);
}
