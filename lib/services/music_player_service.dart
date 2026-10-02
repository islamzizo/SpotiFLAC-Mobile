import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:spotiflac_android/services/playback_notification.dart';
import 'package:spotiflac_android/services/player_widget_service.dart';
import 'package:audio_session/audio_session.dart'
    show AudioSession, AudioSessionConfiguration, AudioInterruptionType;
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/services/app_state_database.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/services/sqlite_helpers.dart'
    show normalizeLookupText;
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/services/playback_normalization.dart';
import 'package:spotiflac_android/services/music_playback_deck.dart';
import 'package:spotiflac_android/services/automix_analysis.dart';
import 'package:spotiflac_android/services/automix_analyzer.dart';
import 'package:spotiflac_android/utils/int_utils.dart';
import 'package:spotiflac_android/utils/ios_container_paths.dart';
import 'package:spotiflac_android/utils/playback_artwork.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:spotiflac_android/utils/string_utils.dart';

part 'music_player_automix.dart';
part 'music_player_autoplay.dart';

final _log = AppLogger('MusicPlayer');

String _playbackUnknownTitle = 'Unknown title';
String _playbackUnknownArtist = 'Unknown artist';

void updateMusicPlayerStrings({
  required String unknownTitle,
  required String unknownArtist,
}) {
  _playbackUnknownTitle = unknownTitle;
  _playbackUnknownArtist = unknownArtist;
}

bool _playbackNormalizationEnabled = false;
bool _autoMixEnabled = false;
bool _usbBitPerfectEnabled = false;
bool _usbDirectEnabled = false;
bool _usbDopEnabled = false;
bool _usbAllowFixedVolume = false;
bool _dapExclusiveEnabled = false;
MusicPlayerHandler? _activeMusicPlayerHandler;
PlaybackNotification _notificationPresentation = const PlaybackNotification();
Future<void> Function(MediaItem)? _toggleNotificationFavorite;
const _notificationChannel = MethodChannel(
  'com.zarz.spotiflac/playback_notification',
);

void configurePlaybackNotification({
  required PlaybackNotification presentation,
  required Future<void> Function(MediaItem) toggleFavorite,
}) {
  _notificationPresentation = presentation;
  _toggleNotificationFavorite = toggleFavorite;
  _activeMusicPlayerHandler?._refreshNotificationControls();
  if (Platform.isIOS) {
    _notificationChannel.setMethodCallHandler((call) async {
      if (call.method == 'favorite') {
        await _activeMusicPlayerHandler?.customAction(
          PlaybackNotification.favoriteAction,
        );
      }
    });
    unawaited(_publishIosNotificationFavorite());
  }
}

Future<void> _publishIosNotificationFavorite() async {
  try {
    await _notificationChannel.invokeMethod<void>('update', {
      'enabled':
          _notificationPresentation.mornye &&
          _notificationPresentation.mediaId != null,
      'loved': _notificationPresentation.loved,
      'label': _notificationPresentation.favoriteLabel,
    });
  } on MissingPluginException {
    // Unit tests do not install the iOS remote-command bridge.
  } on PlatformException catch (error) {
    _log.w('Could not update the system favorite action: ${error.code}');
  }
}

/// Decorative video plugins share AVAudioSession with the music player and
/// may enable mixing while creating a muted cover. Restore music ownership
/// without activating a session when this app is not playing music.
Future<void> restoreMusicAudioSessionAfterVideo() async {
  if (!Platform.isIOS) return;
  final handler = _activeMusicPlayerHandler;
  if (handler == null || handler.mediaItem.value == null) return;
  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  } catch (error) {
    _log.w('Could not restore music audio session after video: $error');
  }
}

/// Enables/disables ReplayGain volume normalization and re-applies it to the
/// track currently playing.
void setPlaybackNormalizationEnabled(bool enabled) {
  if (_playbackNormalizationEnabled == enabled) return;
  _playbackNormalizationEnabled = enabled;
  _activeMusicPlayerHandler?.reapplyNormalization();
}

void setAutoMixEnabled(bool enabled) {
  if (_autoMixEnabled == enabled) return;
  _autoMixEnabled = enabled;
  final handler = _activeMusicPlayerHandler;
  if (handler != null) unawaited(handler._autoMix.cancel());
}

void setUsbBitPerfectEnabled(bool enabled) {
  if (_usbBitPerfectEnabled == enabled) return;
  _usbBitPerfectEnabled = enabled;
  final handler = _activeMusicPlayerHandler;
  if (handler != null) unawaited(handler._autoMix.cancel());
  // Apply at the next source boundary; never raise a playing track's volume.
}

void setUsbOutputOptions({
  required bool direct,
  required bool allowDop,
  bool allowFixedVolume = false,
  bool dapExclusive = false,
}) {
  _usbDirectEnabled = direct;
  _usbDopEnabled = allowDop;
  _usbAllowFixedVolume = allowFixedVolume;
  _dapExclusiveEnabled = dapExclusive;
}

/// Refreshes gain tags after a successful file update, including SAF copies.
void refreshPlaybackNormalization(String source) {
  final handler = _activeMusicPlayerHandler;
  if (handler != null) unawaited(handler._refreshNormalizationSource(source));
}

List<int> buildShuffledQueueOrder({
  required int mediaCount,
  required int currentIndex,
  required Random random,
}) {
  final rest = [
    for (var i = 0; i < mediaCount; i++)
      if (i != currentIndex) i,
  ]..shuffle(random);
  return [
    if (currentIndex >= 0 && currentIndex < mediaCount) currentIndex,
    ...rest,
  ];
}

final AudioContext _musicAudioContext = AudioContext(
  android: const AudioContextAndroid(
    audioFocus: AndroidAudioFocus.none,
    contentType: AndroidContentType.music,
    usageType: AndroidUsageType.media,
    stayAwake: true,
  ),
);

class PlayableMedia {
  final String id;
  final String source;
  final String title;
  final String artist;
  final String album;
  final String? artUri;
  final Duration? duration;
  final int? bitDepth;
  final int? sampleRate;
  final int? bitrate;
  final String? format;
  final bool explicit;
  final String? genre;
  final bool autoplay;

  const PlayableMedia({
    required this.id,
    required this.source,
    required this.title,
    required this.artist,
    this.album = '',
    this.artUri,
    this.duration,
    this.bitDepth,
    this.sampleRate,
    this.bitrate,
    this.format,
    this.explicit = false,
    this.genre,
    this.autoplay = false,
  });

  bool get isContentUri => source.startsWith('content://');

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'title': title,
    'artist': artist,
    'album': album,
    if (artUri != null && artUri!.isNotEmpty) 'artUri': artUri,
    if (duration != null) 'durationMs': duration!.inMilliseconds,
    if (bitDepth != null && bitDepth! > 0) 'bitDepth': bitDepth,
    if (sampleRate != null && sampleRate! > 0) 'sampleRate': sampleRate,
    if (bitrate != null && bitrate! > 0) 'bitrate': bitrate,
    if (format != null && format!.trim().isNotEmpty) 'format': format,
    if (explicit) 'explicit': true,
    if (genre != null) 'genre': genre,
    if (autoplay) 'autoplay': true,
  };

  static PlayableMedia? fromJson(
    Map<String, dynamic> json, {
    String? iosDocumentsPath,
  }) {
    final id = json['id'] as String?;
    final source = json['source'] as String?;
    if (id == null || id.isEmpty || source == null || source.isEmpty) {
      return null;
    }
    final durationMs = (json['durationMs'] as num?)?.toInt();
    var artwork = json['artUri'] as String?;
    if (artwork != null && iosDocumentsPath != null) {
      final uri = Uri.tryParse(artwork);
      if (uri != null && uri.scheme == 'file' && uri.host.isEmpty) {
        try {
          final path = uri.toFilePath();
          final rebased = rebaseIosSandboxPath(path, iosDocumentsPath);
          if (rebased != path) artwork = Uri.file(rebased).toString();
        } on UnsupportedError {
          // Leave malformed or non-local artwork URIs to the image fallback.
        }
      }
    }
    return PlayableMedia(
      id: id,
      source: source,
      title: json['title'] as String? ?? '',
      artist: json['artist'] as String? ?? '',
      album: json['album'] as String? ?? '',
      artUri: artwork,
      duration: (durationMs != null && durationMs > 0)
          ? Duration(milliseconds: durationMs)
          : null,
      bitDepth: readPositiveInt(json['bitDepth']),
      sampleRate: readPositiveInt(json['sampleRate']),
      bitrate: readPositiveInt(json['bitrate']),
      format: json['format']?.toString(),
      explicit: parseExplicitFlag(json['explicit']) == true,
      genre: json['genre'] as String?,
      autoplay: json['autoplay'] == true,
    );
  }

  MediaItem toMediaItem({String? resolvedSource}) {
    return MediaItem(
      id: id,
      title: title.isEmpty ? _playbackUnknownTitle : title,
      artist: artist.isEmpty ? _playbackUnknownArtist : artist,
      album: album.isEmpty ? null : album,
      duration: duration,
      artUri: (artUri != null && artUri!.isNotEmpty)
          ? Uri.tryParse(artUri!)
          : null,
      extras: {
        'source': source,
        if (resolvedSource != null && resolvedSource.isNotEmpty)
          'resolvedSource': resolvedSource,
        if (bitDepth != null && bitDepth! > 0) 'bit_depth': bitDepth,
        if (sampleRate != null && sampleRate! > 0) 'sample_rate': sampleRate,
        if (bitrate != null && bitrate! > 0) 'bitrate': bitrate,
        if (format != null && format!.trim().isNotEmpty)
          'format': format!.trim(),
        if (explicit) 'explicit': true,
        if (autoplay) 'autoplay': true,
      },
    );
  }
}

