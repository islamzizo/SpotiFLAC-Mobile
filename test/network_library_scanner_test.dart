import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/network_library_scanner.dart';
import 'package:spotiflac_android/services/network_storage_service.dart';
import 'package:spotiflac_android/services/library_cleanup.dart';
import 'package:spotiflac_android/utils/file_access.dart';
import 'package:spotiflac_android/utils/logger.dart';

class _Storage extends NetworkStorageService {
  _Storage(this.tree, {this.failedFolder});
  final Map<String, List<NetworkEntry>> tree;
  final String? failedFolder;

  @override
  Future<NetworkConnection> connection(String id) async => NetworkConnection(
    id: id,
    name: 'NAS',
    protocol: NetworkProtocol.webdav,
    address: 'https://nas.test/music/',
    username: 'private-user',
    password: 'private-password',
  );

  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection c, [
    String path = '',
  ]) async {
    if (path == failedFolder) throw const SocketException('offline');
    return tree[path] ?? [];
  }
}

void main() {
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('nas-library-test-'),
  );
  tearDown(() async => directory.delete(recursive: true));

  NetworkLibraryScanner scanner(
    _Storage storage,
    Future<Map<String, dynamic>> Function(String) reader,
  ) => NetworkLibraryScanner(
    storage: storage,
    readMetadata: reader,
    supportDirectory: () async => directory,
    temporaryDirectory: () async => directory,
  );

  test(
    'identical artwork shares storage until the last reference is gone',
    () async {
      final shared = await File(
        '${directory.path}/shared.jpg',
      ).writeAsBytes([1, 2]);
      final different = await File(
        '${directory.path}/different.jpg',
      ).writeAsBytes([3]);
      final scan =
          await scanner(
            _Storage({
              '': [
                const NetworkEntry('one.flac', 'one.flac'),
                const NetworkEntry('two.flac', 'two.flac'),
                const NetworkEntry('three.flac', 'three.flac'),
              ],
            }),
            (source) async => {
              'title': 'Track',
              'cover_path': source.endsWith('three.flac')
                  ? different.path
                  : shared.path,
            },
          ).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {},
            onProgress: (_, _, _) {},
          );
      final rows = await scan.rows().toList();
      expect(rows[0]['id'], isNot(rows[1]['id']));
      expect(rows[0]['coverPath'], rows[1]['coverPath']);
      expect(rows[0]['coverPath'], isNot(rows[2]['coverPath']));
      final covers = Directory('${directory.path}/library_covers');
      expect(await covers.list().length, 2);
      // Removing one track retains its sibling's shared cover.
      expect(
        await pruneUnreferencedLibraryCovers(covers, {
          for (final row in rows.skip(1)) row['coverPath'] as String,
        }),
        0,
      );
      expect(
        await pruneUnreferencedLibraryCovers(covers, {
          rows[2]['coverPath'] as String,
        }),
        1,
      );
      expect(await File(rows[2]['coverPath'] as String).readAsBytes(), [3]);
    },
  );

  test(
    'subfolders keep original metadata, stable identities and persistent artwork',
    () async {
      final cover = await File(
        '${directory.path}/transient.jpg',
      ).writeAsBytes([1, 2, 3]);
      final storage = _Storage({
        'albums/': [const NetworkEntry('albums/One/', 'One', directory: true)],
        'albums/One/': [
          const NetworkEntry(
            'albums/One/Title - Artist #1.flac',
            'Title - Artist #1.flac',
          ),
          const NetworkEntry(
            'albums/One/Title - Artist #1.flac',
            'Title - Artist #1.flac',
          ),
          const NetworkEntry('albums/', 'Parent', directory: true),
        ],
      });
      var reads = 0;
      final progress = <int>[];
      final scan =
          await scanner(storage, (source) async {
            reads++;
            expect(
              Uri.parse(source).pathSegments.last,
              'Title - Artist #1.flac',
            );
            return {
              'title': 'Original Title',
              'artist': 'Original Artist',
              'album': 'Original Album',
              'audio_codec': 'flac',
              'bit_depth': 24,
              'sample_rate': 96000,
              'lyrics': '[00:01.00]Words',
              'replaygain_track_gain': '-4 dB',
              'cover_path': cover.path,
            };
          }).scan(
            NetworkStorageService.source('nas', 'albums/'),
            checkpoint: () async {},
            onProgress: (count, errors, name) => progress.add(count),
          );
      final rows = await scan.rows().toList();
      expect(reads, 1);
      expect(progress, [1]);
      expect(scan.errorCount, 0);
      expect(rows.single['albumName'], 'Original Album');
      expect(rows.single['trackName'], 'Original Title');
      expect(rows.single['artistName'], 'Original Artist');
      expect(rows.single['hasLyrics'], true);
      expect(rows.single['replaygain_track_gain'], '-4 dB');
      expect(rows.single['sampleRate'], 96000);
      expect(rows.toString(), isNot(contains('private-password')));
      expect(rows.toString(), isNot(contains('127.0.0.1')));
      await cover.delete();
      expect(await File(rows.single['coverPath'] as String).readAsBytes(), [
        1,
        2,
        3,
      ]);
      await scan.delete();
      expect(await scan.file.exists(), false);
    },
  );

  test(
    'failed folders and tags report partial results instead of deleting old rows',
    () async {
      LogBuffer().clear();
      final storage = _Storage({
        '': [
          const NetworkEntry('offline/', 'Offline', directory: true),
          const NetworkEntry('ok.flac', 'ok.flac'),
          const NetworkEntry('bad.flac', 'bad.flac'),
        ],
      }, failedFolder: 'offline/');
      final scan =
          await scanner(storage, (source) async {
            if (source.endsWith('bad.flac')) {
              return {'metadataFromFilename': true};
            }
            return {'title': 'Valid', 'album': 'Album'};
          }).scan(
            NetworkStorageService.source('nas', ''),
            checkpoint: () async {},
            onProgress: (_, _, _) {},
          );
      expect(scan.errorCount, 2);
      expect(scan.expectedCount, 1);
      expect((await scan.rows().toList()).single['trackName'], 'Valid');
      final errors = LogBuffer().entries.where(
        (entry) => entry.level == 'ERROR',
      );
      expect(errors, hasLength(2));
      expect(errors.any((entry) => entry.message.contains('bad.flac')), isTrue);
      expect(errors.any((entry) => entry.message.contains('offline/')), isTrue);
      expect(errors.first.error, contains('Network tags unavailable'));
    },
  );

  test(
    'root connection failure never produces an empty successful scan',
    () async {
      await expectLater(
        scanner(_Storage({}, failedFolder: ''), (_) async => {}).scan(
          NetworkStorageService.source('nas', ''),
          checkpoint: () async {},
          onProgress: (_, _, _) {},
        ),
        throwsA(isA<SocketException>()),
      );
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test(
    'cancellation removes incomplete output and stops further tag reads',
    () async {
      var cancelled = false;
      var reads = 0;
      await expectLater(
        scanner(
          _Storage({
            '': [
              const NetworkEntry('one.flac', 'one.flac'),
              const NetworkEntry('two.flac', 'two.flac'),
            ],
          }),
          (_) async {
            reads++;
            cancelled = true;
            return {'title': 'One'};
          },
        ).scan(
          NetworkStorageService.source('nas', ''),
          checkpoint: () async {
            if (cancelled) throw StateError('cancelled');
          },
          onProgress: (_, _, _) {},
        ),
        throwsStateError,
      );
      expect(reads, 1);
      expect(
        await Directory('${directory.path}/network_scans').list().toList(),
        isEmpty,
      );
    },
  );

  test(
    'local file checks never delete or classify NAS files as missing',
    () async {
      final path = NetworkStorageService.source('offline', 'Song.flac');
      expect(await fileExists(path), true);
      expect(await fileStat(path), isNotNull);
      expect((await fileExistenceByPath([path]))[path], isNull);
      expect(await deleteFile(path), false);
    },
  );
}
