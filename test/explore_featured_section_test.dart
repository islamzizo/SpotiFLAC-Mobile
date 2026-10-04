import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/providers/explore_provider.dart';
import 'package:spotiflac_android/widgets/explore_featured_section.dart';
import 'package:spotiflac_android/widgets/audio_quality_badges.dart';
import 'package:spotiflac_android/l10n/app_localizations.dart';

void main() {
  test('featured layout and artwork survive cache serialization', () {
    final section = ExploreSection.fromJson({
      'uri': 'featured',
      'title': 'New',
      'layout': 'featured',
      'items': [
        {
          'id': 'collection-1',
          'type': 'playlist',
          'name': 'Featured playlist',
          'cover_url': 'https://example.test/cover.jpg',
          'featured_cover_url': 'https://example.test/banner.jpg',
          'heading': 'Updated playlist',
          'provider_id': 'example-provider',
          'explicit': true,
        },
      ],
    });
    final restored = ExploreSection.fromJson(section.toJson());
    expect(restored.isFeatured, isTrue);
    expect(restored.items.single.heading, 'Updated playlist');
    expect(restored.items.single.featuredCoverUrl, endsWith('/banner.jpg'));
    expect(restored.items.single.coverUrl, endsWith('/cover.jpg'));
    expect(restored.items.single.providerId, 'example-provider');
    expect(restored.items.single.explicit, isTrue);
    expect(ExploreItem.fromJson({'explicit': false}).explicit, isFalse);
    expect(ExploreItem.fromJson({}).explicit, isNull);
    expect(ExploreSection.fromJson({'items': <Object?>[]}).isFeatured, isFalse);
  });

  for (final (size, scale) in [
    (const Size(390, 844), 1.0),
    (const Size(320, 844), 2.0),
    (const Size(1024, 768), 1.0),
  ]) {
    testWidgets('featured cards scroll and open at $size, text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      ExploreItem? opened;
      final items = List.generate(
        4,
        (index) => ExploreItem(
          id: 'collection-$index',
          uri: 'example:collection:$index',
          type: 'album',
          name: 'Featured $index',
          artists: 'Example artist',
          heading: 'New album',
          explicit: index == 0,
          description: 'An editorial description of the featured album.',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: ExploreFeaturedSection(
                  section: ExploreSection(
                    uri: 'featured',
                    title: 'New',
                    items: items,
                    isFeatured: true,
                  ),
                  onItemTap: (item, _) => opened = item,
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(ExplicitBadge), findsOneWidget);
      expect(
        tester
            .widget<ExplicitTrackTitle>(find.byType(ExplicitTrackTitle).first)
            .explicit,
        isTrue,
      );
      final firstTitle = find.byWidgetPredicate(
        (widget) =>
            widget is ExplicitTrackTitle && widget.title == 'Featured 0',
      );
      final card = find.ancestor(
        of: firstTitle,
        matching: find.byType(GestureDetector),
      );
      expect(tester.getSize(card).width, greaterThan(250));
      await tester.tap(firstTitle);
      expect(opened?.id, 'collection-0');
      await tester.drag(find.byType(ListView), const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('Featured 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
