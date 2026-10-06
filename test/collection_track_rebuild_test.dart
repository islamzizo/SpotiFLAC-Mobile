import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/download_item.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/recent_access_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/screens/album_screen.dart';
import 'package:spotiflac_android/screens/playlist_screen.dart';
import 'package:spotiflac_android/theme/app_theme.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/album_detail_header.dart';
import 'package:spotiflac_android/widgets/track_list_tile.dart';

const _track = Track(
  id: 'example-track',
  name: 'Example song',
  artistName: 'Example artist',
  albumName: 'Example album',
  duration: 180,
);

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);

  CollectionTrackEntry get entry => CollectionTrackEntry(
    key: trackCollectionKey(_track),
    track: _track,
    addedAt: DateTime.utc(2026),
  );

  void publishWishlist() => state = state.copyWith(wishlist: [entry]);
  void publishLoved() => state = state.copyWith(loved: [entry]);
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);

  @override
  void recordAlbumAccess({
    required String id,
    required String name,
    String? artistName,
    String? imageUrl,
    String? providerId,
  }) {}
}

Widget _app(ProviderContainer container, Widget child, {bool mornye = false}) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: mornye
            ? MornyeTheme.build(Brightness.light)
            : AppTheme.light(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets(
    'queue progress leaves track rows untouched but membership updates',
    (tester) async {
      var lookup = const DownloadQueueLookup.empty();
      final snapshot = Provider<DownloadQueueLookup>((ref) => lookup);
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          libraryCollectionsProvider.overrideWith(_Collections.new),
          currentMediaItemProvider.overrideWith((ref) => Stream.value(null)),
          downloadQueueLookupProvider.overrideWith(
            (ref) => ref.watch(snapshot),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        _app(
          container,
          TrackListTile(
            track: _track,
            isInHistory: false,
            onDownload: ({bool forceQualityPicker = false}) {},
            leading: const Text('1'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      var builds = 0;
      final previous = debugOnRebuildDirtyWidget;
      debugOnRebuildDirtyWidget = (element, builtOnce) {
        previous?.call(element, builtOnce);
        if (element.widget is TrackListTile) builds++;
      };
      addTearDown(() => debugOnRebuildDirtyWidget = previous);
      var item = DownloadItem(
        id: 'example-download',
        track: _track,
        service: 'example-provider',
        createdAt: DateTime.utc(2026),
      );
      Future<void> publish() async {
        lookup = DownloadQueueLookup.fromItems([item]);
        container.invalidate(snapshot);
        await tester.pump();
      }

      await publish();
      expect(builds, 1);
      builds = 0;
      for (var tick = 1; tick <= 30; tick++) {
        item = item.copyWith(
          progress: tick / 30,
          bytesReceived: tick * 1024,
          status: DownloadStatus.downloading,
        );
        await publish();
      }
      expect(builds, 0);
      lookup = const DownloadQueueLookup.empty();
      container.invalidate(snapshot);
      await tester.pump();
      expect(builds, 1);
      expect(find.text('Example song'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final mornye in [false, true]) {
    for (final album in [false, true]) {
      testWidgets('Love All isolates the $album page in Mornye=$mornye', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(430, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final collections = _Collections();
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            libraryCollectionsProvider.overrideWith(() => collections),
            recentAccessProvider.overrideWith(_Recent.new),
            currentMediaItemProvider.overrideWith((ref) => Stream.value(null)),
            downloadQueueLookupProvider.overrideWithValue(
              const DownloadQueueLookup.empty(),
            ),
            downloadHistoryVisibleBatchExistsProvider.overrideWith(
              (ref, request) => const <String>{},
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          _app(
            container,
            album
                ? const AlbumScreen(
                    albumId: 'example-album',
                    albumName: 'Example album',
                    tracks: [_track],
                  )
                : const PlaylistScreen(
                    playlistName: 'Example playlist',
                    tracks: [_track],
                  ),
            mornye: mornye,
          ),
        );
        await tester.pumpAndSettle();
        var pageBuilds = 0;
        var actionBuilds = 0;
        final previous = debugOnRebuildDirtyWidget;
        debugOnRebuildDirtyWidget = (element, builtOnce) {
          previous?.call(element, builtOnce);
          if (element.widget is AlbumScreen ||
              element.widget is PlaylistScreen) {
            pageBuilds++;
          }
          if (element.widget is HeaderCircleButton) actionBuilds++;
        };
        addTearDown(() => debugOnRebuildDirtyWidget = previous);
        collections.publishWishlist();
        await tester.pumpAndSettle();
        expect(pageBuilds, 0);
        expect(actionBuilds, 0);
        collections.publishLoved();
        await tester.pumpAndSettle();
        expect(pageBuilds, 0);
        expect(actionBuilds, greaterThan(0));
        final context = tester.element(find.byType(HeaderCircleButton).first);
        expect(
          find.byTooltip(context.l10n.trackOptionRemoveFromLoved),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
