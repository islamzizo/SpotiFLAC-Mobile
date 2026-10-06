import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/library_collections.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/library_collections_database.dart';
import 'package:spotiflac_android/services/library_collections_hydration.dart';

Map<String, dynamic> trackRow(int index) => {
  'track_key': 'example:$index',
  'track_json': jsonEncode(
    Track(
      id: '$index',
      name: 'Song $index',
      artistName: 'Artist $index',
      albumName: 'Album',
      duration: 180,
      source: 'example',
      coverUrl: 'https://example.com/cover-$index.jpg',
      availability: ServiceAvailability(
        tidal: true,
        qobuz: false,
        amazon: false,
        deezer: false,
      ),
    ).toJson(),
  ),
  'added_at': '2026-01-02T03:04:05Z',
};

LibraryCollectionsSnapshot collectionFixture(int count) =>
    LibraryCollectionsSnapshot(
      wishlistRows: List.generate(count, trackRow),
      lovedRows: [
        trackRow(2),
        {'track_key': 'bad', 'track_json': '{'},
      ],
      favoriteArtistRows: [
        {
          'artist_key': 'example:artist',
          'artist_json': jsonEncode({
            'artistId': 'artist',
            'providerId': 'example',
            'name': 'Artist',
            'imageUrl': 'https://example.com/artist.jpg',
            'addedAt': '2025-12-01T00:00:00Z',
          }),
          'added_at': '2026-01-01T00:00:00Z',
        },
        {'artist_key': 'bad', 'artist_json': '[]'},
      ],
      playlistRows: [
        {
          'id': 'playlist',
          'name': 'Playlist',
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': 'invalid',
          'preview_track_json': jsonEncode({'coverUrl': 'cover'}),
        },
        {'id': ''},
        {
          'id': 'other',
          'name': 'Other',
          'created_at': '2026-01-01T00:00:00Z',
          'preview_track_json': '{',
        },
      ],
      playlistTrackRows: [
        {'playlist_id': 'playlist', 'track_key': 'example:2'},
        {'playlist_id': 'playlist', 'track_key': 'example:2'},
        {'playlist_id': 'playlist', 'track_key': 'example:3'},
        {'playlist_id': 'orphan', 'track_key': 'example:orphan'},
        {'playlist_id': '', 'track_key': 'example:ignored'},
        {'playlist_id': 'other', 'track_key': ''},
      ],
    );

