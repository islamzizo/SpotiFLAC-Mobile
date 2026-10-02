import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/unified_library_item.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/services/related_library_tracks.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/utils/clickable_metadata.dart';

UnifiedLibraryItem _track(
  String id, {
  String artist = 'First Artist',
  String album = 'Album',
  String? genre,
  String? path,
}) => UnifiedLibraryItem.fromLocalLibrary(
  LocalLibraryItem(
    id: id,
    trackName: id,
    artistName: artist,
    albumName: album,
    genre: genre,
    filePath: path ?? '/$id.flac',
    scannedAt: DateTime(2026),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'related Library songs rank credits, deduplicate and exclude remote files',
    () {
      final seed = _track(
        'seed',
        artist: 'First Artist feat. Second Artist',
        genre: 'Rock',
      );
      final album = _track('album', genre: 'Rock');
      final genre = _track(
        'genre',
        artist: 'Other',
        album: 'Other Album',
        genre: 'Rock',
      );
      final collaborator = _track(
        'collaborator',
        artist: 'Second Artist',
        album: 'Other Album',
      );
      final results = rankRelatedLibraryTracks(seed, [
        seed,
        album,
        album,
        genre,
        collaborator,
        _track('unrelated', artist: 'Other', album: 'Other Album'),
        _track('remote', path: 'https://example.com/music.flac'),
        _track('album', path: '/duplicate.flac', genre: 'Rock'),
      ]);
      expect(results.map((item) => item.trackName), [
        'album',
        'collaborator',
        'genre',
      ]);
    },
  );

  for (final mornye in [false, true]) {
    testWidgets('artist picker offers each featured credit ($mornye)', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => navigateToArtistCredits(
                    context,
                    artistNames: 'First Artist featured Second Artist',
                  ),
                  child: const Text('Artists'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Artists'));
      await tester.pumpAndSettle();
      expect(find.text('First Artist'), findsOneWidget);
      expect(find.text('Second Artist'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
