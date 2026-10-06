import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/download_item.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => const DownloadQueueState().copyWith(
    items: [
      DownloadItem(
        id: 'queued',
        track: const Track(
          id: 'example:track',
          name: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 180,
        ),
        service: 'example',
        createdAt: DateTime.utc(2026),
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const connectivity = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );

  tearDown(() {
    messenger.setMockMethodCallHandler(paths, null);
    messenger.setMockMethodCallHandler(connectivity, null);
  });

  test('a failed queue setup releases processing and permits retry', () async {
    var pathAttempts = 0;
    messenger.setMockMethodCallHandler(paths, (_) async {
      pathAttempts++;
      throw PlatformException(code: 'folder_unavailable');
    });
    messenger.setMockMethodCallHandler(connectivity, (_) async => null);
    final queue = _Queue();
    final container = ProviderContainer(
      overrides: [
        downloadQueueProvider.overrideWith(() => queue),
        settingsProvider.overrideWith(_Settings.new),
      ],
    );
    addTearDown(container.dispose);
    var started = false;
    var finished = Completer<void>();
    container.listen(downloadQueueProvider, (previous, next) {
      if (next.isProcessing) started = true;
      if (started && !next.isProcessing && !finished.isCompleted) {
        finished.complete();
      }
    });

    queue.resumePendingDownloadsOnForeground();
    await finished.future;
    final state = container.read(downloadQueueProvider);
    expect(state.isProcessing, isFalse);
    expect(state.currentDownload, isNull);
    expect(state.items.single.status, DownloadStatus.queued);
    expect(pathAttempts, greaterThan(0));

    final firstAttempts = pathAttempts;
    started = false;
    finished = Completer<void>();
    queue.resumePendingDownloadsOnForeground();
    await finished.future;
    expect(pathAttempts, greaterThan(firstAttempts));
    expect(container.read(downloadQueueProvider).isProcessing, isFalse);
  });
}
