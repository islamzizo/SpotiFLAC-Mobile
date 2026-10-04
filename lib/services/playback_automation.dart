// Device types are experimental in audio_session. Keep their interpretation
// here so platform route changes do not leak into transport or settings code.
// ignore_for_file: experimental_member_use

import 'package:audio_session/audio_session.dart';

/// Serializes automatic transport requests and remembers who paused playback.
/// A volume change must never undo an explicit pause or a lost output route.
class PlaybackAutomation {
  PlaybackAutomation({
    required bool Function() isPlaying,
    required bool Function() canResume,
    required Future<void> Function() pause,
    required Future<void> Function() play,
    required void Function(Object) onError,
  }) : _isPlaying = isPlaying,
       _canResume = canResume,
       _pause = pause,
       _play = play,
       _onError = onError;

  final bool Function() _isPlaying;
  final bool Function() _canResume;
  final Future<void> Function() _pause;
  final Future<void> Function() _play;
  final void Function(Object) _onError;
  bool _pauseOnMute = false;
  bool _playOnHeadphonesConnected = false;
  bool? _muted;
  bool _pausedByMute = false;
  bool _disposed = false;
  int _intentRevision = 0;
  Set<String>? _headphones;
  Future<void> _tail = Future<void>.value();

  bool get blocksPlayback => _pauseOnMute && _muted != false;

  Future<void> configure({
    required bool pauseOnMute,
    required bool playOnHeadphonesConnected,
  }) {
    if (_pauseOnMute == pauseOnMute &&
        _playOnHeadphonesConnected == playOnHeadphonesConnected) {
      return _tail;
    }
    cancelPendingActions();
    if (_pauseOnMute != pauseOnMute) _muted = null;
    if (_playOnHeadphonesConnected != playOnHeadphonesConnected) {
      _headphones = null;
    }
    _pauseOnMute = pauseOnMute;
    _playOnHeadphonesConnected = playOnHeadphonesConnected;
    return _enqueue(_applyVolume);
  }

  void cancelPendingActions() {
    _intentRevision++;
    _pausedByMute = false;
  }

  Future<void> volumeChanged(double volume) {
    if (!volume.isFinite) return _tail;
    _muted = volume <= 0;
    return _enqueue(_applyVolume);
  }

  Future<void> playbackStarted() => _enqueue(_applyVolume);

  Future<void> _applyVolume() async {
    if (!_pauseOnMute) return;
    if (_muted == true) {
      if (_isPlaying() && _canResume()) {
        _pausedByMute = true;
        await _pause();
      }
    } else if (_muted == false && _pausedByMute) {
      _pausedByMute = false;
      if (!_isPlaying() && _canResume()) await _play();
    }
  }

  Future<void> devicesChanged(Set<AudioDevice> devices) {
    final headphones = devices
        .where(_isHeadphoneOutput)
        .map((device) => device.id)
        .toSet();
    final previous = _headphones;
    _headphones = headphones;
    // The initial device inventory is not a connection gesture.
    if (previous == null || !_playOnHeadphonesConnected) return _tail;
    if (previous.isNotEmpty && headphones.isEmpty) {
      cancelPendingActions();
      return _enqueue(() async {
        if (_isPlaying()) await _pause();
      });
    }
    if (headphones.difference(previous).isEmpty) return _tail;
    return _enqueue(() async {
      if (_playOnHeadphonesConnected &&
          !blocksPlayback &&
          !_isPlaying() &&
          _canResume()) {
        await _play();
      }
    });
  }

  static bool _isHeadphoneOutput(AudioDevice device) =>
      device.isOutput &&
      const {
        AudioDeviceType.wiredHeadset,
        AudioDeviceType.wiredHeadphones,
        AudioDeviceType.usbAudio,
        AudioDeviceType.bluetoothA2dp,
        AudioDeviceType.bluetoothLe,
        AudioDeviceType.hearingAid,
      }.contains(device.type);

  Future<void> _enqueue(Future<void> Function() action) {
    final revision = _intentRevision;
    _tail = _tail.then((_) async {
      if (_disposed || revision != _intentRevision) return;
      try {
        await action();
      } catch (error) {
        _pausedByMute = false;
        _onError(error);
      }
    });
    return _tail;
  }

  Future<void> dispose() async {
    _disposed = true;
    cancelPendingActions();
    await _tail;
  }
}
