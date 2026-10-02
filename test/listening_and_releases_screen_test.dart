import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/providers/weekly_releases_provider.dart';
import 'package:spotiflac_android/screens/listening_statistics_screen.dart';
import 'package:spotiflac_android/screens/weekly_releases_screen.dart';
import 'package:spotiflac_android/services/listening_statistics.dart';
import 'package:spotiflac_android/services/weekly_releases.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

void main() {
  for (final mornye in [false, true]) {
    Widget app(Widget page) => MaterialApp(
      theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: page,
    );
    testWidgets(
      'listening recap shows totals and supports annual view ($mornye)',
      (tester) async {
        final requested = <({int days, int year})>[];
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(_Settings.new),
              listeningSummaryProvider.overrideWith((ref, period) async {
                requested.add(period);
                return ListeningSummary.fromRows([
                  {
                    'day': '2026-10-01',
                    'track_key': 'one',
                    'title': 'One',
                    'artist': 'Artist',
                    'album': 'Album',
                    'milliseconds': 120000,
                    'plays': 1,
                    'artwork': null,
                  },
                ]);
              }),
            ],
            child: app(const ListeningStatisticsScreen()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('1 play · 1 track · 1 active day'), findsOneWidget);
        await tester.tap(find.text('${DateTime.now().year}'));
        await tester.pumpAndSettle();
        expect(requested.last.days, 0);
        expect(requested.last.year, DateTime.now().year);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'new releases supports week/month and explains incomplete providers ($mornye)',
      (tester) async {
        final now = DateTime.now();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              weeklyReleasesProvider.overrideWith(
                (ref, refresh) async => WeeklyReleaseFeed(
                  [
                    for (final days in [1, 10])
                      WeeklyRelease(
                        id: '$days',
                        name: 'Release $days',
                        artist: 'Artist',
                        providerId: 'provider-a',
                        date: now.subtract(Duration(days: days)),
                      ),
                  ],
                  unavailableArtists: ['Other Artist'],
                ),
              ),
            ],
            child: app(const WeeklyReleasesScreen()),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Release 1'), findsOneWidget);
        expect(find.text('Release 10'), findsNothing);
        await tester.tap(find.text('30 days'));
        await tester.pumpAndSettle();
        expect(find.text('Release 10'), findsOneWidget);
        expect(find.textContaining('Other Artist'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
