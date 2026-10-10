import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/theme/app_theme.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/app_bottom_sheet.dart';
import 'package:spotiflac_android/widgets/selection_bottom_bar.dart';

void main() {
  for (final mornye in [false, true]) {
    final name = mornye ? 'Mornye' : 'Material';

    Future<void> showPanel(
      WidgetTester tester,
      VoidCallback onClose, {
      bool tall = false,
    }) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.light)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Stack(
                children: [
                  ListView(children: const [SizedBox(height: 2000)]),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: SelectionBottomBar(
                      selectedCount: 1,
                      allSelected: true,
                      onClose: onClose,
                      onToggleSelectAll: () {},
                      bottomPadding: 0,
                      children: [
                        SizedBox(height: tall ? 900 : 140),
                        TextButton(
                          onPressed: () {},
                          child: const Text('Action'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('$name: downward drag moves the panel and closes once', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      final surface = find.byType(SingleChildScrollView);
      final initial = tester.getTopLeft(surface);
      final handle = find.byType(AppSheetHandle);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(0, 25));
      await gesture.moveBy(const Offset(0, 110));
      await tester.pump();
      expect(tester.getTopLeft(surface).dy, greaterThan(initial.dy + 90));
      final background = tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        ),
      );
      expect(background.position.pixels, 0);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(closed, 1);
      await tester.pumpWidget(const SizedBox());
      expect(closed, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$name: short drag returns without closing', (tester) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      final surface = find.byType(SingleChildScrollView);
      final initial = tester.getTopLeft(surface);
      await tester.timedDrag(
        find.byType(AppSheetHandle),
        const Offset(0, 40),
        const Duration(milliseconds: 600),
      );
      await tester.pumpAndSettle();
      expect(closed, 0);
      expect(tester.getTopLeft(surface), initial);
    });

    testWidgets('$name: reversing a pull returns the whole panel', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      final surface = find.byType(SingleChildScrollView);
      final initial = tester.getTopLeft(surface);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(AppSheetHandle)),
      );
      await gesture.moveBy(const Offset(0, 25));
      await gesture.moveBy(const Offset(0, 100));
      await tester.pump();
      expect(tester.getTopLeft(surface).dy, greaterThan(initial.dy));
      await gesture.moveBy(const Offset(0, -140));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(closed, 0);
      expect(tester.getTopLeft(surface), initial);
    });

    testWidgets('$name: route disposal cancels pending dismiss callback', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++);
      await tester.drag(find.byType(AppSheetHandle), const Offset(0, 150));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(closed, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('$name: tall actions scroll before dragging the panel', (
      tester,
    ) async {
      var closed = 0;
      await showPanel(tester, () => closed++, tall: true);
      final surface = find.byType(SingleChildScrollView);
      final initial = tester.getTopLeft(surface);
      final scroll = tester.widget<SingleChildScrollView>(surface).controller!;
      await tester.timedDrag(
        surface,
        const Offset(0, -220),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(180));
      expect(tester.getTopLeft(surface), initial);
      final offset = scroll.offset;
      await tester.timedDrag(
        surface,
        const Offset(0, 80),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(scroll.offset, lessThan(offset));
      expect(tester.getTopLeft(surface), initial);
      expect(closed, 0);
    });
  }
}
