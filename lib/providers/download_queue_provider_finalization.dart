part of 'download_queue_provider.dart';

/// Result of [DownloadQueueNotifier._finalizeDecryption]. [failStage] is
/// only meaningful to the inline single-item pipeline, which surfaces a
/// distinct error message per stage; the native-worker pipeline uses one
/// generic message and ignores it.
class _DecryptOutcome {
  final String? path;
  final String? newFileName;
  final String? failStage;
  const _DecryptOutcome(this.path, {this.newFileName, this.failStage});
}

class _QualityVariantFileOutcome {
  final String filePath;
  final String? fileName;
  final Map<String, dynamic>? metadata;

  const _QualityVariantFileOutcome({
    required this.filePath,
    this.fileName,
    this.metadata,
  });
}

class _AutoConversionOutcome {
  final String filePath;
  final String? fileName;
  final String quality;
  final bool converted;

  const _AutoConversionOutcome({
    required this.filePath,
    required this.fileName,
    required this.quality,
    required this.converted,
  });
}

/// AC-4 repair only applies to MP4 containers; decrypt can also emit raw
/// FLAC, which the native MP4 box parser would reject as corrupt.
bool _isMp4Container(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.m4a') || lower.endsWith('.mp4');
}

Future<String> _normalizeDecryptedIsoBmffAudioPath(
  String path,
  Map<String, dynamic> result,
) async {
  if (!_isMp4Container(path)) return path;

  final probedCodec = await FFmpegService.probePrimaryAudioCodec(path);
  final reportedCodec =
      result['audio_codec']?.toString() ??
      result['actual_audio_codec']?.toString() ??
      result['format']?.toString();
  final desiredExt = isoBmffAudioExtensionForCodec(
    probedCodec ?? reportedCodec,
  );
  if (path.toLowerCase().endsWith(desiredExt)) return path;

  final targetPath = path.replaceFirst(
    RegExp(r'\.(?:m4a|mp4)$', caseSensitive: false),
    desiredExt,
  );
  if (targetPath == path) return path;
  try {
    final target = File(targetPath);
    if (await target.exists()) {
      _log.w(
        'Cannot normalize ISO-BMFF audio extension; target already exists: '
        '$targetPath',
      );
      return path;
    }
    final renamed = await File(path).rename(targetPath);
    return renamed.path;
  } catch (e) {
    _log.w('Failed to normalize ISO-BMFF audio extension for $path: $e');
    return path;
  }
}

extension _DownloadQueueFinalization on DownloadQueueNotifier {
  Future<void> _saveDownloadedMotionArtwork(
    Ref ref,
    DownloadItem item,
    Track track,
    Map<String, dynamic> result,
  ) async {
    // Store independently of history preferences and the selected UI theme.
    // A later switch to Mornye must still work without network access.
    try {
      final album = (
        album:
            _resolveMetadataText(
              track.albumName,
              result['album']?.toString(),
            ) ??
            item.track.albumName,
        artist:
            _resolveMetadataText(
              track.artistName,
              result['artist']?.toString(),
            ) ??
            item.track.artistName,
      );
      final store = ref.read(motionArtworkStoreProvider);
      final artwork = await store.save(
        album,
        resolveSource: () => resolveDownloadMotionArtworkSource(
          original: item.track,
          downloaded: track,
          result: result,
          getMetadata: PlatformBridge.getProviderMetadata,
        ),
      );
      if (artwork != null && ref.mounted) {
        ref.invalidate(playerMotionArtworkProvider(album));
      }
    } catch (error) {
      _log.w('Optional motion artwork was not saved: ${error.runtimeType}');
    }
  }

