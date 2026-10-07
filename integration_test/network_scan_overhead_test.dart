import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:spotiflac_android/services/network_library_scanner.dart';
import 'package:spotiflac_android/services/network_storage_service.dart';
import 'package:spotiflac_android/utils/lyrics_metadata_helper.dart';

import '../test/support/library_collections_benchmark.dart';
import '../test/support/lyrics_usability_benchmark.dart';

class _Storage extends NetworkStorageService {
  _Storage(int count)
    : entries = List.generate(
        count,
        (index) => NetworkEntry('$index.flac', '$index.flac'),
      );
  final List<NetworkEntry> entries;

  @override
  Future<NetworkConnection> connection(String id) async => NetworkConnection(
    id: id,
    name: 'Fixture',
    protocol: NetworkProtocol.webdav,
    address: 'https://example.test/music/',
  );

  @override
  Future<List<NetworkEntry>> list(
    NetworkConnection c, [
    String path = '',
  ]) async => entries;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final report = <String, dynamic>{
    'platform': Platform.operatingSystem,
    'note':
        'Controlled metadata callback isolates Dart/filesystem overhead; not live NAS throughput or FPS.',
  };
  var completed = 0;
  tearDownAll(() {
    report['completed_cases'] = completed;
    binding.reportData ??= {};
    binding.reportData!['network_scan_overhead'] = report;
  });

  testWidgets('lyrics usability and file-write component costs', (
    tester,
  ) async {
    final root = await Directory.systemTemp.createTemp('scan-components-');
    try {
      for (final (kind, lyrics, usable) in [
        ('lyrics', lyricsUsabilityFixture(250), true),
        ('metadata', lyricsUsabilityFixture(250, metadataOnly: true), false),
        (
          'late',
          '${lyricsUsabilityFixture(250, metadataOnly: true)}\nWords',
          true,
        ),
      ]) {
        // Warm both code paths before five alternating pairs.
        measureLyricsUsability(
          fullDisplayLyricsUsability,
          lyrics,
          repetitions: 10,
        );
        measureLyricsUsability(hasUsableLyricsContent, lyrics, repetitions: 10);
        final baseline = <Map<String, int>>[];
        final candidate = <Map<String, int>>[];
        for (var index = 0; index < 5; index++) {
          for (final optimized
              in index.isEven ? [false, true] : [true, false]) {
            final result = measureLyricsUsability(
              optimized ? hasUsableLyricsContent : fullDisplayLyricsUsability,
              lyrics,
            );
            expect(result['usable'], usable ? 1000 : 0);
            (optimized ? candidate : baseline).add(result);
          }
        }
        report['${kind}_1000_checks_250_lines'] = {
          'full_display': baseline,
          'current': candidate,
        };
      }
      final file = await File(
        '${root.path}/writes.ndjson',
      ).open(mode: FileMode.write);
      try {
        final row =
            '${jsonEncode({'title': 'Example track', 'artist': 'Example', 'album': 'Album', 'padding': List.filled(300, 'x').join()})}\n';
        final writes = await measureCollectionOperation(() async {
          for (var index = 0; index < 2000; index++) {
            await file.writeString(row);
          }
        });
        report['writes_2000'] = writes.timing;
      } finally {
        await file.close();
      }
      completed++;
    } finally {
      await root.delete(recursive: true);
    }
  });

  for (final latency in [Duration.zero, const Duration(milliseconds: 2)]) {
    testWidgets(
      'scan 400 tracks with controlled metadata (${latency.inMilliseconds} ms)',
      (tester) async {
        final root = await Directory.systemTemp.createTemp('scan-overhead-');
        try {
          final tags = <String, dynamic>{
            'title': 'Example track',
            'artist': 'Artist',
            'album': 'Album',
            'lyrics': lyricsUsabilityFixture(250),
            'audio_codec': 'flac',
            'sample_rate': 44100,
          };
          final samples = <Map<String, int>>[];
          for (var sample = 0; sample < 3; sample++) {
            var metadataMicros = 0;
            var notifications = 0;
            final scanner = NetworkLibraryScanner(
              storage: _Storage(400),
              readMetadata: (_) async {
                final watch = Stopwatch()..start();
                if (latency != Duration.zero) {
                  await Future<void>.delayed(latency);
                }
                metadataMicros += watch.elapsedMicroseconds;
                return tags;
              },
              supportDirectory: () async => root,
              temporaryDirectory: () async => root,
            );
            final result = await measureCollectionOperation(
              () => scanner.scan(
                NetworkStorageService.source('fixture', ''),
                checkpoint: () async {},
                onProgress: (_, _, _) => notifications++,
              ),
            );
            expect(result.value.expectedCount, 400);
            expect(result.value.errorCount, 0);
            expect(notifications, 400);
            final rows = await result.value.rows().toList();
            expect(rows.length, 400);
            expect(rows.every((row) => row['hasLyrics'] == true), isTrue);
            expect(rows.map((row) => row['id']).toSet().length, 400);
            samples.add({
              ...result.timing,
              'metadata_microseconds': metadataMicros,
            });
            await result.value.delete();
          }
          report['scan_${latency.inMilliseconds}ms'] = samples;
          completed++;
        } finally {
          await root.delete(recursive: true);
        }
      },
    );
  }
}
