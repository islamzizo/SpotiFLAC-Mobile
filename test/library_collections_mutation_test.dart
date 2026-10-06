import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/services/library_collections_database.dart';

class _CollectionsDatabase implements LibraryCollectionsDatabase {
  final wishlist = <String, Map<String, dynamic>>{};
  final loved = <String, Map<String, dynamic>>{};
  final artists = <String, Map<String, dynamic>>{};
  final playlists = <String, Map<String, dynamic>>{};
  final playlistTracks = <String, List<Map<String, dynamic>>>{};
  final playlistReadStarted = Completer<void>();
  final releasePlaylistRead = Completer<void>();
  int playlistReads = 0;
  LibraryPlaylistTracksSnapshot? stagedPlaylistRows;
  Future<LibraryCollectionsSnapshot>? pendingSnapshot;
  final snapshotReadStarted = Completer<void>();
  final events = <String>[];
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();
  bool failNextWrite = false;

  Future<void> _write(String event, void Function() persist) async {
    events.add(event);
    final fail = failNextWrite;
    failNextWrite = false;
    // Only the first write waits, so an unserialized later write can overtake it.
    if (!writeStarted.isCompleted) {
      writeStarted.complete();
      await releaseWrite.future;
    }
    if (fail) throw StateError('database write failed');
    persist();
  }

  @override
  Future<bool> migrateFromSharedPreferences() async => false;

  @override
  Future<LibraryCollectionsSnapshot> loadSnapshot() async {
    if (!snapshotReadStarted.isCompleted) snapshotReadStarted.complete();
    return pendingSnapshot ??
        Future.value(
          LibraryCollectionsSnapshot(
            wishlistRows: wishlist.values.toList(),
            lovedRows: loved.values.toList(),
            playlistRows: playlists.values.toList(),
            playlistTrackRows: [
              for (final entry in playlistTracks.entries)
                for (final row in entry.value)
                  {'playlist_id': entry.key, 'track_key': row['track_key']},
            ],
            favoriteArtistRows: artists.values.toList(),
          ),
        );
  }

  @override
  Future<List<Map<String, dynamic>>> loadPlaylistTracks(
    String playlistId,
  ) async {
    playlistReads++;
    if (!playlistReadStarted.isCompleted) {
      playlistReadStarted.complete();
      await releasePlaylistRead.future;
    }
    return playlistTracks[playlistId] ?? const [];
  }

  @override
  Future<LibraryPlaylistTracksSnapshot> loadPlaylistTracksSnapshot(
    String playlistId,
  ) async {
    final rows = await loadPlaylistTracks(playlistId);
    return stagedPlaylistRows ?? LibraryPlaylistTracksSnapshot(rows: rows);
  }

  @override
  Future<void> renamePlaylist({
    required String playlistId,
    required String name,
    required String updatedAt,
  }) => _write('rename:$playlistId', () {
    playlists[playlistId] = {
      ...playlists[playlistId]!,
      'name': name,
      'updated_at': updatedAt,
    };
  });

  Future<void> _upsertTrack(
    Map<String, Map<String, dynamic>> rows,
    String collection,
    String key,
    String json,
    String date,
  ) => _write('insert:$collection:$key', () {
    rows[key] = {'track_key': key, 'track_json': json, 'added_at': date};
  });

  @override
  Future<void> upsertWishlistEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) => _upsertTrack(wishlist, 'wishlist', trackKey, trackJson, addedAt);

  @override
  Future<void> deleteWishlistEntry(String trackKey) =>
      _write('delete:wishlist:$trackKey', () => wishlist.remove(trackKey));

  @override
  Future<void> upsertLovedEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) => _upsertTrack(loved, 'loved', trackKey, trackJson, addedAt);

  @override
  Future<void> deleteLovedEntry(String trackKey) =>
      _write('delete:loved:$trackKey', () => loved.remove(trackKey));

  @override
  Future<void> upsertFavoriteArtistEntry({
    required String artistKey,
    required String artistJson,
    required String addedAt,
  }) => _write('insert:artists:$artistKey', () {
    artists[artistKey] = {
      'artist_key': artistKey,
      'artist_json': artistJson,
      'added_at': addedAt,
    };
  });

  @override
  Future<void> deleteFavoriteArtistEntry(String artistKey) =>
      _write('delete:artists:$artistKey', () => artists.remove(artistKey));

  @override
  Future<void> upsertPlaylist({
    required String id,
    required String name,
    required String createdAt,
    required String updatedAt,
    String? coverImagePath,
  }) => _write('insert:playlist:$id', () {
    playlists[id] = {
      'id': id,
      'name': name,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'cover_image_path': coverImagePath,
    };
  });

  @override
  Future<void> deletePlaylist(String playlistId) =>
      _write('delete:playlist:$playlistId', () => playlists.remove(playlistId));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Track _track(String id) => Track(
  id: id,
  name: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
  source: 'example',
);

