import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/models/theme_settings.dart';

final initialThemeSettingsProvider = Provider<ThemeSettings>(
  (ref) => const ThemeSettings(),
);

ThemeSettings loadBootstrapThemeSettings(SharedPreferences prefs) {
  return ThemeSettings(
    themeMode: themeModeFromString(prefs.getString(kThemeModeKey)),
    useDynamicColor: prefs.getBool(kUseDynamicColorKey) ?? true,
    seedColorValue: prefs.getInt(kSeedColorKey) ?? kDefaultSeedColor,
    useAmoled: prefs.getBool(kUseAmoledKey) ?? false,
    style: themeStyleFromString(prefs.getString(kThemeStyleKey)),
    mornyeAccent: mornyeAccentFromString(prefs.getString(kMornyeAccentKey)),
    useSystemFont: prefs.getBool(kUseSystemFontKey) ?? false,
  );
}

final themeProvider = NotifierProvider<ThemeNotifier, ThemeSettings>(() {
  return ThemeNotifier();
});

class ThemeNotifier extends Notifier<ThemeSettings> {
  final Future<SharedPreferences> _prefs = SharedPreferences.getInstance();

  @override
  ThemeSettings build() {
    _loadFromStorage();
    return ref.read(initialThemeSettingsProvider);
  }

  Future<void> _loadFromStorage() async {
    try {
      final prefs = await _prefs;
      state = loadBootstrapThemeSettings(prefs);
    } catch (e) {
      debugPrint('Error loading theme settings: $e');
    }
  }

  Future<void> _saveToStorage() async {
    try {
      final prefs = await _prefs;
      await prefs.setString(kThemeModeKey, state.themeMode.name);
      await prefs.setBool(kUseDynamicColorKey, state.useDynamicColor);
      await prefs.setInt(kSeedColorKey, state.seedColorValue);
      await prefs.setBool(kUseAmoledKey, state.useAmoled);
      await prefs.setString(kThemeStyleKey, state.style.name);
      await prefs.setString(kMornyeAccentKey, state.mornyeAccent.name);
      await prefs.setBool(kUseSystemFontKey, state.useSystemFont);
    } catch (e) {
      debugPrint('Error saving theme settings: $e');
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = state.copyWith(themeMode: mode);
    await _saveToStorage();
  }

  Future<void> setStyle(AppThemeStyle style) async {
    state = state.copyWith(style: style);
    await _saveToStorage();
  }

  Future<void> setUseDynamicColor(bool value) async {
    state = state.copyWith(useDynamicColor: value);
    await _saveToStorage();
  }

  Future<void> setSeedColor(Color color) async {
    state = state.copyWith(seedColorValue: color.toARGB32());
    await _saveToStorage();
  }

  Future<void> setUseAmoled(bool value) async {
    state = state.copyWith(useAmoled: value);
    await _saveToStorage();
  }

  Future<void> setMornyeAccent(MornyeAccent accent) async {
    state = state.copyWith(mornyeAccent: accent);
    await _saveToStorage();
  }

  Future<void> setUseSystemFont(bool value) async {
    state = state.copyWith(useSystemFont: value);
    await _saveToStorage();
  }
}
