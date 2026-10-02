import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_easy/liquid_glass_easy.dart';
import 'package:spotiflac_android/providers/runtime_profile_provider.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';
import 'package:spotiflac_android/widgets/app_switch.dart';
import 'package:spotiflac_android/widgets/extension_repo_card.dart';
import 'package:spotiflac_android/widgets/mornye_chrome.dart';

MornyeGlassLevel _levelFor({
  required bool lowEnd,
  required bool blur,
  required bool liquidCapable,
}) {
  final container = ProviderContainer(
    overrides: [
      lowEndDeviceProvider.overrideWithValue(lowEnd),
      // Device default or the user's "always use blur effects" override.
      backdropBlurEnabledProvider.overrideWithValue(blur),
      deviceSupportsLiquidGlassProvider.overrideWithValue(liquidCapable),
    ],
  );
  addTearDown(container.dispose);
  return container.read(mornyeGlassLevelProvider);
}

void main() {
  test('runtime tiers map to Mornye glass levels', () {
    // Low tier: arm32-only or low-RAM Android.
    expect(
      _levelFor(lowEnd: true, blur: false, liquidCapable: false),
      MornyeGlassLevel.flat,
    );
    // Standard Android: frosted blur without shader passes.
    expect(
      _levelFor(lowEnd: false, blur: false, liquidCapable: false),
      MornyeGlassLevel.frosted,
    );
    // iOS runs the standard tier but keeps the full material.
    expect(
      _levelFor(lowEnd: false, blur: false, liquidCapable: true),
      MornyeGlassLevel.liquid,
    );
    // High-tier Android.
    expect(
      _levelFor(lowEnd: false, blur: true, liquidCapable: true),
      MornyeGlassLevel.liquid,
    );
    // "Always use blur effects" restores the full material on any tier.
    for (final lowEnd in [true, false]) {
      expect(
        _levelFor(lowEnd: lowEnd, blur: true, liquidCapable: false),
        MornyeGlassLevel.liquid,
      );
    }
  });

  testWidgets('frosted level keeps blur but drops every shader surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceSupportsLiquidGlassProvider.overrideWithValue(false),
          backdropBlurEnabledProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                const MornyeGlass(
                  blurEnabled: true,
                  child: SizedBox(width: 200, height: 50),
                ),
                MornyeSegmentedControl(
                  labels: const ['One', 'Two'],
                  selectedIndex: 0,
                  onChanged: (_) {},
                ),
                AppSwitch(value: true, onChanged: (_) {}),
                Consumer(
                  builder: (context, ref, _) => MornyeTabBar(
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.home),
                        label: 'Home',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.music_note),
                        label: 'Library',
                      ),
                    ],
                    selectedIndex: 0,
                    onSelected: (_) {},
                    blurEnabled: ref.watch(mornyeBlurEnabledProvider),
                    liquidGlass: ref.watch(mornyeLiquidGlassProvider),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(LiquidGlassLens), findsNothing);
    expect(find.byType(LiquidGlassTabBar), findsNothing);
    expect(find.byType(LiquidGlassSwitch), findsNothing);
    // The frosted material still samples the page behind it.
    expect(find.byType(BackdropFilter), findsWidgets);
    expect(find.text('Library'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'low clarity uses a small blur and mid-range glass caps its radius',
    (tester) async {
      Future<ui.ImageFilter?> filterFor(double clarity, bool liquid) async {
        await tester.pumpWidget(
          ProviderScope(
            key: UniqueKey(),
            overrides: [
              mornyeGlassLevelProvider.overrideWithValue(
                liquid ? MornyeGlassLevel.liquid : MornyeGlassLevel.frosted,
              ),
            ],
            child: MaterialApp(
              theme: MornyeTheme.build(Brightness.light, glassClarity: clarity),
              home: const MornyeGlass.navigation(
                blurEnabled: true,
                child: SizedBox(width: 200, height: 50),
              ),
            ),
          ),
        );
        final filters = tester.widgetList<BackdropFilter>(
          find.byType(BackdropFilter),
        );
        return filters.isEmpty ? null : filters.single.filter;
      }

      expect(await filterFor(0, false), isNull);
      expect(await filterFor(0.1, false), isNull);
      expect(
        await filterFor(0.25, false),
        ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
      );
      expect(
        await filterFor(0.1, true),
        ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
      );
      expect(
        await filterFor(1, false),
        ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
      );
      expect(
        await filterFor(1, true),
        ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      );
    },
  );

  for (final clarity in [0.0, 0.5]) {
    testWidgets('liquid tab and segment pills follow clarity ($clarity)', (
      tester,
    ) async {
      late BuildContext context;
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark, glassClarity: clarity),
            home: Scaffold(
              body: Builder(
                builder: (builderContext) {
                  context = builderContext;
                  return Column(
                    children: [
                      MornyeSegmentedControl(
                        labels: const ['One', 'Two'],
                        selectedIndex: 0,
                        onChanged: (_) {},
                      ),
                      MornyeTabBar(
                        destinations: const [
                          NavigationDestination(
                            icon: Icon(Icons.home),
                            label: 'Home',
                          ),
                          NavigationDestination(
                            icon: Icon(Icons.music_note),
                            label: 'Library',
                          ),
                        ],
                        selectedIndex: 0,
                        onSelected: (_) {},
                        blurEnabled: true,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final liquid = clarity > 0;
      // Overlays aligned with the bar share this decision.
      expect(
        MornyeTabBar.usesLiquidGlass(
          context,
          blurEnabled: true,
          liquidGlass: true,
        ),
        liquid,
      );
      // At 0% the opaque material drops the shader pills, like MornyeGlass
      // drops its lens; the resting segments and tabs remain usable.
      expect(find.byType(LiquidGlassTabBar), findsNWidgets(liquid ? 2 : 0));
      expect(
        find.byType(LiquidGlassLens),
        liquid ? findsWidgets : findsNothing,
      );
      // The shader bar paints its labels in more than one layer.
      expect(find.text('Two'), findsWidgets);
      expect(find.text('Library'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('plain-page panels keep the glass tint without a backdrop pass', (
    tester,
  ) async {
    Color? tintOf(Finder panel) {
      final decorated = tester
          .widgetList<DecoratedBox>(
            find.descendant(of: panel, matching: find.byType(DecoratedBox)),
          )
          .map((box) => box.decoration)
          .whereType<BoxDecoration>()
          .firstWhere((decoration) => decoration.color != null);
      return decorated.color;
    }

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: const Scaffold(
            body: Column(
              children: [
                MornyeGlass.navigation(
                  key: ValueKey('sampled'),
                  blurEnabled: true,
                  child: SizedBox(width: 200, height: 40),
                ),
                MornyeGlass.navigation(
                  key: ValueKey('plain-page'),
                  blurEnabled: true,
                  samplesBackdrop: false,
                  child: SizedBox(width: 200, height: 40),
                ),
                ExtensionRepoCard(child: SizedBox(width: 200, height: 40)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final sampled = find.byKey(const ValueKey('sampled'));
    final plain = find.byKey(const ValueKey('plain-page'));
    expect(
      find.descendant(of: sampled, matching: find.byType(BackdropFilter)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: plain, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byType(ExtensionRepoCard),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
    // Same translucent material, so the page looks identical behind it.
    expect(tintOf(plain), tintOf(sampled));
    expect(tintOf(plain)!.a, lessThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('liquid level keeps the shader glass', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          home: Scaffold(
            body: Column(
              children: [
                const MornyeGlass(
                  blurEnabled: true,
                  child: SizedBox(width: 200, height: 50),
                ),
                AppSwitch(value: true, onChanged: (_) {}),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(LiquidGlassLens), findsWidgets);
    expect(find.byType(LiquidGlassSwitch), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
