import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/player_widget_service.dart';
import 'package:spotiflac_android/services/playback_notification.dart';

class _Player extends BaseAudioHandler {
  final actions = <String>[];

  @override
  Future<void> play() async {
    actions.add('play');
    playbackState.add(playbackState.value.copyWith(playing: true));
  }

  @override
  Future<void> pause() async {
    actions.add('pause');
    playbackState.add(playbackState.value.copyWith(playing: false));
  }

  @override
  Future<void> skipToNext() async => actions.add('next');

  @override
  Future<void> skipToPrevious() async => actions.add('previous');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/player_widget');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PlayerWidgetService service;
  late _Player player;
  late List<Map<Object?, Object?>> updates;
  late Map<String, Completer<PlayerWidgetArtwork?>> images;
  late int installedWidgets;

  Future<void> settle() async {
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  MediaItem item(String id) => MediaItem(
    id: id,
    title: 'Track $id',
    artist: 'Example Artist',
    album: 'Example Album',
    artUri: Uri.file('/artwork/$id.png'),
    extras: const {'source': '/private/music.flac'},
  );

  Future<Object?> nativeEvent(String method, Object? arguments) {
    final result = Completer<Object?>();
    messenger.handlePlatformMessage(
      channel.name,
      channel.codec.encodeMethodCall(MethodCall(method, arguments)),
      (data) {
        try {
          result.complete(channel.codec.decodeEnvelope(data!));
        } catch (error) {
          result.completeError(error);
        }
      },
    );
    return result.future;
  }

  Future<Object?> command(String action) => nativeEvent('command', action);

  setUp(() {
    updates = [];
    images = {};
    installedWidgets = 1;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getInstalledWidgetCount') return installedWidgets;
      if (call.method == 'update') {
        updates.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return null;
    });
    player = _Player();
    service = PlayerWidgetService(
      channel: channel,
      loadArtwork: (uri) async => uri == null
          ? null
          : (images[uri.toString()] ??= Completer<PlayerWidgetArtwork?>())
                .future,
    )..bind(player);
  });

  tearDown(() async {
    await service.dispose();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'no widgets skips artwork and first installed widget loads current cover',
    () async {
      installedWidgets = 0;
      await service.initialize((_) async {});
      player.mediaItem.add(item('one'));
      await settle();
      expect(images, isEmpty);
      expect(updates.last['title'], 'Track one');
      final added = nativeEvent('installedWidgetCountChanged', 1);
      await settle();
      images[item('one').artUri.toString()]!.complete(
        PlayerWidgetArtwork(Uint8List.fromList([1]), 0xff223344),
      );
      await added;
      expect(updates.any((update) => update['artwork'] != null), isTrue);
      final artworkWrites = updates
          .where((update) => update['artwork'] != null)
          .length;
      await player.play();
      await settle();
      expect(
        updates.where((update) => update['artwork'] != null).length,
        artworkWrites,
      );
      await nativeEvent('installedWidgetCountChanged', 0);
      player.mediaItem.add(item('two'));
      await settle();
      expect(images.containsKey(item('two').artUri.toString()), isFalse);
    },
  );

  test(
    'publishes track and transport changes without position tick writes',
    () async {
      player.mediaItem.add(item('one'));
      player.playbackState.add(
        PlaybackState(
          playing: true,
          processingState: AudioProcessingState.ready,
          controls: const [
            MediaControl.skipToPrevious,
            MediaControl.pause,
            MediaControl.skipToNext,
          ],
        ),
      );
      await settle();
      final count = updates.length;
      for (var second = 1; second < 20; second++) {
        player.playbackState.add(
          player.playbackState.value.copyWith(
            updatePosition: Duration(seconds: second),
          ),
        );
      }
      await settle();
      expect(updates.length, count);
      expect(updates.last['title'], 'Track one');
      expect(updates.last['canNext'], isTrue);
      expect(updates.last.toString(), isNot(contains('/private/music.flac')));
      await player.pause();
      await settle();
      expect(updates.last['playing'], isFalse);
      expect(updates.last['canPlay'], isTrue);
    },
  );

  test(
    'late artwork from a previous track cannot replace current artwork',
    () async {
      player.mediaItem.add(item('one'));
      await settle();
      player.mediaItem.add(item('two'));
      await settle();
      images[item('two').artUri.toString()]!.complete(
        PlayerWidgetArtwork(Uint8List.fromList([2]), 0xff223344),
      );
      await settle();
      images[item('one').artUri.toString()]!.complete(
        PlayerWidgetArtwork(Uint8List.fromList([1]), 0xff443322),
      );
      await settle();
      expect(updates.last['id'], 'two');
      expect(updates.last['artwork'], orderedEquals([2]));
      expect(updates.last['background'], 0xff223344);
      expect(
        updates.any(
          (update) =>
              update['id'] == 'two' && update['background'] == 0xff443322,
        ),
        isFalse,
      );
    },
  );

  test('Mornye notification icons do not disable widget transport', () async {
    final media = item('one');
    player.mediaItem.add(media);
    player.playbackState.add(
      PlaybackState(
        controls: const PlaybackNotification(
          mornye: true,
        ).controls(playing: true, item: media),
      ),
    );
    await settle();
    expect(updates.last['canPrevious'], isTrue);
    expect(updates.last['canNext'], isTrue);
  });

  test(
    'clearing playback also removes artwork and disables the player',
    () async {
      player.mediaItem.add(item('one'));
      await settle();
      images[item('one').artUri.toString()]!.complete(
        PlayerWidgetArtwork(Uint8List.fromList([1]), 0xff223344),
      );
      await settle();
      player.mediaItem.add(null);
      await settle();
      expect(updates.last['canPlay'], isFalse);
      expect(updates.last['title'], isEmpty);
      expect(updates.last['artworkKey'], isEmpty);
      expect(updates.last['artwork'], isNull);
    },
  );

  test(
    'commands use the existing handler and finish after publishing state',
    () async {
      player.mediaItem.add(item('one'));
      await service.initialize(
        (action) => PlayerWidgetService.control(player, action),
      );
      expect(await command('toggle'), isTrue);
      expect(updates.last['playing'], isTrue);
      expect(await command('toggle'), isTrue);
      expect(updates.last['playing'], isFalse);
      await command('next');
      await command('previous');
      expect(player.actions, ['play', 'pause', 'next', 'previous']);
      expect(await command('delete'), isFalse);
      expect(player.actions.length, 4);
    },
  );

  test(
    'rapid widget commands remain in order during player initialization',
    () async {
      final startup = Completer<void>();
      await service.initialize((action) async {
        await startup.future;
        await PlayerWidgetService.control(player, action);
      });
      final first = command('play');
      final second = command('pause');
      await settle();
      expect(player.actions, isEmpty);
      startup.complete();
      await Future.wait([first, second]);
      expect(player.actions, ['play', 'pause']);
    },
  );
}
