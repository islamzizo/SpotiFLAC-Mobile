import 'dart:convert';
import 'dart:io';

import 'package:spotiflac_android/services/ffmpeg_models.dart';
import 'package:spotiflac_android/services/ffmpeg_probe.dart';
import 'package:spotiflac_android/services/ffmpeg_support.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('FFmpeg');

/// Extension descriptor interpretation and MOV-key container fallbacks.
abstract final class FFmpegDecryption {
  static Future<String?> decrypt({
    required String inputPath,
    required DownloadDecryptionDescriptor descriptor,
    bool deleteOriginal = true,
  }) async {
    if (descriptor.normalizedStrategy != 'ffmpeg.mov_key') {
      _log.e(
        'Unsupported download decryption strategy: ${descriptor.strategy}',
      );
      return null;
    }
    final key = descriptor.key.trim();
    if (key.isEmpty) return inputPath;
    return _decryptMovKeyFile(
      inputPath: inputPath,
      decryptionKey: key,
      inputFormat: descriptor.inputFormat,
      outputExtension: descriptor.outputExtension,
      deleteOriginal: deleteOriginal,
    );
  }

  static List<String> _keyCandidates(String rawKey) {
    final candidates = <String>[];
    void add(String key) {
      final normalized = key.trim();
      if (normalized.isNotEmpty && !candidates.contains(normalized)) {
        candidates.add(normalized);
      }
    }

    final trimmed = rawKey.trim();
    if (trimmed.isEmpty) return candidates;
    add(trimmed);
    final noPrefix = trimmed.startsWith(RegExp(r'0x', caseSensitive: false))
        ? trimmed.substring(2)
        : trimmed;
    add(noPrefix);
    final compactHex = noPrefix.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (compactHex.isNotEmpty && compactHex.length.isEven) add(compactHex);
    try {
      final decoded = base64Decode(noPrefix.replaceAll(RegExp(r'\s+'), ''));
      if (decoded.isNotEmpty) {
        add(decoded.map((b) => b.toRadixString(16).padLeft(2, '0')).join());
      }
    } catch (_) {}
    return candidates;
  }

  static String _preferredExtension(String inputPath, String? requested) {
    final extension = (requested ?? '').trim();
    if (extension.isNotEmpty) {
      return extension.startsWith('.') ? extension : '.$extension';
    }
    for (final ext in ['.mp3', '.opus', '.mp4']) {
      if (inputPath.toLowerCase().endsWith(ext)) return ext;
    }
    return '.flac';
  }

  static String _outputPath(String inputPath, String extension) {
    final file = File(inputPath);
    final name = file.uri.pathSegments.last;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final path = '${file.parent.path}${Platform.pathSeparator}$base$extension';
    return path == inputPath
        ? '${file.parent.path}${Platform.pathSeparator}${base}_converted$extension'
        : path;
  }

  static Future<String?> _decryptMovKeyFile({
    required String inputPath,
    required String decryptionKey,
    String? inputFormat,
    String? outputExtension,
    required bool deleteOriginal,
  }) async {
    final preferredExt = _preferredExtension(inputPath, outputExtension);
    var tempOutput = _outputPath(inputPath, preferredExt);
    final demuxer = (inputFormat ?? '').trim().isNotEmpty
        ? inputFormat!.trim()
        : 'mov';
    String command(
      String outputPath, {
      required bool mapAudioOnly,
      required String key,
      bool forceMov = false,
    }) {
      final map = mapAudioOnly ? '-map 0:a ' : '';
      // Encrypted MOV may have a FLAC suffix; override input detection. Native
      // FLAC output also needs an explicit muxer. MOV permits codecs such as
      // AC-4 that the MP4 muxer rejects while keeping the .mp4 filename.
      final muxer = forceMov
          ? '-f mov '
          : outputPath.toLowerCase().endsWith('.flac')
          ? '-f flac '
          : '';
      return '-v error -decryption_key "$key" -f $demuxer -i "$inputPath" $map-c copy $muxer"$outputPath" -y';
    }

    final candidates = _keyCandidates(decryptionKey);
    if (candidates.isEmpty) {
      _log.e('No usable decryption key candidates');
      return null;
    }
    FFmpegResult? lastResult;
    var succeeded = false;
    for (final key in candidates) {
      _log.d('Executing FFmpeg decrypt command (key length: ${key.length})');
      var result = await FFmpegExecution.command(
        command(tempOutput, mapAudioOnly: preferredExt == '.flac', key: key),
      );
      if (!result.success && preferredExt == '.flac') {
        final fallback = _outputPath(inputPath, '.m4a');
        final attempt = await FFmpegExecution.command(
          command(fallback, mapAudioOnly: false, key: key),
        );
        if (attempt.success) {
          tempOutput = fallback;
          result = attempt;
        }
      }
      if (!result.success &&
          (preferredExt == '.flac' || preferredExt == '.m4a')) {
        final fallback = _outputPath(inputPath, '.mp4');
        final attempt = await FFmpegExecution.command(
          command(fallback, mapAudioOnly: false, key: key),
        );
        if (attempt.success) {
          tempOutput = fallback;
          result = attempt;
        }
      }
      if (!result.success) {
        final fallback = _outputPath(inputPath, '.mp4');
        final attempt = await FFmpegExecution.command(
          command(fallback, mapAudioOnly: false, key: key, forceMov: true),
        );
        if (attempt.success) {
          tempOutput = fallback;
          result = attempt;
        }
      }
      lastResult = result;
      if (result.success) {
        succeeded = true;
        break;
      }
      await FFmpegOutput.cleanup(tempOutput);
    }
    if (!succeeded) {
      _log.e('FFmpeg decrypt failed: ${lastResult?.output ?? 'unknown error'}');
      return null;
    }
    try {
      if (!await File(tempOutput).exists()) {
        _log.e('Decrypted output file not found: $tempOutput');
        return null;
      }
      final source = File(inputPath);
      if (deleteOriginal && await source.exists()) await source.delete();
      FFmpegProbe.invalidate(inputPath);
      FFmpegProbe.invalidate(tempOutput);
      return tempOutput;
    } catch (e) {
      _log.e('Failed to finalize decrypted file: $e');
      return null;
    }
  }
}
