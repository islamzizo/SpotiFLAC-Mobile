import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/download_item.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';

const _settings = AppSettings(
  downloadDirectory: '/fixture/output',
  filenameFormat: '{track} - {title}',
  singleFilenameFormat: '{title}',
  audioQuality: 'HIGH',
  autoFallback: false,
  allowQualityVariants: true,
  networkDownloadFolder: 'smb://example.test/music',
);
const _tracks = [
  Track(
    id: 'example:one',
    name: 'First — 音楽',
    artistName: 'Artist & Guest',
    albumArtist: 'Artist & Guest',
    albumName: 'Album',
    duration: 180,
    isrc: 'XX0000000001',
    genre: 'Rock',
  ),
  Track(
    id: 'example:two',
    name: 'Second',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 200,
    trackNumber: 2,
  ),
];

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => _settings;
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'replacement',
        name: 'replacement',
        displayName: 'Replacement',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
        capabilities: {
          'replacesBuiltInProviders': ['example'],
        },
      ),
    ],
  );
}

class _Queue extends DownloadQueueNotifier {
  _Queue(this._initial);
  final DownloadQueueState _initial;

  @override
  DownloadQueueState build() {
    // Keep the real restore/dispose gate. Tests dispose synchronously before
    // its startup microtask, so no storage or network is used here.
    super.build();
    return _initial;
  }
}

Map<String, dynamic> _stableItem(DownloadItem item) => item.toJson()
  ..remove('id')
  ..remove('createdAt');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer scope(DownloadQueueState initial) => ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(_Settings.new),
      extensionProvider.overrideWith(_Extensions.new),
      downloadQueueProvider.overrideWith(() => _Queue(initial)),
    ],
  );

  for (final processing in [false, true]) {
    test('selection matches individual requests (processing: $processing)', () {
      final existing = DownloadItem(
        id: 'existing',
        track: _tracks.first,
        service: 'example',
        createdAt: DateTime.utc(2026),
        qualityOverride: 'LOSSLESS',
        fromBatch: true,
      );
      final initial = const DownloadQueueState().copyWith(
        items: [existing],
        isPaused: true,
        isProcessing: processing,
        currentDownload: processing ? existing : null,
      );
      final baseline = scope(initial);
      final selection = scope(initial);
      try {
        final tracks = [..._tracks, _tracks.first];
        final singles = baseline.read(downloadQueueProvider.notifier);
        for (final track in tracks) {
          singles.addToQueue(track, ' example ');
        }
        final queue = selection.read(downloadQueueProvider.notifier);
        var publications = 0;
        selection.listen(downloadQueueProvider, (_, _) => publications++);
        final before = DateTime.now();
        queue.addIndividualTracksToQueue(tracks, ' example ');
        final after = DateTime.now();
        final state = selection.read(downloadQueueProvider);
        final expected = baseline.read(downloadQueueProvider);
        expect(state.items.map(_stableItem), expected.items.map(_stableItem));
        expect(publications, 1);
        expect(state.items.first, same(existing));
        expect(state.items.map((item) => item.id).toSet(), hasLength(4));
        expect(state.isPaused, true);
        expect(state.isProcessing, processing);
        expect(state.currentDownload, same(initial.currentDownload));
        expect(state.outputDir, expected.outputDir);
        expect(state.filenameFormat, expected.filenameFormat);
        expect(state.singleFilenameFormat, expected.singleFilenameFormat);
        expect(state.audioQuality, expected.audioQuality);
        expect(state.autoFallback, expected.autoFallback);
        for (var i = 0; i < tracks.length; i++) {
          final item = state.items[i + 1];
          expect(item.track, same(tracks[i]));
          expect(item.service, 'replacement');
          expect(item.fromBatch, false);
          expect(item.qualityOverride, isNull);
          expect(item.playlistName, isNull);
          expect(item.playlistPosition, isNull);
          expect(item.createdAt.isBefore(before), false);
          expect(item.createdAt.isAfter(after), false);
        }
        tracks.clear();
        expect(state.items, hasLength(4));
        queue.addIndividualTracksToQueue([_tracks.first], 'example');
        expect(selection.read(downloadQueueProvider).items, hasLength(5));
        expect(
          selection
              .read(downloadQueueProvider)
              .items
              .map((item) => item.id)
              .toSet(),
          hasLength(5),
        );
      } finally {
        selection.dispose();
        baseline.dispose();
      }
    });
  }

  test('empty selection does not publish or change settings', () {
    const initial = DownloadQueueState(outputDir: '/old');
    final container = scope(initial);
    try {
      final queue = container.read(downloadQueueProvider.notifier);
      var publications = 0;
      container.listen(downloadQueueProvider, (_, _) => publications++);
      queue.addIndividualTracksToQueue([], 'example');
      expect(container.read(downloadQueueProvider), same(initial));
      expect(publications, 0);
    } finally {
      container.dispose();
    }
  });

  test(
    'album batches still normalize credits and retain playlist positions',
    () {
      final container = scope(const DownloadQueueState(isPaused: true));
      try {
        container
            .read(downloadQueueProvider.notifier)
            .addMultipleToQueue(
              _tracks,
              ' example ',
              qualityOverride: 'LOSSLESS',
              playlistName: 'Playlist',
              playlistPositions: [7, null],
            );
        final items = container.read(downloadQueueProvider).items;
        expect(items.map((item) => item.track.albumArtist), [
          'Artist',
          'Artist',
        ]);
        expect(items.map((item) => item.fromBatch), everyElement(true));
        expect(
          items.map((item) => item.qualityOverride),
          everyElement('LOSSLESS'),
        );
        expect(items.map((item) => item.playlistPosition), [7, 2]);
      } finally {
        container.dispose();
      }
    },
  );
}
