import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/providers/download_history_provider.dart';
import 'package:spotiflac_android/services/history_maintenance.dart';

class _HistoryRows implements DatabaseExecutor {
  final statements = <Map<String, Object?>>[];
  final _keys = _PathKeys();

  @override
  Future<int> update(
    String table,
    Map<String, Object?> values, {
    String? where,
    List<Object?>? whereArgs,
    ConflictAlgorithm? conflictAlgorithm,
  }) async {
    statements.add({
      'sql':
          'UPDATE $table SET ${values.keys.map((key) => '$key = ?').join(', ')} WHERE $where',
      'args': [...values.values, ...?whereArgs],
    });
    return whereArgs!.single == 'kept' ? 1 : 0;
  }

  @override
  Batch batch() => _keys;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PathKeys implements Batch {
  final statements = <Map<String, Object?>>[];

  @override
  void delete(String table, {String? where, List<Object?>? whereArgs}) {
    statements.add({
      'sql': 'DELETE FROM $table WHERE $where',
      'args': whereArgs,
    });
  }

  @override
  void insert(
    String table,
    Map<String, Object?> values, {
    String? nullColumnHack,
    ConflictAlgorithm? conflictAlgorithm,
  }) {
    expect(conflictAlgorithm, ConflictAlgorithm.ignore);
    statements.add({
      'sql':
          'INSERT OR IGNORE INTO $table (${values.keys.join(', ')}) VALUES (${values.keys.map((_) => '?').join(', ')})',
      'args': values.values.toList(),
    });
  }

  @override
  Future<List<Object?>> commit({
    bool? exclusive,
    bool? noResult,
    bool? continueOnError,
  }) async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadHistoryItem _track(String id) => DownloadHistoryItem(
  id: id,
  trackName: 'Song $id',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: '/music/$id.flac',
  service: 'test',
  downloadedAt: DateTime.utc(2026),
);

void main() {
  test(
    'late maintenance cannot recreate deleted rows or their path keys',
    () async {
      final db = _HistoryRows();
      final updated = await updateExistingHistoryRows(db, [
        {
          'id': 'removed',
          'file_path': '/music/removed.flac',
          'quality': '24-bit',
        },
        {'id': 'kept', 'file_path': '/music/kept.opus', 'quality': 'Opus'},
      ]);
      expect(updated, {'kept'});
      final result = await Process.run('python3', [
        '-c',
        r'''
import json, sqlite3, sys
db = sqlite3.connect(':memory:')
db.executescript("""
CREATE TABLE history(id TEXT PRIMARY KEY, file_path TEXT, quality TEXT);
CREATE TABLE history_path_keys(item_id TEXT, path_key TEXT, UNIQUE(item_id,path_key));
INSERT INTO history VALUES ('removed','/music/removed.flac','16-bit'),('kept','/music/kept.flac','16-bit');
INSERT INTO history_path_keys SELECT id,file_path FROM history;
DELETE FROM history WHERE id='removed';
DELETE FROM history_path_keys WHERE item_id='removed';
""")
with db:
    for statement in json.loads(sys.argv[1]):
        db.execute(statement['sql'], statement['args'])
print(json.dumps({
  'rows': list(db.execute('SELECT id,file_path,quality FROM history')),
  'keys': list(db.execute('SELECT item_id,path_key FROM history_path_keys'))
}))
''',
        jsonEncode([...db.statements, ...db._keys.statements]),
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      final data = jsonDecode(result.stdout as String) as Map<String, dynamic>;
      expect(data['rows'], [
        ['kept', '/music/kept.opus', 'Opus'],
      ]);
      expect(
        (data['keys'] as List).every((row) => (row as List).first == 'kept'),
        isTrue,
      );
      expect(data['keys'], isNotEmpty);
    },
  );

  test(
    '20 removed downloads stay removed when an old metadata probe finishes',
    () {
      final oldSnapshot = [for (var i = 0; i < 20; i++) _track('$i')];
      final fresh = _track('new-download');
      final current = DownloadHistoryState(
        items: [fresh],
        totalCount: 1,
        loadedIndexVersion: 7,
      );
      final result = mergeHistoryMaintenanceUpdates(current, [
        oldSnapshot.last.copyWith(quality: '24-bit'),
      ], {});
      expect(identical(result, current), isTrue);
      expect(result.items.map((item) => item.id), ['new-download']);
      expect(result.lookupItems.map((item) => item.id), ['new-download']);
      expect(result.totalCount, 1);
    },
  );

  test(
    'live ordering, new downloads and lookup-only items survive maintenance',
    () {
      final kept = _track('kept');
      final fresh = _track('fresh');
      final lookupOnly = _track('lookup');
      final current = DownloadHistoryState(
        items: [fresh, kept],
        lookupItems: [lookupOnly, fresh, kept],
        totalCount: 42,
        loadedIndexVersion: 3,
      );
      final result = mergeHistoryMaintenanceUpdates(
        current,
        [
          kept.copyWith(quality: '24-bit'),
          lookupOnly.copyWith(quality: 'Opus'),
          _track('deleted'),
        ],
        {'kept', 'lookup'},
      );
      expect(result.items.map((item) => item.id), ['fresh', 'kept']);
      expect(result.items.last.quality, '24-bit');
      expect(result.lookupItems.map((item) => item.id), [
        'lookup',
        'fresh',
        'kept',
      ]);
      expect(result.lookupItems.first.quality, 'Opus');
      expect(result.totalCount, 42);
      expect(result.loadedIndexVersion, 4);
    },
  );
}
