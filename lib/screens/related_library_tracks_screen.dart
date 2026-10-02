import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/unified_library_item.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/screens/track_metadata_screen.dart';
import 'package:spotiflac_android/services/related_library_tracks.dart';
import 'package:spotiflac_android/utils/nav_bar_inset.dart';
import 'package:spotiflac_android/widgets/app_loading_indicator.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/cached_cover_image.dart';

final relatedLibraryTracksProvider = FutureProvider.autoDispose
    .family<List<UnifiedLibraryItem>, UnifiedLibraryItem>((ref, seed) {
      final includeLocal = ref.watch(
        settingsProvider.select((s) => s.localLibraryEnabled),
      );
      return loadRelatedLibraryTracks(seed, includeLocal: includeLocal);
    });

class RelatedLibraryTracksScreen extends ConsumerWidget {
  const RelatedLibraryTracksScreen({super.key, required this.seed});

  final UnifiedLibraryItem seed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = ref.watch(relatedLibraryTracksProvider(seed));
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: context.l10n.relatedLibraryTracks),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(context.l10n.relatedLibraryDescription),
            ),
          ),
          ...tracks.when(
            loading: () => [
              const SliverToBoxAdapter(
                child: Center(child: AppLoadingIndicator()),
              ),
            ],
            error: (_, _) => [
              SliverToBoxAdapter(
                child: ListTile(
                  title: Text(context.l10n.relatedLibraryLoadError),
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () =>
                        ref.invalidate(relatedLibraryTracksProvider(seed)),
                  ),
                ),
              ),
            ],
            data: (items) => [
              if (items.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(context.l10n.relatedLibraryEmpty),
                  ),
                ),
              SliverList.list(
                children: [
                  for (final item in items)
                    ListTile(
                      leading: CachedCoverImage(
                        imageUrl: item.localCoverPath ?? item.coverUrl ?? '',
                        width: 48,
                        height: 48,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      title: Text(item.trackName),
                      subtitle: Text(item.artistName),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => TrackMetadataScreen(
                            item: item.historyItem,
                            localItem: item.localItem,
                          ),
                        ),
                      ),
                      trailing: IconButton(
                        tooltip: context.l10n.trackMetadataPlay,
                        icon: const Icon(Icons.play_arrow),
                        onPressed: () =>
                            ref.read(musicPlayerControllerProvider).playAll([
                              if (item.localItem != null)
                                playableFromLocal(item.localItem!)
                              else if (item.historyItem != null)
                                playableFromHistory(item.historyItem!),
                            ]),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const NavBarSliverSpacer(),
        ],
      ),
    );
  }
}