  Future<_AutoConversionOutcome> _autoConvertDownloadedFile({
    required String itemId,
    required String filePath,
    required String? fileName,
    required String currentQuality,
    required AppSettings settings,
    required Track track,
    required Map<String, dynamic> result,
    required String downloadService,
    required String storageMode,
    String? downloadTreeUri,
    String? safRelativeDir,
  }) async {
    if (!settings.autoConvertDownloads) {
      return _AutoConversionOutcome(
        filePath: filePath,
        fileName: fileName,
        quality: currentQuality,
        converted: false,
      );
    }

    final targetFormat = normalizeAutoConvertFormat(settings.autoConvertFormat);
    final targetBitrate = normalizeAutoConvertBitrate(
      settings.autoConvertBitrate,
    );
    final targetBitrateKbps = autoConvertBitrateKbps(targetBitrate);
    if (autoConversionAlreadySatisfied(
      filePath: filePath,
      fileName: fileName,
      targetFormat: targetFormat,
      targetBitrate: targetBitrate,
      quality: currentQuality,
      bitrateKbps: readPositiveBitrateKbps(
        result['bitrate'] ?? result['actual_bitrate'],
      ),
    )) {
      return _AutoConversionOutcome(
        filePath: filePath,
        fileName: fileName,
        quality: currentQuality,
        converted: false,
      );
    }

    final baseFileName = (fileName?.trim().isNotEmpty == true
        ? fileName!.trim()
        : File(filePath).uri.pathSegments.last);
    final convertedFileName = convertedOutputFileName(
      originalFileName: baseFileName,
      targetFormat: targetFormat,
    );
    final convertedQuality =
        '${displayFormatForLossyFormat(targetFormat)} ${targetBitrateKbps}kbps';

    Future<void> embedConvertedMetadata(String convertedPath) async {
      if (!settings.embedMetadata) return;
      try {
        await _embedMetadataToFile(
          convertedPath,
          track,
          format: metadataFormatForLossyFormat(targetFormat),
          genre: result['genre'] as String?,
          label: result['label'] as String?,
          copyright: result['copyright'] as String?,
          comment: result['comment'] as String?,
          lyricsLrc: result['lyrics_lrc'] as String?,
          downloadService: downloadService,
          writeExternalLrc: storageMode != 'saf',
        );
      } catch (e) {
        // The audio conversion itself is still valid. Preserve the converted
        // file if an optional tag/cover write fails.
        _log.w('Automatic conversion metadata embed failed: $e');
        result['auto_conversion_metadata_warning'] = e.toString();
      }
    }

    try {
      updateItemStatus(itemId, DownloadStatus.finalizing, progress: 0.97);
      String? convertedPath;
      String? publishedFileName = convertedFileName;
      if (storageMode == 'saf' && isContentUri(filePath)) {
        if (downloadTreeUri == null || downloadTreeUri.isEmpty) {
          throw StateError('Missing SAF tree for automatic conversion');
        }
        convertedPath = await _replaceSafFileVia(
          uri: filePath,
          treeUri: downloadTreeUri,
          relativeDir: safRelativeDir ?? '',
          avoidOverwrite:
              convertedFileName.toLowerCase() != baseFileName.toLowerCase(),
          onPublishedFileName: (value) => publishedFileName = value,
          op: (tempPath, addCleanup) async {
            final output = await FFmpegService.convertAudioFormat(
              inputPath: tempPath,
              targetFormat: targetFormat,
              bitrate: targetBitrate,
              metadata: const {},
              deleteOriginal: false,
            );
            if (output == null) return null;
            addCleanup(output);
            await embedConvertedMetadata(output);
            return (output, convertedFileName);
          },
        );
      } else {
        convertedPath = await FFmpegService.convertAudioFormat(
          inputPath: filePath,
          targetFormat: targetFormat,
          bitrate: targetBitrate,
          metadata: const {},
          deleteOriginal: true,
        );
        if (convertedPath != null) {
          // Deferred SAF downloads are converted in the cache before being
          // published. Keep their logical filename instead of the temporary
          // FFmpeg output basename (native_saf_work_...).
          if (storageMode != 'saf') {
            publishedFileName = File(convertedPath).uri.pathSegments.last;
          }
          await embedConvertedMetadata(convertedPath);
        }
      }

      if (convertedPath == null || convertedPath.isEmpty) {
        throw StateError('FFmpeg returned no automatic conversion output');
      }

      result['file_path'] = convertedPath;
      result['file_name'] = publishedFileName;
      result['audio_codec'] = targetFormat;
      result['format'] = targetFormat;
      result['bitrate'] = targetBitrateKbps;
      result.remove('actual_bit_depth');
      result.remove('actual_sample_rate');
      _log.i(
        'Automatic conversion completed: ${autoConvertFormatLabel(targetFormat)} @ $targetBitrate',
      );
      return _AutoConversionOutcome(
        filePath: convertedPath,
        fileName: publishedFileName,
        quality: convertedQuality,
        converted: true,
      );
    } catch (e) {
      // A successful download remains usable when the optional conversion
      // fails. Conversion helpers only remove the source after atomic output
      // promotion, so returning the original path is safe here.
      result['auto_conversion_warning'] = e.toString();
      _log.w('Automatic conversion failed; keeping downloaded source: $e');
      return _AutoConversionOutcome(
        filePath: filePath,
        fileName: fileName,
        quality: currentQuality,
        converted: false,
      );
    }
  }

