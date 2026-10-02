import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/services/sqlite_helpers.dart' as sqlite;

/// Called inside a transaction. Delayed metadata/SAF probes must never insert
/// rows deleted by orphan cleanup while the probe was running.
Future<Set<String>> updateExistingHistoryRows(
  DatabaseExecutor db,
  Iterable<Map<String, dynamic>> rows,
) async {
  final updatedIds = <String>{};
  final batch = db.batch();
  for (final row in rows) {
    final id = row['id'] as String;
    final changed = await db.update(
      'history',
      row,
      where: 'id = ?',
      whereArgs: [id],
    );
    if (changed == 0) continue;
    updatedIds.add(id);
    sqlite.putPathKeysInBatch(
      batch,
      'history_path_keys',
      id,
      row['file_path'] as String?,
    );
  }
  if (updatedIds.isNotEmpty) await batch.commit(noResult: true);
  return updatedIds;
}
