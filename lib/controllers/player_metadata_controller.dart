import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:spotiflac_android/services/playback_metadata.dart';
import 'package:spotiflac_android/utils/int_utils.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:spotiflac_android/utils/lyrics_parser.dart';

final _log = AppLogger('PlayerMetadata');

/// Owns file metadata and lyrics for the full player. Requests are scoped to
/// the current queue item so a late probe cannot replace another track's data.
class PlayerMetadataController extends ChangeNotifier {
  PlayerMetadataController({PlaybackMetadataReader? readMetadata})
    : _readMetadata = readMetadata ?? readPlaybackFileMetadataWithRetry;

  final PlaybackMetadataReader _readMetadata;
  (String, String, String?)? _requestKey;
  String? _loadedPath;
  Map<String, dynamic> _fallback = const {};
  int _generation = 0;
  bool _disposed = false;

  String? get source => _requestKey?.$2;
  Map<String, dynamic>? _metadata;
  ParsedLyrics _lyrics = ParsedLyrics.empty;
  bool _loading = false;
  Map<String, dynamic>? get metadata => _metadata;
  ParsedLyrics get lyrics => _lyrics;
  bool get loading => _loading;

  Future<void> load(
    MediaItem? item, {
    bool inspectUnresolvedContentUri = false,
  }) async {
    if (_disposed) return;
    final source = item?.extras?['source']?.toString() ?? '';
    if (item == null || source.isEmpty) {
      if (_requestKey == null) return;
      _generation++;
      _requestKey = null;
      _loadedPath = null;
      _replaceMetadata(const {});
      return;
    }
    final resolvedSource = item.extras?['resolvedSource']?.toString().trim();
    final key = (item.id, source, resolvedSource);
    final sameItem = key == _requestKey;
    _fallback = Map.unmodifiable(playbackAudioMetadataFromMediaItem(item));
    if (!sameItem) {
      _generation++;
      _requestKey = key;
      _loadedPath = null;
    }
    if (const {'http', 'https'}.contains(Uri.tryParse(source)?.scheme)) {
      _loadedPath = source;
      _replaceMetadata(_fallback);
      return;
    }
    final path = _metadataPath(source, resolvedSource);
    final unresolved = path == source && source.startsWith('content://');
    if (sameItem) {
      if (metadata == null && _fallback.isNotEmpty) {
        _metadata = _fallback;
        notifyListeners();
      }
      if (loading || _loadedPath == path) return;
    } else {
      _replaceMetadata(_fallback);
    }
    // Opening the player must not copy an unresolved SAF document. Lyrics
    // requests may inspect it until playback publishes its resolved source.
    if (unresolved && !inspectUnresolvedContentUri) return;
    _loading = true;
    notifyListeners();
    final generation = _generation;
    try {
      final probed = await _readMetadata(path);
      if (_disposed || generation != _generation) return;
      _loadedPath = path;
      _replaceMetadata(mergePlaybackFileMetadata(_fallback, probed));
    } catch (error) {
      if (_disposed || generation != _generation) return;
      _log.w('Failed to read metadata: $error');
      _replaceMetadata(_fallback);
    }
  }

  void _replaceMetadata(Map<String, dynamic> value) {
    _metadata = value.isEmpty ? null : Map.unmodifiable(value);
    _lyrics = LyricsParser.parse((value['lyrics'] ?? '').toString());
    _loading = false;
    notifyListeners();
  }

  String _metadataPath(String source, String? resolved) =>
      !source.startsWith('network://') && resolved?.isNotEmpty == true
      ? resolved!
      : source;

  Map<String, dynamic> detailsSnapshot(MediaItem? item) {
    if (item == null) return const {};
    final source = item.extras?['source']?.toString() ?? '';
    final resolved = item.extras?['resolvedSource']?.toString().trim();
    final sameItem = _requestKey == (item.id, source, resolved);
    return {
      'title': item.title,
      'artist': item.artist ?? '',
      'album': item.album ?? '',
      ...playbackAudioMetadataFromMediaItem(item),
      if (sameItem) ...?metadata,
    };
  }

  /// A details sheet owns this snapshot, independently of later track changes.
  /// Probing an unresolved document here does not alter the lyrics lifecycle.
  Future<Map<String, dynamic>> readDetails(MediaItem? item) async {
    final fallback = detailsSnapshot(item);
    final source = item?.extras?['source']?.toString() ?? '';
    final resolved = item?.extras?['resolvedSource']?.toString().trim();
    final path = _metadataPath(source, resolved);
    if (_disposed ||
        path.isEmpty ||
        const {'http', 'https'}.contains(Uri.tryParse(source)?.scheme) ||
        (_requestKey == (item?.id, source, resolved) && _loadedPath == path)) {
      return fallback;
    }
    try {
      return mergePlaybackFileMetadata(fallback, await _readMetadata(path));
    } catch (error) {
      _log.w('Failed to read details metadata: $error');
      return fallback;
    }
  }

  ({String? writers, String? provider}) get credits {
    String? field(String key) {
      final value = metadata?[key];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    return (
      writers: lyrics.writers ?? field('lyricist') ?? field('composer'),
      provider: lyrics.provider ?? field('lyrics_provider'),
    );
  }

  String? get qualityLabel {
    final meta = metadata;
    if (meta == null) return null;
    final parts = <String>[];
    final format = (meta['format'] ?? meta['audio_codec'] ?? '')
        .toString()
        .trim()
        .toUpperCase();
    if (format.isNotEmpty) parts.add(format);
    final bitDepth = readPositiveInt(meta['bit_depth']) ?? 0;
    if (bitDepth > 0) parts.add('$bitDepth-bit');
    final sampleRate = readPositiveInt(meta['sample_rate']) ?? 0;
    if (sampleRate > 0) {
      final khz = sampleRate / 1000;
      parts.add(
        '${khz.toStringAsFixed(khz == khz.roundToDouble() ? 0 : 1)} kHz',
      );
    }
    final bitrate = readPositiveInt(meta['bitrate']) ?? 0;
    if (bitDepth == 0 && bitrate > 0) parts.add('$bitrate kbps');
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
