import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/app_switch.dart';
import 'package:spotiflac_android/widgets/mornye_chrome.dart';
import 'package:spotiflac_android/widgets/mornye_selection_pill.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('tab dragging previews, commits and cancels ($direction)', (
      tester,
    ) async {
      var selected = -1;
      final changes = <int>[];
      final capture = GlobalKey();
      final theme = MornyeTheme.build(Brightness.dark);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: theme,
            home: Directionality(
              textDirection: direction,
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 360,
                    child: StatefulBuilder(
                      builder: (context, setState) => RepaintBoundary(
                        key: capture,
                        child: MornyeTabBar(
                          destinations: const [
                            NavigationDestination(
                              icon: Icon(Icons.home),
                              label: 'Home',
                            ),
                            NavigationDestination(
                              icon: MornyeNavigationIcon(
                                icon: Icons.music_note,
                                badgeCount: 7,
                              ),
                              label: 'Library',
                            ),
                            NavigationDestination(
                              icon: Icon(Icons.search),
                              label: 'Search',
                            ),
                          ],
                          selectedIndex: selected,
                          onSelected: (next) {
                            changes.add(next);
                            setState(() => selected = next);
                          },
                          blurEnabled: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // No selection must still allow activating the first destination.
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      expect(changes, [0]);
      final home = tester.getCenter(find.text('Home'));
      final library = tester.getCenter(find.text('Library'));
      final pill = find.descendant(
        of: find.byType(MornyeSelectionPill),
        matching: find.byType(FractionallySizedBox),
      );
      final gesture = await tester.startGesture(home);
      // Move within tabs, across their boundaries, and reverse direction.
      // One frame must put the pill under the finger without a settling delay.
      for (final fraction in [0.35, 0.45, 0.5, 0.85, 1.2, 1.1, 0.9, 1.5]) {
        final position = Offset(
          home.dx + (library.dx - home.dx) * fraction,
          home.dy,
        );
        await gesture.moveTo(position);
        await tester.pump();
        expect(tester.getCenter(pill).dx, closeTo(position.dx, 0.1));
        expect(changes, [0]);
        if (fraction == 0.5) {
          // Halfway between destinations, both icons and both labels contain
          // active and inactive pixels. A nearest-index color swap cannot pass.
          for (final finder in [
            find.byIcon(Icons.home),
            find.byIcon(Icons.music_note),
            find.text('Home'),
            find.text('Library'),
          ]) {
            final colors = await _foregroundPixels(tester, capture, finder, [
              theme.colorScheme.primary,
              theme.colorScheme.onSurface,
            ]);
            expect(colors, everyElement(greaterThan(3)));
          }
          final badgePixels = await _foregroundPixels(
            tester,
            capture,
            find.text('7'),
            [theme.colorScheme.onError],
          );
          expect(badgePixels.single, greaterThan(3));
        }
      }
      await gesture.moveTo(tester.getCenter(find.text('Search')));
      await tester.pumpAndSettle();
      expect(changes, [0]);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(changes, [0, 2]);
      expect(
        tester.getCenter(pill).dx,
        closeTo(tester.getCenter(find.text('Search')).dx, 0.1),
      );
      final cancelled = await tester.startGesture(
        tester.getCenter(find.text('Search')),
      );
      await cancelled.moveTo(tester.getCenter(find.text('Home')));
      await tester.pump();
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(changes, [0, 2]);
      expect(
        tester.getCenter(pill).dx,
        closeTo(tester.getCenter(find.text('Search')).dx, 0.1),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(changes.length, 3);
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Search'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switch drag toggles once with no filter ($direction)', (
      tester,
    ) async {
      var value = false;
      final changes = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: Center(
                child: StatefulBuilder(
                  builder: (context, setState) => AppSwitch(
                    value: value,
                    onChanged: (next) {
                      changes.add(next);
                      setState(() => value = next);
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final sign = direction == TextDirection.ltr ? 1.0 : -1.0;
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(AppSwitch)),
      );
      await gesture.moveBy(Offset(25 * sign, 0));
      await gesture.moveBy(Offset(25 * sign, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(changes, [true]);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('nested glass uses one bounded filter and large text fits', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(3)),
            child: Scaffold(
              body: Column(
                children: [
                  MornyeGlassPanel(
                    child: MornyeSegmentedControl(
                      labels: const ['A', 'B'],
                      selectedIndex: 0,
                      onChanged: (_) {},
                    ),
                  ),
                  MornyeTabBar(
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.home),
                        label: 'Home',
                      ),
                    ],
                    selectedIndex: 0,
                    onSelected: (_) {},
                    blurEnabled: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(MornyeGlassPanel),
        matching: find.byType(BackdropFilter),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(find.byType(MornyeTabBar)).height, greaterThan(80));
    expect(tester.takeException(), isNull);
  });
}

Future<List<int>> _foregroundPixels(
  WidgetTester tester,
  GlobalKey capture,
  Finder finder,
  List<Color> colors,
) async {
  final boundary =
      capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final rect = tester
      .getRect(finder)
      .shift(-boundary.localToGlobal(Offset.zero));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      final bytes = (await image.toByteData())!;
      final counts = List.filled(colors.length, 0);
      for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
        for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
          final offset = (y * image.width + x) * 4;
          for (var i = 0; i < colors.length; i++) {
            final argb = colors[i].toARGB32();
            if ((bytes.getUint8(offset) - ((argb >> 16) & 255)).abs() <= 2 &&
                (bytes.getUint8(offset + 1) - ((argb >> 8) & 255)).abs() <= 2 &&
                (bytes.getUint8(offset + 2) - (argb & 255)).abs() <= 2) {
              counts[i]++;
            }
          }
        }
      }
      return counts;
    } finally {
      image.dispose();
    }
  }))!;
}