  /// Builds the [DownloadHistoryItem] shared by the native-worker and inline
  /// completion paths. Fields whose source/derivation legitimately differs
  /// between the two callers (SAF location, probed vs. raw audio metadata,
  /// genre/label/copyright fallback chain) are left as parameters.
  DownloadHistoryItem _historyItemFromResult({
    required DownloadItem item,
    required Track trackToDownload,
    required Map<String, dynamic> result,
    required String filePath,
    required String quality,
    required bool useSaf,
    String? downloadTreeUri,
    String? safRelativeDir,
    String? safFileName,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    String? format,
    String? genre,
    String? label,
    String? copyright,
    required bool hasLyrics,
    required int lyricsMetadataScanVersion,
  }) {
    final backendTitle = result['title'] as String?;
    final backendArtist = result['artist'] as String?;
    final backendAlbum = result['album'] as String?;
    final backendYear = result['release_date'] as String?;
    final backendTrackNum = readPositiveInt(result['track_number']);
    final backendDiscNum = readPositiveInt(result['disc_number']);
    final backendTotalTracks = readPositiveInt(result['total_tracks']);
    final backendTotalDiscs = readPositiveInt(result['total_discs']);
    final backendISRC = result['isrc'] as String?;
    final backendComposer = result['composer'] as String?;

    final historyTotalTracks = _resolvePositiveMetadataInt(
      trackToDownload.totalTracks,
      backendTotalTracks,
    );
    final historyTotalDiscs = _resolvePositiveMetadataInt(
      trackToDownload.totalDiscs,
      backendTotalDiscs,
    );
    final historyTrackNumber = _resolveMetadataIndex(
      sourceValue: trackToDownload.trackNumber,
      backendValue: backendTrackNum,
      total: historyTotalTracks,
    );
    final historyDiscNumber = _resolveMetadataIndex(
      sourceValue: trackToDownload.discNumber,
      backendValue: backendDiscNum,
      total: historyTotalDiscs,
    );
    final historyTitle =
        _resolveMetadataText(trackToDownload.name, backendTitle) ??
        item.track.name;
    final historyArtist =
        _resolveMetadataText(trackToDownload.artistName, backendArtist) ??
        item.track.artistName;
    final historyAlbum =
        _resolveMetadataText(trackToDownload.albumName, backendAlbum) ??
        item.track.albumName;
    final historyIsrc = _resolveMetadataText(trackToDownload.isrc, backendISRC);
    final historyReleaseDate = _resolveMetadataText(
      trackToDownload.releaseDate,
      backendYear,
    );
    final historyComposer = _resolveMetadataText(
      trackToDownload.composer,
      backendComposer,
    );

    return DownloadHistoryItem(
      id: item.id,
      trackName: historyTitle,
      artistName: historyArtist,
      albumName: historyAlbum,
      albumArtist: normalizeOptionalString(trackToDownload.albumArtist),
      coverUrl: normalizeCoverReference(trackToDownload.coverUrl),
      filePath: filePath,
      storageMode: useSaf ? 'saf' : 'app',
      downloadTreeUri: useSaf ? downloadTreeUri : null,
      safRelativeDir: useSaf ? safRelativeDir : null,
      safFileName: useSaf ? safFileName : null,
      safRepaired: false,
      service: result['service'] as String? ?? item.service,
      downloadedAt: DateTime.now(),
      isrc: historyIsrc,
      spotifyId: trackToDownload.id,
      trackNumber: historyTrackNumber,
      totalTracks: historyTotalTracks,
      discNumber: historyDiscNumber,
      totalDiscs: historyTotalDiscs,
      duration: trackToDownload.duration,
      releaseDate: historyReleaseDate,
      quality: quality,
      bitDepth: bitDepth,
      sampleRate: sampleRate,
      bitrate: bitrate,
      format: format,
      genre: genre,
      composer: historyComposer,
      label: label,
      copyright: copyright,
      explicit:
          trackToDownload.isExplicit ||
          parseExplicitFlag(result['explicit']) == true,
      hasLyrics: hasLyrics,
      lyricsMetadataScanVersion: lyricsMetadataScanVersion,
    );
  }

  Future<({bool hasLyrics, int scanVersion})> _resolveFinalLyricsAvailability({
    required String filePath,
    Map<String, dynamic>? probedMetadata,
    bool externalLrcWritten = false,
  }) async {
    var metadataScanned = false;
    var hasEmbeddedLyrics = false;
    try {
      final metadata =
          probedMetadata ?? await PlatformBridge.readFileMetadata(filePath);
      if (metadata['error'] == null &&
          (metadata.containsKey('lyrics') ||
              metadata.containsKey('hasLyrics'))) {
        metadataScanned = true;
        hasEmbeddedLyrics =
            metadata['hasLyrics'] == true ||
            hasUsableLyricsContent(metadata['lyrics']?.toString() ?? '');
      }
    } catch (e) {
      _log.d('Final lyrics metadata probe failed for $filePath: $e');
    }

    var hasSidecarLyrics = externalLrcWritten;
    if (!isContentUri(filePath)) {
      try {
        final lrcPath = filePath.replaceAll(RegExp(r'\.[^.]+$'), '.lrc');
        final safeLrcPath = lrcPath == filePath ? '$filePath.lrc' : lrcPath;
        final sidecar = File(safeLrcPath);
        if (await sidecar.exists()) {
          hasSidecarLyrics = hasUsableLyricsContent(
            await sidecar.readAsString(),
          );
        }
      } catch (e) {
        _log.d('Final sidecar lyrics probe failed for $filePath: $e');
      }
    }

    final hasLyrics = hasEmbeddedLyrics || hasSidecarLyrics;
    return (
      hasLyrics: hasLyrics,
      scanVersion: hasLyrics || metadataScanned ? 1 : 0,
    );
  }

  Future<String?> _copySafToTemp(String uri) async {
    try {
      return await PlatformBridge.copyContentUriToTemp(uri);
    } catch (e) {
      _log.w('Failed to copy SAF uri to temp: $e');
      return null;
    }
  }

  Future<String?> _writeTempToSaf({
    required String treeUri,
    required String relativeDir,
    required String fileName,
    required String mimeType,
    required String srcPath,
  }) async {
    try {
      return await PlatformBridge.createSafFileFromPath(
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: fileName,
        mimeType: mimeType,
        srcPath: srcPath,
      );
    } catch (e) {
      _log.w('Failed to write temp file to SAF: $e');
      return null;
    }
  }

  Future<({String uri, String fileName, bool alreadyExists})?>
  _writeTempToSafIfAbsent({
    required String treeUri,
    required String relativeDir,
    required String fileName,
    required String mimeType,
    required String srcPath,
  }) async {
    try {
      final result = await PlatformBridge.createSafFileIfAbsentFromPath(
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: fileName,
        mimeType: mimeType,
        srcPath: srcPath,
      );
      _logSafPublishTimings(result);
      final uri = (result['uri'] as String? ?? '').trim();
      final publishedName = (result['file_name'] as String? ?? '').trim();
      if (uri.isEmpty || publishedName.isEmpty) return null;
      return (
        uri: uri,
        fileName: publishedName,
        alreadyExists: result['already_exists'] == true,
      );
    } catch (e) {
      _log.w('Failed to publish deferred SAF file: $e');
      return null;
    }
  }

