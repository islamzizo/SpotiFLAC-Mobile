import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/models/download_item.dart';
import 'package:spotiflac_android/services/app_state_database.dart';

DownloadStatus downloadQueuePersistenceStatus(DownloadStatus status) =>
    switch (status) {
      DownloadStatus.downloading ||
      DownloadStatus.finalizing => DownloadStatus.queued,
      _ => status,
    };

/// Transfer samples are transient; only restart-relevant state reaches SQLite.
String encodeDownloadQueueItemForPersistence(DownloadItem item) => jsonEncode(
  item.toJson()
    ..['status'] = downloadQueuePersistenceStatus(item.status).name
    ..['progress'] = 0.0
    ..['speedMBps'] = 0.0
    ..['bytesReceived'] = 0
    ..['bytesTotal'] = 0
    ..['preparationStage'] = '',
);

/// Owns durable queue snapshots, including corrupt-row cleanup and write order.
/// A failed write leaves the previous snapshot intact so a later flush retries.
class DownloadQueuePersistence {
  DownloadQueuePersistence({
    required this.currentItems,
    required this.onError,
    this.loadRows = _loadRows,
    this.applyChanges = _applyChanges,
  });

  final List<DownloadItem> Function() currentItems;
  final void Function(Object error) onError;
  final Future<List<Map<String, dynamic>>> Function() loadRows;
  final Future<void> Function({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
  })
  applyChanges;
  static const _pausedKey = 'download_queue_user_paused_v1';
  Timer? _debounce;
  List<DownloadItem>? _pendingItems;
  Future<void> _write = Future<void>.value();
  Future<void> _pauseWrite = Future<void>.value();
  Map<String, ({DownloadItem? item, String? payload})> _saved = {};

  static Future<List<Map<String, dynamic>>> _loadRows() async {
    final database = AppStateDatabase.instance;
    await database.migrateQueueFromSharedPreferences();
    return database.getPendingDownloadQueueRows();
  }

  static Future<void> _applyChanges({
    required List<Map<String, dynamic>> upserts,
    required List<String> deletedIds,
  }) => AppStateDatabase.instance.applyPendingDownloadQueueChanges(
    upserts: upserts,
    deletedIds: deletedIds,
  );

  Future<bool> loadUserPaused() async =>
      (await SharedPreferences.getInstance()).getBool(_pausedKey) == true;

  void setUserPaused(bool paused) {
    _pauseWrite = _pauseWrite
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          if (paused) {
            await prefs.setBool(_pausedKey, true);
          } else {
            await prefs.remove(_pausedKey);
          }
        })
        .catchError(onError);
  }

  Future<List<DownloadItem>> restore() async {
    final rows = await loadRows();
    _saved.clear();
    final pending = <DownloadItem>[];
    for (final row in rows) {
      final id = row['id']?.toString() ?? '';
      // Retain corrupt IDs so the next successful flush deletes those rows.
      _saved[id] = (item: null, payload: null);
      final payload = row['item_json'];
      if (id.isEmpty || payload is! String || payload.isEmpty) continue;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is! Map) continue;
        var item = DownloadItem.fromJson(Map<String, dynamic>.from(decoded));
        final status = downloadQueuePersistenceStatus(item.status);
        _saved[id] = (
          item: item,
          payload:
              row['status']?.toString() == status.name &&
                  payload == encodeDownloadQueueItemForPersistence(item)
              ? payload
              : null,
        );
        if (item.status != status) {
          item = item.copyWith(status: status, progress: 0);
        }
        if (status == DownloadStatus.queued ||
            status == DownloadStatus.skipped) {
          pending.add(item);
        }
      } catch (_) {
        continue;
      }
    }
    return pending;
  }

  void schedule() {
    _debounce?.cancel();
    _pendingItems = currentItems();
    _debounce = Timer(const Duration(milliseconds: 350), flush);
  }

  Future<void> flush() async {
    _debounce?.cancel();
    _debounce = null;
    _pendingItems = null;
    await _enqueue(currentItems());
    await _pauseWrite;
  }

  void dispose() {
    final pending = _pendingItems;
    if (pending != null) unawaited(_enqueue(pending));
    _debounce?.cancel();
    _debounce = null;
    _pendingItems = null;
  }

  Future<void> _enqueue(List<DownloadItem> items) {
    return _write = _write
        .then((_) async {
          final nextSaved = <String, ({DownloadItem? item, String? payload})>{};
          final upserts = <Map<String, dynamic>>[];
          final now = DateTime.now().toIso8601String();
          for (final item in items) {
            if (item.status == DownloadStatus.completed ||
                item.status == DownloadStatus.failed) {
              continue;
            }
            final saved = _saved[item.id];
            final payload =
                identical(saved?.item, item) && saved?.payload != null
                ? saved!.payload!
                : encodeDownloadQueueItemForPersistence(item);
            nextSaved[item.id] = (item: item, payload: payload);
            if (saved?.payload == payload) continue;
            upserts.add({
              'id': item.id,
              'item_json': payload,
              'status': downloadQueuePersistenceStatus(item.status).name,
              'created_at': item.createdAt.toIso8601String(),
              'updated_at': now,
            });
          }
          final deletedIds = _saved.keys
              .where((id) => !nextSaved.containsKey(id))
              .toList(growable: false);
          if (upserts.isNotEmpty || deletedIds.isNotEmpty) {
            await applyChanges(upserts: upserts, deletedIds: deletedIds);
          }
          _saved = nextSaved;
        })
        .catchError(onError);
  }
}
