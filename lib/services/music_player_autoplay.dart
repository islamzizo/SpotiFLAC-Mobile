part of 'music_player_service.dart';

typedef AutoplayLibraryLoader =
    Future<List<PlayableMedia>> Function(PlayableMedia seed);

void setAutoplayEnabled(bool enabled, {bool includeLocal = true}) =>
    musicPlayerRuntime.configure(
      musicPlayerRuntime.settings.copyWith(
        autoplay: enabled,
        localLibraryEnabled: includeLocal,
      ),
    );

/// Bounded database pages keep recommendation work independent of Library
/// size. Both downloaded tracks and enabled scanned sources are local files.
Future<List<PlayableMedia>> _loadAutoplayLibrary(
  PlayableMedia seed,
  MusicPlayerRuntime runtime,
) async {
  final database = runtime.dependencies.libraryDatabase;
  final includeLocal = runtime.settings.localLibraryEnabled;
  final query = QueueLibraryDbQuery(includeLocal: includeLocal);
  final count = (await database.getQueueCounts(query)).allTrackCount;
  final offset = count > 256 ? Random().nextInt(count - 255) : 0;
  final rows = [
    if (seed.artist.trim().isNotEmpty)
      ...await database.getQueueTrackPage(
        QueueLibraryDbQuery(
          includeLocal: includeLocal,
          searchQuery: seed.artist,
          limit: 128,
        ),
      ),
    ...await database.getQueueTrackPage(
      QueueLibraryDbQuery(
        includeLocal: includeLocal,
        offset: offset,
        limit: 256,
      ),
    ),
  ];
  final result = <PlayableMedia>[];
  for (final row in rows) {
    final data = (row['item'] as Map).cast<String, dynamic>();
    final source = data['filePath'] as String? ?? '';
    if (source.isEmpty) continue;
    // Do not interpret remote URLs as streamable Library items.
    if (source.startsWith('http://') || source.startsWith('https://')) continue;
    if (!source.startsWith('content://') && !await File(source).exists()) {
      continue;
    }
    final cover = data['coverPath'] as String? ?? data['coverUrl'] as String?;
    final seconds = readPositiveInt(data['duration']);
    result.add(
      PlayableMedia(
        id: data['id'] as String,
        source: source,
        title: data['trackName'] as String? ?? '',
        artist: data['artistName'] as String? ?? '',
        album: data['albumName'] as String? ?? '',
        genre: data['genre'] as String?,
        artUri: cover == null || cover.isEmpty
            ? null
            : cover.startsWith('/')
            ? Uri.file(cover).toString()
            : cover,
        duration: seconds == null ? null : Duration(seconds: seconds),
        bitDepth: readPositiveInt(data['bitDepth']),
        sampleRate: readPositiveInt(data['sampleRate']),
        bitrate: readPositiveInt(data['bitrate']),
        format: data['format'] as String?,
      ),
    );
  }
  return result;
}

/// Rank once per refill, so the visible queue is the actual playback order.
/// Related songs score higher, while recent plays and repeated artists lose
/// priority. No model, network lookup or audio analysis is needed.
List<PlayableMedia> selectAutoplayTracks({
  required PlayableMedia seed,
  required List<PlayableMedia> candidates,
  required List<PlayableMedia> upcoming,
  required List<PlayableMedia> recent,
  required Set<String> dismissedSources,
  required Random random,
  int limit = 6,
}) {
  String normalized(String? value) => normalizeLookupText(value);
  String songKey(PlayableMedia item) =>
      '${normalized(item.artist)}|${normalized(item.title)}';
  final sources = {
    seed.source,
    ...upcoming.map((item) => item.source),
    ...dismissedSources,
  };
  final songs = {songKey(seed), ...upcoming.map(songKey)};
  final scored = <(PlayableMedia, double)>[];
  for (final item in candidates) {
    if (item.source.trim().isEmpty ||
        item.source.startsWith('http://') ||
        item.source.startsWith('https://') ||
        sources.contains(item.source) ||
        songs.contains(songKey(item))) {
      continue;
    }
    sources.add(item.source);
    songs.add(songKey(item));
    var score = random.nextDouble() * 2;
    if (normalized(seed.artist).isNotEmpty &&
        normalized(seed.artist) == normalized(item.artist)) {
      score += 5;
    }
    if (normalized(seed.album).isNotEmpty &&
        normalized(seed.album) == normalized(item.album)) {
      score += 3;
    }
    if (normalized(seed.genre).isNotEmpty &&
        normalized(seed.genre) == normalized(item.genre)) {
      score += 4;
    }
    final played = recent.lastIndexWhere(
      (previous) =>
          previous.source == item.source || songKey(previous) == songKey(item),
    );
    if (played >= 0) score -= 20 + played.toDouble();
    scored.add((item, score));
  }
  final selected = <PlayableMedia>[];
  while (selected.length < limit && scored.isNotEmpty) {
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    final next = scored.removeAt(0).$1;
    selected.add(next);
    for (var i = 0; i < scored.length; i++) {
      final (item, score) = scored[i];
      if (normalized(item.artist) == normalized(next.artist)) {
        scored[i] = (item, score - 4);
      }
    }
  }
  return selected;
}

