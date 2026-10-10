import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/download_history_provider.dart';
import 'package:spotiflac_android/providers/local_library_provider.dart';

/// Call only after deletion succeeds. A download can also have a scanned row;
/// removing just one index makes its other row visible as a ghost entry.
Future<void> removeDeletedLibraryFileEntries(
  WidgetRef ref,
  Iterable<String> filePaths,
) async {
  final paths = filePaths.toSet();
  if (paths.isEmpty) return;
  await ref.read(downloadHistoryProvider.notifier).removePhysicalFiles(paths);
  await ref.read(localLibraryProvider.notifier).removePhysicalFiles(paths);
}