ProviderContainer _container(_CollectionsDatabase db) {
  final container = ProviderContainer(
    overrides: [
      libraryCollectionsProvider.overrideWith(
        () => LibraryCollectionsNotifier(database: db),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('disposed snapshot read removes native rows before returning', () async {
    final directory = await Directory.systemTemp.createTemp(
      'collection-read-disposed-',
    );
    final path = '${directory.path}/rows.ndjson';
    await File(path).writeAsString('must never be parsed');
    final reply = Completer<LibraryCollectionsSnapshot>();
    final db = _CollectionsDatabase()..pendingSnapshot = reply.future;
    final container = _container(db);
    final notifier = container.read(libraryCollectionsProvider.notifier);
    final done = notifier.ensurePlaylistLoaded('missing');
    await db.snapshotReadStarted.future;
    container.dispose();
    reply.complete(
      LibraryCollectionsSnapshot(
        wishlistRows: const [],
        lovedRows: const [],
        playlistRows: const [],
        playlistTrackRows: const [],
        favoriteArtistRows: const [],
        nativeRowsPath: path,
        nativeRowsDirectory: directory.path,
        nativeRowCount: 1,
      ),
    );
    await done;
    expect(await directory.exists(), isFalse);
  });

  test(
    'playlist worker load is single-flight and retains intervening rename',
    () async {
      final db = _CollectionsDatabase();
      db.playlists['playlist'] = {
        'id': 'playlist',
        'name': 'Original',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      };
      db.playlistTracks['playlist'] = List.generate(
        100,
        (index) => {
          'track_key': 'example:$index',
          'track_json': jsonEncode(_track('$index')),
          'added_at': '2026-01-01T00:00:00Z',
        },
      );
      final container = _container(db);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      await notifier.ensurePlaylistsLoaded(const []);
      final first = notifier.ensurePlaylistLoaded('playlist');
      await db.playlistReadStarted.future;
      final second = notifier.ensurePlaylistLoaded('playlist');
      final rename = notifier.renamePlaylist('playlist', 'Renamed');
      await db.writeStarted.future;
      db.releaseWrite.complete();
      await rename;
      db.releasePlaylistRead.complete();
      await Future.wait([first, second]);
      final playlist = container
          .read(libraryCollectionsProvider)
          .playlistById('playlist')!;
      expect(db.playlistReads, 1);
      expect(playlist.name, 'Renamed');
      expect(playlist.tracksLoaded, isTrue);
      expect(playlist.trackCount, 100);
      expect(
        playlist.tracks.map((entry) => entry.track.id),
        List.generate(100, (index) => '$index'),
      );
    },
  );

  test('disposed playlist read cannot publish a worker result', () async {
    final db = _CollectionsDatabase();
    final directory = await Directory.systemTemp.createTemp(
      'collection-read-disposed-',
    );
    final path = '${directory.path}/rows.ndjson';
    await File(path).writeAsString('must never be parsed');
    db.stagedPlaylistRows = LibraryPlaylistTracksSnapshot(
      nativeRowsPath: path,
      nativeRowsDirectory: directory.path,
      nativeRowCount: 1,
    );
    db.playlists['playlist'] = {
      'id': 'playlist',
      'name': 'Playlist',
      'created_at': '2026-01-01T00:00:00Z',
    };
    final container = _container(db);
    final notifier = container.read(libraryCollectionsProvider.notifier);
    await notifier.ensurePlaylistsLoaded(const []);
    final loading = notifier.ensurePlaylistLoaded('playlist');
    await db.playlistReadStarted.future;
    container.dispose();
    db.releasePlaylistRead.complete();
    await loading;
    expect(db.playlistReads, 1);
    expect(await directory.exists(), isFalse);
  });

  test(
    'late write completion does not publish or start a disposed mutation',
    () async {
      final db = _CollectionsDatabase();
      final container = _container(db);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      await notifier.ensurePlaylistsLoaded(const []);
      final active = notifier.toggleWishlist(_track('active'));
      await db.writeStarted.future;
      final queued = notifier.toggleWishlist(_track('queued'));
      final cancelled = expectLater(queued, throwsStateError);
      container.dispose();
      db.releaseWrite.complete();
      expect(await active, isTrue);
      await cancelled;
      expect(db.events, ['insert:wishlist:example:active']);
      expect(db.wishlist.keys, ['example:active']);
    },
  );

  for (final kind in ['wishlist', 'loved', 'artists']) {
    test('two overlapping $kind toggles persist insert then delete', () async {
      final db = _CollectionsDatabase();
      final container = _container(db);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      await notifier.ensurePlaylistsLoaded(const []);
      Future<bool> toggle() => switch (kind) {
        'wishlist' => notifier.toggleWishlist(_track('song')),
        'loved' => notifier.toggleLoved(_track('song')),
        _ => notifier.toggleFavoriteArtist(
          artistId: 'artist',
          providerId: 'example',
          name: 'Artist',
        ),
      };
      final key = kind == 'artists' ? 'example:artist' : 'example:song';
      final first = toggle();
      await db.writeStarted.future;
      final second = toggle();
      await Future<void>.delayed(Duration.zero);
      expect(db.events, ['insert:$kind:$key']);
      final pending = container.read(libraryCollectionsProvider);
      expect(pending.wishlist, isEmpty);
      expect(pending.loved, isEmpty);
      expect(pending.favoriteArtists, isEmpty);
      db.releaseWrite.complete();
      expect(await Future.wait([first, second]), [true, false]);
      expect(db.events, ['insert:$kind:$key', 'delete:$kind:$key']);
      expect(db.wishlist, isEmpty);
      expect(db.loved, isEmpty);
      expect(db.artists, isEmpty);
      final state = container.read(libraryCollectionsProvider);
      expect(state.wishlist, isEmpty);
      expect(state.loved, isEmpty);
      expect(state.favoriteArtists, isEmpty);
    });
  }

  test(
    'playlist deletion cannot remove a concurrently created playlist',
    () async {
      final db = _CollectionsDatabase();
      for (final id in ['target', 'keep']) {
        db.playlists[id] = {
          'id': id,
          'name': id,
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        };
      }
      final container = _container(db);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      await notifier.ensurePlaylistsLoaded(const []);
      final deletion = notifier.deletePlaylist('target');
      await db.writeStarted.future;
      final creation = notifier.createPlaylist('New');
      await Future<void>.delayed(Duration.zero);
      expect(db.events, ['delete:playlist:target']);
      expect(
        container.read(libraryCollectionsProvider).playlists.map((p) => p.id),
        ['target', 'keep'],
      );
      db.releaseWrite.complete();
      await deletion;
      final createdId = await creation;
      expect(db.events, [
        'delete:playlist:target',
        'insert:playlist:$createdId',
      ]);
      expect(db.playlists.keys.toSet(), {'keep', createdId});
      expect(
        container.read(libraryCollectionsProvider).playlists.map((p) => p.id),
        [createdId, 'keep'],
      );
    },
  );

  test(
    'failed writes retain published state and release the next mutation',
    () async {
      final db = _CollectionsDatabase()..failNextWrite = true;
      final container = _container(db);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      await notifier.ensurePlaylistsLoaded(const []);
      final failed = notifier.toggleWishlist(_track('failed'));
      final failure = expectLater(failed, throwsStateError);
      await db.writeStarted.future;
      final successful = notifier.toggleWishlist(_track('successful'));
      await Future<void>.delayed(Duration.zero);
      expect(db.events, ['insert:wishlist:example:failed']);
      expect(container.read(libraryCollectionsProvider).wishlist, isEmpty);
      db.releaseWrite.complete();
      await failure;
      expect(await successful, isTrue);
      expect(db.wishlist.keys, ['example:successful']);
      expect(
        container.read(libraryCollectionsProvider).wishlist.map((e) => e.key),
        ['example:successful'],
      );
    },
  );
}
