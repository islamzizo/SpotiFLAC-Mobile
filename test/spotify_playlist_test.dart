import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/spotify_account_service.dart';

void main() {
  group('SpotifyPlaylist', () {
    test('round-trips optional metadata through JSON', () {
      const playlist = SpotifyPlaylist(
        id: 'playlist-id',
        name: 'My playlist',
        url: 'https://open.spotify.com/playlist/playlist-id',
        owner: 'Listener',
        coverUrl: 'https://i.scdn.co/image/cover',
        trackCount: 42,
      );

      expect(SpotifyPlaylist.fromJson(playlist.toJson())?.toJson(),
          playlist.toJson());
    });

    test('parses required fields when optional metadata is missing', () {
      final playlist = SpotifyPlaylist.fromJson({
        'id': 'playlist-id',
        'name': 'My playlist',
        'url': 'https://open.spotify.com/playlist/playlist-id',
      });

      expect(playlist, isNotNull);
      expect(playlist!.id, 'playlist-id');
      expect(playlist.owner, isNull);
      expect(playlist.coverUrl, isNull);
      expect(playlist.trackCount, isNull);
    });

    test('rejects malformed records without required fields', () {
      expect(SpotifyPlaylist.fromJson({'id': 'playlist-id'}), isNull);
      expect(SpotifyPlaylist.fromJson({'name': 'Missing id and url'}), isNull);
    });
  });
}
