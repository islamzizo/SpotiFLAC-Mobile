import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/network_storage_service.dart';
import 'package:spotiflac_android/services/network_metadata_service.dart';

void main() {
  late NetworkStorageService storage;
  late Directory directory;
  setUp(() async {
    storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
    );
    await storage.save(
      const NetworkConnection(
        id: 'nas',
        name: 'NAS',
        protocol: NetworkProtocol.http,
        address: 'https://nas.test/music/',
      ),
    );
    directory = await Directory.systemTemp.createTemp('network-tag-test-');
  });
  tearDown(() async {
    await storage.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'playback and Lyrics share one read and embedded cover is cached as a file',
    () async {
      var calls = 0;
      final gate = Completer<Map<String, dynamic>>();
      final reader = NetworkMetadataService(
        storage: storage,
        cacheDirectory: () async => directory,
        reader: (url, name) {
          calls++;
          expect(url, startsWith('http://127.0.0.1:'));
          expect(name, 'Song #1.flac');
          return gate.future;
        },
      );
      final source = NetworkStorageService.source('nas', 'Song #1.flac');
      final a = reader.read(source);
      final b = reader.read(source);
      gate.complete({
        'title': 'Title',
        'lyrics': '[00:01.00]Hello',
        'cover_base64': base64Encode([1, 2, 3]),
      });
      final tags = await a;
      expect(await b, tags);
      expect(calls, 1);
      expect(tags['lyrics'], '[00:01.00]Hello');
      expect(tags.containsKey('cover_base64'), false);
      expect(await File(tags['cover_path'] as String).readAsBytes(), [1, 2, 3]);
      await reader.read(source);
      expect(calls, 1);
    },
  );

  test('rescans can refresh tags without reusing the playback cache', () async {
    var calls = 0;
    final reader = NetworkMetadataService(
      storage: storage,
      reader: (_, _) async => {'title': 'Revision ${++calls}'},
    );
    final source = NetworkStorageService.source('nas', 'song.flac');
    expect((await reader.read(source))['title'], 'Revision 1');
    expect((await reader.read(source))['title'], 'Revision 1');
    expect(
      (await reader.read(source, forceRefresh: true))['title'],
      'Revision 2',
    );
    expect(calls, 2);
  });

  test(
    'a failed read is retryable and corrupt artwork does not discard lyrics',
    () async {
      var calls = 0;
      final reader = NetworkMetadataService(
        storage: storage,
        cacheDirectory: () async => directory,
        reader: (_, name) async {
          if (++calls == 1) return {'error': 'offline'};
          return {'lyrics': 'Plain lyrics', 'cover_base64': 'invalid base64!'};
        },
      );
      final source = NetworkStorageService.source('nas', 'song.mp3');
      await expectLater(reader.read(source), throwsStateError);
      expect((await reader.read(source))['lyrics'], 'Plain lyrics');
      expect(calls, 2);
    },
  );

  test(
    'direct HTTP connection supplies the real filename as a native hint',
    () async {
      await storage.save(
        const NetworkConnection(
          id: 'direct',
          name: 'Single',
          protocol: NetworkProtocol.http,
          address: 'https://nas.test/song.m4a',
        ),
      );
      final reader = NetworkMetadataService(
        storage: storage,
        reader: (_, name) async {
          expect(name, 'song.m4a');
          return {'title': 'Song'};
        },
      );
      expect(
        (await reader.read(
          NetworkStorageService.source('direct', ''),
        ))['title'],
        'Song',
      );
    },
  );
}