/// Technical audio metadata carried with a queue item. This is available
/// immediately when tracks change, before a fresh file probe completes.
Map<String, dynamic> playbackAudioMetadataFromMediaItem(MediaItem item) {
  final extras = item.extras;
  if (extras == null || extras.isEmpty) return const {};

  final metadata = <String, dynamic>{};
  final bitDepth = readPositiveInt(extras['bit_depth']);
  final sampleRate = readPositiveInt(extras['sample_rate']);
  final bitrate = readPositiveInt(extras['bitrate']);
  final format = extras['format']?.toString().trim();
  final explicit = parseExplicitFlag(extras['explicit']);
  if (bitDepth != null) metadata['bit_depth'] = bitDepth;
  if (sampleRate != null) metadata['sample_rate'] = sampleRate;
  if (bitrate != null) metadata['bitrate'] = bitrate;
  if (format != null && format.isNotEmpty) metadata['format'] = format;
  if (explicit != null) metadata['explicit'] = explicit;
  return metadata;
}

/// Combines the immediate queue metadata with the richer file probe while
/// retaining known quality fields when a decoder omits or reports them as 0.
Map<String, dynamic> mergePlaybackFileMetadata(
  Map<String, dynamic> fallback,
  Map<String, dynamic> probed,
) {
  final merged = <String, dynamic>{...fallback, ...probed};
  for (final key in const ['bit_depth', 'sample_rate', 'bitrate']) {
    if (readPositiveInt(probed[key]) == null &&
        readPositiveInt(fallback[key]) != null) {
      merged[key] = fallback[key];
    }
  }
  final probedFormat = probed['format']?.toString().trim();
  final fallbackFormat = fallback['format']?.toString().trim();
  if ((probedFormat == null || probedFormat.isEmpty) &&
      fallbackFormat != null &&
      fallbackFormat.isNotEmpty) {
    merged['format'] = fallbackFormat;
  }
  return merged;
}

typedef PlaybackMetadataReader =
    Future<Map<String, dynamic>> Function(String path);

/// Reads playback metadata with a small bounded retry window for transient
/// cold-start/native bridge failures.
///
/// The native bridge reports some read failures as an `error` field instead
/// of throwing. Treat both forms identically so Now Playing does not cache an
/// empty Lyrics view until the route is reopened. A successful response with
/// no lyrics is still final and is never retried.
Future<Map<String, dynamic>> readPlaybackFileMetadataWithRetry(
  String path, {
  PlaybackMetadataReader? reader,
  List<Duration> retryDelays = const [
    Duration.zero,
    Duration(milliseconds: 250),
    Duration(milliseconds: 750),
  ],
}) async {
  final read = reader ?? PlatformBridge.readFileMetadata;
  final delays = retryDelays.isEmpty ? const [Duration.zero] : retryDelays;
  Object? lastError;
  var lastStack = StackTrace.current;

  for (final delay in delays) {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    try {
      final metadata = await read(path);
      final reportedError = metadata['error']?.toString().trim() ?? '';
      if (reportedError.isEmpty) return metadata;
      lastError = StateError(reportedError);
      lastStack = StackTrace.current;
    } catch (error, stack) {
      lastError = error;
      lastStack = stack;
    }
  }

  Error.throwWithStackTrace(
    lastError ?? StateError('Metadata reader returned no result'),
    lastStack,
  );
}

/// Returns a safe source-start position for restored playback. A completed
/// snapshot starts over instead of immediately completing again on resume.
Duration normalizedPlaybackResumePosition(
  Duration position, {
  Duration? duration,
}) {
  if (position <= Duration.zero) return Duration.zero;
  if (duration != null && duration > Duration.zero && position >= duration) {
    return Duration.zero;
  }
  return position;
}

class MusicPlayerHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  MusicPlaybackDeck _player = MusicPlaybackDeck(playerId: 'music-player');
  late final _MusicAutoMix _autoMix;
  late final _MusicAutoplay _autoplay;
  bool _completing = false;
  double _normalizationVolume = 1;
  final _playerSubscriptions =
      <MusicPlaybackDeck, List<StreamSubscription<dynamic>>>{};
  AudioSession? _audioSession;
  final List<PlayableMedia> _media = [];
  final List<MediaItem> _queueItems = [];
  final Map<String, String> _resolvedPathCache = {};
  final Map<String, int> _resolvedPathSizes = {};
  final Map<String, Future<String?>> _pendingSourceResolutions = {};
  final List<String> _resolvedPathOrder = [];
  final Set<String> _pendingResolvedPathDeletes = {};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  int _index = -1;
  int _playRequestGeneration = 0;
  String? _activeResolvedPath;
  bool _disposed = false;
  bool _initialized = false;
  bool _sourceReady = false;
  Future<void>? _activePlayOperation;
  Future<void> _sourceChangeTail = Future<void>.value();
  Timer? _sleepTimer;
  DateTime? _sleepTimerEndsAt;

  bool _shuffle = false;
  List<MediaItem>? _originalQueueOrder;
  int _shuffleRequestGeneration = 0;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;
  final Random _random = Random();
  final List<int> _playHistory = [];

  // True when playback was paused because another app took audio focus.
  bool _pausedByInterruption = false;
  bool _interruptionActive = false;
  bool _userPaused = false;
  // Position saved with the restored session; applied on the first play().
  Duration? _pendingRestorePosition;
  bool _restoringSession = false;
  int _switchingGeneration = 0;
  Duration _lastBroadcastPosition = Duration.zero;
  DateTime? _lastPositionBroadcastAt;
  DateTime? _lastPeriodicPersistAt;
  Future<void> _sessionWriteTail = Future<void>.value();
  int _sessionQueueRevision = 0;
  int _scheduledSessionQueueRevision = -1;
  int _persistedSessionQueueRevision = -1;
  static const Duration _positionBroadcastInterval = Duration(
    milliseconds: 500,
  );
  static const Duration _positionPersistInterval = Duration(seconds: 10);
  static const int _maxResolvedPathCacheEntries = 3;
  static const int _maxResolvedPathCacheBytes = 256 * 1024 * 1024;

  DateTime? get sleepTimerEndsAt => _sleepTimerEndsAt;

  MusicPlayerHandler({
    AutoMixAnalyzer? autoMixAnalyzer,
    AutoplayLibraryLoader? autoplayLibraryLoader,
  }) {
    _autoMix = _MusicAutoMix(this, autoMixAnalyzer ?? AutoMixAnalyzer());
    _autoplay = _MusicAutoplay(
      this,
      autoplayLibraryLoader ?? _loadAutoplayLibrary,
    );
    _activeMusicPlayerHandler = this;
    _init();
  }

  void _init() {
    if (_initialized) return;
    _initialized = true;
    _player.setReleaseMode(ReleaseMode.stop);
    unawaited(_player.setAudioContext(_musicAudioContext));
    unawaited(_configureAudioSession());

    _listenToPlayer(_player);
  }

  void _listenToPlayer(MusicPlaybackDeck player) {
    // Position updates must continue with the display asleep. UI progress is
    // interpolated between updates; querying native playback every frame is
    // unnecessary and would stop preparing AutoMix when there are no frames.
    player.positionUpdater = TimerPositionUpdater(
      interval: const Duration(milliseconds: 200),
      getPosition: player.getCurrentPosition,
    );
    _playerSubscriptions[player] = [
      player.onPlayerStateChanged.listen((state) {
        if (!identical(player, _player)) return;
        if (state == PlayerState.paused && player.needsSourceReload) {
          _userPaused = true;
          _pausedByInterruption = false;
        }
        if (_switchingGeneration != 0 &&
            (state == PlayerState.stopped ||
                state == PlayerState.completed ||
                state == PlayerState.disposed)) {
          return;
        }
        if (state == PlayerState.completed && _shouldIgnoreComplete) {
          if (_userPaused || _interruptionActive) {
            _broadcastState(playerState: PlayerState.paused);
          }
          return;
        }
        _broadcastState(playerState: state);
      }),
      player.onPositionChanged.listen((position) {
        if (identical(player, _player)) _handlePositionChanged(position);
      }),
      player.onDurationChanged.listen((duration) {
        if (!identical(player, _player) || !_sourceReady) return;
        final current = mediaItem.value;
        if (current != null && duration > Duration.zero) {
          mediaItem.add(current.copyWith(duration: duration));
        }
      }),
      player.onPlayerComplete.listen((_) {
        if (identical(player, _player)) unawaited(_handlePlayerComplete());
      }),
    ];
  }

  Future<void> _disposeDeck(MusicPlaybackDeck player) async {
    final subscriptions = _playerSubscriptions.remove(player);
    if (subscriptions == null) return;
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    await player.dispose();
  }

  /// Configures the OS audio session and reacts to interruptions (e.g. another
  /// app like PowerAmp taking audio focus, or headphones unplugged) so playback
  /// pauses and the UI/notification reflect the real state instead of staying
  /// stuck on "playing".
  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      _audioSession = session;
      await session.configure(const AudioSessionConfiguration.music());

      _subscriptions.add(
        session.interruptionEventStream.listen((event) {
          _log.d(
            'Audio interruption ${event.begin ? 'began' : 'ended'} '
            'type=${event.type} player=${_player.state} '
            'playing=${playbackState.value.playing}',
          );
          if (event.begin) {
            if (event.type == AudioInterruptionType.duck) {
              return;
            }

            // Another app took focus or a transient interruption began.
            _interruptionActive = true;
            _pausedByInterruption =
                _player.state == PlayerState.playing ||
                playbackState.value.playing;
            unawaited(_pauseForFocusLoss(reason: 'audio interruption'));
          } else {
            if (event.type == AudioInterruptionType.duck) {
              return;
            }

            // Focus returned; resume only if we paused due to a transient
            // (duck/pause) interruption.
            _interruptionActive = false;
            if (_pausedByInterruption &&
                event.type == AudioInterruptionType.pause) {
              _pausedByInterruption = false;
              unawaited(play());
            } else {
              _pausedByInterruption = false;
            }
          }
        }),
      );

      _subscriptions.add(
        session.becomingNoisyEventStream.listen((_) {
          // Headphones unplugged / output route lost.
          unawaited(_pauseForFocusLoss(reason: 'becoming noisy'));
        }),
      );
    } catch (e) {
      _log.w('Failed to configure audio session: $e');
    }
  }

  bool get _shouldIgnoreComplete =>
      _switchingGeneration != 0 || _interruptionActive || _userPaused;

  Future<void> _pauseForFocusLoss({required String reason}) async {
    _log.i('Pausing internal player because of $reason');
    _playRequestGeneration++;
    _switchingGeneration = 0;
    await _autoMix.cancel();
    try {
      await _player.pause();
    } catch (e) {
      _log.w('Failed to pause after audio focus loss: $e');
    }
    // Force the UI/notification to reflect the pause even if the engine does
    // not emit a state-change event on focus loss.
    _broadcastState(playerState: PlayerState.paused);
    await _persistSession(position: await _currentPositionForPersist());
  }

  void setSleepTimer(Duration duration) {
    if (duration <= Duration.zero) return;
    _sleepTimer?.cancel();
    _sleepTimerEndsAt = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      _sleepTimer = null;
      _sleepTimerEndsAt = null;
      if (_disposed) return;
      _log.i('Sleep timer elapsed; pausing playback');
      unawaited(pause());
    });
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerEndsAt = null;
  }

  Future<void> _activateAudioSession() async {
    try {
      final session = _audioSession ?? await AudioSession.instance;
      _audioSession = session;
      // Other media plugins can change the process-wide iOS category/options
      // after initialization. Mixing makes us ineligible for Now Playing.
      if (Platform.isIOS) {
        await session.configure(const AudioSessionConfiguration.music());
      }
      final granted = await session.setActive(true);
      if (!granted) {
        _log.w('Audio focus request was not granted');
      }
    } catch (e) {
      _log.w('Failed to activate audio session: $e');
    }
  }

  // Required on some Android builds because audio_session manages focus.
  Future<void> _claimHardwareMediaButtons() async {
    if (!Platform.isAndroid) return;
    try {
      await AudioService.androidForceEnableMediaButtons();
    } catch (e) {
      _log.w('Failed to claim Android media-button routing: $e');
    }
  }

  AudioProcessingState _mapProcessingState(PlayerState state) {
    switch (state) {
      case PlayerState.playing:
      case PlayerState.paused:
        return AudioProcessingState.ready;
      case PlayerState.completed:
        return AudioProcessingState.completed;
      case PlayerState.stopped:
      case PlayerState.disposed:
        return AudioProcessingState.idle;
    }
  }

  void _broadcastState({PlayerState? playerState, bool? loading}) {
    final state = playerState ?? _player.state;
    final playing = state == PlayerState.playing;

    playbackState.add(
      playbackState.value.copyWith(
        controls: _notificationPresentation.controls(
          playing: playing,
          item: mediaItem.value,
        ),
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.skipToPrevious,
          MediaAction.skipToNext,
        },
        androidCompactActionIndices: _notificationPresentation.mornye
            ? const [1, 2, 3]
            : const [0, 1, 2],
        processingState: (loading == true)
            ? AudioProcessingState.loading
            : _mapProcessingState(state),
        playing: playing,
        queueIndex: _index >= 0 ? _index : null,
        speed: _autoMix.rate,
        shuffleMode: _shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        repeatMode: _repeatMode,
      ),
    );
  }

  void _refreshNotificationControls() {
    if (_disposed) return;
    final state = playbackState.value;
    playbackState.add(
      state.copyWith(
        // copyWith creates a fresh updateTime; keep the extrapolated position
        // so changing a star or theme cannot pull the scrubber backwards.
        updatePosition: state.position,
        controls: _notificationPresentation.controls(
          playing: state.playing,
          item: mediaItem.value,
        ),
        androidCompactActionIndices: _notificationPresentation.mornye
            ? const [1, 2, 3]
            : const [0, 1, 2],
      ),
    );
  }

  bool _savingNotificationFavorite = false;

  @override
  Future<dynamic> customAction(
    String name, [
    Map<String, dynamic>? extras,
  ]) async {
    if (name == PlaybackNotification.favoriteAction) {
      final item = mediaItem.value;
      if (item == null || _savingNotificationFavorite) return;
      _savingNotificationFavorite = true;
      try {
        await _toggleNotificationFavorite?.call(item);
      } catch (error) {
        _log.w('Notification favorite failed: $error');
      } finally {
        _savingNotificationFavorite = false;
      }
    } else {
      return super.customAction(name, extras);
    }
  }

  void _broadcastPosition(Duration position, {bool force = false}) {
    final now = DateTime.now();
    final lastAt = _lastPositionBroadcastAt;
    final elapsed = lastAt == null ? null : now.difference(lastAt);
    final moved = (position - _lastBroadcastPosition).abs();
    if (!force &&
        elapsed != null &&
        elapsed < _positionBroadcastInterval &&
        moved < _positionBroadcastInterval) {
      return;
    }
    _lastPositionBroadcastAt = now;
    _lastBroadcastPosition = position;
    playbackState.add(
      playbackState.value.copyWith(
        updatePosition: position,
        speed: _autoMix.rate,
      ),
    );
  }

  void _handlePositionChanged(Duration position) {
    if (!_sourceReady || _switchingGeneration != 0) return;
    _broadcastPosition(position);
    _autoMix.onPosition(position);
    unawaited(_autoplay.fill());
    if (_restoringSession ||
        _player.state != PlayerState.playing ||
        _media.isEmpty ||
        _index < 0 ||
        _index >= _media.length) {
      return;
    }

    final now = DateTime.now();
    final lastPersistAt = _lastPeriodicPersistAt;
    if (lastPersistAt != null &&
        now.difference(lastPersistAt) < _positionPersistInterval) {
      return;
    }
    _lastPeriodicPersistAt = now;
    unawaited(_persistSession(position: position));
  }

  final _normalizationCache = PlaybackNormalizationCache(
    readMetadata: PlatformBridge.readFileMetadata,
    onReadError: (error) =>
        _log.w('Failed to read gain tags for normalization: $error'),
  );
  int _normalizationGeneration = 0;

  Future<void> _refreshNormalizationSource(String source) async {
    _normalizationGeneration++;
    _normalizationCache.invalidate(source);
    // A copy started before the edit can still contain the old comments.
    await _pendingSourceResolutions[source];
    final oldPath = _resolvedPathCache.remove(source);
    _resolvedPathSizes.remove(source);
    _resolvedPathOrder.remove(source);
    if (oldPath != null) await _discardResolvedPath(oldPath);
    if (_disposed) return;
    if (_index >= 0 &&
        _index < _media.length &&
        _media[_index].source == source) {
      reapplyNormalization();
    }
  }

  Future<double> _normalizationVolumeFor(
    String path, {
    String? cacheKey,
    String? displayName,
  }) async {
    if (!_playbackNormalizationEnabled ||
        _usbBitPerfectEnabled ||
        _player.isDirect) {
      return 1.0;
    }
    return _normalizationCache.volumeFor(
      path,
      cacheKey: cacheKey,
      displayName: displayName,
    );
  }

  /// Re-applies normalization to the playing track when the setting flips.
  void reapplyNormalization() {
    final index = _index;
    final generation = _playRequestGeneration;
    final normalizationGeneration = ++_normalizationGeneration;
    if (index < 0 || index >= _media.length) return;
    unawaited(() async {
      await _autoMix.cancel();
      if (generation != _playRequestGeneration ||
          index != _index ||
          index >= _media.length ||
          _disposed) {
        return;
      }
      final media = _media[index];
      var resolved = media.isContentUri
          ? _resolvedPathCache[media.source]
          : media.source;
      ContentUriPlaybackLease? playbackLease;
      if (resolved == null && media.isContentUri) {
        try {
          playbackLease = await PlatformBridge.openContentUriPlaybackLease(
            media.source,
          );
          resolved = playbackLease?.path;
        } catch (_) {}
        resolved ??= await _resolveSource(media);
      }
      if (resolved == null) return;
      final volume = await _normalizationVolumeFor(
        resolved,
        cacheKey: media.isContentUri ? media.source : null,
        displayName: playbackLease?.displayName,
      );
      if (playbackLease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
      }
      if (_index != index ||
          generation != _playRequestGeneration ||
          normalizationGeneration != _normalizationGeneration) {
        return;
      }
      try {
        await _player.setVolume(volume);
        _normalizationVolume = volume;
      } catch (e) {
        _log.w('Failed to apply normalization volume: $e');
      }
    }());
  }

  Future<String?> _resolveSource(PlayableMedia media) async {
    if (!media.isContentUri) return media.source;

    final cached = _resolvedPathCache[media.source];
    if (cached != null) {
      if (await File(cached).exists()) return cached;
      _resolvedPathCache.remove(media.source);
      _resolvedPathSizes.remove(media.source);
      _resolvedPathOrder.remove(media.source);
    }
    final inFlight = _pendingSourceResolutions[media.source];
    if (inFlight != null) return inFlight;

    final resolution = () async {
      try {
        final tempPath = await PlatformBridge.copyContentUriToTemp(
          media.source,
        );
        if (tempPath == null || tempPath.isEmpty) return null;
        if (_disposed) {
          await _discardResolvedPath(tempPath);
          return null;
        }

        _resolvedPathCache[media.source] = tempPath;
        _resolvedPathSizes[media.source] = await File(tempPath).length();
        _resolvedPathOrder
          ..remove(media.source)
          ..add(media.source);
        while (_resolvedPathOrder.length > _maxResolvedPathCacheEntries ||
            (_resolvedPathOrder.length > 1 &&
                _resolvedPathSizes.values.fold<int>(
                      0,
                      (sum, size) => sum + size,
                    ) >
                    _maxResolvedPathCacheBytes)) {
          final evictedSource = _resolvedPathOrder.removeAt(0);
          final evictedPath = _resolvedPathCache.remove(evictedSource);
          _resolvedPathSizes.remove(evictedSource);
          if (evictedPath != null) {
            unawaited(_discardResolvedPath(evictedPath));
          }
        }
        return tempPath;
      } catch (e) {
        _log.e('Failed to resolve content URI for playback: $e');
        return null;
      }
    }();
    _pendingSourceResolutions[media.source] = resolution;
    try {
      return await resolution;
    } finally {
      if (identical(_pendingSourceResolutions[media.source], resolution)) {
        _pendingSourceResolutions.remove(media.source);
      }
    }
  }

  Future<void> _discardResolvedPath(String path) async {
    if (path == _activeResolvedPath || _autoMix.pinnedPaths.contains(path)) {
      _pendingResolvedPathDeletes.add(path);
      return;
    }
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      _log.w('Failed to delete SAF playback temp file: $e');
    }
  }

  Future<void> _cleanupPendingResolvedPaths() async {
    final deletable = _pendingResolvedPathDeletes
        .where(
          (path) =>
              path != _activeResolvedPath &&
              !_autoMix.pinnedPaths.contains(path),
        )
        .toList(growable: false);
    for (final path in deletable) {
      _pendingResolvedPathDeletes.remove(path);
      await _discardResolvedPath(path);
    }
  }

  Future<void> _enqueueSessionWrite(Future<void> Function() operation) {
    final queued = _sessionWriteTail.then((_) async {
      try {
        await operation();
      } catch (e) {
        _log.w('Failed to update persisted playback session: $e');
      }
    });
    _sessionWriteTail = queued;
    return queued;
  }

  void _markSessionQueueChanged() {
    _sessionQueueRevision++;
  }

  List<Map<String, dynamic>> _sessionMedia() {
    final original = _originalQueueOrder;
    final ranks = Map<MediaItem, int>.identity();
    if (original != null) {
      for (var i = 0; i < original.length; i++) {
        ranks[original[i]] = i;
      }
    }
    return [
      for (var i = 0; i < _media.length; i++)
        {
          ..._media[i].toJson(),
          'queueOriginalIndex': ranks[_queueItems[i]] ?? i,
        },
    ];
  }

  void _applyQueueOrder(List<MediaItem> order) {
    final current = _index >= 0 && _index < _queueItems.length
        ? _queueItems[_index]
        : null;
    final media = Map<MediaItem, PlayableMedia>.identity();
    for (var i = 0; i < _media.length; i++) {
      media[_queueItems[i]] = _media[i];
    }
    _queueItems
      ..clear()
      ..addAll(order);
    _media
      ..clear()
      ..addAll(order.map((item) => media[item]!));
    _index = current == null
        ? -1
        : order.indexWhere((item) => identical(item, current));
    _playHistory.clear();
    if (_index >= 0) _playHistory.add(_index);
  }

  void _shuffleQueue() {
    _originalQueueOrder ??= List.of(_queueItems);
    final manual = [
      for (var i = 0; i < _media.length; i++)
        if (i == _index || !_media[i].autoplay) i,
    ];
    final order = buildShuffledQueueOrder(
      mediaCount: manual.length,
      currentIndex: manual.indexOf(_index),
      random: _random,
    );
    _applyQueueOrder([
      ...order.map((index) => _queueItems[manual[index]]),
      for (var i = 0; i < _media.length; i++)
        if (i != _index && _media[i].autoplay) _queueItems[i],
    ]);
  }

  void _rememberEnqueued(List<MediaItem> items, {required bool playNext}) {
    final original = _originalQueueOrder;
    if (original == null) return;
    final current = _queueItems[_index];
    final at = original.indexWhere((item) => identical(item, current));
    final firstAutoplay = original.indexWhere(
      (item) => item.extras?['autoplay'] == true && !identical(item, current),
      max(0, at + 1),
    );
    original.insertAll(
      playNext && at >= 0
          ? at + 1
          : firstAutoplay >= 0
          ? firstAutoplay
          : original.length,
      items,
    );
  }

  /// Persists the queue only when it changed. Periodic position updates write
  /// fixed-size scalar columns, avoiding full queue JSON serialization every
  /// ten seconds for large playback sessions.
  Future<void> _persistSession({Duration? position}) {
    if (_restoringSession) return Future<void>.value();
    if (_media.isEmpty || _index < 0 || _index >= _media.length) {
      _scheduledSessionQueueRevision = -1;
      _persistedSessionQueueRevision = -1;
      return _enqueueSessionWrite(
        AppStateDatabase.instance.clearPlaybackSession,
      );
    }
    final queueRevision = _sessionQueueRevision;
    final index = _index;
    final positionMs = (position ?? Duration.zero).inMilliseconds;
    final shuffle = _shuffle;
    final repeatMode = _repeatMode.name;

    if (_scheduledSessionQueueRevision != queueRevision) {
      final media = _sessionMedia();
      _scheduledSessionQueueRevision = queueRevision;
      return _enqueueSessionWrite(() async {
        try {
          await AppStateDatabase.instance.savePlaybackSession({
            'version': 2,
            'media': media,
            'index': index,
            'positionMs': positionMs,
            'shuffle': shuffle,
            'repeat': repeatMode,
          });
          _persistedSessionQueueRevision = queueRevision;
        } catch (_) {
          if (_scheduledSessionQueueRevision == queueRevision) {
            _scheduledSessionQueueRevision = _persistedSessionQueueRevision;
          }
          rethrow;
        }
      });
    }

    return _enqueueSessionWrite(() async {
      final updated = await AppStateDatabase.instance
          .updatePlaybackSessionState(
            index: index,
            positionMs: positionMs,
            shuffle: shuffle,
            repeatMode: repeatMode,
          );
      if (updated) return;
      // A newer queue snapshot is already (or is about to be) scheduled. Do
      // not recreate a missing row from this older scalar snapshot with a
      // mismatched index; the newer full write will restore it consistently.
      if (_sessionQueueRevision != queueRevision) return;

      // Defensive recovery for an externally cleared/corrupted row. This is
      // intentionally the only state-only path that serializes the queue.
      await AppStateDatabase.instance.savePlaybackSession({
        'version': 2,
        'media': _sessionMedia(),
        'index': index,
        'positionMs': positionMs,
        'shuffle': shuffle,
        'repeat': repeatMode,
      });
      _persistedSessionQueueRevision = queueRevision;
    });
  }

  Future<Duration> _currentPositionForPersist() async {
    // During restore/source preparation the engine may report a stale zero (or
    // the previous source). The broadcast position already represents the
    // intended start point for the current queue item.
    if (!_sourceReady) return playbackState.value.position;
    try {
      final position = await _player.getCurrentPosition();
      if (position != null) return position;
    } catch (_) {}
    return playbackState.value.position;
  }

  /// Flushes the live engine position and every older queued session write.
  /// Called when the app leaves the foreground so a normal restart resumes at
  /// the latest audible point rather than the beginning of the track.
  Future<void> persistCurrentSession() async {
    if (_media.isEmpty || _index < 0 || _index >= _media.length) return;
    final position = await _currentPositionForPersist();
    _lastPeriodicPersistAt = DateTime.now();
    await _persistSession(position: position);
  }

  /// Restores a persisted session paused: queue and current track become
  /// visible (mini player included) without loading any source; the first
  /// play() prepares the source directly at the saved position.
  Future<void> restoreSession({
    required List<PlayableMedia> items,
    required int index,
    required Duration position,
    required bool shuffle,
    List<int>? originalOrder,
    bool queueNeedsRewrite = false,
    AudioServiceRepeatMode repeatMode = AudioServiceRepeatMode.none,
  }) async {
    if (items.isEmpty) return;
    // Never clobber a session the user already started this launch.
    if (_media.isNotEmpty || _index >= 0) return;
    _restoringSession = true;
    try {
      _media
        ..clear()
        ..addAll(items);
      _queueItems
        ..clear()
        ..addAll(items.map((m) => m.toMediaItem()));
      _index = index.clamp(0, items.length - 1);
      _shuffle = shuffle;
      if (shuffle) {
        final order = [for (var i = 0; i < items.length; i++) i];
        if (originalOrder?.length == items.length) {
          order.sort((a, b) => originalOrder![a].compareTo(originalOrder[b]));
        }
        _originalQueueOrder = order.map((i) => _queueItems[i]).toList();
      }
      _repeatMode = repeatMode;
      _pendingRestorePosition = position > Duration.zero ? position : null;
      _sourceReady = false;
      _lastPeriodicPersistAt = null;
      _sessionQueueRevision++;
      if (queueNeedsRewrite) {
        _scheduledSessionQueueRevision = -1;
        _persistedSessionQueueRevision = -1;
      } else {
        _scheduledSessionQueueRevision = _sessionQueueRevision;
        _persistedSessionQueueRevision = _sessionQueueRevision;
      }
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      mediaItem.add(_media[_index].toMediaItem());
      if (position > Duration.zero) {
        playbackState.add(
          playbackState.value.copyWith(updatePosition: position),
        );
      }
      _broadcastState(playerState: PlayerState.paused);
    } finally {
      _restoringSession = false;
    }
    if (queueNeedsRewrite) {
      await _persistSession(position: position);
    }
    _autoplay.updateMode();
  }

  bool _isCurrentPlayRequest(int generation, PlayableMedia media) {
    return !_disposed &&
        generation == _playRequestGeneration &&
        _index >= 0 &&
        _index < _media.length &&
        _media[_index].id == media.id &&
        _media[_index].source == media.source;
  }

  Future<void> setQueueAndPlay(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {
    if (items.isEmpty) return;
    _autoplay.reset();
    _playRequestGeneration++;
    _media
      ..clear()
      ..addAll(items);
    _queueItems
      ..clear()
      ..addAll(items.map((m) => m.toMediaItem()));
    _originalQueueOrder = null;
    _index = initialIndex.clamp(0, items.length - 1);
    if (_shuffle) _shuffleQueue();
    _markSessionQueueChanged();
    _playHistory.clear();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    await _playIndex(_index);
  }

  Future<void> enqueue(PlayableMedia item, {bool playNext = false}) async {
    if (_media.isEmpty || _index < 0) {
      await setQueueAndPlay([item]);
      return;
    }
    final insertAt = playNext
        ? (_index + 1).clamp(0, _media.length)
        : _autoplay.manualInsertIndex;
    _media.insert(insertAt, item);
    final queueItem = item.toMediaItem();
    _queueItems.insert(insertAt, queueItem);
    _rememberEnqueued([queueItem], playNext: playNext);
    _markSessionQueueChanged();

    for (var i = 0; i < _playHistory.length; i++) {
      if (_playHistory[i] >= insertAt) _playHistory[i]++;
    }

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  Future<void> enqueueAll(
    List<PlayableMedia> items, {
    bool playNext = false,
  }) async {
    if (items.isEmpty) return;
    if (_media.isEmpty || _index < 0) {
      await setQueueAndPlay(items);
      return;
    }
    var at = playNext
        ? (_index + 1).clamp(0, _media.length)
        : _autoplay.manualInsertIndex;
    final queued = <MediaItem>[];
    for (final item in items) {
      _media.insert(at, item);
      final queueItem = item.toMediaItem();
      _queueItems.insert(at, queueItem);
      queued.add(queueItem);
      for (var i = 0; i < _playHistory.length; i++) {
        if (_playHistory[i] >= at) _playHistory[i]++;
      }
      at++;
    }
    _rememberEnqueued(queued, playNext: playNext);
    _markSessionQueueChanged();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  void moveQueueItem(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _media.length ||
        newIndex < 0 ||
        newIndex >= _media.length ||
        oldIndex == newIndex) {
      return;
    }
    final media = _media.removeAt(oldIndex);
    final qi = _queueItems.removeAt(oldIndex);
    _media.insert(newIndex, media);
    _queueItems.insert(newIndex, qi);
    _markSessionQueueChanged();

    if (_index == oldIndex) {
      _index = newIndex;
    } else {
      if (oldIndex < _index && newIndex >= _index) {
        _index--;
      } else if (oldIndex > _index && newIndex <= _index) {
        _index++;
      }
    }

    _playHistory.clear();

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  /// Removes one queued occurrence, including when the same song is queued
  /// twice. The current source is protected if playback advances mid-gesture.
  void removeQueuedItem(MediaItem item) {
    final at = _queueItems.indexWhere((entry) => identical(entry, item));
    if (_disposed || at < 0 || at == _index) return;
    _autoplay.dismiss(_media[at]);
    _queueItems.removeAt(at);
    _media.removeAt(at);
    _originalQueueOrder?.removeWhere((entry) => identical(entry, item));
    if (at < _index) _index--;
    final history = [
      for (final index in _playHistory)
        if (index != at) index > at ? index - 1 : index,
    ];
    _playHistory
      ..clear()
      ..addAll(history);
    _markSessionQueueChanged();
    unawaited(_autoMix.cancel());
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  Future<void> _playIndex(
    int index, {
    bool recordHistory = true,
    Duration startPosition = Duration.zero,
  }) async {
    if (_disposed || index < 0 || index >= _media.length) return;
    // A normal track change supersedes a pending restore. A restored start
    // keeps it until the source is actually ready so a transient failure can
    // be retried from the same position.
    if (startPosition <= Duration.zero) {
      _pendingRestorePosition = null;
    }
    final generation = ++_playRequestGeneration;
    _sourceReady = false;
    // Advance the requested index synchronously so consecutive Next taps do
    // not all target the same song while AutoMix/source preparation awaits.
    _index = index;
    unawaited(_autoplay.fill());
    final media = _media[index];
    _switchingGeneration = generation;
    await _player.cancelPreparation();
    await _serializeSourceChange(() async {
      try {
        if (!_isCurrentPlayRequest(generation, media)) return;
        await _autoMix.cancel();
        if (!_isCurrentPlayRequest(generation, media)) return;
        // Retire the audible source before publishing another song's title.
        await _player.stop();
        if (!_isCurrentPlayRequest(generation, media)) return;
        await _loadIndex(
          generation,
          media,
          recordHistory: recordHistory,
          startPosition: startPosition,
        );
      } finally {
        if (_switchingGeneration == generation) _switchingGeneration = 0;
      }
    });
  }

  Future<void> _serializeSourceChange(Future<void> Function() action) {
    final operation = _sourceChangeTail.then((_) => action());
    // A failed operation must not poison later transport requests.
    _sourceChangeTail = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _startResolvedSource(
    String path,
    int generation,
    PlayableMedia media,
    Duration? position,
  ) async {
    // AudioPlayer.play combines prepare/seek/resume without a cancellation
    // boundary. A late prepare from an old request could resume the wrong
    // source. Serialize preparation and recheck before making it audible.
    await _player.setSource(
      DeviceFileSource(path),
      preferBitPerfect: _usbBitPerfectEnabled,
      directUsb: _usbDirectEnabled,
      allowFixedVolume: _usbAllowFixedVolume,
      dapExclusive: _dapExclusiveEnabled,
      allowDop: _usbDopEnabled,
      requiresDsd:
          media.bitDepth == 1 ||
          const ['dsf', 'dff'].contains(media.format?.toLowerCase()) ||
          media.source.toLowerCase().endsWith('.dsf') ||
          media.source.toLowerCase().endsWith('.dff'),
    );
    if (!_isCurrentPlayRequest(generation, media)) return;
    if (position != null) {
      await _player.seek(position);
      if (!_isCurrentPlayRequest(generation, media)) return;
    }
    await _player.resume();
    if (!_isCurrentPlayRequest(generation, media)) await _player.pause();
  }

  Future<void> _loadIndex(
    int generation,
    PlayableMedia media, {
    required bool recordHistory,
    required Duration startPosition,
  }) async {
    _pausedByInterruption = false;
    _interruptionActive = false;
    _userPaused = false;

    if (recordHistory) _recordPlayHistory(_index);

    final effectiveStartPosition = normalizedPlaybackResumePosition(
      startPosition,
      duration: media.duration,
    );
    mediaItem.add(media.toMediaItem());
    _lastBroadcastPosition = Duration.zero;
    _lastPositionBroadcastAt = null;
    _broadcastPosition(effectiveStartPosition, force: true);
    // Claim the playing state up front (while the app is still in the
    // foreground window) so audio_service can start its foreground service
    // before the async source resolve below.
    _broadcastState(playerState: PlayerState.playing, loading: true);
    await _claimHardwareMediaButtons();
    if (!_isCurrentPlayRequest(generation, media)) return;

    // Android opens SAF files through a short-lived file-descriptor lease.
    // MediaPlayer duplicates that descriptor, so the original can be closed
    // immediately after play() without retaining a full-file cache copy.
    ContentUriPlaybackLease? playbackLease;
    if (Platform.isAndroid && media.isContentUri) {
      try {
        playbackLease = await PlatformBridge.openContentUriPlaybackLease(
          media.source,
        );
      } catch (e) {
        _log.w('Failed to open direct SAF playback lease: $e');
      }
    }
    var resolved = playbackLease?.path ?? await _resolveSource(media);
    var usingLocalSafCopy = media.isContentUri && playbackLease == null;
    if (!_isCurrentPlayRequest(generation, media)) {
      if (playbackLease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
      }
      return;
    }
    if (resolved == null) {
      _log.e('No playable source for ${media.title}');
      _broadcastState(playerState: PlayerState.stopped);
      return;
    }

    try {
      await musicPlayerExclusiveAudioHook?.call();
    } catch (_) {}
    if (!_isCurrentPlayRequest(generation, media)) {
      if (playbackLease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
      }
      return;
    }

    _switchingGeneration = generation;
    try {
      // Set before play() so the track never starts at the wrong loudness;
      // always set (1.0 when disabled/untagged) so a previous track's
      // attenuation can't leak into the next one.
      var normalizationVolume = await _normalizationVolumeFor(
        resolved,
        cacheKey: media.isContentUri ? media.source : null,
        displayName: playbackLease?.displayName,
      );
      if (!_isCurrentPlayRequest(generation, media)) return;
      await _player.setAudioContext(_musicAudioContext);
      if (!_isCurrentPlayRequest(generation, media)) return;
      await _activateAudioSession();
      if (!_isCurrentPlayRequest(generation, media)) return;
      await _player.stop();
      _sourceReady = false;
      if (!_isCurrentPlayRequest(generation, media)) return;
      await _player.setVolume(normalizationVolume);
      _normalizationVolume = normalizationVolume;
      if (!_isCurrentPlayRequest(generation, media)) return;
      final startAt = effectiveStartPosition > Duration.zero
          ? effectiveStartPosition
          : null;
      try {
        await _startResolvedSource(resolved, generation, media, startAt);
        if (playbackLease != null) {
          await PlatformBridge.closeContentUriPlaybackLease(
            playbackLease.token,
          );
          playbackLease = null;
        }
      } catch (directError) {
        if (directError is UsbOutputUnavailable ||
            playbackLease == null ||
            !_isCurrentPlayRequest(generation, media)) {
          rethrow;
        }
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
        playbackLease = null;
        _log.w(
          'Direct SAF playback unavailable; using bounded local fallback: '
          '$directError',
        );
        final fallback = await _resolveSource(media);
        if (fallback == null || !_isCurrentPlayRequest(generation, media)) {
          rethrow;
        }
        resolved = fallback;
        usingLocalSafCopy = true;
        normalizationVolume = await _normalizationVolumeFor(
          fallback,
          cacheKey: media.source,
        );
        if (!_isCurrentPlayRequest(generation, media)) return;
        await _player.setVolume(normalizationVolume);
        if (!_isCurrentPlayRequest(generation, media)) return;
        _normalizationVolume = normalizationVolume;
        await _startResolvedSource(fallback, generation, media, startAt);
      }
      if (!_isCurrentPlayRequest(generation, media)) return;
      _sourceReady = true;
      _pendingRestorePosition = null;
      _activeResolvedPath = usingLocalSafCopy ? resolved : null;
      await _cleanupPendingResolvedPaths();
      if (!_isCurrentPlayRequest(generation, media)) return;
      // Plain file paths were already published before loading. Re-publishing
      // them with an identical resolved path made Now Playing clear and probe
      // the same metadata twice on every Next. SAF needs this second event so
      // the UI can inspect its temporary local copy.
      if (usingLocalSafCopy) {
        mediaItem.add(media.toMediaItem(resolvedSource: resolved));
      }
      _broadcastPosition(effectiveStartPosition, force: true);
      _broadcastState();
      _lastPeriodicPersistAt = DateTime.now();
      unawaited(_persistSession(position: effectiveStartPosition));
      // Some files do not emit onDurationChanged reliably (stuck at 0:00);
      // poll the engine for the real duration as a fallback.
      unawaited(_ensureDurationKnown(media, generation));
    } catch (e) {
      if (!_isCurrentPlayRequest(generation, media)) return;
      _sourceReady = false;
      _log.e('Playback failed for ${media.title}: $e');
      _broadcastState(playerState: PlayerState.stopped);
    } finally {
      if (playbackLease != null) {
        await PlatformBridge.closeContentUriPlaybackLease(playbackLease.token);
      }
      if (_switchingGeneration == generation) {
        _switchingGeneration = 0;
      }
    }
  }

  /// Resolves the real track duration when the initial metadata had none and
  /// the duration-changed event did not fire, so the seek bar and total time
  /// do not get stuck at 0:00.
  Future<void> _ensureDurationKnown(PlayableMedia media, int generation) async {
    for (var attempt = 0; attempt < 15; attempt++) {
      if (!_isCurrentPlayRequest(generation, media)) return;
      final current = mediaItem.value;
      final existing = current?.duration;
      if (existing != null && existing > Duration.zero) return;

      try {
        final d = await _player.getDuration();
        if (!_isCurrentPlayRequest(generation, media)) return;
        if (d != null && d > Duration.zero) {
          final item = mediaItem.value;
          if (item != null) {
            mediaItem.add(item.copyWith(duration: d));
          }
          return;
        }
      } catch (_) {
        // Duration probing is best-effort; retry until the bounded loop ends.
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  void _recordPlayHistory(int index) {
    _playHistory.add(index);
    if (_playHistory.length > 200) _playHistory.removeAt(0);
  }

  Future<void> _onComplete() async {
    if (_repeatMode == AudioServiceRepeatMode.one &&
        _index >= 0 &&
        _index < _media.length) {
      await _playIndex(_index, recordHistory: false);
      return;
    }
    if (_index == _media.length - 1 &&
        _repeatMode == AudioServiceRepeatMode.none) {
      final generation = _playRequestGeneration;
      await _autoplay.fill();
      if (_disposed ||
          generation != _playRequestGeneration ||
          _shouldIgnoreComplete) {
        return;
      }
    }
    if (_index >= 0 && _index < _media.length - 1) {
      await _playIndex(_index + 1);
    } else if (_repeatMode == AudioServiceRepeatMode.all && _media.isNotEmpty) {
      await _playIndex(0);
    } else {
      _broadcastState(playerState: PlayerState.completed);
    }
  }

  Future<void> _handlePlayerComplete() async {
    if (_completing) return;
    if (_shouldIgnoreComplete) {
      if (_userPaused || _interruptionActive) {
        _broadcastState(playerState: PlayerState.paused);
      }
      return;
    }

    _completing = true;
    try {
      await _onComplete();
    } finally {
      _completing = false;
    }
  }

  @override
  Future<void> play() async {
    final activeOperation = _activePlayOperation;
    if (activeOperation != null) {
      await activeOperation;
      return;
    }

    final operation = _playInternal();
    _activePlayOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_activePlayOperation, operation)) {
        _activePlayOperation = null;
      }
    }
  }

  Future<void> _playInternal() async {
    _pausedByInterruption = false;
    _interruptionActive = false;
    _userPaused = false;
    if (_player.needsSourceReload) {
      final generation = _playRequestGeneration;
      final index = _index;
      final position =
          await _player.getCurrentPosition() ?? playbackState.value.position;
      if (generation != _playRequestGeneration || _disposed) return;
      await _playIndex(index, recordHistory: false, startPosition: position);
      return;
    }
    if ((!_sourceReady ||
            _player.state == PlayerState.stopped ||
            _player.state == PlayerState.completed) &&
        _index >= 0 &&
        _index < _media.length) {
      await _playIndex(
        _index,
        recordHistory: false,
        startPosition: _pendingRestorePosition ?? Duration.zero,
      );
      return;
    }
    await _activateAudioSession();
    await _claimHardwareMediaButtons();
    try {
      await _player.resume();
    } on PlatformException {
      if (!_player.needsSourceReload) rethrow;
      _broadcastState(playerState: PlayerState.paused);
      return;
    }
    _broadcastState(playerState: PlayerState.playing);
  }

  @override
  Future<void> click([MediaButton button = MediaButton.media]) async {
    switch (button) {
      case MediaButton.media:
        if (playbackState.value.playing) {
          await pause();
        } else {
          await play();
        }
        break;
      case MediaButton.next:
        await skipToNext();
        break;
      case MediaButton.previous:
        await skipToPrevious();
        break;
    }
  }

  @override
  Future<void> pause() async {
    final generation = ++_playRequestGeneration;
    _switchingGeneration = 0;
    _userPaused = true;
    _pausedByInterruption = false;
    await _autoMix.cancel();
    await _serializeSourceChange(() async {
      if (generation != _playRequestGeneration || _disposed) return;
      await _player.pause();
      if (generation != _playRequestGeneration || _disposed) return;
      _broadcastState(playerState: PlayerState.paused);
      await _persistSession(position: await _currentPositionForPersist());
    });
  }

  @override
  Future<void> seek(Duration position) async {
    await _autoMix.cancel();
    await _player.seek(position);
    _broadcastPosition(position, force: true);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final generation = ++_shuffleRequestGeneration;
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    await _autoMix.cancel();
    if (generation != _shuffleRequestGeneration ||
        _disposed ||
        enabled == _shuffle) {
      return;
    }
    _shuffle = enabled;
    if (enabled) {
      _shuffleQueue();
    } else {
      final original = _originalQueueOrder;
      if (original != null) _applyQueueOrder(List.of(original));
      _originalQueueOrder = null;
    }
    _markSessionQueueChanged();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    if (_media.isNotEmpty && _index >= 0) {
      unawaited(_persistSession(position: playbackState.value.position));
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await _autoMix.cancel();
    // Group repeat has no meaning for a flat queue; treat it as all.
    _repeatMode = repeatMode == AudioServiceRepeatMode.group
        ? AudioServiceRepeatMode.all
        : repeatMode;
    _autoplay.updateMode();
    _broadcastState();
    if (_media.isNotEmpty && _index >= 0) {
      unawaited(_persistSession(position: playbackState.value.position));
    }
  }

  @override
  Future<void> stop() async {
    _autoplay.reset();
    cancelSleepTimer();
    final generation = ++_playRequestGeneration;
    _switchingGeneration = 0;
    _userPaused = true;
    await _autoMix.cancel();
    await _serializeSourceChange(() => _stopSession(generation));
  }

  Future<void> _stopSession(int generation) async {
    if (generation != _playRequestGeneration || _disposed) return;
    await _player.stop();
    if (generation != _playRequestGeneration || _disposed) return;
    _sourceReady = false;
    _activeResolvedPath = null;
    await _cleanupPendingResolvedPaths();
    if (generation != _playRequestGeneration || _disposed) return;
    _index = -1;
    _pausedByInterruption = false;
    _interruptionActive = false;
    _userPaused = false;
    _playHistory.clear();
    _pendingRestorePosition = null;
    _scheduledSessionQueueRevision = -1;
    _persistedSessionQueueRevision = -1;
    // An explicit stop ends the session for good; nothing to restore later.
    await _enqueueSessionWrite(AppStateDatabase.instance.clearPlaybackSession);
    if (generation != _playRequestGeneration || _disposed) return;
    // A stopped session has no current item; this also hides the mini player.
    mediaItem.add(null);
    _broadcastState(playerState: PlayerState.stopped);
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    if (_index >= 0 && _index == _media.length - 1) {
      final generation = _playRequestGeneration;
      await _autoplay.fill();
      if (_disposed || generation != _playRequestGeneration) return;
    }
    if (_index < _media.length - 1) await _playIndex(_index + 1);
  }

  @override
  Future<void> skipToPrevious() async {
    await _autoMix.cancel();
    if (playbackState.value.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      _broadcastPosition(Duration.zero, force: true);
      return;
    }
    if (_shuffle) {
      if (_playHistory.length >= 2) {
        _playHistory.removeLast();
        final prev = _playHistory.last;
        await _playIndex(prev, recordHistory: false);
      } else {
        await _player.seek(Duration.zero);
        _broadcastPosition(Duration.zero, force: true);
      }
      return;
    }
    if (_index > 0) await _playIndex(_index - 1);
  }

  @override
  Future<void> skipToQueueItem(int index) => _playIndex(index);

  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    if (parentMediaId == AudioService.browsableRootId ||
        parentMediaId == AudioService.recentRootId) {
      return List<MediaItem>.unmodifiable(_queueItems);
    }
    return const [];
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    final index = _media.indexWhere((m) => m.id == mediaId);
    if (index < 0) return null;
    return _queueItems[index];
  }

  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final index = _media.indexWhere((m) => m.id == mediaId);
    if (index >= 0) await _playIndex(index);
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) =>
      playFromMediaId(mediaItem.id);

  /// Called when a file is deleted from disk. Removes it from the queue and, if
  /// it is the track currently playing, stops or advances so a deleted song can
  /// no longer be played.
  Future<void> onSourceDeleted(String source) async {
    final target = source.trim();
    if (target.isEmpty || _media.isEmpty) return;

    final discardedPath = _resolvedPathCache.remove(target);
    _resolvedPathOrder.remove(target);
    if (discardedPath != null) {
      await _discardResolvedPath(discardedPath);
    }

    final wasCurrent =
        _index >= 0 &&
        _index < _media.length &&
        _media[_index].source == target;

    var removedBeforeCurrent = 0;
    final kept = <PlayableMedia>[];
    final keptQueue = <MediaItem>[];
    for (var i = 0; i < _media.length; i++) {
      if (_media[i].source == target) {
        if (i < _index) removedBeforeCurrent++;
        continue;
      }
      kept.add(_media[i]);
      keptQueue.add(_queueItems[i]);
    }

    if (kept.length == _media.length) return;

    _media
      ..clear()
      ..addAll(kept);
    _queueItems
      ..clear()
      ..addAll(keptQueue);
    final keptSet = Set<MediaItem>.identity()..addAll(keptQueue);
    _originalQueueOrder?.removeWhere((item) => !keptSet.contains(item));
    _markSessionQueueChanged();
    _playHistory.clear();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));

    if (_media.isEmpty) {
      await stop();
      return;
    }

    if (wasCurrent) {
      final nextIndex = _index.clamp(0, _media.length - 1);
      await _playIndex(nextIndex);
    } else {
      _index = (_index - removedBeforeCurrent).clamp(0, _media.length - 1);
      _broadcastState();
      unawaited(_persistSession(position: playbackState.value.position));
    }
  }

  Future<void> dispose() async {
    _autoplay.reset();
    _disposed = true;
    if (identical(_activeMusicPlayerHandler, this)) {
      _activeMusicPlayerHandler = null;
    }
    cancelSleepTimer();
    _playRequestGeneration++;
    await _sourceChangeTail;
    await _autoMix.dispose();
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _sourceReady = false;
    for (final player in _playerSubscriptions.keys.toList()) {
      await _disposeDeck(player);
    }
    _activeResolvedPath = null;
    final tempPaths = <String>{
      ..._resolvedPathCache.values,
      ..._pendingResolvedPathDeletes,
    };
    _resolvedPathCache.clear();
    _resolvedPathSizes.clear();
    _resolvedPathOrder.clear();
    _pendingResolvedPathDeletes.clear();
    for (final path in tempPaths) {
      await _discardResolvedPath(path);
    }
  }
}

MusicPlayerHandler? _handler;
Future<MusicPlayerHandler>? _initFuture;
final StreamController<MusicPlayerHandler> _handlerReadyController =
    StreamController<MusicPlayerHandler>.broadcast();

MusicPlayerHandler? get musicPlayerHandler => _handler;

Future<void> Function()? musicPlayerExclusiveAudioHook;

/// Flushes the current playback position if the player has been initialized.
Future<void> persistCurrentPlaybackSession() async {
  final handler = _handler;
  if (handler == null) return;
  await handler.persistCurrentSession();
}

Future<MusicPlayerHandler> initMusicPlayer() async {
  if (_handler != null) return _handler!;
  final existingFuture = _initFuture;
  if (existingFuture != null) return existingFuture;

  final future = _doInitMusicPlayer();
  _initFuture = future;
  return future;
}

Future<MusicPlayerHandler> _doInitMusicPlayer() async {
  try {
    final handler = await AudioService.init(
      builder: () => MusicPlayerHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.zarz.spotiflac.playback',
        androidNotificationChannelName: 'Playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
    _handler = handler;
    if (Platform.isAndroid || Platform.isIOS) {
      PlayerWidgetService.instance.bind(handler);
    }
    _handlerReadyController.add(handler);
    return handler;
  } catch (_) {
    _initFuture = null;
    rethrow;
  }
}

/// Restores the last persisted playback session (if any) into a freshly
/// initialized handler, paused. Entries whose plain file paths no longer
/// exist are dropped; content URIs are kept and fail gracefully at play time.
Future<void>? _restoreSessionFuture;

Future<void> restorePersistedPlaybackSession() =>
    _restoreSessionFuture ??= _restorePersistedPlaybackSession();

Future<void> _restorePersistedPlaybackSession() async {
  try {
    final session = await AppStateDatabase.instance.getPlaybackSession();
    if (session == null) return;

    final rawMedia = session['media'];
    if (rawMedia is! List) {
      await AppStateDatabase.instance.clearPlaybackSession();
      return;
    }

    final items = <PlayableMedia>[];
    final keptOriginalIndices = <int>[];
    final iosDocumentsPath = Platform.isIOS
        ? (await getApplicationDocumentsDirectory()).path
        : null;
    var artworkRelocated = false;
    for (var i = 0; i < rawMedia.length; i++) {
      final entry = rawMedia[i];
      if (entry is! Map) continue;
      final media = PlayableMedia.fromJson(
        Map<String, dynamic>.from(entry),
        iosDocumentsPath: iosDocumentsPath,
      );
      if (media == null) continue;
      if (!media.isContentUri && !await File(media.source).exists()) {
        continue;
      }
      final artwork = await resolveRestoredArtworkUri(
        media.artUri,
        loadLibraryCoverPath: () async {
          final database = LibraryDatabase.instance;
          final row = await database.getById(media.id);
          if (row != null) return row['coverPath'] as String?;
          final matches = await database.findByTrackAndArtist(
            media.title,
            media.artist,
          );
          for (final row in matches) {
            if (row['filePath'] == media.source) {
              return row['coverPath'] as String?;
            }
          }
          return null;
        },
      );
      items.add(
        artwork == media.artUri
            ? media
            : PlayableMedia.fromJson({...media.toJson(), 'artUri': artwork})!,
      );
      artworkRelocated |= artwork != entry['artUri'];
      keptOriginalIndices.add(i);
    }
    if (items.isEmpty) {
      await AppStateDatabase.instance.clearPlaybackSession();
      return;
    }

    // Remap the saved index onto the surviving list; if the current track
    // itself was dropped, land on the nearest earlier survivor at 0:00.
    final savedIndex = (session['index'] as num?)?.toInt() ?? 0;
    var index = 0;
    for (var i = 0; i < keptOriginalIndices.length; i++) {
      if (keptOriginalIndices[i] <= savedIndex) index = i;
    }
    var position = Duration(
      milliseconds: (session['positionMs'] as num?)?.toInt() ?? 0,
    );
    if (keptOriginalIndices[index] != savedIndex) {
      position = Duration.zero;
    }

    final handler = await initMusicPlayer();
    await handler.restoreSession(
      items: items,
      index: index,
      position: position,
      shuffle: session['shuffle'] == true,
      originalOrder: [
        for (final i in keptOriginalIndices)
          ((rawMedia[i] as Map)['queueOriginalIndex'] as num?)?.toInt() ?? i,
      ],
      queueNeedsRewrite: items.length != rawMedia.length || artworkRelocated,
      repeatMode: AudioServiceRepeatMode.values.firstWhere(
        (mode) => mode.name == session['repeat'],
        orElse: () => AudioServiceRepeatMode.none,
      ),
    );
    _log.i(
      'Restored playback session: ${items.length} track(s), paused at '
      '${position.inSeconds}s',
    );
  } catch (e) {
    _log.w('Failed to restore playback session: $e');
  }
}

Stream<MediaItem?> musicPlayerMediaItemEvents() async* {
  final existing = _handler;
  if (existing != null) {
    yield existing.mediaItem.value;
    yield* existing.mediaItem;
    return;
  }
  yield null;
  await for (final handler in _handlerReadyController.stream) {
    yield handler.mediaItem.value;
    yield* handler.mediaItem;
    return;
  }
}

Stream<PlaybackState> musicPlayerPlaybackStateEvents() async* {
  final existing = _handler;
  if (existing != null) {
    yield existing.playbackState.value;
    yield* existing.playbackState;
    return;
  }
  await for (final handler in _handlerReadyController.stream) {
    yield handler.playbackState.value;
    yield* handler.playbackState;
    return;
  }
}

Stream<List<MediaItem>> musicPlayerQueueEvents() async* {
  final existing = _handler;
  if (existing != null) {
    yield existing.queue.value;
    yield* existing.queue;
    return;
  }
  yield const [];
  await for (final handler in _handlerReadyController.stream) {
    yield handler.queue.value;
    yield* handler.queue;
    return;
  }
}
