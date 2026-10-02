import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:spotiflac_android/utils/audio_format_utils.dart';
import 'package:spotiflac_android/utils/file_access.dart';
import 'package:spotiflac_android/utils/ios_container_paths.dart';
import 'package:spotiflac_android/services/history_database.dart';
import 'package:spotiflac_android/services/album_completeness.dart';
import 'package:spotiflac_android/services/library_cleanup.dart';
import 'package:spotiflac_android/services/library_search.dart';
import 'package:spotiflac_android/services/sqlite_helpers.dart' as sqlite;

part 'library_database_models.dart';
part 'library_database_queue_sql.dart';

final _log = AppLogger('LibraryDatabase');

class LibraryDatabase {
  static final LibraryDatabase instance = LibraryDatabase._init();
  // The FTS table is a derived, optional index and is initialized lazily after
  // the existing schema migration, so it does not require a user_version bump.
  static const int schemaVersion = 15;
  static const String legacySourceId = LocalLibraryItem.legacySourceId;
  static const String visibleLibraryView = 'library_visible';
  static const String searchFtsTable = 'library_search_fts';
  static const String lookupSummaryTable = 'library_lookup_summary';
  static const String _scanStageTable = 'library_scan_stage';
  static const String _scanStagePathKeysTable = 'library_scan_path_keys_stage';
  static const String _incrementalStageTable = 'library_incremental_stage';
  static const String _incrementalStagePathKeysTable =
      'library_incremental_path_keys_stage';
  static const String _downloadedLibraryIdsStageTable =
      'library_downloaded_ids_stage';
  // v4 records ReplayGain availability; older rows rescan once.
  static const int audioMetadataScanVersion = 4;

  /// First scan version whose rows record lyrics availability (v3).
  static const int lyricsMetadataScanVersion = 3;
  static final sqlite.SingleFlightInitializer<Database> _database =
      sqlite.SingleFlightInitializer<Database>();
  bool _historyAttached = false;
  // null means this database connection has not attempted FTS setup yet.
  // false is a completed capability/setup result and must not be retried.
  bool? _searchFtsAvailable;

  LibraryDatabase._init();

  Future<Database> get database {
    return _database.getOrCreate(() async {
      final db = await sqlite.openAppDatabase(
        'local_library.db',
        version: schemaVersion,
        onCreate: _createDB,
        onUpgrade: _upgradeDB,
        onOpen: _migrateIosContainerPaths,
      );
      // Library upserts use INSERT OR REPLACE. Recursive triggers ensure the
      // implicit delete also decrements materialized lookup ref-counts.
      await db.execute('PRAGMA recursive_triggers = ON');
      // onCreate normally initializes this derived index. Retry once after
      // opening an existing database in case an earlier setup was
      // interrupted; unsupported SQLite builds remain on the LIKE fallback.
      _searchFtsAvailable ??= await _createSearchFts(db);
      return db;
    });
  }

  bool get searchFtsAvailable => _searchFtsAvailable ?? false;

