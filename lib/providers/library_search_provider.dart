import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/models/unified_library_item.dart';
import 'package:spotiflac_android/providers/download_history_provider.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/local_library_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/services/history_database.dart';
import 'package:spotiflac_android/services/library_search.dart';

typedef LibrarySearchRequest = ({
  String query,
  LibrarySearchKind kind,
  int limit,
  int offset,
});

/// Resolve the selected record by its source and ID, without matching titles
/// that may also belong to another edition or remix.
final librarySearchTrackProvider = FutureProvider.autoDispose
    .family<UnifiedLibraryItem?, ({String source, String id})>((
      ref,
      key,
    ) async {
      if (key.source == 'local') {
        final row = await LibraryDatabase.instance.getById(key.id);
        return row == null
            ? null
            : UnifiedLibraryItem.fromLocalLibrary(
                LocalLibraryItem.fromJson(row),
              );
      }
      final row = await HistoryDatabase.instance.getById(key.id);
      return row == null
          ? null
          : UnifiedLibraryItem.fromDownloadHistory(
              DownloadHistoryItem.fromJson(row),
            );
    });

final librarySearchProvider = FutureProvider.autoDispose
    .family<List<LibrarySearchHit>, LibrarySearchRequest>((ref, request) async {
      final query = LibrarySearchQuery(request.query);
      if (query.terms.isEmpty) return const [];
      if (request.kind == LibrarySearchKind.playlists) {
        final playlists = ref.watch(
          libraryCollectionsProvider.select((state) => state.playlists),
        );
        final matches = playlists.where((p) => query.matches(p.name)).toList()
          ..sort((a, b) {
            final relevance = query.rank(a.name).compareTo(query.rank(b.name));
            if (relevance != 0) return relevance;
            final title = a.name.toLowerCase().compareTo(b.name.toLowerCase());
            return title != 0 ? title : a.id.compareTo(b.id);
          });
        return matches
            .skip(request.offset)
            .take(request.limit)
            .map((p) {
              return LibrarySearchHit(
                kind: LibrarySearchKind.playlists,
                id: p.id,
                title: p.name,
                cover: p.coverImagePath ?? p.previewCover,
                trackCount: p.trackCount,
              );
            })
            .toList(growable: false);
      }
      final includeLocal = ref.watch(
        settingsProvider.select((s) => s.localLibraryEnabled),
      );
      ref.watch(downloadHistoryProvider.select((s) => s.loadedIndexVersion));
      if (includeLocal) {
        ref.watch(localLibraryProvider.select((s) => s.loadedIndexVersion));
      }
      return LibraryDatabase.instance.searchLibrary(
        query: request.query,
        kind: request.kind,
        includeLocal: includeLocal,
        limit: request.limit,
        offset: request.offset,
      );
    });
