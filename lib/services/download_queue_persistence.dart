import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/models/download_item.dart';
import 'package:spotiflac_android/services/app_state_database.dart';
import 'package:spotiflac_android/services/download_queue_codec.dart';

export 'package:spotiflac_android/services/download_queue_codec.dart'
    show downloadQueuePersistenceStatus, encodeDownloadQueueItemForPersistence;

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
  Map<String, DownloadQueueSavedItem> _saved = {};

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

  Future<List<DownloadItem>> restore() {
    final restored = _write.then((_) async {
      final decoded = await decodeDownloadQueueRows(await loadRows());
      _saved = decoded.saved;
      return decoded.items;
    });
    // A restore is ordered with durable writes now that decoding can yield to
    // a worker. Its error still reaches the caller without poisoning retries.
    _write = restored.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return restored;
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
          final nextSaved = <String, DownloadQueueSavedItem>{};
          final upserts = <Map<String, dynamic>>[];
          final now = DateTime.now().toIso8601String();
          final changed = <DownloadItem>[];
          for (final item in items) {
            if (item.status == DownloadStatus.completed ||
                item.status == DownloadStatus.failed) {
              continue;
            }
            final saved = _saved[item.id];
            final cached =
                identical(saved?.item, item) && saved?.payload != null;
            nextSaved[item.id] = (
              item: item,
              payload: cached ? saved!.payload : null,
            );
            if (!cached) {
              changed.add(item);
            }
          }
          final encoded = await encodeDownloadQueueItems(changed);
          for (var index = 0; index < changed.length; index++) {
            final item = changed[index];
            final saved = _saved[item.id];
            final payload = encoded[index];
            if (identical(nextSaved[item.id]?.item, item)) {
              nextSaved[item.id] = (item: item, payload: payload);
            }
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
