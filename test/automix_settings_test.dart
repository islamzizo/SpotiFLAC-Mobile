import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/automix_options.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/widgets/automix_settings.dart';

void main() {
  testWidgets(
    'manual duration saves at end of drag and USB disables DSP controls',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(
            const AppSettings(
              autoMix: true,
              autoMixDuration: 5,
              autoMixEffect: AutoMixEffect.custom,
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SingleChildScrollView(child: AutoMixSettings()),
            ),
          ),
        ),
      );
      final slider = tester.widget<Slider>(find.byType(Slider).first);
      slider.onChanged!(45);
      await tester.pump();
      expect(container.read(settingsProvider).autoMixDuration, 5);
      expect(find.text('Mix duration: 45 s'), findsOneWidget);
      slider.onChangeEnd!(45);
      await tester.pump();
      expect(container.read(settingsProvider).autoMixDuration, 45);
      container.read(settingsProvider.notifier).setUsbBitPerfect(true);
      await tester.pump();
      for (final slider in tester.widgetList<Slider>(find.byType(Slider))) {
        expect(slider.onChanged, isNull);
      }
      expect(tester.takeException(), isNull);
    },
  );
}
