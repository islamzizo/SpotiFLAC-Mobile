import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/network_download_staging.dart';
import 'package:spotiflac_android/services/network_storage_service.dart';

class _Dav {
  late HttpServer server;
  final files = <String, List<int>>{};
  final folders = <String>{'/music/'};
  final methods = <String>[];
  bool rejectWrites = false;
  bool loseMoveResponse = false;
  int puts = 0;
  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final path = Uri.decodeComponent(r.uri.path);
      methods.add(r.method);
      if (r.headers.value('authorization') !=
          'Basic ${base64Encode(utf8.encode('user:secret'))}') {
        r.response.statusCode = 401;
        await r.response.close();
        return;
      }
      switch (r.method) {
        case 'PROPFIND':
          if (!folders.contains(path)) {
            r.response.statusCode = 404;
            break;
          }
          r.response.statusCode = 207;
          r.response.write('<d:multistatus xmlns:d="DAV:">');
          for (final name in [...folders, ...files.keys]) {
            if (!name.startsWith(path) || name == path) continue;
            final tail = name
                .substring(path.length)
                .replaceFirst(RegExp(r'/$'), '');
            if (tail.contains('/')) continue;
            final href = Uri(path: name).toString().replaceAll('&', '&amp;');
            r.response.write(
              '<d:response><d:href>$href</d:href><d:propstat><d:prop>'
              '<d:resourcetype>${folders.contains(name) ? '<d:collection/>' : ''}</d:resourcetype>'
              '<d:getcontentlength>${files[name]?.length ?? 0}</d:getcontentlength>'
              '</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>',
            );
          }
          r.response.write('</d:multistatus>');
        case 'MKCOL':
          r.response.statusCode = folders.add(path) ? 201 : 405;
        case 'PUT':
          if (rejectWrites) {
            r.response.statusCode = 403;
            break;
          }
          puts++;
          try {
            files[path] = await r.fold<List<int>>([], (a, b) => a..addAll(b));
          } on HttpException {
            // A cancelled request may close halfway through its body.
            return;
          }
          r.response.statusCode = 201;
        case 'MOVE':
          final target = Uri.decodeComponent(
            Uri.parse(r.headers.value('destination')!).path,
          );
          expect(r.headers.value('overwrite'), 'F');
          if (files.containsKey(target)) {
            r.response.statusCode = 412;
            break;
          }
          files[target] = files.remove(path)!;
          r.response.statusCode = 201;
          if (loseMoveResponse) {
            loseMoveResponse = false;
            (await r.response.detachSocket(writeHeaders: false)).destroy();
            return;
          }
        case 'DELETE':
          r.response.statusCode = files.remove(path) == null ? 404 : 204;
        case 'GET':
          final bytes = files[path];
          if (bytes == null) {
            r.response.statusCode = 404;
            break;
          }
          r.response.contentLength = bytes.length;
          r.response.add(bytes);
        default:
          r.response.statusCode = 405;
      }
      await r.response.close();
    });
  }
}

