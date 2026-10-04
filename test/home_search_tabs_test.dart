import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/l10n/app_localizations.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/explore_provider.dart';
import 'package:spotiflac_android/providers/extension_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/recent_access_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/providers/track_provider.dart';
import 'package:spotiflac_android/screens/home_tab.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/app_search_field.dart';
import 'package:spotiflac_android/widgets/lazy_tab_view.dart';
import 'package:spotiflac_android/widgets/mornye_chrome.dart';

void main() {
  testWidgets(
    'Home keeps its feed while Search retains its query and results',
    (tester) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final search = _Search();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            extensionProvider.overrideWith(_Extensions.new),
            exploreProvider.overrideWith(_Explore.new),
            downloadHistoryProvider.overrideWith(_History.new),
            recentAccessProvider.overrideWith(_Recent.new),
            trackProvider.overrideWith(() => search),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const _Tabs(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Featured albums'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('Recently visited artist'), findsNothing);

      await tester.tap(find.text('Open Search'));
      await tester.pumpAndSettle();
      expect(find.text('Search'), findsWidgets);
      expect(find.text('Featured albums').hitTestable(), findsNothing);
      expect(find.text('Recently visited artist'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Example');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Example',
      );
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(search._requests, 1);
      expect(find.text('Found artist'), findsOneWidget);

      await tester.tap(find.text('Open Home'));
      await tester.pumpAndSettle();
      expect(find.text('Featured albums'), findsOneWidget);
      expect(find.byType(TextField).hitTestable(), findsNothing);
      expect(find.text('Found artist').hitTestable(), findsNothing);

      await tester.tap(find.text('Open Search'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Example',
      );
      expect(find.text('Found artist'), findsOneWidget);
      expect(search._requests, 1);
      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(find.text('Found artist'), findsNothing);
      expect(find.text('Recently visited artist'), findsOneWidget);
      expect(find.text('Featured albums').hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed verification search can retry the same query', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final search = _Search(failFirst: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(_Recent.new),
          trackProvider.overrideWith(() => search),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const _Tabs(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Search'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Example');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(search._requests, 1);
    expect(find.text('Found artist'), findsNothing);

    await tester.tap(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(search._requests, 2);
    expect(find.text('Found artist'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final (brightness, itemType) in [
    for (final brightness in Brightness.values)
      for (final itemType in ['artist', 'track']) (brightness, itemType),
  ]) {
    testWidgets(
      'Search keeps field glass and scrolls $itemType results without blur in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(430, 650);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final search = _Search(resultCount: 120, itemType: itemType);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(_Settings.new),
              extensionProvider.overrideWith(_Extensions.new),
              exploreProvider.overrideWith(_Explore.new),
              downloadHistoryProvider.overrideWith(_History.new),
              downloadHistoryBatchExistsProvider.overrideWith(
                (ref, request) async => <String>{},
              ),
              downloadQueueLookupProvider.overrideWith(
                (ref) => DownloadQueueState().lookup,
              ),
              currentMediaItemProvider.overrideWith(
                (ref) => Stream.value(null),
              ),
              recentAccessProvider.overrideWith(_Recent.new),
              trackProvider.overrideWith(() => search),
            ],
            child: MaterialApp(
              theme: MornyeTheme.build(brightness),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const HomeTab(mode: HomeTabMode.search),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(AppSearchField),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
        await tester.enterText(find.byType(TextField), 'Example');
        await tester.testTextInput.receiveAction(TextInputAction.search);
        await tester.pumpAndSettle();
        expect(find.text('Found $itemType 0'), findsOneWidget);
        expect(find.text('Found $itemType 119'), findsNothing);
        expect(
          find.descendant(
            of: find.ancestor(
              of: find.text('Found $itemType 0'),
              matching: find.byType(MornyeGlassPanel),
            ),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );

        await tester.scrollUntilVisible(
          find.text('Found $itemType 119'),
          500,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.text('Found $itemType 119').hitTestable(), findsOneWidget);
        expect(search._requests, 1);
        expect(
          find.descendant(
            of: find.ancestor(
              of: find.text('Found $itemType 119'),
              matching: find.byType(MornyeGlassPanel),
            ),
            matching: find.byType(BackdropFilter),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Search builds recent items as they enter the viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          exploreProvider.overrideWith(_Explore.new),
          downloadHistoryProvider.overrideWith(_History.new),
          recentAccessProvider.overrideWith(() => _Recent(itemCount: 10)),
          trackProvider.overrideWith(_Search.new),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const HomeTab(mode: HomeTabMode.search),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Recent artist 0'), findsOneWidget);
    expect(find.text('Recent artist 9'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('Recent artist 9'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Recent artist 9').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _Tabs extends StatefulWidget {
  const _Tabs();

  @override
  State<_Tabs> createState() => _TabsState();
}

class _TabsState extends State<_Tabs> {
  int _index = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: LazyTabView(
      index: _index,
      children: [
        TickerMode(
          key: const ValueKey('home'),
          enabled: _index == 0,
          child: const HomeTab(mode: HomeTabMode.browse),
        ),
        TickerMode(
          key: const ValueKey('search'),
          enabled: _index == 1,
          child: const HomeTab(mode: HomeTabMode.search),
        ),
      ],
    ),
    bottomNavigationBar: Row(
      children: [
        for (final (index, label) in [(0, 'Open Home'), (1, 'Open Search')])
          TextButton(
            onPressed: () {
              FocusManager.instance.primaryFocus?.unfocus();
              setState(() => _index = index);
            },
            child: Text(label),
          ),
      ],
    ),
  );
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(searchProvider: 'example', hasSearchedBefore: true);
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'example',
        name: 'example',
        displayName: 'Example',
        version: '1.0.0',
        description: '',
        enabled: true,
        status: 'loaded',
        hasMetadataProvider: true,
        searchBehavior: SearchBehavior(enabled: true),
      ),
    ],
  );
}

class _Explore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState(
    sections: [
      ExploreSection(
        uri: 'example:featured',
        title: 'Featured albums',
        items: [],
      ),
    ],
  );
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Recent extends RecentAccessNotifier {
  _Recent({this.itemCount = 1});

  final int itemCount;

  @override
  RecentAccessState build() => RecentAccessState(
    isLoaded: true,
    items: List.generate(
      itemCount,
      (index) => RecentAccessItem(
        id: 'recent-$index',
        name: itemCount == 1
            ? 'Recently visited artist'
            : 'Recent artist $index',
        type: RecentAccessType.artist,
        accessedAt: DateTime(2026, 1, itemCount - index),
        providerId: 'example',
      ),
    ),
  );
}

class _Search extends TrackNotifier {
  _Search({
    bool failFirst = false,
    this.resultCount = 1,
    this.itemType = 'artist',
  }) : _failFirst = failFirst;

  final bool _failFirst;
  final int resultCount;
  final String itemType;
  int _requests = 0;

  @override
  Future<void> customSearch(
    String extensionId,
    String query, {
    Map<String, dynamic>? options,
    String? selectedFilter,
    bool allowVerificationRetry = true,
  }) async {
    _requests++;
    if (_failFirst && _requests == 1) {
      state = const TrackState(
        hasSearchText: true,
        error: 'verification_required',
      );
      return;
    }
    state = TrackState(
      hasSearchText: true,
      searchExtensionId: 'example',
      tracks: List.generate(
        resultCount,
        (index) => Track(
          id: '$itemType-$index',
          name: resultCount == 1 ? 'Found $itemType' : 'Found $itemType $index',
          artistName: '',
          albumName: '',
          duration: 0,
          itemType: itemType,
          source: 'example',
        ),
      ),
    );
  }
}
