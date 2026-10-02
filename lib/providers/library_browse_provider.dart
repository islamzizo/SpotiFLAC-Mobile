import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/download_history_provider.dart';
import 'package:spotiflac_android/providers/local_library_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/album_completeness.dart';
import 'package:spotiflac_android/services/library_database.dart';

typedef LibraryBrowseRequest = ({
  bool artists,
  String? artist,
  String search,
  String sort,
  int limit,
  String? completeness,
});

class LibraryBrowseEntry {
  final String source;
  final String key;
  final String name;
  final String artist;
  final String? cover;
  final String samplePath;
  final int trackCount;
  final AlbumCompleteness? completeness;

  const LibraryBrowseEntry({
    required this.source,
    required this.key,
    required this.name,
    required this.artist,
    this.cover,
    required this.samplePath,
    required this.trackCount,
    this.completeness,
  });

  factory LibraryBrowseEntry.fromRow(
    Map<String, dynamic> row, {
    required bool isArtist,
  }) {
    final artist = row['artist_name'] as String? ?? '';
    final localCover = row['cover_path'] as String?;
    return LibraryBrowseEntry(
      source: row['queue_source'] as String? ?? '',
      key: (row[isArtist ? 'artist_key' : 'album_key'] as String?) ?? '',
      name: isArtist ? artist : row['album_name'] as String? ?? '',
      artist: artist,
      cover: localCover?.isNotEmpty == true
          ? localCover
          : row['cover_url'] as String?,
      samplePath: row['sample_file_path'] as String? ?? '',
      trackCount: (row['track_count'] as num?)?.toInt() ?? 0,
      completeness: AlbumCompleteness.fromRow(row),
    );
  }
}

final libraryBrowseProvider = FutureProvider.autoDispose
    .family<List<LibraryBrowseEntry>, LibraryBrowseRequest>((
      ref,
      request,
    ) async {
      ref.watch(downloadHistoryProvider.select((s) => s.loadedIndexVersion));
      ref.watch(localLibraryProvider.select((s) => s.loadedIndexVersion));
      final includeLocal = ref.watch(
        settingsProvider.select((s) => s.localLibraryEnabled),
      );
      final query = QueueLibraryDbQuery(
        limit: request.limit,
        includeSingleTrackAlbums: true,
        albumArtist: request.artist,
        searchQuery: request.search,
        sortMode: request.sort,
        includeLocal: includeLocal,
        metadata: request.completeness,
      );
      final rows = request.artists
          ? await LibraryDatabase.instance.getQueueArtistPage(query)
          : await LibraryDatabase.instance.getQueueAlbumPage(query);
      return rows
          .map(
            (row) => LibraryBrowseEntry.fromRow(row, isArtist: request.artists),
          )
          .toList(growable: false);
    });
