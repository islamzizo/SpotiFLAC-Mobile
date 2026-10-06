import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/models/download_item.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/app_state_database.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(downloadDirectory: '/fixture/output');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'background flush waits for restored provider state and skips a disposed owner',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_state_migrated_queue_to_sqlite_v1': true,
        'download_queue_user_paused_v1': true,
      });
      final previousFactory = databaseFactoryOrNull;
      databaseFactory = databaseFactorySqflitePlugin;
      addTearDown(() => databaseFactory = previousFactory);
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const sqlite = MethodChannel('com.tekartik.sqflite');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        paths,
        (_) async => '/fixture/documents',
      );
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
      final items = List.generate(
        128,
        (index) => DownloadItem(
          id: 'queue-$index',
          track: Track(
            id: 'example:$index',
            name: 'Song $index',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 180,
          ),
          // Avoid extension/native download work; the persisted queue is paused.
          service: '',
          createdAt: DateTime.utc(2026).add(Duration(seconds: index)),
        ),
      );
      final rows = <String, Map<String, Object?>>{
        for (final item in items)
          item.id: {
            'id': item.id,
            'item_json': encodeDownloadQueueItemForPersistence(item),
            'status': 'queued',
            'created_at': item.createdAt.toIso8601String(),
            'updated_at': item.createdAt.toIso8601String(),
          },
      };
      var started = Completer<void>();
      var release = Completer<void>();
      var queueReads = 0;
      var deletes = 0;
      var writes = 0;
      messenger.setMockMethodCallHandler(sqlite, (call) async {
        if (call.method == 'openDatabase') return {'id': 1};
        final arguments = call.arguments as Map? ?? {};
        final sql = arguments['sql'] as String? ?? '';
        if (call.method == 'query') {
          if (sql.toLowerCase().contains('pragma user_version')) {
            return {
              'columns': ['user_version'],
              'rows': [
                [4],
              ],
            };
          }
          if (!sql.contains('download_queue_items')) {
            return {'columns': <String>[], 'rows': <List<Object?>>[]};
          }
          queueReads++;
          final snapshot = rows.values.toList();
          started.complete();
          await release.future;
          const columns = [
            'id',
            'item_json',
            'status',
            'created_at',
            'updated_at',
          ];
          return {
            'columns': columns,
            'rows': [
              for (final row in snapshot)
                [for (final column in columns) row[column]],
            ],
          };
        }
        if (call.method == 'batch') {
          for (final raw in arguments['operations'] as List) {
            final operation = raw as Map;
            final statement = operation['sql'] as String;
            final values = operation['arguments'] as List;
            if (statement.startsWith('DELETE FROM download_queue_items')) {
              rows.remove(values.first as String);
              deletes++;
            } else if (statement.startsWith('INSERT')) {
              const columns = [
                'id',
                'item_json',
                'status',
                'created_at',
                'updated_at',
              ];
              rows[values.first as String] = {
                for (var i = 0; i < columns.length; i++) columns[i]: values[i],
              };
              writes++;
            } else {
              fail('Unexpected queue mutation: $statement');
            }
          }
          return null;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(sqlite, null));
      ProviderContainer scope() => ProviderContainer(
        overrides: [settingsProvider.overrideWith(_Settings.new)],
      );

      final container = scope();
      final queue = container.read(downloadQueueProvider.notifier);
      await started.future;
      expect(container.read(downloadQueueProvider).items, isEmpty);
      var flushed = false;
      final background = queue.flushQueuePersistence().then(
        (_) => flushed = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(flushed, false);
      expect([writes, deletes], [0, 0]);
      release.complete();
      await background;
      expect(
        container.read(downloadQueueProvider).items.map((item) => item.id),
        items.map((item) => item.id),
      );
      expect(rows.keys, items.map((item) => item.id));
      expect(
        [writes, deletes],
        [0, 0],
        reason:
            'restored canonical rows must survive the first background flush',
      );
      expect(queueReads, 1);
      container.dispose();

      // Disposal completes the restore gate but must not access provider state
      // or persist an empty snapshot after ownership has ended.
      started = Completer();
      release = Completer();
      final disposed = scope();
      final disposedQueue = disposed.read(downloadQueueProvider.notifier);
      await started.future;
      final pending = disposedQueue.flushQueuePersistence();
      disposed.dispose();
      await pending;
      expect(rows.keys, items.map((item) => item.id));
      expect([writes, deletes], [0, 0]);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await (await AppStateDatabase.instance.database).close();
    },
  );
}