  Future<List<LibrarySearchHit>> searchLibrary({
    required String query,
    required LibrarySearchKind kind,
    required bool includeLocal,
    int limit = 40,
    int offset = 0,
  }) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    return LibrarySearchStore(
      db,
      historyFts: HistoryDatabase.instance.searchFtsAvailable,
      localFts: searchFtsAvailable,
    ).search(
      query: query,
      kind: kind,
      includeLocal: includeLocal,
      limit: limit,
      offset: offset,
    );
  }

  Future<void> _migrateIosContainerPaths(Database db) async {
    if (!Platform.isIOS) return;
    final documents = await getApplicationDocumentsDirectory();
    // Keep rows and their lookup keys consistent before any startup cleanup
    // can mistake a relocated file for a deleted one. Bookmarks remain the
    // authority for external sources.
    await db.transaction((txn) async {
      const localSources = "bookmark IS NULL OR bookmark = ''";
      final sources = await txn.query(
        'library_sources',
        columns: ['id', 'path'],
        where: localSources,
      );
      final localSourceIds = sources.map((source) => source['id']).toSet();
      final rows = await txn.query(
        'library',
        columns: ['id', 'source_id', 'file_path', 'cover_path'],
      );
      final batch = txn.batch();
      for (final row in rows) {
        final updates = <String, Object?>{};
        for (final column in ['file_path', 'cover_path']) {
          // Bookmarks own external audio paths, but extracted covers always
          // live in our sandbox, including covers from bookmarked folders.
          if (column == 'file_path' &&
              !localSourceIds.contains(row['source_id'])) {
            continue;
          }
          final previous = row[column] as String?;
          if (previous == null) continue;
          final current = rebaseIosSandboxPath(previous, documents.path);
          if (current != previous) updates[column] = current;
        }
        if (updates.isEmpty) continue;
        final id = row['id'] as String;
        batch.update('library', updates, where: 'id = ?', whereArgs: [id]);
        if (updates.containsKey('file_path')) {
          _putPathKeysInBatch(batch, id, updates['file_path'] as String);
        }
      }
      for (final source in sources) {
        final previous = source['path'] as String;
        final current = rebaseIosSandboxPath(previous, documents.path);
        if (current == previous) continue;
        batch.update(
          'library_sources',
          {'path': current},
          where: 'id = ?',
          whereArgs: [source['id']],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> _ensureHistoryAttached(Database db) async {
    if (_historyAttached) return;
    await HistoryDatabase.instance.database;
    final dbPath = await getApplicationDocumentsDirectory();
    final historyPath = join(dbPath.path, 'history.db');
    try {
      await db.execute('ATTACH DATABASE ? AS history_db', [historyPath]);
    } catch (e) {
      final message = e.toString().toLowerCase();
      if (!message.contains('already in use') &&
          !message.contains('already exists')) {
        rethrow;
      }
    }
    _historyAttached = true;
  }

  Future<void> _createDB(Database db, int version) async {
    _log.i('Creating library database schema v$version');

    await db.execute('''
      CREATE TABLE library (
        id TEXT PRIMARY KEY,
        source_id TEXT NOT NULL DEFAULT '$legacySourceId',
        track_name TEXT NOT NULL,
        artist_name TEXT NOT NULL,
        album_name TEXT NOT NULL,
        album_artist TEXT,
        file_path TEXT NOT NULL UNIQUE,
        cover_path TEXT,
        scanned_at TEXT NOT NULL,
        file_mod_time INTEGER,
        isrc TEXT,
        track_number INTEGER,
        total_tracks INTEGER,
        disc_number INTEGER,
        total_discs INTEGER,
        duration INTEGER,
        release_date TEXT,
        bit_depth INTEGER,
        sample_rate INTEGER,
        bitrate INTEGER,
        genre TEXT,
        composer TEXT,
        label TEXT,
        copyright TEXT,
        explicit INTEGER NOT NULL DEFAULT 0,
        has_lyrics INTEGER NOT NULL DEFAULT 0,
        has_replaygain INTEGER NOT NULL DEFAULT 0,
        format TEXT,
        audio_metadata_scan_version INTEGER NOT NULL DEFAULT 4,
        track_name_norm TEXT,
        artist_name_norm TEXT,
        album_name_norm TEXT,
        album_artist_norm TEXT,
        match_key TEXT,
        album_key TEXT,
        search_text TEXT,
        sort_genre TEXT,
        sort_release TEXT,
        sort_added INTEGER
      )
    ''');

    await db.execute('CREATE INDEX idx_library_isrc ON library(isrc)');
    await db.execute(
      'CREATE INDEX idx_library_track_artist ON library(track_name, artist_name)',
    );
    await db.execute(
      'CREATE INDEX idx_library_album ON library(album_name, album_artist)',
    );
    await db.execute(
      'CREATE INDEX idx_library_file_path ON library(file_path)',
    );
    await _createNormalizedIndexes(db);
    await _createQueueIndexes(db);
    await _createPathKeyTable(db);
    await _createLibrarySources(db);
    await _createLookupSummary(db);
    _searchFtsAvailable = await _createSearchFts(db);

    _log.i('Library database schema created with indexes');
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    _log.i('Upgrading library database from v$oldVersion to v$newVersion');

    if (oldVersion < 2) {
      await db.execute('ALTER TABLE library ADD COLUMN cover_path TEXT');
      _log.i('Added cover_path column');
    }

    if (oldVersion < 3) {
      await db.execute('ALTER TABLE library ADD COLUMN file_mod_time INTEGER');
      _log.i('Added file_mod_time column for incremental scanning');
    }

    if (oldVersion < 4) {
      await db.execute('ALTER TABLE library ADD COLUMN bitrate INTEGER');
      _log.i('Added bitrate column for lossy format quality');
    }

    if (oldVersion < 5) {
      await db.execute('ALTER TABLE library ADD COLUMN label TEXT');
      await db.execute('ALTER TABLE library ADD COLUMN copyright TEXT');
      _log.i('Added label/copyright columns');
    }

    if (oldVersion < 6) {
      await db.execute('ALTER TABLE library ADD COLUMN total_tracks INTEGER');
      await db.execute('ALTER TABLE library ADD COLUMN total_discs INTEGER');
      await db.execute('ALTER TABLE library ADD COLUMN composer TEXT');
      _log.i('Added total_tracks/total_discs/composer columns');
    }

    if (oldVersion < 7) {
      await sqlite.addColumnIfMissing(db, 'library', 'track_name_norm', 'TEXT');
      await sqlite.addColumnIfMissing(
        db,
        'library',
        'artist_name_norm',
        'TEXT',
      );
      await sqlite.addColumnIfMissing(db, 'library', 'album_name_norm', 'TEXT');
      await sqlite.addColumnIfMissing(
        db,
        'library',
        'album_artist_norm',
        'TEXT',
      );
      await sqlite.addColumnIfMissing(db, 'library', 'match_key', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'library', 'album_key', 'TEXT');
      await _backfillNormalizedColumns(db);
      await _createNormalizedIndexes(db);
      _log.i('Added normalized local library lookup columns');
    }
    if (oldVersion < 8) {
      await _createPathKeyTable(db);
      await sqlite.backfillPathKeys(db, 'library', 'library_path_keys');
      _log.i('Added local library path-key lookup table');
    }
    if (oldVersion < 9) {
      await sqlite.addColumnIfMissing(
        db,
        'library',
        'audio_metadata_scan_version',
        'INTEGER NOT NULL DEFAULT 0',
      );
      _log.i('Marked existing rows for one-time audio metadata rescan');
    }
    if (oldVersion < 10) {
      await sqlite.addColumnIfMissing(db, 'library', 'search_text', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'library', 'sort_genre', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'library', 'sort_release', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'library', 'sort_added', 'INTEGER');
      await _backfillQueueColumns(db);
      await _createQueueIndexes(db);
      _log.i('Added persisted queue sort/search columns');
    }
    if (oldVersion < 11) {
      await sqlite.addColumnIfMissing(
        db,
        'library',
        'source_id',
        "TEXT NOT NULL DEFAULT '$legacySourceId'",
      );
      await _createLibrarySources(db);
      _log.i('Added multiple local library sources');
    }
    if (oldVersion < 12) {
      await sqlite.addColumnIfMissing(
        db,
        'library',
        'explicit',
        'INTEGER NOT NULL DEFAULT 0',
      );
      _log.i('Added explicit-content metadata');
    }
    if (oldVersion < 13) {
      await sqlite.addColumnIfMissing(
        db,
        'library',
        'has_lyrics',
        'INTEGER NOT NULL DEFAULT 0',
      );
      _log.i('Added indexed lyrics availability metadata');
    }
    if (oldVersion < 14) {
      await _createLookupSummary(db);
      _log.i('Added incremental Library lookup summary');
    }
    if (oldVersion < 15) {
      // Rows keep their older audio_metadata_scan_version, so the next
      // incremental scan re-reads them once and fills the real value.
      await sqlite.addColumnIfMissing(
        db,
        'library',
        'has_replaygain',
        'INTEGER NOT NULL DEFAULT 0',
      );
      _log.i('Added indexed ReplayGain availability metadata');
    }
  }

  Future<void> _createLookupSummary(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $lookupSummaryTable (
        source_id TEXT NOT NULL,
        kind TEXT NOT NULL,
        value TEXT NOT NULL,
        ref_count INTEGER NOT NULL,
        PRIMARY KEY (source_id, kind, value)
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_lookup_summary_value '
      'ON $lookupSummaryTable(kind, value)',
    );

    for (final name in const [
      'library_lookup_insert_isrc',
      'library_lookup_delete_isrc',
      'library_lookup_update_isrc',
      'library_lookup_insert_match',
      'library_lookup_delete_match',
      'library_lookup_update_match',
    ]) {
      await db.execute('DROP TRIGGER IF EXISTS $name');
    }

    await db.execute('''
      CREATE TRIGGER library_lookup_insert_isrc AFTER INSERT ON library
      WHEN NEW.isrc IS NOT NULL AND NEW.isrc != ''
      BEGIN
        INSERT OR IGNORE INTO $lookupSummaryTable(source_id, kind, value, ref_count)
        VALUES (NEW.source_id, 'isrc', NEW.isrc, 0);
        UPDATE $lookupSummaryTable SET ref_count = ref_count + 1
        WHERE source_id = NEW.source_id AND kind = 'isrc' AND value = NEW.isrc;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER library_lookup_delete_isrc AFTER DELETE ON library
      WHEN OLD.isrc IS NOT NULL AND OLD.isrc != ''
      BEGIN
        UPDATE $lookupSummaryTable SET ref_count = ref_count - 1
        WHERE source_id = OLD.source_id AND kind = 'isrc' AND value = OLD.isrc;
        DELETE FROM $lookupSummaryTable
        WHERE source_id = OLD.source_id AND kind = 'isrc' AND value = OLD.isrc
          AND ref_count <= 0;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER library_lookup_update_isrc AFTER UPDATE OF source_id, isrc ON library
      WHEN OLD.source_id IS NOT NEW.source_id OR OLD.isrc IS NOT NEW.isrc
      BEGIN
        UPDATE $lookupSummaryTable SET ref_count = ref_count - 1
        WHERE OLD.isrc IS NOT NULL AND OLD.isrc != ''
          AND source_id = OLD.source_id AND kind = 'isrc' AND value = OLD.isrc;
        DELETE FROM $lookupSummaryTable
        WHERE source_id = OLD.source_id AND kind = 'isrc' AND value = OLD.isrc
          AND ref_count <= 0;
        INSERT OR IGNORE INTO $lookupSummaryTable(source_id, kind, value, ref_count)
        SELECT NEW.source_id, 'isrc', NEW.isrc, 0
        WHERE NEW.isrc IS NOT NULL AND NEW.isrc != '';
        UPDATE $lookupSummaryTable SET ref_count = ref_count + 1
        WHERE NEW.isrc IS NOT NULL AND NEW.isrc != ''
          AND source_id = NEW.source_id AND kind = 'isrc' AND value = NEW.isrc;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER library_lookup_insert_match AFTER INSERT ON library
      WHEN NEW.match_key IS NOT NULL AND NEW.match_key != ''
      BEGIN
        INSERT OR IGNORE INTO $lookupSummaryTable(source_id, kind, value, ref_count)
        VALUES (NEW.source_id, 'match', NEW.match_key, 0);
        UPDATE $lookupSummaryTable SET ref_count = ref_count + 1
        WHERE source_id = NEW.source_id AND kind = 'match' AND value = NEW.match_key;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER library_lookup_delete_match AFTER DELETE ON library
      WHEN OLD.match_key IS NOT NULL AND OLD.match_key != ''
      BEGIN
        UPDATE $lookupSummaryTable SET ref_count = ref_count - 1
        WHERE source_id = OLD.source_id AND kind = 'match' AND value = OLD.match_key;
        DELETE FROM $lookupSummaryTable
        WHERE source_id = OLD.source_id AND kind = 'match' AND value = OLD.match_key
          AND ref_count <= 0;
      END
    ''');
    await db.execute('''
      CREATE TRIGGER library_lookup_update_match AFTER UPDATE OF source_id, match_key ON library
      WHEN OLD.source_id IS NOT NEW.source_id OR OLD.match_key IS NOT NEW.match_key
      BEGIN
        UPDATE $lookupSummaryTable SET ref_count = ref_count - 1
        WHERE OLD.match_key IS NOT NULL AND OLD.match_key != ''
          AND source_id = OLD.source_id AND kind = 'match' AND value = OLD.match_key;
        DELETE FROM $lookupSummaryTable
        WHERE source_id = OLD.source_id AND kind = 'match' AND value = OLD.match_key
          AND ref_count <= 0;
        INSERT OR IGNORE INTO $lookupSummaryTable(source_id, kind, value, ref_count)
        SELECT NEW.source_id, 'match', NEW.match_key, 0
        WHERE NEW.match_key IS NOT NULL AND NEW.match_key != '';
        UPDATE $lookupSummaryTable SET ref_count = ref_count + 1
        WHERE NEW.match_key IS NOT NULL AND NEW.match_key != ''
          AND source_id = NEW.source_id AND kind = 'match' AND value = NEW.match_key;
      END
    ''');

    await db.delete(lookupSummaryTable);
    await db.rawInsert('''
      INSERT INTO $lookupSummaryTable(source_id, kind, value, ref_count)
      SELECT source_id, 'isrc', isrc, COUNT(*)
      FROM library WHERE isrc IS NOT NULL AND isrc != ''
      GROUP BY source_id, isrc
    ''');
    await db.rawInsert('''
      INSERT INTO $lookupSummaryTable(source_id, kind, value, ref_count)
      SELECT source_id, 'match', match_key, COUNT(*)
      FROM library WHERE match_key IS NOT NULL AND match_key != ''
      GROUP BY source_id, match_key
    ''');
  }

  Future<bool> _createSearchFts(DatabaseExecutor db) {
    return sqlite.createTrigramFtsIndex(
      db,
      ftsTable: searchFtsTable,
      contentTable: 'library',
      triggerPrefix: 'library_search_fts',
    );
  }

  Future<void> _createLibrarySources(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS library_sources (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        bookmark TEXT,
        volume_id TEXT,
        is_removable INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1,
        available INTEGER NOT NULL DEFAULT 1,
        last_scanned_at TEXT,
        last_seen_at TEXT,
        last_scan_error TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_source_id ON library(source_id)',
    );
    await db.insert('library_sources', {
      'id': legacySourceId,
      'path': 'legacy://local-library',
      'display_name': 'Music',
      'enabled': 1,
      'available': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.execute('DROP VIEW IF EXISTS $visibleLibraryView');
    await db.execute('''
      CREATE VIEW $visibleLibraryView AS
      SELECT l.*
      FROM library l
      JOIN library_sources s ON s.id = l.source_id
      WHERE s.enabled = 1 AND s.available = 1
    ''');
  }

  Future<void> _createPathKeyTable(DatabaseExecutor db) =>
      sqlite.createPathKeyTable(db, 'library_path_keys');

  void _putPathKeysInBatch(Batch batch, String id, String? filePath) =>
      sqlite.putPathKeysInBatch(batch, 'library_path_keys', id, filePath);

  static String normalizeLookupText(String? value) =>
      sqlite.normalizeLookupText(value);

  static String matchKeyFor(String trackName, String artistName) {
    return '${normalizeLookupText(trackName)}|${normalizeLookupText(artistName)}';
  }

  static String albumKeyFor(
    String albumName,
    String? albumArtist,
    String artistName,
  ) {
    return '${normalizeLookupText(albumName)}|${normalizeLookupText(albumArtist ?? artistName)}';
  }

  Future<void> _createNormalizedIndexes(DatabaseExecutor db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_match_key ON library(match_key)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_album_key ON library(album_key)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_track_norm ON library(track_name_norm)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_artist_norm ON library(artist_name_norm)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_album_norm ON library(album_name_norm)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_scanned_at ON library(scanned_at)',
    );
  }

  Future<void> _createQueueIndexes(DatabaseExecutor db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_queue_added '
      'ON library(sort_added DESC, track_name_norm, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_queue_track '
      'ON library(track_name_norm, artist_name_norm, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_queue_artist '
      'ON library(artist_name_norm, track_name_norm, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_queue_album '
      'ON library(album_name_norm, track_name_norm, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_queue_genre '
      'ON library(sort_genre, track_name_norm, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_queue_release '
      'ON library(sort_release, track_name_norm, id)',
    );
  }

  Future<void> _backfillNormalizedColumns(Database db) async {
    final rows = await db.query(
      'library',
      columns: [
        'id',
        'track_name',
        'artist_name',
        'album_name',
        'album_artist',
      ],
    );
    final batch = db.batch();
    for (final row in rows) {
      final trackName = row['track_name'] as String? ?? '';
      final artistName = row['artist_name'] as String? ?? '';
      final albumName = row['album_name'] as String? ?? '';
      final albumArtist = row['album_artist'] as String?;
      batch.update(
        'library',
        _normalizedColumns(
          trackName: trackName,
          artistName: artistName,
          albumName: albumName,
          albumArtist: albumArtist,
        ),
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  Map<String, dynamic> _normalizedColumns({
    required String trackName,
    required String artistName,
    required String albumName,
    required String? albumArtist,
  }) {
    final trackNorm = normalizeLookupText(trackName);
    final artistNorm = normalizeLookupText(artistName);
    final albumNorm = normalizeLookupText(albumName);
    final albumArtistNorm = normalizeLookupText(albumArtist ?? artistName);
    return {
      'track_name_norm': trackNorm,
      'artist_name_norm': artistNorm,
      'album_name_norm': albumNorm,
      'album_artist_norm': albumArtistNorm,
      'match_key': '$trackNorm|$artistNorm',
      'album_key': '$albumNorm|$albumArtistNorm',
    };
  }

  Map<String, dynamic> _queueColumns({
    required String? trackName,
    required String? artistName,
    required String? albumName,
    required String? albumArtist,
    required String? genre,
    required String? releaseDate,
    required int? fileModTime,
    required String? scannedAt,
  }) {
    final trackNorm = normalizeLookupText(trackName);
    final artistNorm = normalizeLookupText(artistName);
    final albumNorm = normalizeLookupText(albumName);
    final albumArtistNorm = normalizeLookupText(
      (albumArtist ?? '').trim().isEmpty ? artistName : albumArtist,
    );
    return {
      'search_text': [
        trackNorm,
        artistNorm,
        albumNorm,
        albumArtistNorm,
      ].where((value) => value.isNotEmpty).join(' '),
      'sort_genre': normalizeLookupText(genre),
      'sort_release': releaseDate?.trim() ?? '',
      'sort_added':
          fileModTime ??
          DateTime.tryParse(scannedAt ?? '')?.millisecondsSinceEpoch ??
          0,
    };
  }

  Future<void> _backfillQueueColumns(Database db) async {
    final rows = await db.query(
      'library',
      columns: [
        'id',
        'track_name',
        'artist_name',
        'album_name',
        'album_artist',
        'genre',
        'release_date',
        'file_mod_time',
        'scanned_at',
      ],
    );
    final batch = db.batch();
    for (final row in rows) {
      batch.update(
        'library',
        _queueColumns(
          trackName: row['track_name'] as String?,
          artistName: row['artist_name'] as String?,
          albumName: row['album_name'] as String?,
          albumArtist: row['album_artist'] as String?,
          genre: row['genre'] as String?,
          releaseDate: row['release_date'] as String?,
          fileModTime: (row['file_mod_time'] as num?)?.toInt(),
          scannedAt: row['scanned_at'] as String?,
        ),
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  Map<String, dynamic> _jsonToDbRow(
    Map<String, dynamic> json, {
    String? sourceId,
  }) {
    final fileModTime = (json['fileModTime'] as num?)?.toInt();
    final scannedAt = json['scannedAt'] as String?;
    final row = {
      'id': json['id'],
      'source_id': sourceId ?? json['sourceId'] ?? legacySourceId,
      'track_name': json['trackName'],
      'artist_name': json['artistName'],
      'album_name': json['albumName'],
      'album_artist': json['albumArtist'],
      'file_path': json['filePath'],
      'cover_path': json['coverPath'],
      'scanned_at': json['scannedAt'],
      'file_mod_time': json['fileModTime'],
      'isrc': json['isrc'],
      'track_number': json['trackNumber'],
      'total_tracks': json['totalTracks'],
      'disc_number': json['discNumber'],
      'total_discs': json['totalDiscs'],
      'duration': json['duration'],
      'release_date': json['releaseDate'],
      'bit_depth': json['bitDepth'],
      'sample_rate': json['sampleRate'],
      'bitrate': json['bitrate'],
      'genre': json['genre'],
      'composer': json['composer'],
      'label': json['label'],
      'copyright': json['copyright'],
      'explicit': json['explicit'] == true || json['explicit'] == 1 ? 1 : 0,
      'has_lyrics': json['hasLyrics'] == true || json['hasLyrics'] == 1 ? 1 : 0,
      'has_replaygain': metadataHasReplayGain(json) ? 1 : 0,
      'format': json['format'],
      'audio_metadata_scan_version':
          (json['audioMetadataScanVersion'] as num?)?.toInt() ??
          (json['metadataFromFilename'] == true ? 0 : audioMetadataScanVersion),
    };
    row.addAll(
      _queueColumns(
        trackName: json['trackName'] as String?,
        artistName: json['artistName'] as String?,
        albumName: json['albumName'] as String?,
        albumArtist: json['albumArtist'] as String?,
        genre: json['genre'] as String?,
        releaseDate: json['releaseDate'] as String?,
        fileModTime: fileModTime,
        scannedAt: scannedAt,
      ),
    );
    row.addAll(
      _normalizedColumns(
        trackName: json['trackName'] as String? ?? '',
        artistName: json['artistName'] as String? ?? '',
        albumName: json['albumName'] as String? ?? '',
        albumArtist: json['albumArtist'] as String?,
      ),
    );
    return row;
  }

  Map<String, dynamic> _dbRowToJson(Map<String, dynamic> row) {
    return {
      'id': row['id'],
      'sourceId': row['source_id'] ?? legacySourceId,
      'trackName': row['track_name'],
      'artistName': row['artist_name'],
      'albumName': row['album_name'],
      'albumArtist': row['album_artist'],
      'filePath': row['file_path'],
      'coverPath': row['cover_path'],
      'scannedAt': row['scanned_at'],
      'fileModTime': row['file_mod_time'],
      'isrc': row['isrc'],
      'trackNumber': row['track_number'],
      'totalTracks': row['total_tracks'],
      'discNumber': row['disc_number'],
      'totalDiscs': row['total_discs'],
      'duration': row['duration'],
      'releaseDate': row['release_date'],
      'bitDepth': row['bit_depth'],
      'sampleRate': row['sample_rate'],
      'bitrate': row['bitrate'],
      'genre': row['genre'],
      'composer': row['composer'],
      'label': row['label'],
      'copyright': row['copyright'],
      'explicit': row['explicit'] == 1 || row['explicit'] == true,
      'hasLyrics': row['has_lyrics'] == 1 || row['has_lyrics'] == true,
      'hasReplayGain':
          row['has_replaygain'] == 1 || row['has_replaygain'] == true,
      'format': row['format'],
    };
  }

  Future<void> upsert(Map<String, dynamic> json, {String? sourceId}) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'library',
        _jsonToDbRow(json, sourceId: sourceId),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final batch = txn.batch();
      _putPathKeysInBatch(
        batch,
        json['id'] as String,
        json['filePath'] as String?,
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> upsertBatch(
    List<Map<String, dynamic>> items, {
    String? sourceId,
  }) async {
    if (items.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final json in items) {
        batch.insert(
          'library',
          _jsonToDbRow(json, sourceId: sourceId),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        _putPathKeysInBatch(
          batch,
          json['id'] as String,
          json['filePath'] as String?,
        );
      }
      await batch.commit(noResult: true);
    });
    _log.i('Batch inserted ${items.length} items');
  }

  /// Removes rows from one source whose normalized path keys already exist in
  /// download History, without materializing either database's paths in Dart.
  Future<int> deleteDownloadedRowsForSource(String sourceId) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    const downloadedMatch = '''
      EXISTS (
        SELECT 1
        FROM library_path_keys lk
        JOIN history_db.history_path_keys hk ON hk.path_key = lk.path_key
        WHERE lk.item_id = library.id
      )
    ''';
    await db.execute('DROP TABLE IF EXISTS $_downloadedLibraryIdsStageTable');
    await db.execute(
      'CREATE TEMP TABLE $_downloadedLibraryIdsStageTable '
      '(id TEXT PRIMARY KEY)',
    );
    try {
      await db.rawInsert(
        'INSERT INTO $_downloadedLibraryIdsStageTable(id) '
        'SELECT id FROM library '
        'WHERE source_id = ? AND $downloadedMatch',
        [sourceId],
      );
      final countRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $_downloadedLibraryIdsStageTable',
      );
      final count = Sqflite.firstIntValue(countRows) ?? 0;
      if (count == 0) return 0;

      await db.transaction((txn) async {
        await txn.rawDelete(
          'DELETE FROM library_path_keys WHERE item_id IN '
          '(SELECT id FROM $_downloadedLibraryIdsStageTable)',
        );
        await txn.rawDelete(
          'DELETE FROM library WHERE id IN '
          '(SELECT id FROM $_downloadedLibraryIdsStageTable)',
        );
      });
      return count;
    } finally {
      await db.execute('DROP TABLE IF EXISTS $_downloadedLibraryIdsStageTable');
    }
  }

  /// Upserts incremental scan rows after filtering them through the attached
  /// History path-key index. This keeps the hot incremental path independent
  /// of total History size.
  Future<({int upserted, int skipped})> upsertBatchExcludingHistory(
    List<Map<String, dynamic>> items, {
    required String sourceId,
  }) async {
    if (items.isEmpty) return (upserted: 0, skipped: 0);
    final db = await database;
    await _ensureHistoryAttached(db);
    await db.execute('DROP TABLE IF EXISTS $_incrementalStageTable');
    await db.execute('DROP TABLE IF EXISTS $_incrementalStagePathKeysTable');
    await db.execute(
      'CREATE TEMP TABLE $_incrementalStageTable '
      'AS SELECT * FROM library WHERE 0',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_${_incrementalStageTable}_id '
      'ON $_incrementalStageTable(id)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_${_incrementalStageTable}_path '
      'ON $_incrementalStageTable(file_path)',
    );
    await db.execute('''
      CREATE TEMP TABLE $_incrementalStagePathKeysTable (
        item_id TEXT NOT NULL,
        path_key TEXT NOT NULL,
        PRIMARY KEY (item_id, path_key)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_${_incrementalStagePathKeysTable}_key '
      'ON $_incrementalStagePathKeysTable(path_key)',
    );

    try {
      final batch = db.batch();
      final stagedIds = <String>{};
      for (final json in items) {
        final id = json['id'] as String?;
        if (id == null || id.trim().isEmpty) {
          throw const FormatException('Library scan row has no valid id');
        }
        batch.insert(
          _incrementalStageTable,
          _jsonToDbRow(json, sourceId: sourceId),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        sqlite.putPathKeysInBatch(
          batch,
          _incrementalStagePathKeysTable,
          id,
          json['filePath'] as String?,
          // The stage starts empty: only a repeated id has keys to replace.
          replaceExisting: !stagedIds.add(id),
        );
      }
      await batch.commit(noResult: true);

      const historyMatch =
          '''
        EXISTS (
          SELECT 1
          FROM $_incrementalStagePathKeysTable sk
          JOIN history_db.history_path_keys hk ON hk.path_key = sk.path_key
          WHERE sk.item_id = s.id
        )
      ''';
      final skippedRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $_incrementalStageTable s '
        'WHERE $historyMatch',
      );
      final skipped = Sqflite.firstIntValue(skippedRows) ?? 0;
      final stagedRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $_incrementalStageTable',
      );
      final staged = Sqflite.firstIntValue(stagedRows) ?? 0;
      final columns = (await db.rawQuery(
        'PRAGMA table_info(library)',
      )).map((row) => row['name'] as String).toList(growable: false);
      final columnList = columns.join(', ');
      final selectedColumns = columns.map((column) => 's.$column').join(', ');

      await db.transaction((txn) async {
        await txn.rawDelete('''
          DELETE FROM library_path_keys
          WHERE item_id IN (
            SELECT s.id FROM $_incrementalStageTable s WHERE NOT $historyMatch
          )
        ''');
        await txn.rawInsert('''
          INSERT OR REPLACE INTO library ($columnList)
          SELECT $selectedColumns FROM $_incrementalStageTable s
          WHERE NOT $historyMatch
        ''');
        await txn.rawInsert('''
          INSERT OR IGNORE INTO library_path_keys(item_id, path_key)
          SELECT sk.item_id, sk.path_key
          FROM $_incrementalStagePathKeysTable sk
          JOIN $_incrementalStageTable s ON s.id = sk.item_id
          WHERE NOT $historyMatch
        ''');
      });
      return (upserted: staged - skipped, skipped: skipped);
    } finally {
      await db.execute('DROP TABLE IF EXISTS $_incrementalStagePathKeysTable');
      await db.execute('DROP TABLE IF EXISTS $_incrementalStageTable');
    }
  }

  Future<void> replaceAll(List<Map<String, dynamic>> items) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('library_path_keys');
      await txn.delete('library');
      if (items.isEmpty) {
        return;
      }

      final batch = txn.batch();
      for (final json in items) {
        batch.insert(
          'library',
          _jsonToDbRow(json),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        _putPathKeysInBatch(
          batch,
          json['id'] as String,
          json['filePath'] as String?,
        );
      }
      await batch.commit(noResult: true);
    });
    _log.i('Replaced library with ${items.length} items');
  }

  /// Stages scan rows in bounded, independently committed batches, then swaps
  /// only this source in one short transaction. Download-history exclusion is
  /// an indexed SQLite anti-join, avoiding a full History path set in Dart.
  Future<({int inserted, int skipped})> replaceSourceStream(
    String sourceId,
    Stream<Map<String, dynamic>> items, {
    int batchSize = 300,
    bool preserveMissing = false,
  }) async {
    if (batchSize <= 0) {
      throw ArgumentError.value(batchSize, 'batchSize', 'Must be positive');
    }
    final db = await database;
    await _ensureHistoryAttached(db);
    await db.execute('DROP TABLE IF EXISTS $_scanStageTable');
    await db.execute('DROP TABLE IF EXISTS $_scanStagePathKeysTable');
    await db.execute(
      'CREATE TEMP TABLE $_scanStageTable AS SELECT * FROM library WHERE 0',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_${_scanStageTable}_id '
      'ON $_scanStageTable(id)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX idx_${_scanStageTable}_path '
      'ON $_scanStageTable(file_path)',
    );
    await db.execute('''
      CREATE TEMP TABLE $_scanStagePathKeysTable (
        item_id TEXT NOT NULL,
        path_key TEXT NOT NULL,
        PRIMARY KEY (item_id, path_key)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_${_scanStagePathKeysTable}_key '
      'ON $_scanStagePathKeysTable(path_key)',
    );

    var streamed = 0;
    try {
      var batch = db.batch();
      var pending = 0;
      Future<void> flush() async {
        if (pending == 0) return;
        await batch.commit(noResult: true);
        batch = db.batch();
        pending = 0;
      }

      final stagedIds = <String>{};
      await for (final json in items) {
        final id = json['id'] as String?;
        if (id == null || id.trim().isEmpty) {
          throw const FormatException('Library scan row has no valid id');
        }
        batch.insert(
          _scanStageTable,
          _jsonToDbRow(json, sourceId: sourceId),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        sqlite.putPathKeysInBatch(
          batch,
          _scanStagePathKeysTable,
          id,
          json['filePath'] as String?,
          // The stage starts empty: only a repeated id has keys to replace.
          replaceExisting: !stagedIds.add(id),
        );
        streamed++;
        pending++;
        if (pending >= batchSize) await flush();
      }
      await flush();

      const historyMatch =
          '''
        EXISTS (
          SELECT 1
          FROM $_scanStagePathKeysTable sk
          JOIN history_db.history_path_keys hk ON hk.path_key = sk.path_key
          WHERE sk.item_id = s.id
        )
      ''';
      final skippedRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $_scanStageTable s '
        'WHERE $historyMatch',
      );
      final skipped = Sqflite.firstIntValue(skippedRows) ?? 0;
      final stagedRows = await db.rawQuery(
        'SELECT COUNT(*) AS count FROM $_scanStageTable',
      );
      final staged = Sqflite.firstIntValue(stagedRows) ?? 0;
      final columns = (await db.rawQuery(
        'PRAGMA table_info(library)',
      )).map((row) => row['name'] as String).toList(growable: false);
      final columnList = columns.join(', ');
      final selectedColumns = columns.map((column) => 's.$column').join(', ');

      await db.transaction((txn) async {
        await deleteReplacedLibraryScanRows(
          txn,
          sourceId,
          stageTable: _scanStageTable,
          preserveMissing: preserveMissing,
        );
        await txn.rawDelete('''
          DELETE FROM library_path_keys
          WHERE item_id IN (
            SELECT s.id FROM $_scanStageTable s WHERE NOT $historyMatch
          )
        ''');
        await txn.rawInsert('''
          INSERT OR REPLACE INTO library ($columnList)
          SELECT $selectedColumns FROM $_scanStageTable s
          WHERE NOT $historyMatch
        ''');
        await txn.rawInsert('''
          INSERT OR IGNORE INTO library_path_keys(item_id, path_key)
          SELECT sk.item_id, sk.path_key
          FROM $_scanStagePathKeysTable sk
          JOIN $_scanStageTable s ON s.id = sk.item_id
          WHERE NOT $historyMatch
        ''');
      });
      final inserted = staged - skipped;
      _log.i(
        'Streamed $streamed rows, staged $staged unique rows, and swapped '
        '$inserted into Library source '
        '$sourceId ($skipped downloads excluded)',
      );
      return (inserted: inserted, skipped: skipped);
    } finally {
      await db.execute('DROP TABLE IF EXISTS $_scanStagePathKeysTable');
      await db.execute('DROP TABLE IF EXISTS $_scanStageTable');
    }
  }

  Future<List<LocalLibrarySource>> getSources() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.*, COUNT(l.id) AS track_count
      FROM library_sources s
      LEFT JOIN library l ON l.source_id = s.id
      GROUP BY s.id
      HAVING s.path != 'legacy://local-library' OR COUNT(l.id) > 0
      ORDER BY s.is_removable, LOWER(s.display_name), LOWER(s.path)
    ''');
    return rows.map(_sourceFromRow).toList(growable: false);
  }

  Future<LocalLibrarySource?> getSourceByPath(String path) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT s.*, COUNT(l.id) AS track_count
      FROM library_sources s
      LEFT JOIN library l ON l.source_id = s.id
      WHERE s.path = ?
      GROUP BY s.id
      LIMIT 1
      ''',
      [path],
    );
    return rows.isEmpty ? null : _sourceFromRow(rows.first);
  }

  LocalLibrarySource _sourceFromRow(Map<String, Object?> row) {
    DateTime? parseDate(Object? value) =>
        value is String ? DateTime.tryParse(value) : null;
    return LocalLibrarySource(
      id: row['id'] as String,
      path: row['path'] as String,
      displayName: row['display_name'] as String,
      bookmark: row['bookmark'] as String?,
      volumeId: row['volume_id'] as String?,
      isRemovable: (row['is_removable'] as num?)?.toInt() == 1,
      enabled: (row['enabled'] as num?)?.toInt() != 0,
      available: (row['available'] as num?)?.toInt() != 0,
      trackCount: (row['track_count'] as num?)?.toInt() ?? 0,
      lastScannedAt: parseDate(row['last_scanned_at']),
      lastSeenAt: parseDate(row['last_seen_at']),
      lastScanError: row['last_scan_error'] as String?,
    );
  }

  Future<void> upsertSource(LocalLibrarySource source) async {
    final db = await database;
    final values = <String, Object?>{
      'path': source.path,
      'display_name': source.displayName,
      'bookmark': source.bookmark,
      'volume_id': source.volumeId,
      'is_removable': source.isRemovable ? 1 : 0,
      'enabled': source.enabled ? 1 : 0,
      'available': source.available ? 1 : 0,
      'last_scanned_at': source.lastScannedAt?.toIso8601String(),
      'last_seen_at': source.lastSeenAt?.toIso8601String(),
      'last_scan_error': source.lastScanError,
    };
    final updated = await db.update(
      'library_sources',
      values,
      where: 'id = ?',
      whereArgs: [source.id],
    );
    if (updated == 0) {
      await db.insert('library_sources', {'id': source.id, ...values});
    }
  }

  Future<void> updateSourceState(
    String sourceId, {
    bool? enabled,
    bool? available,
    DateTime? lastScannedAt,
    DateTime? lastSeenAt,
    String? lastScanError,
    bool clearLastScanError = false,
  }) async {
    final values = <String, Object?>{};
    if (enabled != null) values['enabled'] = enabled ? 1 : 0;
    if (available != null) values['available'] = available ? 1 : 0;
    if (lastScannedAt != null) {
      values['last_scanned_at'] = lastScannedAt.toIso8601String();
    }
    if (lastSeenAt != null) {
      values['last_seen_at'] = lastSeenAt.toIso8601String();
    }
    if (lastScanError != null || clearLastScanError) {
      values['last_scan_error'] = clearLastScanError ? null : lastScanError;
    }
    if (values.isEmpty) return;
    final db = await database;
    await db.update(
      'library_sources',
      values,
      where: 'id = ?',
      whereArgs: [sourceId],
    );
  }

  Future<void> migrateLegacySource({
    required String path,
    required String displayName,
    String? bookmark,
    String? volumeId,
    bool isRemovable = false,
    bool available = true,
    DateTime? lastScannedAt,
  }) async {
    if (path.trim().isEmpty) return;
    final db = await database;
    await db.update(
      'library_sources',
      {
        'path': path,
        'display_name': displayName,
        'bookmark': bookmark,
        'volume_id': volumeId,
        'is_removable': isRemovable ? 1 : 0,
        'available': available ? 1 : 0,
        'last_scanned_at': lastScannedAt?.toIso8601String(),
        'last_seen_at': available ? DateTime.now().toIso8601String() : null,
      },
      where: 'id = ?',
      whereArgs: [legacySourceId],
    );
  }

  Future<void> removeSource(String sourceId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.rawDelete(
        'DELETE FROM library_path_keys WHERE item_id IN '
        '(SELECT id FROM library WHERE source_id = ?)',
        [sourceId],
      );
      await txn.delete(
        'library',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      if (sourceId == legacySourceId) {
        await txn.update(
          'library_sources',
          {
            'path': 'legacy://local-library',
            'display_name': 'Music',
            'bookmark': null,
            'volume_id': null,
            'is_removable': 0,
            'enabled': 1,
            'available': 1,
            'last_scanned_at': null,
            'last_seen_at': null,
            'last_scan_error': null,
          },
          where: 'id = ?',
          whereArgs: [sourceId],
        );
      } else {
        await txn.delete(
          'library_sources',
          where: 'id = ?',
          whereArgs: [sourceId],
        );
      }
    });
  }

  Future<List<Map<String, dynamic>>> getAll({int? limit, int? offset}) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      orderBy: 'album_artist, album_name, disc_number, track_number',
      limit: limit,
      offset: offset,
    );
    return rows.map(_dbRowToJson).toList();
  }

  String _escapeLikePattern(String value) {
    return value
        .replaceAll('\\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
  }

  String _orderByForSort(LocalLibrarySortMode sortMode) {
    return switch (sortMode) {
      LocalLibrarySortMode.title =>
        'track_name_norm, artist_name_norm, album_name_norm, disc_number, track_number',
      LocalLibrarySortMode.artist =>
        'artist_name_norm, album_name_norm, disc_number, track_number, track_name_norm',
      LocalLibrarySortMode.latest =>
        'scanned_at DESC, album_artist_norm, album_name_norm, disc_number, track_number',
      LocalLibrarySortMode.quality =>
        'COALESCE(bit_depth, 0) DESC, COALESCE(sample_rate, 0) DESC, COALESCE(bitrate, 0) DESC, album_artist_norm, album_name_norm, disc_number, track_number',
      LocalLibrarySortMode.album =>
        'album_artist_norm, album_name_norm, COALESCE(disc_number, 0), COALESCE(track_number, 0), track_name_norm',
    };
  }

  Future<List<Map<String, dynamic>>> getQueueTrackPage(
    QueueLibraryDbQuery request,
  ) async {
    return (await getQueueTrackPageResult(request)).rows;
  }

  Future<QueueLibraryDbPage> getQueueTrackPageResult(
    QueueLibraryDbQuery request,
  ) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    final args = <Object?>[];
    final orderTerms = _queueTrackOrderTerms(request.sortMode);
    final usesCursor =
        request.cursor != null &&
        request.cursor!.values.length == orderTerms.length;
    final unionSql = _queueTrackUnionSql(
      request,
      args,
      orderTerms: orderTerms,
      usesCursor: usesCursor,
    );
    final rows = await db.rawQuery(
      '''
      SELECT *
      FROM ($unionSql)
      ORDER BY ${_queueTrackOrderBy(request.sortMode)}
      LIMIT ? ${usesCursor ? '' : 'OFFSET ?'}
      ''',
      [...args, request.limit, if (!usesCursor) request.offset],
    );
    return QueueLibraryDbPage(
      rows: rows.map(_queueTrackRowToJson).toList(growable: false),
      nextCursor: _queueCursorFromRow(rows.lastOrNull, orderTerms),
    );
  }

  Future<QueueLibraryCounts> getQueueCounts(QueueLibraryDbQuery request) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    final fastCounts = await _getUnfilteredQueueCounts(db, request);
    if (fastCounts != null) return fastCounts;
    final parts = <String>[];
    final args = <Object?>[];

    if (request.source != 'local') {
      final where = <String>[];
      _appendQueueHistoryFilters(where, args, request);
      parts.add('''
        SELECT
          COUNT(*) AS all_count,
          COUNT(DISTINCT CASE WHEN grouped.track_count > ${isAlbumCompletenessFilter(request.metadata) ? 0 : 1} THEN h.album_key END) AS album_count,
          COALESCE(SUM(CASE WHEN grouped.track_count = 1 THEN 1 ELSE 0 END), 0) AS single_count
        FROM history_db.history h
        JOIN (
          SELECT album_key, COUNT(*) AS track_count
          FROM history_db.history
          GROUP BY album_key
        ) grouped ON grouped.album_key = h.album_key
        ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ''');
    }

    if (request.includeLocal && request.source != 'downloaded') {
      final where = <String>[
        '''
        NOT EXISTS (
          SELECT 1
          FROM library_path_keys lpk
          JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
          WHERE lpk.item_id = l.id
        )
        ''',
      ];
      _appendQueueLocalFilters(where, args, request);
      parts.add('''
        SELECT
          COUNT(*) AS all_count,
          COUNT(DISTINCT CASE WHEN grouped.track_count > ${isAlbumCompletenessFilter(request.metadata) ? 0 : 1} THEN l.album_key END) AS album_count,
          COALESCE(SUM(CASE WHEN grouped.track_count = 1 THEN 1 ELSE 0 END), 0) AS single_count
        FROM $visibleLibraryView l
        JOIN (
          SELECT album_key, COUNT(*) AS track_count
          FROM $visibleLibraryView candidate
          WHERE NOT EXISTS (
            SELECT 1
            FROM library_path_keys lpk
            JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
            WHERE lpk.item_id = candidate.id
          )
          GROUP BY album_key
        ) grouped ON grouped.album_key = l.album_key
        WHERE ${where.join(' AND ')}
      ''');
    }

    if (parts.isEmpty) {
      return const QueueLibraryCounts(
        allTrackCount: 0,
        albumCount: 0,
        singleTrackCount: 0,
      );
    }

    final rows = await db.rawQuery('''
      SELECT
        COALESCE(SUM(all_count), 0) AS all_count,
        COALESCE(SUM(single_count), 0) AS single_count,
        COALESCE(SUM(album_count), 0) AS album_count
      FROM (${parts.join(' UNION ALL ')})
      ''', args);
    final row = rows.isNotEmpty ? rows.first : const <String, Object?>{};

    return QueueLibraryCounts(
      allTrackCount: (row['all_count'] as num?)?.toInt() ?? 0,
      albumCount: (row['album_count'] as num?)?.toInt() ?? 0,
      singleTrackCount: (row['single_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// The default Library badges do not need a row-by-row join against album
  /// counts. Aggregate the covering album-key indexes directly and reserve the
  /// more expensive filtered query for active search/quality/metadata filters.
  Future<QueueLibraryCounts?> _getUnfilteredQueueCounts(
    Database db,
    QueueLibraryDbQuery request,
  ) async {
    if (normalizeLookupText(request.searchQuery).isNotEmpty ||
        request.quality != null ||
        request.format != null ||
        request.metadata != null) {
      return null;
    }
    final source = request.source;
    if (source != null && source != 'downloaded' && source != 'local') {
      return null;
    }

    final parts = <String>[];
    if (source != 'local') {
      parts.add('''
        SELECT
          COALESCE(SUM(track_count), 0) AS all_count,
          COALESCE(SUM(CASE WHEN track_count > 1 THEN 1 ELSE 0 END), 0) AS album_count,
          COALESCE(SUM(CASE WHEN track_count = 1 THEN 1 ELSE 0 END), 0) AS single_count
        FROM (
          SELECT album_key, COUNT(*) AS track_count
          FROM history_db.history
          GROUP BY album_key
        )
      ''');
    }
    if (request.includeLocal && source != 'downloaded') {
      parts.add('''
        SELECT
          COALESCE(SUM(track_count), 0) AS all_count,
          COALESCE(SUM(CASE WHEN track_count > 1 THEN 1 ELSE 0 END), 0) AS album_count,
          COALESCE(SUM(CASE WHEN track_count = 1 THEN 1 ELSE 0 END), 0) AS single_count
        FROM (
          SELECT l.album_key, COUNT(*) AS track_count
          FROM $visibleLibraryView l
          WHERE NOT EXISTS (
            SELECT 1
            FROM library_path_keys lpk
            JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
            WHERE lpk.item_id = l.id
          )
          GROUP BY l.album_key
        )
      ''');
    }
    if (parts.isEmpty) {
      return const QueueLibraryCounts(
        allTrackCount: 0,
        albumCount: 0,
        singleTrackCount: 0,
      );
    }

    final rows = await db.rawQuery('''
      SELECT
        COALESCE(SUM(all_count), 0) AS all_count,
        COALESCE(SUM(album_count), 0) AS album_count,
        COALESCE(SUM(single_count), 0) AS single_count
      FROM (${parts.join(' UNION ALL ')})
    ''');
    final row = rows.isEmpty ? const <String, Object?>{} : rows.first;
    return QueueLibraryCounts(
      allTrackCount: (row['all_count'] as num?)?.toInt() ?? 0,
      albumCount: (row['album_count'] as num?)?.toInt() ?? 0,
      singleTrackCount: (row['single_count'] as num?)?.toInt() ?? 0,
    );
  }

  Future<List<Map<String, dynamic>>> getQueueAlbumPage(
    QueueLibraryDbQuery request,
  ) async {
    return (await getQueueAlbumPageResult(request)).rows;
  }

  Future<QueueLibraryDbPage> getQueueAlbumPageResult(
    QueueLibraryDbQuery request,
  ) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    final args = <Object?>[];
    final orderTerms = _queueAlbumOrderTerms(request.sortMode);
    final usesCursor =
        request.cursor != null &&
        request.cursor!.values.length == orderTerms.length;
    final unionSql = _queueAlbumUnionSql(
      request,
      args,
      orderTerms: orderTerms,
      usesCursor: usesCursor,
    );
    final rows = await db.rawQuery(
      '''
      SELECT *
      FROM ($unionSql)
      ORDER BY ${_queueAlbumOrderBy(request.sortMode)}
      LIMIT ? ${usesCursor ? '' : 'OFFSET ?'}
      ''',
      [...args, request.limit, if (!usesCursor) request.offset],
    );
    return QueueLibraryDbPage(
      rows: rows.toList(growable: false),
      nextCursor: _queueCursorFromRow(rows.lastOrNull, orderTerms),
    );
  }

  /// Album artists across downloaded and scanned music, without loading tracks
  /// into Dart. Scanned paths already represented by downloads are excluded.
  Future<List<Map<String, dynamic>>> getQueueArtistPage(
    QueueLibraryDbQuery request,
  ) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    final parts = <String>[
      '''
        SELECT sort_album_artist AS artist_key,
          COALESCE(NULLIF(album_artist, ''), artist_name) AS artist_name,
          cover_url, NULL AS cover_path, file_path AS sample_file_path
        FROM history_db.history
      ''',
      if (request.includeLocal)
        '''
          SELECT album_artist_norm AS artist_key,
            COALESCE(NULLIF(album_artist, ''), artist_name) AS artist_name,
            NULL AS cover_url, cover_path, file_path AS sample_file_path
          FROM $visibleLibraryView l
          WHERE NOT EXISTS (
            SELECT 1 FROM library_path_keys lpk
            JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
            WHERE lpk.item_id = l.id
          )
        ''',
    ];
    final search = normalizeLookupText(request.searchQuery);
    return db.rawQuery(
      '''
      SELECT artist_key, MIN(artist_name) AS artist_name,
        MAX(NULLIF(cover_url, '')) AS cover_url,
        MAX(NULLIF(cover_path, '')) AS cover_path,
        MAX(sample_file_path) AS sample_file_path,
        COUNT(*) AS track_count
      FROM (${parts.join(' UNION ALL ')})
      WHERE artist_key != '' ${search.isEmpty ? '' : "AND artist_key LIKE ? ESCAPE '\\'"}
      GROUP BY artist_key
      ORDER BY artist_key
      LIMIT ? OFFSET ?
    ''',
      [
        if (search.isNotEmpty) '%${_escapeLikePattern(search)}%',
        request.limit,
        request.offset,
      ],
    );
  }

  Future<List<Map<String, dynamic>>> getQueueLocalAlbumTracks(
    String albumName,
    String artistName,
  ) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where:
          "LOWER(album_name) = ? AND LOWER(COALESCE(NULLIF(album_artist, ''), artist_name)) = ?",
      whereArgs: [albumName.toLowerCase(), artistName.toLowerCase()],
      orderBy:
          'COALESCE(disc_number, 0), COALESCE(track_number, 0), track_name',
    );
    return rows.map(_dbRowToJson).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> getQueueLocalAlbumTracksByKey(
    String albumKey,
  ) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'album_key = ?',
      whereArgs: [albumKey],
      orderBy:
          'COALESCE(disc_number, 0), COALESCE(track_number, 0), track_name',
    );
    return rows.map(_dbRowToJson).toList(growable: false);
  }

  Future<Map<String, dynamic>?> getById(String id) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _dbRowToJson(rows.first);
  }

  Future<Map<String, dynamic>?> getByIsrc(String isrc) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'isrc = ?',
      whereArgs: [isrc],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _dbRowToJson(rows.first);
  }

  Future<List<Map<String, dynamic>>> findByTrackAndArtist(
    String trackName,
    String artistName,
  ) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'match_key = ?',
      whereArgs: [matchKeyFor(trackName, artistName)],
    );
    return rows.map(_dbRowToJson).toList();
  }

  Future<Map<String, dynamic>?> findFirstByTrackAndArtist(
    String trackName,
    String artistName,
  ) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'match_key = ?',
      whereArgs: [matchKeyFor(trackName, artistName)],
      orderBy: _orderByForSort(LocalLibrarySortMode.album),
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _dbRowToJson(rows.first);
  }

  Future<Map<String, dynamic>?> findExisting({
    String? isrc,
    String? trackName,
    String? artistName,
  }) async {
    if (isrc != null && isrc.isNotEmpty) {
      final byIsrc = await getByIsrc(isrc);
      if (byIsrc != null) return byIsrc;
    }

    if (trackName != null && artistName != null) {
      final matches = await findByTrackAndArtist(trackName, artistName);
      if (matches.isNotEmpty) return matches.first;
    }

    return null;
  }

  /// Resolves a track list with a bounded number of indexed queries instead
  /// of issuing up to three SQLite calls for every track.
  Future<List<Map<String, dynamic>?>> findExistingBatch(
    List<LocalLibraryBatchLookupRequest> requests,
  ) async {
    if (requests.isEmpty) return const [];
    final db = await database;
    final byId = <String, Map<String, dynamic>>{};
    final byIsrc = <String, Map<String, dynamic>>{};
    final byMatchKey = <String, Map<String, dynamic>>{};

    Future<void> loadColumn(
      String column,
      Iterable<String> rawValues,
      Map<String, Map<String, dynamic>> destination,
    ) {
      return sqlite.loadRowsByColumn(
        db,
        table: visibleLibraryView,
        column: column,
        rawValues: rawValues,
        destination: destination,
        mapRow: _dbRowToJson,
      );
    }

    await Future.wait([
      loadColumn('id', requests.map((request) => request.id ?? ''), byId),
      loadColumn('isrc', requests.map((request) => request.isrc ?? ''), byIsrc),
      loadColumn(
        'match_key',
        requests.map(
          (request) => matchKeyFor(request.trackName, request.artistName),
        ),
        byMatchKey,
      ),
    ]);

    return requests
        .map((request) {
          final id = request.id?.trim() ?? '';
          if (id.isNotEmpty && byId[id] != null) return byId[id];
          final isrc = request.isrc?.trim() ?? '';
          if (isrc.isNotEmpty && byIsrc[isrc] != null) return byIsrc[isrc];
          return byMatchKey[matchKeyFor(request.trackName, request.artistName)];
        })
        .toList(growable: false);
  }

  Future<LocalLibraryLookupIndex> getLookupIndex() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT summary.kind, summary.value
      FROM $lookupSummaryTable summary
      JOIN library_sources source ON source.id = summary.source_id
      WHERE source.enabled = 1 AND source.available = 1
      GROUP BY summary.kind, summary.value
    ''');
    final isrcs = <String>{};
    final matchKeys = <String>{};
    for (final row in rows) {
      final value = row['value'] as String?;
      if (value == null || value.isEmpty) continue;
      if (row['kind'] == 'isrc') {
        isrcs.add(value);
      } else if (row['kind'] == 'match') {
        matchKeys.add(value);
      }
    }
    return LocalLibraryLookupIndex(
      isrcs: Set<String>.unmodifiable(isrcs),
      matchKeys: Set<String>.unmodifiable(matchKeys),
    );
  }

  Future<List<String>> getCoverPaths({int? limit, int? offset}) async {
    final db = await database;
    final rows = await db.query(
      'library',
      columns: ['cover_path'],
      where: 'cover_path IS NOT NULL AND cover_path != ""',
      limit: limit,
      offset: offset,
    );
    return rows
        .map((row) => row['cover_path'] as String?)
        .whereType<String>()
        .toList(growable: false);
  }

  /// Groups of tracks sharing one ISRC across download history and the
  /// local library. Library rows whose path key already appears in history
  /// are excluded so a scanned copy of a download doesn't pair with itself.
  /// Entries come back best-quality first.
  Future<List<IsrcDuplicateGroup>> findIsrcDuplicateGroups() async {
    final db = await database;
    final rows = await db.rawQuery('''
      WITH merged AS (
        SELECT h.id AS id, 'downloaded' AS source, h.track_name, h.artist_name,
               h.album_name, h.file_path, UPPER(TRIM(h.isrc)) AS isrc_key,
               h.bit_depth, h.sample_rate, h.bitrate, h.format
        FROM history_db.history h
        WHERE h.isrc IS NOT NULL AND TRIM(h.isrc) != ''
        UNION ALL
        SELECT l.id AS id, 'local' AS source, l.track_name, l.artist_name,
               l.album_name, l.file_path, UPPER(TRIM(l.isrc)) AS isrc_key,
               l.bit_depth, l.sample_rate, l.bitrate, l.format
        FROM $visibleLibraryView l
        WHERE l.isrc IS NOT NULL AND TRIM(l.isrc) != ''
          AND NOT EXISTS (
            SELECT 1
            FROM library_path_keys lpk
            JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
            WHERE lpk.item_id = l.id
          )
      )
      SELECT * FROM merged
      WHERE isrc_key IN (
        SELECT isrc_key FROM merged GROUP BY isrc_key HAVING COUNT(*) > 1
      )
      ORDER BY isrc_key, bit_depth DESC, sample_rate DESC, bitrate DESC
    ''');

    final groups = <String, List<IsrcDuplicateEntry>>{};
    for (final row in rows) {
      final isrc = row['isrc_key'] as String? ?? '';
      final filePath = row['file_path'] as String? ?? '';
      if (isrc.isEmpty || filePath.isEmpty) continue;
      groups
          .putIfAbsent(isrc, () => [])
          .add(
            IsrcDuplicateEntry(
              id: row['id'] as String,
              source: row['source'] as String,
              trackName: row['track_name'] as String? ?? '',
              artistName: row['artist_name'] as String? ?? '',
              albumName: row['album_name'] as String? ?? '',
              filePath: filePath,
              bitDepth: (row['bit_depth'] as num?)?.toInt(),
              sampleRate: (row['sample_rate'] as num?)?.toInt(),
              bitrate: (row['bitrate'] as num?)?.toInt(),
              format: row['format'] as String?,
            ),
          );
    }
    return [
      for (final entry in groups.entries)
        if (entry.value.length > 1)
          IsrcDuplicateGroup(isrc: entry.key, entries: entry.value),
    ];
  }

  Future<void> deleteByPath(String filePath) async {
    final db = await database;
    final rows = await db.query(
      'library',
      columns: ['id'],
      where: 'file_path = ?',
      whereArgs: [filePath],
    );
    final ids = rows.map((row) => row['id'] as String).toList(growable: false);
    await db.transaction((txn) async {
      for (final id in ids) {
        await txn.delete(
          'library_path_keys',
          where: 'item_id = ?',
          whereArgs: [id],
        );
      }
      await txn.delete(
        'library',
        where: 'file_path = ?',
        whereArgs: [filePath],
      );
    });
  }

  Future<void> replaceWithConvertedItem({
    required LocalLibraryItem item,
    required String newFilePath,
    required String targetFormat,
    required String bitrate,
    int? bitDepth,
    int? sampleRate,
    bool keepOriginal = false,
  }) async {
    final db = await database;
    final stat = await fileStat(newFilePath);
    final now = DateTime.now();
    final normalizedFormat = _normalizeConvertedFormat(targetFormat);
    final convertedBitrate =
        _convertedBitrate(targetFormat: targetFormat, bitrate: bitrate) ??
        estimateAverageBitrateKbps(
          fileSizeBytes: stat?.size,
          durationSeconds: item.duration,
        );
    final updated = item.toJson()
      ..['id'] = _generateLibraryId(newFilePath)
      ..['filePath'] = newFilePath
      ..['scannedAt'] = now.toIso8601String()
      ..['fileModTime'] = stat?.modified?.millisecondsSinceEpoch
      ..['format'] = normalizedFormat
      ..['bitrate'] = convertedBitrate
      // Conversion may rewrite gain tags; rescan the resulting file.
      ..['hasReplayGain'] = false
      ..['audioMetadataScanVersion'] = 0;

    if (normalizedFormat == 'mp3' ||
        normalizedFormat == 'opus' ||
        normalizedFormat == 'aac') {
      updated['bitDepth'] = null;
      updated['sampleRate'] = null;
    } else {
      updated['bitDepth'] = bitDepth ?? item.bitDepth;
      updated['sampleRate'] = sampleRate ?? item.sampleRate;
    }

    await db.transaction((txn) async {
      if (!keepOriginal) {
        await txn.delete(
          'library_path_keys',
          where: 'item_id = ?',
          whereArgs: [item.id],
        );
        await txn.delete(
          'library',
          where: 'id = ? OR file_path = ?',
          whereArgs: [item.id, item.filePath],
        );
      }
      await txn.insert(
        'library',
        _jsonToDbRow(updated),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final batch = txn.batch();
      _putPathKeysInBatch(
        batch,
        updated['id'] as String,
        updated['filePath'] as String?,
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> updateAudioMetadata(
    String id, {
    int? duration,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    bool? explicit,
    bool? hasLyrics,
    bool? hasReplayGain,
    String? format,
  }) async {
    final values = <String, dynamic>{};
    if (duration != null && duration > 0) {
      values['duration'] = duration;
    }
    if (bitDepth != null && bitDepth > 0) {
      values['bit_depth'] = bitDepth;
    }
    if (sampleRate != null && sampleRate > 0) {
      values['sample_rate'] = sampleRate;
    }
    if (bitrate != null && bitrate > 0) {
      values['bitrate'] = bitrate;
    }
    if (explicit != null) {
      values['explicit'] = explicit ? 1 : 0;
    }
    if (hasLyrics != null) {
      values['has_lyrics'] = hasLyrics ? 1 : 0;
    }
    if (hasReplayGain != null) {
      values['has_replaygain'] = hasReplayGain ? 1 : 0;
    }
    final normalizedFormat = normalizeAudioFormatValue(format);
    if (normalizedFormat != null) {
      values['format'] = normalizedFormat;
    }
    if (values.isEmpty) return;

    final db = await database;
    if (hasReplayGain == null && hasLyrics == null) {
      await db.update('library', values, where: 'id = ?', whereArgs: [id]);
      return;
    }
    // A quality-only update must not confirm absent tags. ReplayGain-only
    // writes can advance lyrics-aware rows, while older rows still rescan.
    final replayGainOnly = hasReplayGain != null && hasLyrics == null;
    final scanVersion = hasReplayGain != null
        ? audioMetadataScanVersion
        : lyricsMetadataScanVersion;
    final versionSql = replayGainOnly
        ? 'CASE WHEN COALESCE(audio_metadata_scan_version, 0) >= ? '
              'THEN MAX(COALESCE(audio_metadata_scan_version, 0), ?) '
              'ELSE COALESCE(audio_metadata_scan_version, 0) END'
        : 'MAX(COALESCE(audio_metadata_scan_version, 0), ?)';
    final columns = values.keys.toList(growable: false);
    await db.rawUpdate(
      'UPDATE library SET ${columns.map((column) => '$column = ?').join(', ')}, '
      'audio_metadata_scan_version = $versionSql WHERE id = ?',
      [
        ...columns.map((column) => values[column]),
        if (replayGainOnly) lyricsMetadataScanVersion,
        scanVersion,
        id,
      ],
    );
  }

  Future<void> delete(String id) async {
    await deleteByIds([id]);
  }

  Future<void> deleteByIds(Iterable<String> ids) async {
    if (ids.isEmpty) return;
    await deleteLibraryItemsByIds(await database, ids);
  }

  Future<int> cleanupMissingFiles({
    String? sourceId,
    Future<bool> Function()? canDelete,
  }) async {
    final db = await database;
    final removed = await cleanupMissingLibraryRows(
      db,
      sourceId: sourceId,
      canDelete: canDelete,
    );

    if (removed > 0) {
      _log.i('Cleaned up $removed missing files from library');
    }
    return removed;
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('library_path_keys');
      await txn.delete('library');
      await txn.update('library_sources', {
        'last_scanned_at': null,
        'last_scan_error': null,
      });
    });
    _log.i('Cleared all library data');
  }

  Future<int> getCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $visibleLibraryView',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getSourceCount(String sourceId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM library WHERE source_id = ?',
      [sourceId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database.reset();
    _historyAttached = false;
    _searchFtsAvailable = null;
  }

  Future<Map<String, int>> getFileModTimes({String? sourceId}) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT file_path, COALESCE(file_mod_time, 0) AS file_mod_time, '
      'audio_metadata_scan_version FROM library '
      '${sourceId == null ? '' : 'WHERE source_id = ?'}',
      sourceId == null ? const [] : [sourceId],
    );
    final result = <String, int>{};
    for (final row in rows) {
      final path = row['file_path'] as String;
      final modTime = (row['file_mod_time'] as num?)?.toInt() ?? 0;
      final scanVersion =
          (row['audio_metadata_scan_version'] as num?)?.toInt() ?? 0;
      // A sentinel timestamp keeps the path in deletion/dedup checks while
      // making the incremental scanner treat a legacy row as changed once.
      result[path] = libraryIncrementalSnapshotModTime(
        storedModTime: modTime,
        storedScanVersion: scanVersion,
      );
    }
    return result;
  }

  /// Uses the already normalized, backfilled timestamps from the scan caller.
  /// Bounded writes avoid a second query and a library-sized StringBuffer.
  Future<String> writeFileModTimesSnapshot(
    Map<String, int> fileModTimes,
  ) async {
    final tempDir = await getTemporaryDirectory();
    final file = File(
      join(
        tempDir.path,
        'library_file_mod_times_${DateTime.now().microsecondsSinceEpoch}.tsv',
      ),
    );
    try {
      final output = await file.open(mode: FileMode.write);
      try {
        final buffer = StringBuffer();
        for (final entry in fileModTimes.entries) {
          if (entry.key.isEmpty) continue;
          buffer
            ..write(entry.value)
            ..write('\t')
            ..writeln(entry.key);
          if (buffer.length >= 64 * 1024) {
            await output.writeString(buffer.toString());
            buffer.clear();
          }
        }
        if (buffer.isNotEmpty) await output.writeString(buffer.toString());
        await output.flush();
      } finally {
        await output.close();
      }
    } catch (_) {
      if (await file.exists()) await file.delete();
      rethrow;
    }
    return file.path;
  }

  Future<void> updateFileModTimes(Map<String, int> fileModTimes) async {
    if (fileModTimes.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final entry in fileModTimes.entries) {
      batch.update(
        'library',
        {'file_mod_time': entry.value, 'sort_added': entry.value},
        where: 'file_path = ?',
        whereArgs: [entry.key],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<Set<String>> getAllFilePaths() async {
    final db = await database;
    final rows = await db.rawQuery('SELECT file_path FROM library');
    return rows.map((r) => r['file_path'] as String).toSet();
  }

  Future<int> deleteByPaths(List<String> filePaths) async {
    if (filePaths.isEmpty) return 0;
    final db = await database;
    var totalDeleted = 0;
    const chunkSize = 500;
    // One commit for the whole removal; a rescan that dropped a folder can
    // otherwise pay several WAL commits per chunk.
    await db.transaction((txn) async {
      for (var i = 0; i < filePaths.length; i += chunkSize) {
        final end = (i + chunkSize < filePaths.length)
            ? i + chunkSize
            : filePaths.length;
        final chunk = filePaths.sublist(i, end);
        final placeholders = List.filled(chunk.length, '?').join(',');
        await txn.rawDelete(
          'DELETE FROM library_path_keys WHERE item_id IN '
          '(SELECT id FROM library WHERE file_path IN ($placeholders))',
          chunk,
        );
        totalDeleted += await txn.rawDelete(
          'DELETE FROM library WHERE file_path IN ($placeholders)',
          chunk,
        );
      }
    });
    if (totalDeleted > 0) {
      _log.i('Deleted $totalDeleted items from library');
    }
    return totalDeleted;
  }

  String _normalizeConvertedFormat(String targetFormat) {
    return normalizeAudioFormatValue(targetFormat) ?? 'mp3';
  }

  int? _convertedBitrate({
    required String targetFormat,
    required String bitrate,
  }) {
    switch (targetFormat.trim().toLowerCase()) {
      case 'mp3':
      case 'opus':
      case 'aac':
        final match = RegExp(r'(\d+)').firstMatch(bitrate);
        return match != null ? int.tryParse(match.group(1)!) : null;
      default:
        return null;
    }
  }

  String _generateLibraryId(String filePath) {
    return 'lib_${_hashString(filePath).toRadixString(16)}';
  }

  int _hashString(String input) {
    var hash = 5381;
    for (final codeUnit in input.codeUnits) {
      hash = (((hash << 5) + hash) + codeUnit) & 0xffffffff;
    }
    return hash;
  }
}
