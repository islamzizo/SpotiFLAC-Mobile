import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/services/network_storage_service.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';

typedef NetworkTagReader =
    Future<Map<String, dynamic>> Function(String url, String name);

/// One bounded native tag read per source, shared by playback and Lyrics.
/// Only the selected track is inspected; browsing does not scan the NAS.
class NetworkMetadataService {
  NetworkMetadataService({
    NetworkStorageService? storage,
    NetworkTagReader? reader,
    Future<Directory> Function()? cacheDirectory,
  }) : _storage = storage ?? NetworkStorageService.instance,
       _reader =
           reader ??
           ((url, name) =>
               PlatformBridge.readFileMetadata(url, displayName: name)),
       _directory = cacheDirectory ?? getTemporaryDirectory;

  static final instance = NetworkMetadataService();
  final NetworkStorageService _storage;
  final NetworkTagReader _reader;
  final Future<Directory> Function() _directory;
  final _cache = <String, ({DateTime time, Map<String, dynamic> value})>{};
  final _pending = <String, Future<Map<String, dynamic>>>{};
  Future<void> _tail = Future.value();

  Future<Map<String, dynamic>> read(
    String source, {
    bool forceRefresh = false,
  }) {
    if (forceRefresh) _cache.remove(source);
    final cached = _cache[source];
    if (cached != null &&
        DateTime.now().difference(cached.time) < const Duration(minutes: 5)) {
      return Future.value(cached.value);
    }
    final pending = _pending[source];
    if (pending != null) return pending;
    if (_pending.length >= 4) {
      return Future.error(StateError('Network metadata reader is busy'));
    }
    final operation = _tail.then((_) => _load(source));
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    final result = operation.whenComplete(() {
      _pending.remove(source);
    });
    _pending[source] = result;
    return result;
  }

  Future<Map<String, dynamic>> _load(String source) async {
    final uri = Uri.parse(source);
    if (uri.scheme != 'network') {
      throw const FormatException('Expected a network source');
    }
    final connection = await _storage.connection(uri.host);
    final path = uri.pathSegments.join('/');
    var name =
        (path.isEmpty
            ? connection.root.pathSegments.lastOrNull
            : uri.pathSegments.lastOrNull) ??
        '';
    if (name.toLowerCase().endsWith('.alac')) {
      name = '${name.substring(0, name.length - 5)}.m4a';
    }
    final url = await _storage.resolve(source);
    final metadata = Map<String, dynamic>.from(await _reader(url, name));
    if (metadata['error']?.toString().isNotEmpty == true) {
      throw StateError('Network metadata could not be read');
    }
    final cover = metadata.remove('cover_base64');
    if (cover is String &&
        cover.isNotEmpty &&
        cover.length <= 6 * 1024 * 1024) {
      // A cover/cache failure must not discard successfully read tags or lyrics.
      try {
        final directory = Directory(
          '${(await _directory()).path}/network_metadata',
        );
        await directory.create(recursive: true);
        final file = File(
          '${directory.path}/${sha256.convert(utf8.encode(source))}.image',
        );
        await file.writeAsBytes(base64Decode(cover), flush: true);
        metadata['cover_path'] = file.path;
        final files = await directory
            .list()
            .where((entry) => entry is File)
            .cast<File>()
            .toList();
        final dated = <({File file, DateTime time})>[];
        for (final entry in files) {
          dated.add((file: entry, time: (await entry.stat()).modified));
        }
        dated.sort((a, b) => b.time.compareTo(a.time));
        for (final old in dated.skip(32)) {
          await old.file.delete();
        }
      } catch (_) {}
    }
    final value = Map<String, dynamic>.unmodifiable(metadata);
    // Oversized tag blocks can still be displayed for the current song, but
    // must not accumulate across a large NAS collection in the memory cache.
    if (utf8.encode(jsonEncode(value)).length > 128 * 1024) return value;
    _cache.remove(source);
    while (_cache.length >= 32) {
      _cache.remove(_cache.keys.first);
    }
    _cache[source] = (time: DateTime.now(), value: value);
    return value;
  }
}
