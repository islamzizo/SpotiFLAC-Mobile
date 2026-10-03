import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:go_router/go_router.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/screens/playlist_screen.dart';
import 'package:spotiflac_android/services/spotify_account_service.dart';
import 'package:spotiflac_android/services/spotify_library_extras_service.dart';
import 'package:spotiflac_android/services/shell_navigation_service.dart';
import 'package:spotiflac_android/utils/spotify_navigation_scope.dart';

class SpotifyAccountScreen extends ConsumerStatefulWidget {
  const SpotifyAccountScreen({super.key});
  @override
  ConsumerState<SpotifyAccountScreen> createState() => _SpotifyAccountScreenState();
}

class _SpotifyAccountScreenState extends ConsumerState<SpotifyAccountScreen> {
  final _spotify = SpotifyAccountService.instance;
  final _extras = SpotifyLibraryExtrasService.instance;
  final _cookies = WebViewCookieManager();
  late final WebViewController _web;
  List<SpotifyPlaylist> _playlists = const [];
  bool _signedIn = false;
  bool _loading = false;
  bool _capturing = false;
  int _progress = 0;
  String? _error;
  String? _openingId;
  final GlobalKey<NavigatorState> _spotifyNavigatorKey =
      GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setUserAgent('Mozilla/5.0 (Linux; Android 16; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36')
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..setNavigationDelegate(NavigationDelegate(
        onProgress: (value) { if (mounted) setState(() => _progress = value); },
        onPageFinished: _onPageFinished,
        onWebResourceError: (error) {
          if (mounted && error.isForMainFrame == true) setState(() => _error = error.description);
        },
      ))
      ..loadRequest(Uri.parse(SpotifyAccountService.loginUrl));
    _loadSavedState();
  }

  Future<void> _loadSavedState() async {
    try {
      final signed = await _spotify.isSignedIn();
      final playlists = await _spotify.getPlaylists();
      if (!mounted) return;
      setState(() { _signedIn = signed; _playlists = playlists; });
      // Refresh the saved Spotify library whenever this screen is opened.
      if (signed) await _syncPlaylists();
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not load saved Spotify session: $error');
    }
  }

  Future<void> _onPageFinished(String url) async {
    if (_signedIn || _capturing || _loading || !url.contains('spotify.com')) return;
    if (await _hasSessionCookie()) await _syncPlaylists();
  }

  Future<bool> _hasSessionCookie() async {
    try {
      final cookies = await _cookies.getCookies(domain: Uri.parse('https://open.spotify.com'));
      return cookies.any((cookie) => cookie.name == 'sp_dc' && cookie.value.isNotEmpty);
    } catch (_) { return false; }
  }

  Future<bool> _captureSession() async {
    _capturing = true;
    try {
      WebViewCookie? spDc;
      WebViewCookie? spKey;
      for (final domain in [Uri.parse('https://open.spotify.com'), Uri.parse('https://accounts.spotify.com')]) {
        final cookies = await _cookies.getCookies(domain: domain);
        for (final cookie in cookies) {
          if (cookie.name == 'sp_dc' && cookie.value.isNotEmpty) spDc = cookie;
          if (cookie.name == 'sp_key' && cookie.value.isNotEmpty) spKey = cookie;
        }
      }
      if (spDc == null) return false;
      await _spotify.saveWebSession(spDc: spDc.value, spKey: spKey?.value);
      return true;
    } finally { _capturing = false; }
  }

  Future<void> _startLogin() async {
    setState(() { _error = null; _signedIn = false; _loading = false; _playlists = const []; });
    await _web.loadRequest(Uri.parse(SpotifyAccountService.loginUrl));
  }

  Future<void> _syncPlaylists() async {
    if (_loading) return;
    setState(() { _loading = true; _error = null; });
    try {
      final hasSession = await _captureSession();
      if (!hasSession && !await _spotify.isSignedIn()) {
        throw const SpotifyAccountException('Log in to Spotify above, then sync your library.');
      }
      final normal = await _spotify.syncPlaylists();
      final merged = List<SpotifyPlaylist>.from(normal);
      try {
        final liked = await _extras.fetchLikedSongsEntry();
        if (liked != null && !merged.any((item) => item.id == liked.id)) merged.insert(0, liked);
      } catch (_) {
        if (!merged.any((item) => item.id == 'liked-songs')) {
          merged.insert(0, const SpotifyPlaylist(id: 'liked-songs', name: 'Liked Songs', url: 'https://open.spotify.com/collection/tracks'));
        }
      }
      if (!mounted) return;
      setState(() { _playlists = merged; _signedIn = true; _loading = false; });
    } catch (error) {
      if (!mounted) return;
      setState(() { _loading = false; _error = error.toString(); });
    }
  }

  Track _toTrack(SpotifyWebTrack track) => Track(
    id: track.id, name: track.name, artistName: track.artistName,
    albumName: track.albumName ?? '', coverUrl: track.coverUrl,
    duration: ((track.durationMs ?? 0) / 1000).round(),
  );

  void _openQueueFromSpotify() {
    if (!mounted) return;
    context.go('/');
    ShellNavigationService.homeTabNavigatorKey.currentState?.popUntil(
      (route) => route.isFirst,
    );
    var attempts = 0;
    void selectLibraryWhenReady() {
      attempts++;
      if (ShellNavigationService.requestTab(ShellTab.library)) return;
      if (attempts >= 10) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        selectLibraryWhenReady();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      selectLibraryWhenReady();
    });
  }

  Future<void> _openPlaylist(SpotifyPlaylist playlist) async {
    if (_openingId != null) return;
    setState(() { _openingId = playlist.id; _error = null; });
    try {
      final tracks = playlist.id == 'liked-songs'
          ? await _extras.fetchLikedSongsTracks()
          : await _extras.fetchPlaylistTracks(playlist.id);
      if (!mounted) return;
      if (tracks.isEmpty) {
        setState(() => _error = playlist.id == 'liked-songs'
          ? 'Liked Songs is empty or Spotify returned no tracks.'
          : 'This playlist is empty or Spotify returned no tracks.');
        return;
      }
      await _spotifyNavigatorKey.currentState?.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => SpotifyNavigationScope(
            onViewQueue: _openQueueFromSpotify,
            navigatorKey: _spotifyNavigatorKey,
            push: (builder) => _spotifyNavigatorKey.currentState?.push<void>(
              MaterialPageRoute<void>(builder: builder),
            ),
            child: PlaylistScreen(
              playlistName: playlist.name,
              coverUrl: playlist.coverUrl,
              tracks: tracks.map(_toTrack).toList(growable: false),
              playlistId: playlist.id == 'liked-songs' ? null : playlist.id,
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not open Spotify playlist: $error');
    } finally {
      if (mounted) setState(() => _openingId = null);
    }
  }

  Future<void> _signOut() async {
    await _spotify.signOut();
    await _cookies.clearCookies();
    if (!mounted) return;
    setState(() { _signedIn = false; _playlists = const []; _error = null; });
    await _startLogin();
  }

  @override
  Widget build(BuildContext context) => Navigator(
    key: _spotifyNavigatorKey,
    onGenerateInitialRoutes: (_, _) => [
      MaterialPageRoute<void>(
        builder: (_) => _buildSpotifyHome(),
      ),
    ],
  );

  Widget _buildSpotifyHome() => Scaffold(
    appBar: AppBar(
      title: const Text('Spotify'),
      actions: [
        if (_signedIn) IconButton(
          tooltip: 'Sign out', onPressed: _loading ? null : _signOut,
          icon: const Icon(Icons.logout),
        ),
      ],
    ),
    body: Column(children: [
      if (_progress < 100 && !_signedIn)
        LinearProgressIndicator(value: _progress == 0 ? null : _progress / 100),
      Expanded(child: _signedIn ? _buildLibrary() : _buildLogin()),
      _buildBottomBar(),
    ]),
  );

  Widget _buildLogin() => Column(children: [
    const Padding(
      padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Text('Log in to Spotify. After login, SpotiFLAC syncs your playlists and Liked Songs.', textAlign: TextAlign.center),
    ),
    Expanded(child: WebViewWidget(controller: _web)),
  ]);

  Widget _buildLibrary() {
    if (_playlists.isEmpty && _loading) {
      return const Center(child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 12),
          Text('Syncing Spotify library…'),
        ],
      ));
    }
    return RefreshIndicator(
      onRefresh: _syncPlaylists,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.only(top: 8, bottom: 12),
        itemCount: _playlists.isEmpty ? 2 : _playlists.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(children: [
              const Icon(Icons.library_music_outlined),
              const SizedBox(width: 10),
              Expanded(child: Text('${_playlists.length} Spotify playlists', style: Theme.of(context).textTheme.titleMedium)),
            ]),
            );
          }
          if (_playlists.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('No playlists loaded. Pull down to refresh.')),
            );
          }
          final playlist = _playlists[index - 1];
          final opening = _openingId == playlist.id;
          final liked = playlist.id == 'liked-songs';
          final subtitle = liked
            ? (playlist.trackCount == null ? 'Liked songs' : 'Liked songs • ${playlist.trackCount} tracks')
            : [if (playlist.owner?.isNotEmpty == true) playlist.owner!, if (playlist.trackCount != null) '${playlist.trackCount} tracks'].join(' • ');
          return ListTile(
            leading: playlist.coverUrl == null
              ? CircleAvatar(child: Icon(liked ? Icons.favorite : Icons.music_note))
              : ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.network(playlist.coverUrl!, width: 52, height: 52, fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) => const CircleAvatar(child: Icon(Icons.music_note))),
                ),
            title: Text(playlist.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(subtitle.isEmpty ? 'Spotify playlist' : subtitle),
            trailing: opening
              ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.chevron_right),
            onTap: opening ? null : () => _openPlaylist(playlist),
          );
        },
      ),
    );
  }

  Widget _buildBottomBar() => Material(
    elevation: 8,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Column(children: [
          if (_error != null) Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!, textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
          if (_signedIn && _loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('Syncing Spotify library…'),
                ],
              ),
            ),
          if (!_signedIn)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _loading ? null : _startLogin,
                icon: const Icon(Icons.login),
                label: const Text('Log in with Spotify'),
              ),
            ),
          const SizedBox(height: 6),
          Text(_signedIn ? 'Library syncs automatically when you open this screen.' : 'Uses the Spotify web login session; no developer client ID is required.',
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    ),
  );
}