class _MusicAutoplay {
  _MusicAutoplay(this.handler, this.loadLibrary);

  final MusicPlayerHandler handler;
  final AutoplayLibraryLoader loadLibrary;
  final Set<String> _dismissed = {};
  Future<void>? _pending;
  int _generation = 0;
  (String, int)? _attempt;

  bool get enabled =>
      handler._settings.autoplay &&
      handler._repeatMode == AudioServiceRepeatMode.none;

  int get manualInsertIndex {
    for (var i = handler._index + 1; i < handler._media.length; i++) {
      if (handler._media[i].autoplay) return i;
    }
    return handler._media.length;
  }

  void reset() {
    _generation++;
    _pending = null;
    _attempt = null;
    _dismissed.clear();
  }

  void dismiss(PlayableMedia item) => _dismissed.add(item.source);

  void updateMode() {
    reset();
    // Never remove the song already playing or a manually queued song.
    // Refresh suggestions when the enabled Library sources change too.
    for (var i = handler._media.length - 1; i > handler._index; i--) {
      if (handler._media[i].autoplay) {
        handler.removeQueuedItem(handler._queueItems[i]);
      }
    }
    _dismissed.clear();
    if (enabled) unawaited(fill());
  }

  Future<void> fill() async {
    if (!enabled ||
        handler._disposed ||
        handler._index < 0 ||
        handler._index >= handler._media.length) {
      return;
    }
    if (handler._media.length - handler._index - 1 >= 3) return;
    final pending = _pending;
    if (pending != null) return pending;
    final seed = handler._media[handler._index];
    final attempt = (seed.source, handler._sessionQueueRevision);
    if (_attempt == attempt) return;
    _attempt = attempt;
    final operation = _fill(seed, _generation);
    _pending = operation;
    try {
      await operation;
    } finally {
      if (identical(_pending, operation)) _pending = null;
    }
  }

  Future<void> _fill(PlayableMedia seed, int generation) async {
    try {
      final candidates = await loadLibrary(seed);
      if (!enabled ||
          handler._disposed ||
          generation != _generation ||
          handler._index < 0) {
        return;
      }
      // Re-check the live queue after I/O: quick skips and manual additions
      // must not duplicate entries or replace the user's selected track.
      final current = handler._media[handler._index];
      final upcoming = handler._media.skip(handler._index + 1).toList();
      if (upcoming.length >= 3) return;
      final selected = selectAutoplayTracks(
        seed: current,
        candidates: candidates,
        upcoming: upcoming,
        recent: handler._playHistory
            .where((i) => i >= 0 && i < handler._media.length)
            .map((i) => handler._media[i])
            .toList(),
        dismissedSources: _dismissed,
        random: handler._random,
        limit: 6 - upcoming.length,
      );
      if (selected.isEmpty) return;
      final additions = [
        for (final item in selected)
          PlayableMedia.fromJson({...item.toJson(), 'autoplay': true})!,
      ];
      final queueItems = additions.map(handler._toMediaItem).toList();
      handler._media.addAll(additions);
      handler._queueItems.addAll(queueItems);
      handler._originalQueueOrder?.addAll(queueItems);
      handler._markSessionQueueChanged();
      handler.queue.add(List.unmodifiable(handler._queueItems));
      unawaited(
        handler._persistSession(position: handler.playbackState.value.position),
      );
    } catch (error) {
      _log.w('Could not prepare Library Autoplay: $error');
    }
  }
}
