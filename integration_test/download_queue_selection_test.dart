import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/models/download_item.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/app_state_database.dart';

import '../test/support/playlist_batch_benchmark.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _Settings extends SettingsNotifier {
  _Settings(this._directory);
  final String _directory;
  @override
  AppSettings build() => AppSettings(
    downloadDirectory: _directory,
    filenameFormat: '{track} - {title}',
    singleFilenameFormat: '{title}',
    allowQualityVariants: true,
    networkDownloadFolder: 'smb://example.test/music',
  );
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'note':
        'Five alternating pairs of synchronous enqueue on the real notifier, paused during startup. Restore and persistence use private platform SQLite and are verified outside timing. Not download speed or FPS.',
  };
  var completed = 0;
  late Directory root;
  late Database db;
  late PathProviderPlatform originalPaths;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('queue-selection-');
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    SharedPreferences.setMockInitialValues({
      'app_state_migrated_queue_to_sqlite_v1': true,
      'download_queue_user_paused_v1': true,
    });
    db = await AppStateDatabase.instance.database;
    expect(db.path, '${root.path}/app_state.db');
  });
  tearDownAll(() async {
    await db.close();
    PathProviderPlatform.instance = originalPaths;
    await root.delete(recursive: true);
    report['completed_cases'] = completed;
    binding.reportData ??= {};
    binding.reportData!['queue_selection'] = report;
  });

  ProviderContainer scope() => ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(() => _Settings(root.path)),
      extensionProvider.overrideWith(_Extensions.new),
    ],
  );

  for (final count in [1000, 2000]) {
    testWidgets('enqueue $count individual tracks in one selection', (
      tester,
    ) async {
      final tracks = await playlistBatchFixture(count);
      final old = DownloadItem(
        id: 'persisted',
        track: tracks.first,
        service: 'example',
        createdAt: DateTime.utc(2026),
        fromBatch: true,
        qualityOverride: 'LOSSLESS',
      );
      final samples = <String, List<Map<String, int>>>{
        'single': [],
        'selection': [],
      };
      for (var sample = 0; sample < 5; sample++) {
        for (final bulk in sample.isEven ? [false, true] : [true, false]) {
          await db.delete('download_queue_items');
          final stamp = old.createdAt.toIso8601String();
          await db.insert('download_queue_items', {
            'id': old.id,
            'item_json': jsonEncode(old.toJson()),
            'status': 'queued',
            'created_at': stamp,
            'updated_at': stamp,
          });
          final container = scope();
          try {
            final queue = container.read(downloadQueueProvider.notifier);
            queue.pauseQueue(persistAcrossRestarts: false);
            var publications = 0;
            final subscription = container.listen(
              downloadQueueProvider,
              (_, _) => publications++,
            );
            final timer = Stopwatch()..start();
            if (bulk) {
              queue.addIndividualTracksToQueue(tracks, ' example ');
            } else {
              for (final track in tracks) {
                queue.addToQueue(track, ' example ');
              }
            }
            timer.stop();
            subscription.close();
            samples[bulk ? 'selection' : 'single']!.add({
              'microseconds': timer.elapsedMicroseconds,
              'publications': publications,
            });
            expect(publications, bulk ? 1 : count * 2);
            final early = container.read(downloadQueueProvider).items.toList();
            expect(early, hasLength(count));
            await queue.flushQueuePersistence();
            final state = container.read(downloadQueueProvider);
            expect(state.isPaused, true);
            expect(state.isProcessing, false);
            expect(state.items, hasLength(count + 1));
            expect(
              jsonEncode(state.items.first.toJson()),
              jsonEncode(old.toJson()),
            );
            expect(
              state.items.map((item) => item.id).toSet(),
              hasLength(count + 1),
            );
            final rows = await AppStateDatabase.instance
                .getPendingDownloadQueueRows();
            expect(
              rows.map((row) => row['id']),
              state.items.map((item) => item.id),
            );
            for (var i = 0; i < count; i++) {
              final item = state.items[i + 1];
              expect(item, same(early[i]));
              expect(item.track, same(tracks[i]));
              expect(item.fromBatch, false);
              expect(item.service, 'example');
              expect(item.preserveQualityVariant, true);
              expect(item.networkDownloadFolder, 'smb://example.test/music');
              expect(item.playlistName, isNull);
              expect(item.playlistPosition, isNull);
              expect(
                jsonDecode(rows[i + 1]['item_json'] as String),
                jsonDecode(jsonEncode(item.toJson())),
              );
            }
          } finally {
            container.dispose();
          }
        }
      }
      report['tracks_$count'] = samples;
      completed++;
    });
  }

  testWidgets('selection persistence rolls back and retries all rows', (
    tester,
  ) async {
    await db.delete('download_queue_items');
    final tracks = await playlistBatchFixture(300);
    await db.execute(
      r'''CREATE TRIGGER fail_selection BEFORE INSERT ON download_queue_items
      WHEN json_extract(NEW.item_json, '$.track.id') = '129'
      BEGIN SELECT RAISE(ABORT, 'fixture row failure'); END''',
    );
    final container = scope();
    try {
      final queue = container.read(downloadQueueProvider.notifier);
      queue.pauseQueue(persistAcrossRestarts: false);
      queue.addIndividualTracksToQueue(tracks, 'example');
      final early = container.read(downloadQueueProvider).items;
      // Queue persistence reports errors through its logger and retains the
      // previous durable snapshot so the next explicit flush can retry.
      await queue.flushQueuePersistence();
      expect(await db.query('download_queue_items'), isEmpty);
      expect(container.read(downloadQueueProvider).items, early);
      await db.execute('DROP TRIGGER fail_selection');
      await queue.flushQueuePersistence();
      final rows = await AppStateDatabase.instance
          .getPendingDownloadQueueRows();
      expect(rows.map((row) => row['id']), early.map((item) => item.id));
      expect(container.read(downloadQueueProvider).isPaused, true);
    } finally {
      await db.execute('DROP TRIGGER IF EXISTS fail_selection');
      container.dispose();
    }
    completed++;
  });
}