  void _logSafPublishTimings(Map<String, dynamic> result) {
    final timings = result['publish_timings_ms'];
    if (timings is Map && timings.isNotEmpty) {
      _log.d('SAF publish timings (ms): $timings');
    }
  }

  Future<({String uri, String fileName})?> _writeTempToSafUnique({
    required String treeUri,
    required String relativeDir,
    required String fileName,
    required String mimeType,
    required String srcPath,
    String preservedSuffix = '',
  }) async {
    try {
      final result = await PlatformBridge.createUniqueSafFileFromPath(
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: fileName,
        mimeType: mimeType,
        srcPath: srcPath,
        preservedSuffix: preservedSuffix,
      );
      _logSafPublishTimings(result);
      final uri = (result['uri'] as String? ?? '').trim();
      final publishedName = (result['file_name'] as String? ?? '').trim();
      if (uri.isEmpty || publishedName.isEmpty) return null;
      return (uri: uri, fileName: publishedName);
    } catch (e) {
      _log.w('Failed to write unique temp file to SAF: $e');
      return null;
    }
  }

  Future<({String uri, String fileName})?> _writeTempToSafCollisionAware({
    required String treeUri,
    required String relativeDir,
    required String cleanFileName,
    required String variantFileName,
    required String mimeType,
    required String srcPath,
    String preservedSuffix = '',
  }) async {
    try {
      final result = await PlatformBridge.createCollisionAwareSafFileFromPath(
        treeUri: treeUri,
        relativeDir: relativeDir,
        cleanFileName: cleanFileName,
        variantFileName: variantFileName,
        mimeType: mimeType,
        srcPath: srcPath,
        preservedSuffix: preservedSuffix,
      );
      _logSafPublishTimings(result);
      final uri = (result['uri'] as String? ?? '').trim();
      final publishedName = (result['file_name'] as String? ?? '').trim();
      if (uri.isEmpty || publishedName.isEmpty) return null;
      return (uri: uri, fileName: publishedName);
    } catch (e) {
      _log.w('Failed to write collision-aware temp file to SAF: $e');
      return null;
    }
  }

  Future<bool> _writeLrcToSaf({
    required String treeUri,
    required String relativeDir,
    required String baseName,
    required String lrcContent,
  }) async {
    try {
      if (!hasUsableLyricsContent(lrcContent)) return false;
      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/$baseName.lrc';
      await File(tempPath).writeAsString(lrcContent);
      final lrcName = '$baseName.lrc';
      final uri = await _writeTempToSaf(
        treeUri: treeUri,
        relativeDir: relativeDir,
        fileName: lrcName,
        mimeType: _mimeTypeForExt('.lrc'),
        srcPath: tempPath,
      );
      if (uri != null) {
        _log.d('External LRC saved to SAF: $lrcName');
      } else {
        _log.w('Failed to write external LRC to SAF');
      }
      try {
        await File(tempPath).delete();
      } catch (_) {}
      return uri != null;
    } catch (e) {
      _log.w('Failed to create external LRC in SAF: $e');
      return false;
    }
  }

  Future<void> _deleteSafFile(String uri) async {
    try {
      await PlatformBridge.safDelete(uri);
    } catch (e) {
      _log.w('Failed to delete SAF file: $e');
    }
  }

