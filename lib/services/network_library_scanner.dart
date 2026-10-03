import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/services/network_metadata_service.dart';
import 'package:spotiflac_android/services/network_storage_service.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/lyrics_metadata_helper.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('LocalLibrary');

/// A single tag read at a time; only NDJSON and artwork are stored locally.
/// Failed listings never count as empty directories. Partial scans retain old
/// rows through the same ingestion policy used for local/SAF scans.
class NetworkLibraryScanner {
  NetworkLibraryScanner({
    NetworkStorageService? storage,
    Future<Map<String, dynamic>> Function(String)? readMetadata,
    Future<Directory> Function()? supportDirectory,
    Future<Directory> Function()? temporaryDirectory,
  }) : _storage = storage ?? NetworkStorageService.instance,
       _readMetadata =
           readMetadata ??
           ((source) => NetworkMetadataService.instance.read(
             source,
             forceRefresh: true,
           )),
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;

  final NetworkStorageService _storage;
  final Future<Map<String, dynamic>> Function(String) _readMetadata;
  final Future<Directory> Function() _supportDirectory, _temporaryDirectory;

  Future<LibraryScanNDJSONFile> scan(
    String source, {
    required Future<void> Function() checkpoint,
    required void Function(int processed, int errors, String name) onProgress,
  }) async {
    final uri = Uri.parse(source);
    if (uri.scheme != 'network' ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('Invalid network library source');
    }
    final connection = await _storage.connection(uri.host);
    if (connection.protocol == NetworkProtocol.http) {
      throw const FormatException('Library folders require SMB or WebDAV');
    }
    final root = networkPath(uri.pathSegments.join('/'));
    if (root.isNotEmpty && !root.endsWith('/')) {
      throw const FormatException('Expected a network folder');
    }
    await checkpoint();
    // Fail before creating scan output if the root cannot be listed.
    final first = await _storage.list(connection, root);
    final temp = await Directory(
      '${(await _temporaryDirectory()).path}/network_scans',
    ).create(recursive: true);
    final covers = await Directory(
      '${(await _supportDirectory()).path}/library_covers',
    ).create(recursive: true);
    final file = File('${temp.path}/${NetworkStorageService.newId()}.ndjson');
    final output = await file.open(mode: FileMode.write);
    var written = 0;
    var processed = 0;
    var errors = 0;
    final pending = <String>[root];
    final visited = <String>{};
    final seenFiles = <String>{};
    try {
      while (pending.isNotEmpty) {
        await checkpoint();
        final folder = pending.removeLast();
        if (!visited.add(folder)) continue;
        if (visited.length > 100000) {
          throw StateError('Too many network folders');
        }
        final List<NetworkEntry> entries;
        try {
          entries = folder == root
              ? first
              : await _storage.list(connection, folder);
        } catch (error) {
          errors++;
          _log.e('Network folder listing failed [$folder]', error);
          onProgress(processed, errors, folder);
          continue;
        }
        for (final entry in entries) {
          await checkpoint();
          final path = networkPath(entry.path);
          // Reject provider parent links and paths outside this folder.
          if (!path.startsWith(folder) || path == folder) continue;
          if (entry.directory) {
            if (!path.endsWith('/')) {
              throw const FormatException('Invalid folder entry');
            }
            pending.add(path);
            continue;
          }
          if (!entry.audio || !seenFiles.add(path)) continue;
          final trackSource = NetworkStorageService.source(connection.id, path);
          try {
            final tags = await _readMetadata(trackSource);
            if (tags['error'] != null || tags['metadataFromFilename'] == true) {
              throw StateError(
                tags['error']?.toString() ?? 'Network tags unavailable',
              );
            }
            final id = 'network_${sha256.convert(utf8.encode(trackSource))}';
            String? coverPath;
            final cover = tags['cover_path']?.toString();
            if (cover != null &&
                cover.isNotEmpty &&
                await File(cover).exists()) {
              // Identical embedded artwork shares an immutable file, including
              // across albums/sources. Cleanup retains all DB cover references.
              File? target;
              File? staged;
              try {
                final digest = await sha256.bind(File(cover).openRead()).first;
                target = File('${covers.path}/network_cover_$digest.image');
                staged = File(
                  '${target.path}.${NetworkStorageService.newId()}.tmp',
                );
                if (!await target.exists() || await target.length() == 0) {
                  await File(cover).copy(staged.path);
                  await staged.rename(target.path);
                }
                coverPath = target.path;
              } catch (_) {
                if (target != null && await target.exists()) {
                  coverPath = target.path;
                }
              } finally {
                if (staged != null && await staged.exists()) {
                  await staged.delete();
                }
              }
            }
            await checkpoint();
            final row = networkLibraryRow(trackSource, entry, tags)
              ..['id'] = id
              ..['coverPath'] = coverPath;
            await output.writeString('${jsonEncode(row)}\n');
            written++;
          } catch (error) {
            // Cancellation must abort the whole staging operation.
            await checkpoint();
            errors++;
            _log.e('Network track scan failed [$trackSource]', error);
          }
          processed++;
          onProgress(processed, errors, entry.name);
        }
      }
      await checkpoint();
      await output.close();
      return LibraryScanNDJSONFile(
        file: file,
        expectedCount: written,
        errorCount: errors,
      );
    } catch (_) {
      await output.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }
}

Map<String, dynamic> networkLibraryRow(
  String source,
  NetworkEntry entry,
  Map<String, dynamic> tags,
) {
  String text(String key, String fallback) {
    final value = tags[key]?.toString().trim() ?? '';
    return value.isEmpty ? fallback : value;
  }

  return {
    'filePath': source,
    'scannedAt': DateTime.now().toIso8601String(),
    'trackName': text(
      'title',
      entry.name.replaceFirst(RegExp(r'\.[^.]+$'), ''),
    ),
    'artistName': text('artist', 'Unknown Artist'),
    'albumName': text('album', 'Unknown Album'),
    'format': text('audio_codec', text('format', entry.extension)),
    'hasLyrics': hasUsableLyricsContent(tags['lyrics']?.toString() ?? ''),
    'explicit': tags['explicit'] == true,
    for (final field in const {
      'album_artist': 'albumArtist',
      'isrc': 'isrc',
      'genre': 'genre',
      'date': 'releaseDate',
      'composer': 'composer',
      'label': 'label',
      'copyright': 'copyright',
      'album_type': 'albumType',
      'track_number': 'trackNumber',
      'total_tracks': 'totalTracks',
      'disc_number': 'discNumber',
      'total_discs': 'totalDiscs',
      'duration': 'duration',
      'bit_depth': 'bitDepth',
      'sample_rate': 'sampleRate',
      'bitrate': 'bitrate',
      'replaygain_track_gain': 'replaygain_track_gain',
      'replaygain_album_gain': 'replaygain_album_gain',
    }.entries)
      if (tags[field.key] != null) field.value: tags[field.key],
  };
}
