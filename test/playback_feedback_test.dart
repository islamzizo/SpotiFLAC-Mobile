import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/l10n/app_localizations.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/services/music_player_runtime.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/app_snack_bar.dart';
import 'package:spotiflac_android/widgets/mornye_chrome.dart';
import 'package:spotiflac_android/widgets/playback_feedback.dart';

void main() {
  for (final mornye in [false, true]) {
    testWidgets('muted feedback is transient and themed (Mornye: $mornye)', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final runtime = MusicPlayerRuntime();
      addTearDown(runtime.dispose);
      // Notices emitted before the shell mounts must not be replayed.
      runtime.notifyMutedPlayback();
      final message = mornye
          ? 'Volume media nol. Lagu dijeda. Tekan play lagi untuk tetap memutar.'
          : 'Media volume is zero. Playback paused. Press play again to continue.';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
          child: MaterialApp(
            locale: Locale(mornye ? 'id' : 'en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            builder: (_, child) =>
                AppScaffoldMessenger(child: PlaybackFeedback(child: child!)),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      runtime.notifyMutedPlayback();
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(
        find.byType(MornyeGlassPanel),
        mornye ? findsOneWidget : findsNothing,
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      runtime.notifyMutedPlayback();
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      // A later mute episode may emit the exact same warning again.
      runtime.notifyMutedPlayback();
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
