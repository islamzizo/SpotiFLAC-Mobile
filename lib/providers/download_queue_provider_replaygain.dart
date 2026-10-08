// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

class _AlbumRgTrackEntry {
  String filePath;
  final String trackId;
  final double integratedLufs;
  final double truePeakLinear;
  final double durationSecs;

  _AlbumRgTrackEntry({
    required this.filePath,
    required this.trackId,
    required this.integratedLufs,
    required this.truePeakLinear,
    required this.durationSecs,
  });
}

class _AlbumRgAccumulator {
  final List<_AlbumRgTrackEntry> entries = [];
}

extension _DownloadQueueReplayGain on DownloadQueueNotifier {
  String _albumRgKey(Track track) => albumReplayGainKey(track);

  /// Purge a track's stale ReplayGain accumulator entry, dropping the whole
  /// album accumulator once it becomes empty.
  void _purgeAlbumRgEntry(Track track) {
    final key = _albumRgKey(track);
    final accumulator = _albumRgData[key];
    if (accumulator == null) return;
    accumulator.entries.removeWhere((e) => e.trackId == track.id);
    if (accumulator.entries.isEmpty) {
      _albumRgData.remove(key);
    }
  }

  /// Store a track's ReplayGain scan result for later album gain computation.
  void _storeTrackReplayGainForAlbum(
    Track track,
    String filePath,
    ReplayGainResult rg,
  ) {
    // Network staging is released per published track. Track ReplayGain is
    // embedded normally; do not schedule later writes to deleted staging files.
    if (filePath.contains('/network_downloads/')) return;
    final key = _albumRgKey(track);
    _albumRgData.putIfAbsent(key, () => _AlbumRgAccumulator());
    // Remove any stale entry for this track (e.g. from a previous failed
    // attempt that was retried).  Without this, the same track can accumulate
    // multiple entries and bias the album loudness calculation.
    _albumRgData[key]!.entries.removeWhere((e) => e.trackId == track.id);
    _albumRgData[key]!.entries.add(
      _AlbumRgTrackEntry(
        filePath: filePath,
        trackId: track.id,
        integratedLufs: rg.integratedLufs,
        truePeakLinear: rg.truePeakLinear,
        durationSecs: track.duration.toDouble(),
      ),
    );
  }

  /// Replace the temp path stored in the accumulator with the final output
  /// path.  For SAF downloads the embed happens on a temp file which is later
  /// deleted — this ensures the album-gain writer targets the real file.
  void _updateAlbumRgFilePath(Track track, String finalPath) {
    final key = _albumRgKey(track);
    final accumulator = _albumRgData[key];
    if (accumulator == null) return;
    for (final entry in accumulator.entries) {
      if (entry.trackId == track.id) {
        entry.filePath = finalPath;
        break;
      }
    }
  }

  /// After a track completes, check whether all tracks from the same album
  /// in the current queue are done.  If so, compute album gain and write it
  /// to every track's file.
  Future<void> _checkAndWriteAlbumReplayGain(Track track) async {
    final settings = ref.read(settingsProvider);
    if (!settings.embedReplayGain) return;

    final key = _albumRgKey(track);
    final accumulator = _albumRgData[key];
    if (accumulator == null || accumulator.entries.isEmpty) return;

    if (albumReplayGainBlocked(state.items, key)) return;

    // The accumulator entries represent successfully scanned tracks.  Entries
    // are only added after a successful ReplayGain scan, removed on retry or
    // when a non-completed item is removed from the queue, so every entry
    // here corresponds to a track that completed (or is about to complete)
    // its download.
    await _computeAndWriteAlbumRg(key, accumulator);
  }

  /// Write album ReplayGain tags to a single file.
  Future<void> _writeAlbumReplayGain(
    String filePath,
    String albumGain,
    String albumPeak,
  ) async {
    final ok = await ReplayGainService.writeAlbumTags(
      filePath,
      albumGain,
      albumPeak,
    );
    if (!ok) {
      _log.w('Album ReplayGain write failed for: $filePath');
    }
  }

  /// Re-check album ReplayGain for all albums that still have accumulator data.
  /// Called after removing/dismissing a failed or skipped item, which may
  /// unblock an album that was waiting for retryable items to be resolved.
  void _retriggerAlbumRgChecks() {
    if (_albumRgData.isEmpty) return;
    final settings = ref.read(settingsProvider);
    if (!settings.embedReplayGain) return;

    // Decide readiness once before starting writes, which may remove completed
    // accumulators. Avoid scanning the entire queue again for every album.
    final keys = readyReplayGainAlbums(state.items, {
      for (final entry in _albumRgData.entries)
        entry.key: entry.value.entries.length,
    });
    for (final key in keys) {
      final acc = _albumRgData[key];
      if (acc == null || acc.entries.isEmpty) continue;
      _computeAndWriteAlbumRg(key, acc);
    }
  }

  /// Compute album RG and write it — extracted from _checkAndWriteAlbumReplayGain
  /// for use when no queue items remain (all completed and removed).
  Future<void> _computeAndWriteAlbumRg(
    String key,
    _AlbumRgAccumulator accumulator,
  ) async {
    final validEntries = accumulator.entries.toList();
    // Single-track albums already have their track gain, so need no write.
    if (validEntries.length <= 1) {
      _albumRgData.remove(key);
      return;
    }

    // Duration-weighted power-mean of LUFS, matching whole-program loudness:
    // album_loudness = 10 * log10( Σ(10^(Li/10) * di) / Σ(di) ).
    double sumWeightedPower = 0;
    double sumDuration = 0;
    double maxPeak = 0;
    for (final entry in validEntries) {
      final weight = entry.durationSecs > 0 ? entry.durationSecs : 1.0;
      sumWeightedPower += pow(10, entry.integratedLufs / 10.0) * weight;
      sumDuration += weight;
      if (entry.truePeakLinear > maxPeak) {
        maxPeak = entry.truePeakLinear;
      }
    }
    final albumLufs = 10.0 * _log10(sumWeightedPower / sumDuration);
    const replayGainReferenceLufs = -18.0;
    final albumGainDb = replayGainReferenceLufs - albumLufs;

    final albumGain =
        '${albumGainDb >= 0 ? "+" : ""}${albumGainDb.toStringAsFixed(2)} dB';
    final albumPeak = maxPeak.toStringAsFixed(6);

    _log.i(
      'Album ReplayGain for "$key": gain=$albumGain, peak=$albumPeak (${validEntries.length} tracks, album LUFS=${albumLufs.toStringAsFixed(1)})',
    );

    for (final entry in validEntries) {
      try {
        await _writeAlbumReplayGain(entry.filePath, albumGain, albumPeak);
      } catch (e) {
        _log.w('Failed to write album ReplayGain to ${entry.filePath}: $e');
      }
    }

    _albumRgData.remove(key);
  }
}