void main() {
  test(
    'native row file preserves snapshot parity and is always cleaned',
    () async {
      final snapshot = collectionFixture(80);
      final temporary = await Directory.systemTemp.createTemp(
        'collection-read-test-',
      );
      final file = File('${temporary.path}/rows.ndjson');
      final rows = [
        for (final row in snapshot.wishlistRows)
          {'kind': 'wishlist', 'row': row},
        for (final row in snapshot.lovedRows) {'kind': 'loved', 'row': row},
        for (final row in snapshot.playlistRows)
          {'kind': 'playlist', 'row': row},
        for (final row in snapshot.playlistTrackRows)
          {'kind': 'membership', 'row': row},
        for (final row in snapshot.favoriteArtistRows)
          {'kind': 'artist', 'row': row},
      ];
      await file.writeAsString(rows.map(jsonEncode).join('\n'));
      final native = LibraryCollectionsSnapshot(
        wishlistRows: const [],
        lovedRows: const [],
        playlistRows: const [],
        playlistTrackRows: const [],
        favoriteArtistRows: const [],
        nativeRowsPath: file.path,
        nativeRowsDirectory: temporary.path,
        nativeRowCount: rows.length,
      );
      final actual = await hydrateLibraryCollectionsSnapshot(native);
      expect(
        jsonEncode(actual.toJson()),
        jsonEncode(decodeLibraryCollectionsSnapshot(snapshot).toJson()),
      );
      expect(actual.playlistById('playlist')!.trackKeys, {
        'example:2',
        'example:3',
      });
      expect(await temporary.exists(), isFalse);
      for (final content in [
        'not json',
        '${jsonEncode(rows.first)}\n',
        jsonEncode({'kind': 'unknown', 'row': <String, dynamic>{}}),
      ]) {
        final directory = await Directory.systemTemp.createTemp(
          'collection-read-test-',
        );
        final path = '${directory.path}/rows.ndjson';
        await File(path).writeAsString(content);
        await expectLater(
          hydrateLibraryCollectionsSnapshot(
            LibraryCollectionsSnapshot(
              wishlistRows: const [],
              lovedRows: const [],
              playlistRows: const [],
              playlistTrackRows: const [],
              favoriteArtistRows: const [],
              nativeRowsPath: path,
              nativeRowsDirectory: directory.path,
              nativeRowCount: rows.length,
            ),
          ),
          throwsA(isA<Error>()),
        );
        expect(await directory.exists(), isFalse);
      }
    },
  );

  test(
    'native playlist rows preserve track index and remove their staging',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'collection-read-playlist-',
      );
      final path = '${directory.path}/rows.ndjson';
      await File(path).writeAsString(
        List.generate(
          80,
          (index) =>
              jsonEncode({'kind': 'playlist_track', 'row': trackRow(index)}),
        ).join('\n'),
      );
      final known = List.generate(80, (index) => 'example:$index').toSet();
      final loaded = await hydratePlaylistTracksSnapshot(
        LibraryPlaylistTracksSnapshot(
          nativeRowsPath: path,
          nativeRowsDirectory: directory.path,
          nativeRowCount: 80,
        ),
        knownKeys: known,
      );
      expect(loaded.tracks.length, 80);
      expect(loaded.membershipUnchanged, isTrue);
      expect(loaded.trackKeys, known);
      expect(await directory.exists(), isFalse);
    },
  );

  test(
    'export worker keeps category/playlist/track order and original snapshot',
    () async {
      final base = decodeLibraryCollectionsSnapshot(collectionFixture(20000));
      final entries = base.wishlist.take(80).toList();
      final state = base.copyWith(
        playlists: [
          base.playlists.first.copyWith(
            tracks: entries,
            coverImagePath: () => '/covers/custom.jpg',
          ),
          base.playlists.last.copyWith(tracks: entries.reversed.toList()),
        ],
      );
      final expected = jsonEncode(state.toJson());
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      final pending = exportLibraryCollectionsState(state);
      final newer = state.copyWith(wishlist: const [], playlists: const []);
      final actual = await pending;
      timer.cancel();
      expect(jsonEncode(actual), expected);
      final json = await exportLibraryCollectionsJson(state);
      expect(json, expected);
      expect(jsonDecode(json), jsonDecode(expected));
      expect(newer.wishlistCount, 0);
      expect(ticks, greaterThan(1));
    },
  );

  test(
    'JSON fragment worker preserves escaping and small empty categories',
    () async {
      final state = LibraryCollectionsState(
        wishlist: [
          CollectionTrackEntry(
            key: 'example:escaped',
            addedAt: DateTime.utc(2026),
            track: const Track(
              id: 'escaped',
              name: '"音楽"\n\\line\t',
              artistName: 'İstanbul 🎵',
              albumName: '',
              duration: 180,
              comment: 'comma , colon : braces {} bracket []',
              source: 'example',
            ),
          ),
        ],
      );
      final json = await exportLibraryCollectionsJson(state);
      expect(json, jsonEncode(state.toJson()));
      expect((jsonDecode(json) as Map)['loved'], isEmpty);
      expect(
        await exportLibraryCollectionsJson(LibraryCollectionsState()),
        jsonEncode(LibraryCollectionsState().toJson()),
      );
    },
  );

  for (final count in [3, 80]) {
    test(
      'collection hydration preserves row order and lazy indices ($count)',
      () async {
        final snapshot = collectionFixture(count);
        final expected = decodeLibraryCollectionsSnapshot(snapshot);
        final actual = await hydrateLibraryCollectionsSnapshot(snapshot);
        expect(jsonEncode(actual.toJson()), jsonEncode(expected.toJson()));
        expect(
          actual.wishlist.map((entry) => entry.track.id),
          List.generate(count, (index) => '$index'),
        );
        expect(actual.loved.map((entry) => entry.key), ['example:2']);
        expect(actual.favoriteArtists.single.addedAt, DateTime.utc(2025, 12));
        expect(actual.containsFavoriteArtistKey('example:artist'), isTrue);
        final playlist = actual.playlistById('playlist')!;
        expect(playlist.trackKeys, {'example:2', 'example:3'});
        expect(playlist.tracks, isEmpty);
        expect(playlist.tracksLoaded, isFalse);
        expect(playlist.previewCover, 'cover');
        expect(playlist.updatedAt, playlist.createdAt);
        expect(actual.playlistById('other')!.previewCover, isNull);
        expect(actual.isTrackInAnyPlaylist('example:2'), isTrue);
        expect(actual.isTrackInAnyPlaylist('example:orphan'), isFalse);
        expect(actual.isLoaded, isTrue);
      },
    );
  }

  test(
    'playlist hydration retains duplicates and removes corrupt memberships',
    () async {
      final rows = [
        ...List.generate(80, trackRow),
        trackRow(0),
        {'track_key': 'corrupt', 'track_json': 'not json'},
        {'track_key': '', 'track_json': '{}'},
        {'track_key': 'array', 'track_json': '[]'},
        {'track_key': 'missing-fields', 'track_json': '{}'},
      ];
      final validKeys = List.generate(80, (index) => 'example:$index').toSet();
      final corrupted = await hydratePlaylistTracks(
        rows,
        knownKeys: {...validKeys, 'corrupt'},
      );
      expect(corrupted.tracks.length, 81);
      expect(corrupted.tracks.last.key, 'example:0');
      expect(corrupted.trackKeys, validKeys);
      expect(corrupted.membershipUnchanged, isFalse);
      final valid = await hydratePlaylistTracks(rows, knownKeys: validKeys);
      expect(valid.membershipUnchanged, isTrue);
      final playlist = UserPlaylistCollection(
        id: 'playlist',
        name: 'Playlist',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        tracks: const [],
        tracksLoaded: false,
        trackKeys: validKeys,
      );
      final loaded = playlist.withHydratedTracks(
        tracks: valid.tracks,
        trackKeys: valid.trackKeys,
        membershipUnchanged: valid.membershipUnchanged,
      );
      expect(loaded.sharesMembershipIndexWith(playlist), isTrue);
      expect(loaded.tracksLoaded, isTrue);
      expect(loaded.trackCount, 80);
    },
  );

  test('large collection parsing leaves caller timers able to run', () async {
    final snapshot = collectionFixture(20000);
    var ticks = 0;
    final timer = Timer.periodic(
      const Duration(milliseconds: 1),
      (_) => ticks++,
    );
    final loaded = await hydrateLibraryCollectionsSnapshot(snapshot);
    timer.cancel();
    expect(loaded.wishlistCount, 20000);
    expect(loaded.containsWishlistKey('example:19999'), isTrue);
    // The old synchronous parsing path cannot service this timer while parsing.
    expect(ticks, greaterThan(1));
  });

  test(
    'worker failure releases a pending batch and allows subsequent loads',
    () async {
      final valid = collectionFixture(80);
      final invalid = LibraryCollectionsSnapshot(
        wishlistRows: valid.wishlistRows,
        lovedRows: valid.lovedRows,
        favoriteArtistRows: valid.favoriteArtistRows,
        playlistRows: valid.playlistRows,
        playlistTrackRows: [
          {'playlist_id': 123, 'track_key': 'invalid-type'},
        ],
      );
      await expectLater(
        hydrateLibraryCollectionsSnapshot(invalid),
        throwsA(isA<Error>()),
      );
      final subsequent = await hydrateLibraryCollectionsSnapshot(valid);
      expect(subsequent.wishlistCount, 80);
      expect(subsequent.playlistById('playlist')!.trackCount, 2);
    },
  );
}
