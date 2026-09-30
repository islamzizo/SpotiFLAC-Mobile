import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';

/// True on low-end hardware (arm32-only or low-RAM, resolved at startup in
/// main.dart via a ProviderScope override). UI uses it to skip expensive
/// effects like the shell's backdrop blur.
final lowEndDeviceProvider = Provider<bool>((ref) => false);

/// Raw device capability decided by the startup runtime profile (overridden
/// in main.dart). Only the `high` tier enables blur by default.
final deviceSupportsBackdropBlurProvider = Provider<bool>((ref) => false);

/// Whether the device's GPU is expected to sustain Mornye's shader glass
/// (refractive lenses, the travelling tab pill, liquid switches and per-line
/// lyric defocus) on top of plain backdrop blur. Overridden in main.dart:
/// mid-range Android keeps frosted blur without the shader passes.
final deviceSupportsLiquidGlassProvider = Provider<bool>((ref) => true);

/// Whether backdrop blur effects should render: the device default, or the
/// user's manual override from appearance settings.
final backdropBlurEnabledProvider = Provider<bool>((ref) {
  return ref.watch(deviceSupportsBackdropBlurProvider) ||
      ref.watch(settingsProvider.select((s) => s.forceBackdropBlur));
});

/// How much of Mornye's glass the device renders.
enum MornyeGlassLevel {
  /// Opaque surfaces; no backdrop sampling.
  flat,

  /// Translucent surfaces over one backdrop blur; no shader passes.
  frosted,

  /// Frosted surfaces plus refractive shader lenses and blur-driven motion.
  liquid,
}

final mornyeGlassLevelProvider = Provider<MornyeGlassLevel>((ref) {
  final lowEnd = ref.watch(lowEndDeviceProvider);
  if (!lowEnd && ref.watch(deviceSupportsLiquidGlassProvider)) {
    return MornyeGlassLevel.liquid;
  }
  // The user's "always use blur effects" override restores the full material.
  if (ref.watch(backdropBlurEnabledProvider)) return MornyeGlassLevel.liquid;
  return lowEnd ? MornyeGlassLevel.flat : MornyeGlassLevel.frosted;
});

/// Backdrop blur for Mornye surfaces (frosted or liquid).
final mornyeBlurEnabledProvider = Provider<bool>(
  (ref) => ref.watch(mornyeGlassLevelProvider) != MornyeGlassLevel.flat,
);

/// Shader glass and continuously re-filtered blur effects (liquid only).
final mornyeLiquidGlassProvider = Provider<bool>(
  (ref) => ref.watch(mornyeGlassLevelProvider) == MornyeGlassLevel.liquid,
);