void main() {
  late _Dav dav;
  late NetworkStorageService storage;
  late NetworkDownloadStaging staging;
  late Directory temp;
  const folder = 'network://nas/';
  setUp(() async {
    dav = _Dav();
    await dav.start();
    storage = NetworkStorageService(
      read: () async => null,
      write: (_) async {},
    );
    await storage.save(
      NetworkConnection(
        id: 'nas',
        name: 'NAS',
        protocol: NetworkProtocol.webdav,
        address: 'http://127.0.0.1:${dav.server.port}/music/',
        username: 'user',
        password: 'secret',
      ),
    );
    temp = await Directory.systemTemp.createTemp('network-upload-test-');
    staging = NetworkDownloadStaging(
      storage: storage,
      directory: () async => temp,
    );
  });
  tearDown(() async {
    await storage.dispose();
    await dav.server.close(force: true);
    await temp.delete(recursive: true);
  });
  Future<File> prepare({
    String dir = 'Artist/Album/',
    bool lyrics = false,
  }) async {
    final work = await staging.workDirectory('item');
    final audio = await File(
      '${work.path}/Song #1.flac',
    ).writeAsBytes(List.generate(300000, (i) => i % 251));
    if (lyrics) {
      await File('${work.path}/Song #1.lrc').writeAsString('[00:01.00]Lyrics');
    }
    await staging.save('item', {
      'localPath': audio.path,
      'folder': folder,
      'relativeDir': dir,
    });
    return audio;
  }

  Future<String> publish({void Function()? checkpoint}) => staging.publish(
    'item',
    checkpoint: checkpoint ?? () {},
    progress: (_, _) {},
  );

  test(
    'write probe creates and removes its own file; permission errors remain errors',
    () async {
      await storage.checkUploadAccess(folder);
      expect(dav.files, isEmpty);
      dav.rejectWrites = true;
      await expectLater(
        storage.checkUploadAccess(folder),
        throwsA(isA<HttpException>()),
      );
      expect(dav.files, isEmpty);
    },
  );

  test(
    'upload creates nested folders, publishes audio and LRC and retains staging until commit',
    () async {
      final file = await prepare(lyrics: true);
      final destination = await publish();
      expect(Uri.parse(destination).pathSegments.last, 'Song #1.flac');
      expect(
        dav.files['/music/Artist/Album/Song #1.flac'],
        await file.readAsBytes(),
      );
      expect(
        utf8.decode(dav.files['/music/Artist/Album/Song #1.lrc']!),
        '[00:01.00]Lyrics',
      );
      expect(dav.files.keys.any((p) => p.endsWith('.part')), false);
      expect(await file.exists(), true);
      await staging.discard('item');
      expect(await file.exists(), false);
    },
  );

  test(
    'existing name gets a suffix and existing bytes are unchanged',
    () async {
      dav.files['/music/Song #1.flac'] = [9];
      await prepare(dir: '');
      expect(Uri.parse(await publish()).pathSegments.last, 'Song #1 (2).flac');
      expect(dav.files['/music/Song #1.flac'], [9]);
    },
  );

  test(
    'failed write retries finalized local audio after a service restart',
    () async {
      final file = await prepare(dir: '');
      dav.rejectWrites = true;
      await expectLater(publish(), throwsA(isA<HttpException>()));
      expect(await file.exists(), true);
      dav.rejectWrites = false;
      staging = NetworkDownloadStaging(
        storage: storage,
        directory: () async => temp,
      );
      await publish();
      expect(dav.puts, 1);
      expect(dav.files['/music/Song #1.flac'], await file.readAsBytes());
    },
  );

  test('an existing lyrics sidecar also reserves its audio name', () async {
    dav.files['/music/Song #1.lrc'] = utf8.encode('Older lyrics');
    await prepare(dir: '', lyrics: true);
    expect(Uri.parse(await publish()).pathSegments.last, 'Song #1 (2).flac');
    expect(utf8.decode(dav.files['/music/Song #1.lrc']!), 'Older lyrics');
    expect(dav.files.containsKey('/music/Song #1 (2).lrc'), true);
  });

  test(
    'post-processing output is adopted into owned staging before upload',
    () async {
      final output = await File(
        '${temp.path}/converted.m4a',
      ).writeAsBytes([1, 2, 3]);
      await File('${temp.path}/converted.lrc').writeAsString('Lyrics');
      await staging.save('item', {
        'localPath': output.path,
        'folder': folder,
        'relativeDir': '',
      });
      final owned = (await staging.read('item'))!['localPath'] as String;
      expect(owned, isNot(output.path));
      await output.delete();
      await publish();
      expect(dav.files['/music/converted.m4a'], [1, 2, 3]);
      expect(utf8.decode(dav.files['/music/converted.lrc']!), 'Lyrics');
    },
  );

  test(
    'lost MOVE response is reconciled by bytes without duplicate upload',
    () async {
      await prepare(dir: '');
      dav.loseMoveResponse = true;
      await expectLater(publish(), throwsA(anything));
      expect(dav.puts, 1);
      await publish();
      expect(dav.puts, 1);
      expect(dav.files.keys.toList(), ['/music/Song #1.flac']);
    },
  );

  test(
    'same-length conflicting file is never overwritten or adopted',
    () async {
      final file = await prepare(dir: '');
      final data = (await staging.read('item'))!;
      data['target'] = 'network://nas/Song%20%231.flac';
      await staging.save('item', data);
      dav.files['/music/Song #1.flac'] = List.filled(await file.length(), 42);
      await expectLater(publish(), throwsStateError);
      expect(dav.puts, 0);
      expect(dav.files['/music/Song #1.flac']!.first, 42);
    },
  );

  test(
    'cancellation before publish keeps local audio and removes partial file',
    () async {
      final file = await prepare(dir: '');
      await expectLater(
        publish(
          checkpoint: () {
            if (dav.puts > 0) throw StateError('cancelled');
          },
        ),
        throwsStateError,
      );
      expect(await file.exists(), true);
      expect(dav.files, isEmpty);
    },
  );

  test(
    'plain HTTP and traversal cannot be used as write destinations',
    () async {
      await storage.save(
        const NetworkConnection(
          id: 'http',
          name: 'HTTP',
          protocol: NetworkProtocol.http,
          address: 'https://example.test/',
        ),
      );
      await expectLater(
        storage.checkUploadAccess('network://http/'),
        throwsFormatException,
      );
      await expectLater(
        storage.prepareUpload(folder, '../', 'song.flac'),
        throwsFormatException,
      );
      expect(dav.puts, 0);
    },
  );
}
