import 'package:flutter/widgets.dart';

/// Keeps navigation launched from the Spotify account flow on the Spotify
/// route instead of accidentally targeting the hidden MainShell tab stack.
class SpotifyNavigationScope extends InheritedWidget {
  const SpotifyNavigationScope({
    super.key,
    required this.onViewQueue,
    required this.navigatorKey,
    required this.push,
    required super.child,
  });

  final VoidCallback onViewQueue;
  final GlobalKey<NavigatorState> navigatorKey;
  final void Function(WidgetBuilder builder) push;

  static SpotifyNavigationScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SpotifyNavigationScope>();

  @override
  bool updateShouldNotify(SpotifyNavigationScope oldWidget) =>
      !identical(onViewQueue, oldWidget.onViewQueue) || !identical(push, oldWidget.push);
}
