import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/library_database_models.dart';
import 'package:spotiflac_android/services/library_queue_store.dart';
import 'package:spotiflac_android/services/library_row_mapper.dart';
import 'package:spotiflac_android/services/library_schema.dart';

import 'support/sqlite_process_database.dart';

List<String> _tracks(QueueLibraryDbPage page) => [
  for (final row in page.rows) '${row['source']}:${(row['item'] as Map)['id']}',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteProcessDatabase db;
  late LibraryQueueStore store;

  Future<void> addHistory(
    String id,
    String album,
    int number, {
    String artist = 'Artist',
    String title = 'Song',
    String? path,
  }) async {
    final file = path ?? '/$id.flac';
    await db.insert('history_db.history', {
      'id': id,
      'track_name': title,
      'artist_name': artist,
      'album_name': album,
      'album_artist': artist,
      'file_path': file,
      'downloaded_at': '2026-01-01',
      'service': 'example-provider',
      'album_key': '${album.toLowerCase()}|${artist.toLowerCase()}',
      'track_number': number,
      'total_tracks': 2,
      'disc_number': 1,
      'total_discs': 1,
      'bit_depth': 16,
      'genre': 'Pop',
      'release_date': '2026',
      'sort_track': title.toLowerCase(),
      'sort_artist': artist.toLowerCase(),
      'sort_album': album.toLowerCase(),
      'sort_album_artist': artist.toLowerCase(),
      'sort_genre': 'pop',
      'sort_release': '2026',
      'sort_added': 1,
      'search_text': '$title $artist $album'.toLowerCase(),
      'has_replaygain': number == 1 ? 1 : 0,
    });
    await db.insert('history_db.history_path_keys', {
      'item_id': id,
      'path_key': file,
    });
  }

  Future<void> addLocal(
    String id,
    int number, {
    String? path,
    String source = 'legacy',
  }) async {
    final file = path ?? '/$id.flac';
    final track = LocalLibraryItem(
      id: id,
      sourceId: source,
      trackName: 'Song',
      artistName: 'Artist',
      albumName: 'Local',
      filePath: file,
      scannedAt: DateTime.utc(2026),
      fileModTime: 1,
      trackNumber: number,
      totalTracks: 2,
      discNumber: 1,
      totalDiscs: 1,
      bitDepth: 16,
      genre: 'Pop',
      releaseDate: '2026',
      hasReplayGain: number == 1,
    );
    await db.insert('library', LibraryRowMapper.encode(track.toJson()));
    await db.insert('library_path_keys', {'item_id': id, 'path_key': file});
  }

  setUp(() async {
    db = await SqliteProcessDatabase.open();
    await LibrarySchema.create(db, LibrarySchema.version);
    await db.execute("ATTACH DATABASE ':memory:' AS history_db");
    final definition = RegExp(r'CREATE TABLE history\s*\([\s\S]*?\n\s*\)')
        .firstMatch(
          File('lib/services/history_database.dart').readAsStringSync(),
        )!
        .group(0)!;
    await db.execute(
      definition.replaceFirst(
        'CREATE TABLE history',
        'CREATE TABLE history_db.history',
      ),
    );
    await db.execute(
      'CREATE TABLE history_db.history_path_keys (item_id TEXT, path_key TEXT)',
    );
    await addHistory('h1', 'Downloaded', 1);
    await addHistory('h2', 'Downloaded', 2);
    await addHistory('single', 'Single', 2, artist: 'Another Artist');
    await addLocal('l1', 1);
    await addLocal('l2', 2);
    await addLocal('mirror', 1, path: '/h1.flac');
    await db.insert('library_sources', {
      'id': 'offline',
      'path': '/offline',
      'display_name': 'Offline',
      'available': 0,
    });
    await addLocal('hidden', 1, source: 'offline');
    store = LibraryQueueStore(db, historyFts: false, localFts: false);
  });
  tearDown(() => db.close());

  test(
    'track cursors match offset ordering across source ties for every sort',
    () async {
      for (final sort in [
        'latest',
        'oldest',
        'a-z',
        'z-a',
        'artist-asc',
        'artist-desc',
        'album-asc',
        'album-desc',
        'release-oldest',
        'release-newest',
        'genre-asc',
        'genre-desc',
      ]) {
        final expected = _tracks(
          await store.trackPage(QueueLibraryDbQuery(sortMode: sort)),
        );
        final actual = <String>[];
        QueueLibraryDbCursor? cursor;
        do {
          final page = await store.trackPage(
            QueueLibraryDbQuery(sortMode: sort, limit: 2, cursor: cursor),
          );
          actual.addAll(_tracks(page));
          cursor = page.nextCursor;
        } while (cursor != null);
        expect(actual, expected, reason: sort);
        expect(actual, hasLength(5), reason: sort);
        expect(actual, isNot(contains('local:mirror')));
        expect(actual, isNot(contains('local:hidden')));
      }
    },
  );

  test(
    'album cursors and invalid-cursor offset fallback preserve results',
    () async {
      for (final sort in [
        'latest',
        'album-asc',
        'album-desc',
        'artist-asc',
        'release-newest',
      ]) {
        final expected = (await store.albumPage(
          QueueLibraryDbQuery(sortMode: sort),
        )).rows;
        final first = await store.albumPage(
          QueueLibraryDbQuery(sortMode: sort, limit: 1),
        );
        final second = await store.albumPage(
          QueueLibraryDbQuery(
            sortMode: sort,
            limit: 1,
            cursor: first.nextCursor,
          ),
        );
        expect([...first.rows, ...second.rows], expected, reason: sort);
        final fallback = await store.albumPage(
          QueueLibraryDbQuery(
            sortMode: sort,
            offset: 1,
            limit: 1,
            cursor: const QueueLibraryDbCursor(['wrong length']),
          ),
        );
        expect(fallback.rows, [expected.last], reason: sort);
      }
    },
  );

  test(
    'fast counts agree with filtered counts and deduplicate visible paths',
    () async {
      final fast = await store.counts(const QueueLibraryDbQuery());
      final filtered = await store.counts(
        const QueueLibraryDbQuery(quality: 'cd'),
      );
      expect(
        [fast.allTrackCount, fast.albumCount, fast.singleTrackCount],
        [5, 2, 1],
      );
      expect(
        [
          filtered.allTrackCount,
          filtered.albumCount,
          filtered.singleTrackCount,
        ],
        [5, 2, 1],
      );
      final local = await store.counts(
        const QueueLibraryDbQuery(source: 'local'),
      );
      expect(local.allTrackCount, 2);
      final gain = await store.trackPage(
        const QueueLibraryDbQuery(metadata: 'missing-replaygain'),
      );
      expect(_tracks(gain).toSet(), {
        'downloaded:h2',
        'downloaded:single',
        'local:l2',
      });
    },
  );

  test('artist counts use the same filter as the track query', () async {
    for (final artist in ['Artist', 'Another Artist', 'Missing Artist']) {
      final query = QueueLibraryDbQuery(albumArtist: artist);
      final counts = await store.counts(query);
      final tracks = await store.trackPage(query);
      expect(counts.allTrackCount, tracks.rows.length, reason: artist);
      expect(
        [counts.allTrackCount, counts.albumCount, counts.singleTrackCount],
        switch (artist) {
          'Artist' => [4, 2, 0],
          'Another Artist' => [1, 0, 1],
          _ => [0, 0, 0],
        },
      );
    }
  });

  test(
    'independent FTS inputs match LIKE fallback and escape literal search',
    () async {
      await db.execute(
        "CREATE VIRTUAL TABLE history_db.history_search_fts USING fts5(search_text, tokenize='trigram')",
      );
      await db.execute(
        'INSERT INTO history_db.history_search_fts(rowid, search_text) SELECT rowid, search_text FROM history_db.history',
      );
      final expected = _tracks(
        await store.trackPage(const QueueLibraryDbQuery(searchQuery: 'Artist')),
      );
      const search = QueueLibraryDbQuery(searchQuery: 'Artist');
      final expectedAlbums = (await store.albumPage(search)).rows;
      final expectedCounts = await store.counts(search);
      final expectedArtists = await store.artistPage(search);
      for (final flags in [(true, false), (false, true), (true, true)]) {
        final indexed = LibraryQueueStore(
          db,
          historyFts: flags.$1,
          localFts: flags.$2,
        );
        expect(
          _tracks(
            await indexed.trackPage(
              const QueueLibraryDbQuery(searchQuery: 'Artist'),
            ),
          ),
          expected,
        );
        expect((await indexed.albumPage(search)).rows, expectedAlbums);
        final counts = await indexed.counts(search);
        expect(
          [counts.allTrackCount, counts.albumCount, counts.singleTrackCount],
          [
            expectedCounts.allTrackCount,
            expectedCounts.albumCount,
            expectedCounts.singleTrackCount,
          ],
        );
        expect(await indexed.artistPage(search), expectedArtists);
      }
      await addHistory(
        'literal',
        'Special',
        1,
        artist: 'Literal',
        title: 'Percent % Track',
      );
      expect(
        _tracks(
          await store.trackPage(const QueueLibraryDbQuery(searchQuery: '%')),
        ),
        ['downloaded:literal'],
      );
    },
  );

  test(
    'artist pages aggregate visible inventory without loading track models',
    () async {
      final artists = await store.artistPage(const QueueLibraryDbQuery());
      expect(artists.map((row) => row['artist_name']), [
        'Another Artist',
        'Artist',
      ]);
      expect(artists.map((row) => row['track_count']), [1, 4]);
      final downloaded = await store.artistPage(
        const QueueLibraryDbQuery(includeLocal: false),
      );
      expect(downloaded.map((row) => row['track_count']), [1, 2]);
    },
  );
}
