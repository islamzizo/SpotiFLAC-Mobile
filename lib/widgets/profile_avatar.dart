import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/services/spotify_account_service.dart';
import 'package:spotiflac_android/services/shell_navigation_service.dart';

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    this.name = '',
    this.photoPath,
    this.photo,
    this.size = 40,
  });

  final String name;
  final String? photoPath;
  final Uint8List? photo;
  final double size;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // ListTile can constrain height more than width. Keep the clipped
        // image square even when the surrounding slot is rectangular.
        final diameter = constraints.biggest.shortestSide.clamp(0.0, size);
        return Align(
          widthFactor: 1,
          heightFactor: 1,
          child: _buildAvatar(context, diameter),
        );
      },
    );
  }

  Widget _buildAvatar(BuildContext context, double diameter) {
    final scheme = Theme.of(context).colorScheme;
    final fallback = ColoredBox(
      color: scheme.primaryContainer,
      child: Center(
        child: name.trim().isEmpty
            ? Icon(
                Icons.person,
                size: diameter * 0.55,
                color: scheme.onPrimaryContainer,
              )
            : Text(
                name.trim().characters.first.toUpperCase(),
                style: TextStyle(
                  fontSize: diameter * 0.42,
                  fontWeight: FontWeight.w600,
                  color: scheme.onPrimaryContainer,
                ),
              ),
      ),
    );
    return ExcludeSemantics(
      child: ClipOval(
        child: SizedBox.square(
          dimension: diameter,
          child: photo != null
              ? Image.memory(
                  photo!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => fallback,
                )
              : photoPath != null
              ? Image.file(
                  File(photoPath!),
                  fit: BoxFit.cover,
                  cacheWidth:
                      (diameter * MediaQuery.devicePixelRatioOf(context))
                          .ceil(),
                  errorBuilder: (_, _, _) => fallback,
                )
              : fallback,
        ),
      ),
    );
  }
}

class SpotifyProfileAvatar extends StatelessWidget {
  const SpotifyProfileAvatar({
    super.key,
    required this.profile,
    this.size = 40,
  });

  final SpotifyProfile profile;
  final double size;

  @override
  Widget build(BuildContext context) {
    final fallback = ProfileAvatar(name: profile.displayName, size: size);
    final imageUrl = profile.imageUrl;
    if (imageUrl == null || imageUrl.isEmpty) return fallback;

    return ClipOval(
      child: SizedBox.square(
        dimension: size,
        child: Image.network(
          imageUrl,
          fit: BoxFit.cover,
          cacheWidth:
              (size * MediaQuery.devicePixelRatioOf(context)).ceil(),
          errorBuilder: (_, _, _) => fallback,
        ),
      ),
    );
  }
}

class HomeProfileButton extends StatelessWidget {
  const HomeProfileButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SpotifyProfile?>(
      valueListenable: SpotifyAccountService.instance.profileNotifier,
      builder: (context, profile, _) {
        // Ensure an existing cached profile is loaded when Home is first built.
        if (profile == null) {
          SpotifyAccountService.instance.getProfile();
        }
        return IconButton(
          tooltip: context.l10n.settingsTitle,
          iconSize: 44,
          padding: const EdgeInsets.all(6),
          constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
          visualDensity: VisualDensity.standard,
          onPressed: () =>
              ShellNavigationService.requestTab(ShellTab.settings),
          icon: profile == null
              ? const ProfileAvatar(size: 44)
              : SpotifyProfileAvatar(profile: profile, size: 44),
        );
      },
    );
  }
}
