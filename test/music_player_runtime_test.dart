import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/services/app_state_database.dart';
import 'package:spotiflac_android/services/listening_statistics.dart';
import 'package:spotiflac_android/services/music_playback_deck.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/services/playback_notification.dart';

class _Deck implements MusicPlaybackDeck {
  @override
  PlayerState state = PlayerState.stopped;
  final volumes = <double>[];
  Map<String, bool>? outputOptions;
  Duration position = Duration.zero;
  int disposals = 0;

  @override
  bool get isDirect => false;
  @override
  bool get needsSourceReload => false;
  @override
  Stream<PlayerState> get onPlayerStateChanged => const Stream.empty();
  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();
  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();
  @override
  Stream<void> get onPlayerComplete => const Stream.empty();
  @override
  set positionUpdater(PositionUpdater updater) {}
  @override
  Future<void> setReleaseMode(ReleaseMode mode) async {}
  @override
  Future<void> setAudioContext(AudioContext context) async {}
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> cancelPreparation() async {}
  @override
  Future<void> stop() async => state = PlayerState.stopped;
  @override
  Future<void> pause() async => state = PlayerState.paused;
  @override
  Future<void> resume() async => state = PlayerState.playing;
  @override
  Future<void> seek(Duration value) async => position = value;
  @override
  Future<Duration?> getDuration() async => const Duration(seconds: 60);
  @override
  Future<Duration?> getCurrentPosition() async => position;
  @override
  Future<void> dispose() async => disposals++;
  @override
  Future<void> setSource(
    DeviceFileSource source, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
  }) async {
    outputOptions = {
      'bitPerfect': preferBitPerfect,
      'direct': directUsb,
      'dop': allowDop,
      'fixedVolume': allowFixedVolume,
      'exclusive': dapExclusive,
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements AudioSession {
  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {}
  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async => true;
  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      const Stream.empty();
  @override
  Stream<void> get becomingNoisyEventStream => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SessionStore implements AppStateDatabase {
  @override
  Future<void> savePlaybackSession(Map<String, dynamic> session) async {}
  @override
  Future<bool> updatePlaybackSessionState({
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

MusicPlayerRuntime _runtime({
  AppSettings settings = const AppSettings(pauseOnMute: false),
  Future<MusicPlayerHandler> Function(MusicPlayerHandler Function())?
  initialize,
  List<_Deck>? decks,
  MusicPlaybackDeck Function(String)? createDeck,
  Stream<double> volumeChanges = const Stream.empty(),
}) {
  final runtime = MusicPlayerRuntime(
    settings: settings,
    dependencies: PlaybackDependencies(
      createDeck:
          createDeck ??
          (_) {
            final deck = _Deck();
            decks?.add(deck);
            return deck;
          },
      audioSession: () async => _Session(),
      initializeHandler: initialize ?? (builder) async => builder(),
      readMetadata: (_, {displayName}) async => {
        'replaygain_track_gain': '-6 dB',
      },
      sessionDatabase: _SessionStore(),
      recorder: ListeningRecorder(
        write: (_) async {},
        elapsed: () => Duration.zero,
        now: () => DateTime(2026),
      ),
      volumeChanges: volumeChanges,
      isAndroid: false,
      isIOS: false,
    ),
  );
  addTearDown(runtime.dispose);
  return runtime;
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

const _item = MediaItem(id: 'one', title: 'One');
const _track = PlayableMedia(
  id: 'one',
  source: '/one.flac',
  title: 'One',
  artist: 'Artist',
  duration: Duration(seconds: 60),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pre-init events have empty values and cancellation never waits for init',
    () async {
      var calls = 0;
      final runtime = _runtime(
        initialize: (builder) async {
          calls++;
          return builder();
        },
      );
      final items = <MediaItem?>[];
      final queues = <List<MediaItem>>[];
      final states = <PlaybackState>[];
      final itemEvents = runtime.mediaItemEvents().listen(items.add);
      final queueEvents = runtime.queueEvents().listen(queues.add);
      final stateEvents = runtime.playbackStateEvents().listen(states.add);
      await _settle();

      expect(items, [null]);
      expect(queues, [isEmpty]);
      expect(states, isEmpty);
      await Future.wait([
        itemEvents.cancel(),
        queueEvents.cancel(),
        stateEvents.cancel(),
      ]).timeout(const Duration(seconds: 1));
      expect(calls, 0);
      await runtime.initialize();
      await _settle();
      expect(items, [null]);
      expect(queues, [isEmpty]);
      expect(states, isEmpty);
    },
  );

  test(
    'pending init is deduplicated and uses the latest live configuration',
    () async {
      final ready = Completer<MusicPlayerHandler>();
      final volume = StreamController<double>.broadcast();
      addTearDown(volume.close);
      var calls = 0;
      late MusicPlayerHandler created;
      final runtime = _runtime(
        volumeChanges: volume.stream,
        initialize: (builder) {
          calls++;
          created = builder();
          return ready.future;
        },
      );
      final items = <MediaItem?>[];
      final events = runtime.mediaItemEvents().listen(items.add);
      addTearDown(events.cancel);
      runtime.configure(runtime.settings.copyWith(autoMix: true));
      final first = runtime.initialize();
      expect(runtime.initialize(), same(first));
      await _settle();
      expect(calls, 1);
      expect(runtime.handler, isNull);
      expect(volume.hasListener, isFalse);
      runtime.configure(runtime.settings.copyWith(pauseOnMute: true));
      created.mediaItem.add(_item);
      await _settle();
      expect(volume.hasListener, isTrue);
      expect(items, [null]);
      ready.complete(created);
      expect(await first, same(created));
      expect(await runtime.initialize(), same(created));
      await _settle();
      expect(items, [null, _item]);
      expect(calls, 1);
      expect(runtime.settings.autoMix, isTrue);
      await runtime.dispose();
      expect(volume.hasListener, isFalse);
    },
  );

  test('failed initialization releases its handler and can retry', () async {
    var calls = 0;
    final decks = <_Deck>[];
    final runtime = _runtime(
      decks: decks,
      initialize: (builder) async {
        final handler = builder();
        if (++calls == 1) throw StateError('Initialization failed');
        return handler;
      },
    );
    await expectLater(runtime.initialize(), throwsStateError);
    expect(runtime.handler, isNull);
    expect(decks.single.disposals, 1);
    final retried = await runtime.initialize();
    expect(runtime.handler, same(retried));
    expect(calls, 2);
    await runtime.dispose();
    expect(decks.map((deck) => deck.disposals), [1, 1]);
  });

  test(
    'deck construction failure leaves no partial handler and can retry',
    () async {
      var calls = 0;
      final deck = _Deck();
      final runtime = _runtime(
        createDeck: (_) {
          if (++calls == 1) throw StateError('Deck creation failed');
          return deck;
        },
      );
      await expectLater(runtime.initialize(), throwsStateError);
      expect(runtime.handler, isNull);
      final handler = await runtime.initialize();
      expect(runtime.handler, same(handler));
      expect(calls, 2);
      await runtime.dispose();
      expect(deck.disposals, 1);
    },
  );

  test('an initializer returning a disposed handler can retry', () async {
    var calls = 0;
    final runtime = _runtime(
      initialize: (builder) async {
        final handler = builder();
        if (++calls == 1) await handler.dispose();
        return handler;
      },
    );
    await expectLater(runtime.initialize(), throwsStateError);
    final handler = await runtime.initialize();
    expect(runtime.handler, same(handler));
    expect(handler.isDisposed, isFalse);
    expect(calls, 2);
  });

  test(
    'runtime disposal retires a pending handler and closes its events',
    () async {
      final ready = Completer<MusicPlayerHandler>();
      final decks = <_Deck>[];
      late MusicPlayerHandler created;
      final runtime = _runtime(
        decks: decks,
        initialize: (builder) {
          created = builder();
          return ready.future;
        },
      );
      final closed = Completer<void>();
      final events = runtime.mediaItemEvents().listen(
        (_) {},
        onDone: closed.complete,
      );
      addTearDown(events.cancel);
      final pending = runtime.initialize();
      final failed = expectLater(pending, throwsStateError);
      await _settle();
      final disposed = runtime.dispose();
      expect(runtime.dispose(), same(disposed));
      expect(created.isDisposed, isTrue);
      expect(runtime.handler, isNull);
      ready.complete(created);
      await failed;
      await disposed;
      await closed.future.timeout(const Duration(seconds: 1));
      expect(decks.single.disposals, 1);
      await expectLater(runtime.initialize(), throwsStateError);
    },
  );

  test(
    'a delayed builder cannot create playback resources after disposal',
    () async {
      final build = Completer<void>();
      final decks = <_Deck>[];
      final runtime = _runtime(
        decks: decks,
        initialize: (builder) async {
          await build.future;
          return builder();
        },
      );
      final failed = expectLater(runtime.initialize(), throwsStateError);
      await _settle();
      final disposed = runtime.dispose();
      build.complete();
      await failed;
      await disposed;
      expect(runtime.handler, isNull);
      expect(decks, isEmpty);
    },
  );

  test(
    'event subscribers follow a replacement and ignore the retired handler',
    () async {
      final runtime = _runtime();
      final items = <MediaItem?>[];
      final queues = <List<MediaItem>>[];
      final itemEvents = runtime.mediaItemEvents().listen(items.add);
      final queueEvents = runtime.queueEvents().listen(queues.add);
      addTearDown(itemEvents.cancel);
      addTearDown(queueEvents.cancel);
      final first = await runtime.initialize();
      first.mediaItem.add(_item);
      first.queue.add([_item]);
      await _settle();
      expect(items.last, _item);
      expect(queues.last, [_item]);
      await first.dispose();
      await _settle();
      expect(items.last, isNull);
      expect(queues.last, isEmpty);
      first.mediaItem.add(const MediaItem(id: 'stale', title: 'Stale'));
      first.queue.add([_item]);
      final second = await runtime.initialize();
      const replacement = MediaItem(id: 'two', title: 'Two');
      second.mediaItem.add(replacement);
      second.queue.add([replacement]);
      await _settle();
      expect(items.last, replacement);
      expect(queues.last, [replacement]);
      expect(items.whereType<MediaItem>().map((item) => item.id), [
        'one',
        'two',
      ]);
    },
  );

  test(
    'provider scopes isolate transport settings and notification favorites',
    () async {
      final firstDecks = <_Deck>[];
      final secondDecks = <_Deck>[];
      final first = _runtime(
        decks: firstDecks,
        settings: const AppSettings(
          pauseOnMute: false,
          playbackNormalization: true,
        ),
      );
      final second = _runtime(
        decks: secondDecks,
        settings: const AppSettings(
          pauseOnMute: false,
          usbBitPerfect: true,
          usbDirect: true,
          usbDsdOverPcm: true,
          usbAllowFixedVolume: true,
          dapExclusive: true,
        ),
      );
      final containers = [
        for (final runtime in [first, second])
          ProviderContainer(
            overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
          ),
      ];
      for (final container in containers) {
        addTearDown(container.dispose);
        await container.read(musicPlayerControllerProvider).playSingle(_track);
      }
      expect(firstDecks.single.state, PlayerState.playing);
      expect(secondDecks.single.state, PlayerState.playing);
      expect(firstDecks.single.volumes.last, closeTo(0.501, 0.001));
      expect(secondDecks.single.volumes.last, 1);
      expect(firstDecks.single.outputOptions!.values, everyElement(isFalse));
      expect(secondDecks.single.outputOptions!.values, everyElement(isTrue));
      final toggled = <String>[];
      first.configureNotification(
        presentation: const PlaybackNotification(mornye: true),
        toggleFavorite: (item) async {
          toggled.add('first:${item.id}');
          return true;
        },
      );
      second.configureNotification(
        presentation: const PlaybackNotification(mornye: true),
        toggleFavorite: (item) async {
          toggled.add('second:${item.id}');
          return false;
        },
      );
      await first.handler!.customAction(PlaybackNotification.favoriteAction);
      expect(first.notification.loved, isTrue);
      expect(second.notification.loved, isFalse);
      await second.handler!.customAction(PlaybackNotification.favoriteAction);
      expect(toggled, ['first:one', 'second:one']);
      expect(
        first.handler!.playbackState.value.controls.first.label,
        'Remove from favorites',
      );
      expect(
        second.handler!.playbackState.value.controls.first.label,
        'Favorite',
      );
      first.configure(first.settings.copyWith(playbackNormalization: false));
      await _settle();
      expect(firstDecks.single.volumes.last, 1);
      expect(second.settings.usbBitPerfect, isTrue);
      expect(secondDecks.single.volumes, [1]);
    },
  );
}
