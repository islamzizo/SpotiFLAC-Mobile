import 'dart:math';

import 'package:spotiflac_android/models/unified_library_item.dart';
import 'package:spotiflac_android/providers/download_history_provider.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/utils/artist_utils.dart';
import 'package:spotiflac_android/utils/file_access.dart';

String _normalized(String? value) => (value ?? '').trim().toLowerCase();

/// Only related, locally stored songs qualify. A sparse library can return
/// an empty result instead of silently looking up online tracks.
List<UnifiedLibraryItem> rankRelatedLibraryTracks(
  UnifiedLibraryItem seed,
  List<UnifiedLibraryItem> candidates,
) {
  final artists = splitArtistNames(seed.artistName).map(_normalized).toSet();
  final seenPaths = {seed.filePath};
  final seenSongs = {
    '${_normalized(seed.artistName)}|${_normalized(seed.trackName)}',
  };
  final scored = <(UnifiedLibraryItem, int)>[];
  for (final item in candidates) {
    final path = item.filePath.trim();
    if (path.isEmpty ||
        path.startsWith('http://') ||
        path.startsWith('https://')) {
      continue;
    }
    final sameArtist = splitArtistNames(
      item.artistName,
    ).map(_normalized).any(artists.contains);
    final sameGenre =
        _normalized(seed.genre).isNotEmpty &&
        _normalized(seed.genre) == _normalized(item.genre);
    final sameAlbum =
        sameArtist &&
        _normalized(seed.albumName).isNotEmpty &&
        _normalized(seed.albumName) == _normalized(item.albumName);
    final score =
        (sameArtist ? 5 : 0) + (sameGenre ? 4 : 0) + (sameAlbum ? 3 : 0);
    if (score == 0 || !seenPaths.add(path)) continue;
    final song =
        '${_normalized(item.artistName)}|${_normalized(item.trackName)}';
    if (!seenSongs.add(song)) continue;
    scored.add((item, score));
  }
  scored.sort((a, b) {
    final score = b.$2.compareTo(a.$2);
    return score != 0 ? score : a.$1.trackName.compareTo(b.$1.trackName);
  });
  return scored.map((entry) => entry.$1).toList(growable: false);
}

Future<List<UnifiedLibraryItem>> loadRelatedLibraryTracks(
  UnifiedLibraryItem seed, {
  required bool includeLocal,
}) async {
  final database = LibraryDatabase.instance;
  final count = (await database.getQueueCounts(
    QueueLibraryDbQuery(includeLocal: includeLocal),
  )).allTrackCount;
  final rows = <Map<String, dynamic>>[];
  for (final artist in splitArtistNames(seed.artistName).take(4)) {
    rows.addAll(
      await database.getQueueTrackPage(
        QueueLibraryDbQuery(
          includeLocal: includeLocal,
          searchQuery: artist,
          limit: 96,
        ),
      ),
    );
  }
  rows.addAll(
    await database.getQueueTrackPage(
      QueueLibraryDbQuery(
        includeLocal: includeLocal,
        offset: count > 256 ? Random().nextInt(count - 255) : 0,
        limit: 256,
      ),
    ),
  );
  final candidates = <UnifiedLibraryItem>[];
  for (final row in rows) {
    final json = Map<String, dynamic>.from(row['item'] as Map);
    if (row['source'] == 'local') {
      candidates.add(
        UnifiedLibraryItem.fromLocalLibrary(LocalLibraryItem.fromJson(json)),
      );
    } else if (row['source'] == 'downloaded') {
      candidates.add(
        UnifiedLibraryItem.fromDownloadHistory(
          DownloadHistoryItem.fromJson(json),
        ),
      );
    }
  }
  // Bound storage-provider probes as well as database pages.
  final ranked = rankRelatedLibraryTracks(seed, candidates).take(48).toList();
  final exists = await fileExistenceByPath(
    ranked.map((item) => item.filePath).toList(),
  );
  return ranked
      .where((item) => exists[item.filePath] == true)
      .take(24)
      .toList(growable: false);
}
