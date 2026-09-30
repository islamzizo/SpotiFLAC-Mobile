import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/theme_settings.dart';
import 'package:spotiflac_android/providers/theme_provider.dart';
import 'package:spotiflac_android/screens/settings/appearance_settings_page.dart';
import 'package:spotiflac_android/theme/dynamic_color_wrapper.dart';
import 'package:spotiflac_android/theme/mornye_theme.dart';

void main() {
  test('glass clarity restores safely from old and invalid settings', () {
    expect(
      ThemeSettings.fromJson({}).mornyeGlassClarity,
      kDefaultMornyeGlassClarity,
    );
    for (final (saved, expected) in [
      (0, 0.0),
      (1, 1.0),
      (-1, 0.0),
      (2, 1.0),
      (double.nan, kDefaultMornyeGlassClarity),
    ]) {
      final settings = ThemeSettings.fromJson({kMornyeGlassClarityKey: saved});
      expect(settings.mornyeGlassClarity, expected);
      expect(ThemeSettings.fromJson(settings.toJson()), settings);
    }
  });
  test('custom accents keep text readable in both appearances', () {
    double contrast(Color first, Color second) {
      final a = first.computeLuminance();
      final b = second.computeLuminance();
      return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
    }

    for (final brightness in Brightness.values) {
      for (final accent in MornyeAccent.values.where(
        (accent) => accent != MornyeAccent.red,
      )) {
        final scheme = MornyeTheme.build(
          brightness,
          accent: accent,
        ).colorScheme;
        expect(
          contrast(scheme.primary, scheme.surface),
          greaterThanOrEqualTo(4.5),
          reason: '$accent on $brightness',
        );
        expect(
          contrast(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(4.5),
          reason: 'Button text for $accent on $brightness',
        );
      }
    }
  });

  Future<void> openSettings(
    WidgetTester tester,
    SharedPreferences prefs,
  ) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialThemeSettingsProvider.overrideWithValue(
            loadBootstrapThemeSettings(prefs),
          ),
        ],
        child: DynamicColorWrapper(
          builder: (light, dark, mode) => MaterialApp(
            theme: light,
            darkTheme: dark,
            themeMode: mode,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const MornyeSettingsTheme(child: AppearanceSettingsPage()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('glass clarity previews live and survives restart ($mode)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kThemeModeKey: mode.name,
      });
      final prefs = await SharedPreferences.getInstance();
      await openSettings(tester, prefs);
      final slider = find.byKey(const ValueKey('mornye-glass-clarity'));
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.drag(slider, const Offset(160, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, 1);
      expect(prefs.getDouble(kMornyeGlassClarityKey), 1);
      final context = tester.element(slider);
      expect(MornyeTheme.glassClarityOf(context), 1);
      expect(
        MornyeTheme.fromContext(
          context,
          brightness: Brightness.dark,
        ).extension<MornyeTheme>()!.glassClarity,
        1,
      );
      await tester.pumpWidget(const SizedBox());
      await openSettings(tester, prefs);
      expect(tester.widget<Slider>(slider).value, 1);
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.drag(slider, const Offset(-320, 0));
      await tester.pumpAndSettle();
      expect(tester.widget<Slider>(slider).value, 0);
      expect(prefs.getDouble(kMornyeGlassClarityKey), 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Mornye accent updates live and survives restart ($mode)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kThemeModeKey: mode.name,
        kSeedColorKey: 0xff123456,
      });
      final prefs = await SharedPreferences.getInstance();
      await openSettings(tester, prefs);
      final page = find.byType(AppearanceSettingsPage);
      final initial = Theme.of(tester.element(page));
      expect(
        initial.colorScheme.primary,
        MornyeTheme.accentColor(MornyeAccent.red, initial.brightness),
      );

      final blue = find.byTooltip('Blue');
      await tester.ensureVisible(blue);
      await tester.tap(blue);
      await tester.pumpAndSettle();
      final theme = Theme.of(tester.element(page));
      expect(
        theme.colorScheme.primary,
        MornyeTheme.accentColor(MornyeAccent.blue, theme.brightness),
      );
      expect(prefs.getString(kMornyeAccentKey), 'blue');
      expect(prefs.getInt(kSeedColorKey), 0xff123456);
      final overlay = MornyeTheme.fromContext(
        tester.element(page),
        brightness: Brightness.dark,
      );
      expect(overlay.extension<MornyeTheme>()!.accent, MornyeAccent.blue);
      expect(
        overlay.colorScheme.primary,
        MornyeTheme.accentColor(MornyeAccent.blue, Brightness.dark),
      );

      await tester.pumpWidget(const SizedBox());
      await openSettings(tester, prefs);
      expect(
        Theme.of(tester.element(page)).colorScheme.primary,
        theme.colorScheme.primary,
      );
      await tester.ensureVisible(find.byTooltip('Red (default)'));
      await tester.tap(find.byTooltip('Red (default)'));
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(page)).colorScheme.primary,
        initial.colorScheme.primary,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final style in AppThemeStyle.values) {
    testWidgets(
      'system font persists and restores the default ($style)',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          kThemeStyleKey: style.name,
          kMornyeAccentKey: 'blue',
          kUseDynamicColorKey: false,
        });
        final prefs = await SharedPreferences.getInstance();
        await openSettings(tester, prefs);
        final page = find.byType(AppearanceSettingsPage);
        final original = Theme.of(
          tester.element(page),
        ).textTheme.bodyLarge!.fontFamily;
        final setting = find.text('Use system font');
        await tester.scrollUntilVisible(
          setting,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(setting);
        await tester.pumpAndSettle();
        final theme = Theme.of(tester.element(page));
        final systemFamily = theme.textTheme.bodyLarge!.fontFamily;
        expect(systemFamily, isNot('Inter'));
        expect(systemFamily, isNot('Google Sans Flex'));
        expect(prefs.getBool(kUseSystemFontKey), isTrue);
        if (style == AppThemeStyle.mornye) {
          final overlay = MornyeTheme.fromContext(
            tester.element(page),
            brightness: Brightness.dark,
          );
          expect(overlay.extension<MornyeTheme>()!.useSystemFont, isTrue);
          expect(overlay.extension<MornyeTheme>()!.accent, MornyeAccent.blue);
          expect(overlay.textTheme.bodyLarge!.fontFamily, systemFamily);
        }
        await tester.pumpWidget(const SizedBox());
        await openSettings(tester, prefs);
        expect(
          Theme.of(tester.element(page)).textTheme.bodyLarge!.fontFamily,
          systemFamily,
        );
        await tester.scrollUntilVisible(
          setting,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.tap(setting);
        await tester.pumpAndSettle();
        expect(prefs.getBool(kUseSystemFontKey), isFalse);
        expect(
          Theme.of(tester.element(page)).textTheme.bodyLarge!.fontFamily,
          original,
        );
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }
}
