import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/l10n/app_localizations.dart';
import 'package:spotiflac_android/models/unified_library_item.dart';
import 'package:spotiflac_android/providers/download_history_provider.dart';
import 'package:spotiflac_android/providers/library_search_provider.dart';
import 'package:spotiflac_android/providers/playback_provider.dart';
import 'package:spotiflac_android/screens/track_metadata_screen.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/services/library_search.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/library_search_results.dart';
import 'package:spotiflac_android/widgets/track_card.dart';

class _PlaybackRecorder extends PlaybackController {
  final paths = <String>[];

  @override
  Future<void> playMediaQueue(
    Iterable<PlayableMedia> queue, {
    required int startIndex,
    required String externalPath,
  }) async {
    paths.add(externalPath);
  }
}

LibrarySearchHit _hit(
  LibrarySearchKind kind,
  int index, {
  String query = 'Found',
}) => LibrarySearchHit(
  kind: kind,
  id: '$index',
  title: '$query ${kind.name} $index',
);

void main() {
  for (final mornye in [false, true]) {
    for (final local in [false, true]) {
      testWidgets(
        'search opens metadata; only Play starts audio ($mornye/$local)',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          FlutterSecureStorage.setMockInitialValues({});
          const channel = MethodChannel('com.zarz.spotiflac/backend');
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            (call) async => switch (call.method) {
              'safStat' => jsonEncode({'exists': true, 'size': 100}),
              'readAudioMetadata' || 'readFileMetadata' => '{}',
              'getLyricsLRCWithSource' => jsonEncode({
                'lyrics': '',
                'source': '',
              }),
              'getSafFileModTimes' => '{}',
              _ => null,
            },
          );
          addTearDown(
            () => tester.binding.defaultBinaryMessenger
                .setMockMethodCallHandler(channel, null),
          );
          const path = 'content://library/document/song.flac';
          final item = local
              ? UnifiedLibraryItem.fromLocalLibrary(
                  LocalLibraryItem(
                    id: 'chosen',
                    trackName: 'Song',
                    artistName: 'Artist',
                    albumName: 'Album',
                    filePath: path,
                    scannedAt: DateTime(2026),
                  ),
                )
              : UnifiedLibraryItem.fromDownloadHistory(
                  DownloadHistoryItem(
                    id: 'chosen',
                    trackName: 'Song',
                    artistName: 'Artist',
                    albumName: 'Album',
                    filePath: path,
                    service: 'provider-a',
                    downloadedAt: DateTime(2026),
                  ),
                );
          final player = _PlaybackRecorder();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                playbackProvider.overrideWith(() => player),
                librarySearchProvider.overrideWith(
                  (ref, request) async =>
                      request.kind == LibrarySearchKind.songs
                      ? [
                          LibrarySearchHit(
                            kind: LibrarySearchKind.songs,
                            id: 'chosen',
                            title: 'Song',
                            source: local ? 'local' : 'history',
                          ),
                        ]
                      : [],
                ),
                librarySearchTrackProvider.overrideWith((ref, key) async {
                  expect(key, (
                    source: local ? 'local' : 'history',
                    id: 'chosen',
                  ));
                  return item;
                }),
              ],
              child: MaterialApp(
                theme: mornye
                    ? MornyeTheme.build(Brightness.dark)
                    : ThemeData(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: Scaffold(
                  body: CustomScrollView(
                    slivers: [
                      LibrarySearchResults(query: 'Song', onOpenArtist: (_) {}),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<TrackCard>(find.byType(TrackCard)).style,
            mornye ? TrackCardStyle.flat : TrackCardStyle.filled,
          );
          await tester.tap(find.text('Song'));
          await tester.pumpAndSettle();
          final details = tester.widget<TrackMetadataScreen>(
            find.byType(TrackMetadataScreen),
          );
          expect(details.item, item.historyItem);
          expect(details.localItem, item.localItem);
          expect(player.paths, isEmpty);
          tester.state<NavigatorState>(find.byType(Navigator).first).pop();
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Play'));
          await tester.pumpAndSettle();
          expect(player.paths, [path]);
          expect(find.byType(TrackMetadataScreen), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final mornye in [false, true]) {
    testWidgets('Library shows every result type and paginates ($mornye)', (
      tester,
    ) async {
      final requests = <LibrarySearchRequest>[];
      final artists = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            librarySearchProvider.overrideWith((ref, request) async {
              requests.add(request);
              return List.generate(
                request.limit,
                (i) => _hit(request.kind, request.offset + i),
              );
            }),
          ],
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: CustomScrollView(
                slivers: [
                  LibrarySearchResults(
                    query: 'Found',
                    onOpenArtist: artists.add,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        requests.map((r) => r.kind).toSet(),
        LibrarySearchKind.values.toSet(),
      );
      expect(requests.every((r) => r.limit == 6 && r.offset == 0), isTrue);
      await tester.tap(find.text('Artists').first);
      await tester.pumpAndSettle();
      expect(requests.last.limit, 41);
      await tester.tap(find.text('Found artists 0'));
      expect(artists, ['Found artists 0']);
      await tester.scrollUntilVisible(
        find.byIcon(Icons.expand_more),
        600,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(requests.last.offset, 40);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an older query cannot replace newer results', (tester) async {
    final old = Completer<List<LibrarySearchHit>>();
    late StateSetter update;
    var query = 'old';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          librarySearchProvider.overrideWith((ref, request) {
            if (request.kind != LibrarySearchKind.songs) {
              return Future.value([]);
            }
            return request.query == 'old'
                ? old.future
                : Future.value([_hit(request.kind, 0, query: request.query)]);
          }),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return Scaffold(
                body: CustomScrollView(
                  slivers: [
                    LibrarySearchResults(query: query, onOpenArtist: (_) {}),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    update(() => query = 'new');
    await tester.pumpAndSettle();
    old.complete([_hit(LibrarySearchKind.songs, 0, query: 'old')]);
    await tester.pumpAndSettle();
    expect(find.text('new songs 0'), findsOneWidget);
    expect(find.text('old songs 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
