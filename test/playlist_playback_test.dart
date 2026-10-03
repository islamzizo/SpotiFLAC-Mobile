import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/local_library_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/playback_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/screens/library_tracks_folder_screen.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/theme/app_theme.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/track_card.dart';

final _tracks = [
  for (final name in ['First', 'Unavailable', 'Selected', 'Last'])
    Track(
      id: name,
      name: name,
      artistName: 'Artist',
      albumName: 'Album',
      duration: 180,
    ),
];

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(playerMode: 'internal');

  @override
  void setPlayerMode(String mode) => state = state.copyWith(playerMode: mode);
}

class _Handler extends Fake implements MusicPlayerHandler {}

class _Player extends MusicPlayerController {
  List<PlayableMedia> queue = [];
  int? index;

  @override
  Future<MusicPlayerHandler?> ensureInitialized() async => _Handler();

  @override
  Future<void> playAll(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {
    queue = items;
    index = initialIndex;
  }
}

class _Playback extends PlaybackController {
  final List<List<String>> resolvedRequests = [];
  final Map<String, String?> paths = {
    'First': 'content://library/first',
    'Selected': 'content://library/selected',
    'Last': 'content://library/last',
  };

  @override
  Future<List<String?>> resolveTrackFilePaths(List<Track> tracks) async {
    resolvedRequests.add(tracks.map((track) => track.id).toList());
    return [for (final track in tracks) paths[track.id]];
  }
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    playlists: [
      UserPlaylistCollection(
        id: 'playlist',
        name: 'Playlist',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        tracks: [
          for (final track in _tracks)
            CollectionTrackEntry(
              key: track.id,
              track: track,
              addedAt: DateTime(2026),
            ),
        ],
      ),
    ],
  );

  @override
  Future<void> ensurePlaylistLoaded(String playlistId) async {}
}

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final mornye in [false, true]) {
    testWidgets('playlist row queues its neighbors (Mornye: $mornye)', (
      tester,
    ) async {
      final player = _Player();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            musicPlayerControllerProvider.overrideWithValue(player),
            playbackProvider.overrideWith(_Playback.new),
            libraryCollectionsProvider.overrideWith(_Collections.new),
            localLibraryProvider.overrideWith(_Library.new),
            downloadHistoryProvider.overrideWith(_History.new),
            downloadHistoryVisibleBatchExistsProvider.overrideWith(
              (ref, request) => {
                for (final track in request.tracks)
                  if (track.spotifyId != 'Unavailable') track.lookupKey,
              },
            ),
            localLibraryCoverProvider.overrideWith(
              (ref, request) async => null,
            ),
            localLibraryFirstCoverProvider.overrideWith(
              (ref, request) async => null,
            ),
          ],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LibraryTracksFolderScreen(
              mode: LibraryTracksFolderMode.playlist,
              playlistId: 'playlist',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.ancestor(
        of: find.text('Selected'),
        matching: find.byType(TrackCard),
      );
      await tester.scrollUntilVisible(row, 200);
      await tester.tap(
        find.descendant(of: row, matching: find.byIcon(Icons.play_arrow)),
      );
      await tester.pumpAndSettle();

      expect(player.queue.map((item) => item.title), [
        'First',
        'Selected',
        'Last',
      ]);
      expect(player.index, 1);
      expect(tester.takeException(), isNull);
    });
  }

  late ProviderContainer container;
  late _Player player;
  late _Playback playback;
  setUp(() {
    player = _Player();
    playback = _Playback();
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        musicPlayerControllerProvider.overrideWithValue(player),
        playbackProvider.overrideWith(() => playback),
      ],
    );
    addTearDown(container.dispose);
  });

  test(
    'starting at the last track does not rotate earlier tracks after it',
    () async {
      await container
          .read(playbackProvider.notifier)
          .playTrackList(_tracks, startIndex: 3);
      expect(player.queue.map((item) => item.title), [
        'First',
        'Selected',
        'Last',
      ]);
      expect(player.index, player.queue.length - 1);
    },
  );

  test(
    'missing and virtual CUE tracks do not shift the selected track',
    () async {
      playback.paths['Unavailable'] = '/album.cue#track02';
      await container
          .read(playbackProvider.notifier)
          .playTrackList(_tracks, startIndex: 2);
      expect(player.queue.map((item) => item.title), [
        'First',
        'Selected',
        'Last',
      ]);
      expect(player.index, 1);
    },
  );

  test('repeated tracks retain the selected occurrence', () async {
    await container.read(playbackProvider.notifier).playTrackList([
      _tracks.first,
      _tracks.last,
      _tracks.first,
      _tracks[2],
    ], startIndex: 2);
    expect(player.queue.map((item) => item.title), [
      'First',
      'Last',
      'First',
      'Selected',
    ]);
    expect(player.index, 2);
  });

  test('unavailable selection starts the next playable track', () async {
    await container
        .read(playbackProvider.notifier)
        .playTrackList(_tracks, startIndex: 1);
    expect(player.queue[player.index!].title, 'Selected');
  });

  test('empty playlist leaves existing playback alone', () async {
    await container.read(playbackProvider.notifier).playTrackList([]);
    expect(player.index, isNull);
  });

  test(
    'no playable files reports an error without replacing playback',
    () async {
      playback.paths.clear();
      await expectLater(
        container.read(playbackProvider.notifier).playTrackList(_tracks),
        throwsA(isA<Exception>()),
      );
      expect(player.index, isNull);
    },
  );

  test('external mode opens only the selected available file', () async {
    container.read(settingsProvider.notifier).setPlayerMode('external');
    final calls = <MethodCall>[];
    const channel = MethodChannel('com.zarz.spotiflac/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await container
        .read(playbackProvider.notifier)
        .playTrackList(_tracks, startIndex: 2);
    expect(calls.single.method, 'openContentUri');
    expect(
      calls.single.arguments,
      containsPair('uri', 'content://library/selected'),
    );
    expect(player.index, isNull);
    expect(playback.resolvedRequests, [
      ['Selected'],
    ]);
  });

  test('external mode skips unavailable and CUE candidates lazily', () async {
    container.read(settingsProvider.notifier).setPlayerMode('external');
    playback.paths['Selected'] = '/album.cue#track02';
    const channel = MethodChannel('com.zarz.spotiflac/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await container
        .read(playbackProvider.notifier)
        .playTrackList(_tracks, startIndex: 1);
    expect(playback.resolvedRequests, [
      ['Unavailable'],
      ['Selected'],
      ['Last'],
    ]);
    expect(
      calls.single.arguments,
      containsPair('uri', 'content://library/last'),
    );
  });

  test(
    'external mode routes a network fallback to the internal queue',
    () async {
      container.read(settingsProvider.notifier).setPlayerMode('external');
      playback.paths['Selected'] = 'network://storage/track.flac';
      await container
          .read(playbackProvider.notifier)
          .playTrackList(_tracks, startIndex: 1);
      expect(
        player.queue[player.index!].source,
        'network://storage/track.flac',
      );
      expect(playback.resolvedRequests.take(2), [
        ['Unavailable'],
        ['Selected'],
      ]);
      expect(playback.resolvedRequests.last, _tracks.map((track) => track.id));
    },
  );
}