  /// Shared "SAF roundtrip" used by every finalize step that needs to
  /// transform a SAF file: copies [uri] to a local temp file, lets [op]
  /// transform it (returning the local path to publish plus the file name
  /// to publish it under, or null to abort), writes that file back into the
  /// SAF tree, deletes the original SAF file if its URI changed, and always
  /// cleans up the local temp file(s). Returns the new content:// URI, or
  /// null if the temp copy, [op], or the SAF write failed.
  Future<String?> _replaceSafFileVia({
    required String uri,
    required String treeUri,
    required String relativeDir,
    required Future<(String path, String fileName)?> Function(
      String tempPath,
      void Function(String path) addCleanup,
    )
    op,
    bool avoidOverwrite = false,
    String preservedSuffix = '',
    String? collisionCleanFileName,
    String? collisionVariantFileName,
    void Function(String fileName)? onPublishedFileName,
  }) async {
    final tempPath = await _copySafToTemp(uri);
    if (tempPath == null) return null;
    // Files op produces are registered here the moment they exist, so they
    // are cleaned up even if op throws before returning.
    final producedTemps = <String>{};
    String? outPath;
    try {
      final produced = await op(tempPath, producedTemps.add);
      if (produced == null) return null;
      outPath = produced.$1;
      final fileName = produced.$2;
      final dotIndex = fileName.lastIndexOf('.');
      final ext = dotIndex >= 0 ? fileName.substring(dotIndex) : '';
      String? newUri;
      if (collisionCleanFileName != null && collisionVariantFileName != null) {
        final published = await _writeTempToSafCollisionAware(
          treeUri: treeUri,
          relativeDir: relativeDir,
          cleanFileName: collisionCleanFileName,
          variantFileName: collisionVariantFileName,
          mimeType: _mimeTypeForExt(ext),
          srcPath: outPath,
          preservedSuffix: preservedSuffix,
        );
        newUri = published?.uri;
        if (published != null) {
          onPublishedFileName?.call(published.fileName);
        }
      } else if (avoidOverwrite) {
        final published = await _writeTempToSafUnique(
          treeUri: treeUri,
          relativeDir: relativeDir,
          fileName: fileName,
          mimeType: _mimeTypeForExt(ext),
          srcPath: outPath,
          preservedSuffix: preservedSuffix,
        );
        newUri = published?.uri;
        if (published != null) {
          onPublishedFileName?.call(published.fileName);
        }
      } else {
        newUri = await _writeTempToSaf(
          treeUri: treeUri,
          relativeDir: relativeDir,
          fileName: fileName,
          mimeType: _mimeTypeForExt(ext),
          srcPath: outPath,
        );
        if (newUri != null) {
          onPublishedFileName?.call(fileName);
        }
      }
      if (newUri == null) return null;
      if (newUri != uri) {
        await _deleteSafFile(uri);
      }
      return newUri;
    } finally {
      try {
        await File(tempPath).delete();
      } catch (_) {}
      if (outPath != null) {
        producedTemps.add(outPath);
      }
      for (final path in producedTemps) {
        if (path == tempPath) continue;
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  }

  Future<_QualityVariantFileOutcome> _finalizeQualityVariantFilename({
    required DownloadItem item,
    required Map<String, dynamic> result,
    required String filePath,
    required String storageMode,
    String? downloadTreeUri,
    String? safRelativeDir,
    String? fileName,
    bool collisionOnly = false,
  }) async {
    if (!item.preserveQualityVariant || result['already_exists'] == true) {
      return _QualityVariantFileOutcome(filePath: filePath, fileName: fileName);
    }

    Map<String, dynamic>? metadata;
    try {
      metadata = await PlatformBridge.readFileMetadata(filePath);
      if (metadata['error'] != null) metadata = null;
    } catch (e) {
      _log.d('Quality variant metadata probe failed for $filePath: $e');
    }

    final bitDepth = readPositiveInt(
      metadata?['bit_depth'] ?? result['actual_bit_depth'],
    );
    final sampleRate = readPositiveInt(
      metadata?['sample_rate'] ?? result['actual_sample_rate'],
    );
    final detectedFormat =
        normalizeAudioFormatValue(
          metadata?['audio_codec']?.toString() ??
              metadata?['codec']?.toString() ??
              metadata?['format']?.toString(),
        ) ??
        normalizeAudioFormatValue(
          result['audio_codec']?.toString() ?? result['format']?.toString(),
        ) ??
        normalizeAudioFormatValue(
          audioFormatForPath(filePath, fileName: fileName),
        );
    final bitrateKbps = readPositiveBitrateKbps(
      metadata?['bitrate'] ??
          metadata?['bit_rate'] ??
          result['bitrate'] ??
          result['actual_bitrate'],
    );
    final qualityLabel = buildQualityVariantFilenameLabel(
      detectedFormat: detectedFormat,
      bitDepth: bitDepth,
      sampleRate: sampleRate,
      bitrateKbps: bitrateKbps,
      measuredQuality:
          result['_native_actual_quality']?.toString() ??
          result['quality']?.toString(),
    );
    if (qualityLabel == null) {
      _log.w(
        'Keeping collision-safe temporary quality label because the final '
        'audio specification could not be measured: $filePath',
      );
      return _QualityVariantFileOutcome(
        filePath: filePath,
        fileName: fileName,
        metadata: metadata,
      );
    }

    if (bitDepth != null) result['actual_bit_depth'] = bitDepth;
    if (sampleRate != null) result['actual_sample_rate'] = sampleRate;
    if (detectedFormat != null) result['audio_codec'] = detectedFormat;
    if (bitrateKbps != null) {
      result['bitrate'] = bitrateKbps;
    }

    final stagingLabel = qualityVariantStagingLabel(item.id);
    final localPathSegments = File(filePath).uri.pathSegments;
    final currentFileName = storageMode == 'saf'
        ? (fileName ?? result['file_name']?.toString() ?? '')
        : (localPathSegments.isEmpty ? '' : localPathSegments.last);
    final variantFileName = applyQualityVariantFilenameLabel(
      fileName: currentFileName,
      stagingLabel: stagingLabel,
      qualityLabel: qualityLabel,
    );
    final cleanFileName = removeQualityVariantStagingLabel(
      fileName: currentFileName,
      stagingLabel: stagingLabel,
    );
    final preferredFileName = variantFileName;
    if (preferredFileName == currentFileName) {
      return _QualityVariantFileOutcome(
        filePath: filePath,
        fileName: fileName,
        metadata: metadata,
      );
    }

    if (storageMode == 'saf' && isContentUri(filePath)) {
      if (downloadTreeUri == null || downloadTreeUri.isEmpty) {
        return _QualityVariantFileOutcome(
          filePath: filePath,
          fileName: fileName,
          metadata: metadata,
        );
      }
      String? publishedFileName;
      final renamedUri = await _replaceSafFileVia(
        uri: filePath,
        treeUri: downloadTreeUri,
        relativeDir: safRelativeDir ?? '',
        avoidOverwrite: !collisionOnly,
        preservedSuffix: qualityLabel,
        collisionCleanFileName: collisionOnly ? cleanFileName : null,
        collisionVariantFileName: collisionOnly ? variantFileName : null,
        onPublishedFileName: (name) => publishedFileName = name,
        op: (tempPath, addCleanup) async => (tempPath, preferredFileName),
      );
      if (renamedUri == null) {
        return _QualityVariantFileOutcome(
          filePath: filePath,
          fileName: fileName,
          metadata: metadata,
        );
      }
      final finalName = publishedFileName ?? preferredFileName;
      result['file_path'] = renamedUri;
      result['file_name'] = finalName;
      return _QualityVariantFileOutcome(
        filePath: renamedUri,
        fileName: finalName,
        metadata: metadata,
      );
    }

    final source = File(filePath);
    final parent = source.parent;
    final cleanTarget = File(
      '${parent.path}${Platform.pathSeparator}$cleanFileName',
    );
    final lockTarget = collisionOnly
        ? cleanTarget
        : File('${parent.path}${Platform.pathSeparator}$preferredFileName');
    return _withQualityVariantFileLock(lockTarget.path, () async {
      final selectedFileName = collisionOnly
          ? resolveQualityVariantFilename(
              fileName: currentFileName,
              stagingLabel: stagingLabel,
              qualityLabel: qualityLabel,
              collisionOnly: true,
              cleanNameExists:
                  cleanTarget.path != source.path && await cleanTarget.exists(),
            )
          : preferredFileName;
      if (selectedFileName == currentFileName) {
        return _QualityVariantFileOutcome(
          filePath: filePath,
          fileName: fileName,
          metadata: metadata,
        );
      }

      var target = File(
        '${parent.path}${Platform.pathSeparator}$selectedFileName',
      );
      var counter = 2;
      while (await target.exists() && target.path != source.path) {
        final dotIndex = selectedFileName.lastIndexOf('.');
        final hasExtension = dotIndex > 0;
        final stem = hasExtension
            ? selectedFileName.substring(0, dotIndex)
            : selectedFileName;
        final extension = hasExtension
            ? selectedFileName.substring(dotIndex)
            : '';
        target = File(
          '${parent.path}${Platform.pathSeparator}$stem ($counter)$extension',
        );
        counter++;
      }
      try {
        final renamed = await source.rename(target.path);
        result['file_path'] = renamed.path;
        final renamedSegments = renamed.uri.pathSegments;
        result['file_name'] = renamedSegments.isEmpty
            ? null
            : renamedSegments.last;
        return _QualityVariantFileOutcome(
          filePath: renamed.path,
          fileName: result['file_name'] as String?,
          metadata: metadata,
        );
      } catch (e) {
        _log.w('Failed to apply measured quality filename: $e');
        return _QualityVariantFileOutcome(
          filePath: filePath,
          fileName: fileName,
          metadata: metadata,
        );
      }
    });
  }

  /// Shared decrypt finalize used by both the inline single-item pipeline
  /// and the native-worker pipeline. Divergences captured as parameters:
  /// [repairAc4] (inline repairs AC-4 containers using the still-encrypted
  /// source; native-worker does not) and [onStart] (inline logs its own
  /// "detected" message; native-worker logs a differently worded one).
  Future<_DecryptOutcome> _finalizeDecryption({
    required Map<String, dynamic> result,
    required String filePath,
    required String storageMode,
    String? downloadTreeUri,
    required String safRelativeDir,
    required String baseName,
    required String extFallback,
    required bool repairAc4,
    void Function(String strategy)? onStart,
  }) async {
    if (result['already_exists'] == true) {
      return _DecryptOutcome(filePath);
    }

    final descriptor = DownloadDecryptionDescriptor.fromDownloadResult(result);
    if (descriptor == null) {
      return _DecryptOutcome(filePath);
    }
    onStart?.call(descriptor.normalizedStrategy);

    if (storageMode == 'saf' && isContentUri(filePath)) {
      if (downloadTreeUri == null || downloadTreeUri.isEmpty) {
        return const _DecryptOutcome(
          null,
          failStage: DownloadQueueNotifier._decryptStageSafAccess,
        );
      }
      String? failStage;
      var opStarted = false;
      String? producedFileName;
      final newUri = await _replaceSafFileVia(
        uri: filePath,
        treeUri: downloadTreeUri,
        relativeDir: safRelativeDir,
        op: (tempPath, addCleanup) async {
          opStarted = true;
          final rawDecryptedTempPath =
              await FFmpegService.decryptWithDescriptor(
                inputPath: tempPath,
                descriptor: descriptor,
                deleteOriginal: false,
              );
          if (rawDecryptedTempPath == null) {
            failStage = DownloadQueueNotifier._decryptStageDecrypt;
            return null;
          }
          addCleanup(rawDecryptedTempPath);
          final decryptedTempPath = await _normalizeDecryptedIsoBmffAudioPath(
            rawDecryptedTempPath,
            result,
          );
          if (decryptedTempPath != rawDecryptedTempPath) {
            addCleanup(decryptedTempPath);
          }
          if (repairAc4 && _isMp4Container(decryptedTempPath)) {
            try {
              await PlatformBridge.ensureAC4Config(decryptedTempPath, tempPath);
            } catch (e) {
              _log.w('AC-4 container repair skipped: $e');
            }
          }
          final dotIndex = decryptedTempPath.lastIndexOf('.');
          final decryptedExt = dotIndex >= 0
              ? decryptedTempPath.substring(dotIndex).toLowerCase()
              : extFallback;
          const allowedExt = <String>{'.flac', '.m4a', '.mp4', '.mp3', '.opus'};
          final finalExt = allowedExt.contains(decryptedExt)
              ? decryptedExt
              : extFallback;
          final newFileName = '$baseName$finalExt';
          producedFileName = newFileName;
          return (decryptedTempPath, newFileName);
        },
      );
      if (newUri == null) {
        return _DecryptOutcome(
          null,
          failStage:
              failStage ??
              (opStarted
                  ? DownloadQueueNotifier._decryptStageSafWrite
                  : DownloadQueueNotifier._decryptStageSafAccess),
        );
      }
      return _DecryptOutcome(newUri, newFileName: producedFileName);
    }

    if (repairAc4) {
      final rawDecryptedPath = await FFmpegService.decryptWithDescriptor(
        inputPath: filePath,
        descriptor: descriptor,
        deleteOriginal: false,
      );
      if (rawDecryptedPath == null) {
        try {
          await deleteFile(filePath);
        } catch (_) {}
        return const _DecryptOutcome(
          null,
          failStage: DownloadQueueNotifier._decryptStageDecrypt,
        );
      }
      final decryptedPath = await _normalizeDecryptedIsoBmffAudioPath(
        rawDecryptedPath,
        result,
      );
      if (_isMp4Container(decryptedPath)) {
        try {
          await PlatformBridge.ensureAC4Config(decryptedPath, filePath);
        } catch (e) {
          _log.w('AC-4 container repair skipped: $e');
        }
      }
      try {
        await deleteFile(filePath);
      } catch (_) {}
      return _DecryptOutcome(decryptedPath);
    }

    final rawDecryptedPath = await FFmpegService.decryptWithDescriptor(
      inputPath: filePath,
      descriptor: descriptor,
      deleteOriginal: true,
    );
    final decryptedPath = rawDecryptedPath == null
        ? null
        : await _normalizeDecryptedIsoBmffAudioPath(rawDecryptedPath, result);
    return _DecryptOutcome(
      decryptedPath,
      failStage: decryptedPath == null
          ? DownloadQueueNotifier._decryptStageDecrypt
          : null,
    );
  }

  Future<String?> _finalizeNativeWorkerContainerConversion({
    required _NativeWorkerRequestContext context,
    required Map<String, dynamic> result,
    required AppSettings settings,
    required Track track,
    required String filePath,
  }) async {
    if (context.outputExt != '.flac') {
      return filePath;
    }
    final resultAudioFormat = normalizeAudioFormatValue(
      result['audio_codec']?.toString() ??
          result['actual_audio_codec']?.toString(),
    );
    final requiresContainerConversion =
        result['requires_container_conversion'] == true ||
        result['requiresContainerConversion'] == true ||
        _shouldRequestContainerConversion(
          context.item.service,
          context.outputExt,
        );
    // M4A/MP4 identifies a container, not necessarily a lossy codec. When an
    // extension explicitly requests conversion, probe the stream below rather
    // than treating the container label as proof that its audio is lossy.
    if (!requiresContainerConversion && isLossyAudioFormat(resultAudioFormat)) {
      _log.d(
        'Native-worker output is $resultAudioFormat; preserving native container.',
      );
      return filePath;
    }
    final resultOutputExt = _downloadResultOutputExt(
      result,
      filePath: filePath,
    );
    final lowerPath = filePath.toLowerCase();
    final resultFileName = (result['file_name'] as String?)?.toLowerCase();
    final mayNeedContainerConversion =
        requiresContainerConversion ||
        lowerPath.endsWith('.m4a') ||
        lowerPath.endsWith('.mp4') ||
        resultOutputExt == '.m4a' ||
        resultOutputExt == '.mp4' ||
        isContentUri(filePath);
    if (!mayNeedContainerConversion) {
      return filePath;
    }
    final requestedDecryptionExt =
        DownloadDecryptionDescriptor.fromDownloadResult(
          result,
        )?.normalizedOutputExtension;
    if (!requiresContainerConversion &&
        requestedDecryptionExt != null &&
        requestedDecryptionExt != '.flac') {
      _log.d(
        'Native-worker decrypted output requested $requestedDecryptionExt; preserving native container.',
      );
      return filePath;
    }
    final looksLikeM4a =
        lowerPath.endsWith('.m4a') ||
        lowerPath.endsWith('.mp4') ||
        resultOutputExt == '.m4a' ||
        resultOutputExt == '.mp4' ||
        (resultFileName != null &&
            (resultFileName.endsWith('.m4a') ||
                resultFileName.endsWith('.mp4')));
    if (!requiresContainerConversion &&
        !looksLikeM4a &&
        !isContentUri(filePath)) {
      return filePath;
    }

    Future<void> embedFlacMetadata(String flacPath) async {
      if (!settings.embedMetadata) return;
      await _embedMetadataToFile(
        flacPath,
        track,
        format: 'flac',
        genre: result['genre'] as String?,
        label: result['label'] as String?,
        copyright: result['copyright'] as String?,
        comment: result['comment'] as String?,
        lyricsLrc: result['lyrics_lrc'] as String?,
        downloadService: context.item.service,
        writeExternalLrc: context.storageMode != 'saf',
      );
    }

    void markFinalOutputAsFlac() {
      result['audio_codec'] = 'flac';
      result['format'] = 'flac';
      result['actual_extension'] = '.flac';
      result['output_extension'] = '.flac';
    }

    if (context.storageMode == 'saf' && isContentUri(filePath)) {
      final treeUri = context.downloadTreeUri;
      if (treeUri == null || treeUri.isEmpty) {
        return null;
      }
      var preserve = false;
      final rawFileName =
          (result['file_name'] as String?) ?? context.safFileName ?? 'track';
      final newFileName =
          '${rawFileName.replaceFirst(RegExp(r'\.[^.]+$'), '')}.flac';
      final newUri = await _replaceSafFileVia(
        uri: filePath,
        treeUri: treeUri,
        relativeDir: context.safRelativeDir ?? '',
        op: (tempPath, addCleanup) async {
          final codec = await FFmpegService.probePrimaryAudioCodec(tempPath);
          final isAlreadyNativeFlac =
              codec == 'flac' && await FFmpegService.isNativeFlacFile(tempPath);
          final shouldAttemptConversion =
              FFmpegService.isLosslessAudioCodec(codec) ||
              (requiresContainerConversion && isInconclusiveAudioCodec(codec));
          if (!shouldAttemptConversion) {
            _log.d(
              'Preserving native container; audio codec is ${codec ?? 'unknown'}, '
              'no FLAC container conversion needed.',
            );
            preserve = true;
            return null;
          }
          if (isAlreadyNativeFlac) {
            _log.d(
              'Native FLAC payload detected in temporary container; publishing '
              'as FLAC and embedding metadata.',
            );
            await embedFlacMetadata(tempPath);
            return (tempPath, newFileName);
          }
          final flacPath = await FFmpegService.convertM4aToFlac(tempPath);
          if (flacPath == null) {
            return null;
          }
          addCleanup(flacPath);
          await embedFlacMetadata(flacPath);
          return (flacPath, newFileName);
        },
      );
      if (preserve) {
        return filePath;
      }
      if (newUri == null) {
        return null;
      }
      result['file_name'] = newFileName;
      markFinalOutputAsFlac();
      return newUri;
    }

    final codec = await FFmpegService.probePrimaryAudioCodec(filePath);
    final isAlreadyNativeFlac =
        codec == 'flac' && await FFmpegService.isNativeFlacFile(filePath);
    final shouldAttemptConversion =
        FFmpegService.isLosslessAudioCodec(codec) ||
        (requiresContainerConversion && isInconclusiveAudioCodec(codec));
    if (!shouldAttemptConversion) {
      _log.d(
        'Preserving native container; audio codec is ${codec ?? 'unknown'}, '
        'no FLAC container conversion needed.',
      );
      return filePath;
    }
    if (isAlreadyNativeFlac) {
      final flacPath = await FFmpegService.ensureNativeFlacExtension(filePath);
      await embedFlacMetadata(flacPath);
      markFinalOutputAsFlac();
      return flacPath;
    }
    final flacPath = await FFmpegService.convertM4aToFlac(filePath);
    if (flacPath == null) {
      return null;
    }
    await embedFlacMetadata(flacPath);
    markFinalOutputAsFlac();
    return flacPath;
  }

  /// Shared external-LRC finalize used by both the inline single-item
  /// pipeline (SAF only; the local-file case is already handled during
  /// metadata embedding) and the native-worker pipeline (both storage
  /// modes). [resolveBaseName] and [onFetchError] are each caller's own
  /// base-name fallback chain and fetch-failure log line, evaluated lazily
  /// to match the original call sites exactly.
  Future<bool> _saveExternalLrc({
    required Map<String, dynamic> result,
    required AppSettings settings,
    required ExtensionState extensionState,
    required Track track,
    required String service,
    required String filePath,
    required String storageMode,
    String? downloadTreeUri,
    required String safRelativeDir,
    required Future<String> Function() resolveBaseName,
    required void Function(Object e) onFetchError,
  }) async {
    final lyricsMode = settings.lyricsMode;
    final shouldSaveExternalLrc =
        settings.embedMetadata &&
        settings.embedLyrics &&
        !_shouldSkipLyrics(extensionState, track.source, service) &&
        (lyricsMode == 'external' || lyricsMode == 'both');
    if (!shouldSaveExternalLrc) {
      return false;
    }

    String? lrcContent = result['lyrics_lrc'] as String?;
    if (!hasUsableLyricsContent(lrcContent ?? '')) {
      try {
        lrcContent = await PlatformBridge.getLyricsLRC(
          track.id,
          track.name,
          track.artistName,
          durationMs: track.duration * 1000,
        );
      } catch (e) {
        onFetchError(e);
      }
    }
    if (!hasUsableLyricsContent(lrcContent ?? '') ||
        isInstrumentalLyricsMarker(lrcContent!)) {
      return false;
    }
    final resolvedLrc = lrcContent;

    if (storageMode == 'saf' && isContentUri(filePath)) {
      if (downloadTreeUri == null || downloadTreeUri.isEmpty) {
        return false;
      }
      final baseName = await resolveBaseName();
      final written = await _writeLrcToSaf(
        treeUri: downloadTreeUri,
        relativeDir: safRelativeDir,
        baseName: baseName,
        lrcContent: resolvedLrc,
      );
      if (written) result['lyrics_lrc'] = resolvedLrc;
      return written;
    }

    try {
      final lrcPath = filePath.replaceAll(RegExp(r'\.[^.]+$'), '.lrc');
      final safeLrcPath = lrcPath == filePath ? '$filePath.lrc' : lrcPath;
      await File(safeLrcPath).writeAsString(resolvedLrc);
      result['lyrics_lrc'] = resolvedLrc;
      _log.d('Native-worker external LRC saved: $safeLrcPath');
      return true;
    } catch (e) {
      _log.w('Failed to save native-worker external LRC: $e');
      return false;
    }
  }
}
