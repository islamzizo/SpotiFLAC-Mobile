import 'package:flutter/foundation.dart';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class SpotifyAccountProfile {
  const SpotifyAccountProfile({
    required this.displayName,
    this.username,
    this.imageUrl,
  });

  final String displayName;
  final String? username;
  final String? imageUrl;

  Map<String, dynamic> toJson() => {
    'displayName': displayName,
    if (username != null) 'username': username,
    if (imageUrl != null) 'imageUrl': imageUrl,
  };

  static SpotifyAccountProfile? fromJson(Map<String, dynamic> json) {
    final displayName = json['displayName']?.toString().trim() ?? '';
    if (displayName.isEmpty) return null;
    return SpotifyAccountProfile(
      displayName: displayName,
      username: json['username']?.toString(),
      imageUrl: json['imageUrl']?.toString(),
    );
  }
}

class SpotifyPlaylist {
  const SpotifyPlaylist({
    required this.id,
    required this.name,
    required this.url,
    this.owner,
    this.coverUrl,
    this.trackCount,
  });

  final String id;
  final String name;
  final String url;
  final String? owner;
  final String? coverUrl;
  final int? trackCount;

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'url': url,
    if (owner != null) 'owner': owner,
    if (coverUrl != null) 'coverUrl': coverUrl,
    if (trackCount != null) 'trackCount': trackCount,
  };

  static SpotifyPlaylist? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final name = json['name'] as String?;
    final url = json['url'] as String?;
    if (id == null || name == null || url == null) return null;
    return SpotifyPlaylist(
      id: id, name: name, url: url,
      owner: json['owner'] as String?,
      coverUrl: json['coverUrl'] as String?,
      trackCount: (json['trackCount'] as num?)?.toInt(),
    );
  }
}

class SpotifyAccountException implements Exception {
  const SpotifyAccountException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Restores the legacy Spotify Web Player session flow. Spotify's web endpoints
/// and persisted GraphQL hashes are private interfaces and can change at any time.
class SpotifyAccountService {
  SpotifyAccountService._();
  static final instance = SpotifyAccountService._();

  static const loginUrl =
      'https://accounts.spotify.com/login?continue=https%3A%2F%2Fopen.spotify.com%2F';
  static const _tokenUrl = 'https://open.spotify.com/api/token';
  static const _serverTimeUrl = 'https://open.spotify.com/api/server-time';
  static const _nuanceUrl =
      'https://gist.githubusercontent.com/sonic-liberation/22ed9c6ba463899e933427f7de1f0eef/raw/nuances.json';
  static const _graphqlUrl = 'https://api-partner.spotify.com/pathfinder/v2/query';
  static const _libraryHash = '390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455';
  static const _previousLibraryHash = '973e511ca44261fda7eebac8b653155e7caee3675abb4fb110cc1b8c78b091c3';
  static const _signedInKey = 'spotify_web_signed_in';
  static const _spDcKey = 'spotify_web_sp_dc';
  static const _spKeyKey = 'spotify_web_sp_key';
  static const accessTokenKey = 'spotify_web_access_token';
  static const _expiryKey = 'spotify_web_access_token_expires';
  static const _playlistsKey = 'spotify_web_playlists';
  static const _profileKey = 'spotify_web_profile';

  final _storage = const FlutterSecureStorage();
  final ValueNotifier<SpotifyAccountProfile?> profileNotifier =
      ValueNotifier<SpotifyAccountProfile?>(null);

  Future<bool> isSignedIn() async =>
      await _storage.read(key: _signedInKey) == 'true';

  Future<void> saveWebSession({required String spDc, String? spKey}) async {
    await _storage.write(key: _signedInKey, value: 'true');
    await _storage.write(key: _spDcKey, value: spDc);
    if (spKey != null && spKey.isNotEmpty) {
      await _storage.write(key: _spKeyKey, value: spKey);
    } else {
      await _storage.delete(key: _spKeyKey);
    }
    await _storage.delete(key: accessTokenKey);
    await _storage.delete(key: _expiryKey);
  }

  Future<SpotifyAccountProfile?> getProfile() async {
    final raw = await _storage.read(key: _profileKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final profile = SpotifyAccountProfile.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      profileNotifier.value = profile;
      return profile;
    } catch (_) {
      return null;
    }
  }

  Future<SpotifyAccountProfile?> syncProfile() async {
    final spDc = await _storage.read(key: _spDcKey);
    if (spDc == null || spDc.isEmpty) return getProfile();
    try {
      final token = await _validToken(
        spDc,
        await _storage.read(key: _spKeyKey) ?? '',
      );
      final response = await http.get(
        Uri.parse('https://api.spotify.com/v1/me'),
        headers: {
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );
      if (response.statusCode != 200) return await getProfile();
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return await getProfile();
      final images = decoded['images'];
      final firstImage = images is List && images.isNotEmpty
          ? _map(images.first)
          : null;
      final imageUrl =
          firstImage == null ? null : firstImage['url']?.toString();
      final id = decoded['id']?.toString();
      final displayName = decoded['display_name']?.toString().trim();
      final profile = SpotifyAccountProfile(
        displayName: displayName?.isNotEmpty == true ? displayName! : (id ?? ''),
        username: id,
        imageUrl: imageUrl,
      );
      if (profile.displayName.isEmpty) return getProfile();
      await _storage.write(
        key: _profileKey,
        value: jsonEncode(profile.toJson()),
      );
      profileNotifier.value = profile;
      return profile;
    } catch (_) {
      return await getProfile();
    }
  }

  Future<List<SpotifyPlaylist>> getPlaylists() async {
    final raw = await _storage.read(key: _playlistsKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded.whereType<Map<dynamic, dynamic>>()
          .map((v) => SpotifyPlaylist.fromJson(Map<String, dynamic>.from(v)))
          .whereType<SpotifyPlaylist>().toList(growable: false);
    } catch (_) { return const []; }
  }

  Future<List<SpotifyPlaylist>> syncPlaylists() async {
    final spDc = await _storage.read(key: _spDcKey);
    if (spDc == null || spDc.isEmpty) {
      throw const SpotifyAccountException('Spotify session is missing. Log in again.');
    }
    final token = await _validToken(spDc, await _storage.read(key: _spKeyKey) ?? '');
    final syncedProfile = await syncProfile();
    String? fallbackProfileName = syncedProfile?.displayName;
    String? fallbackProfileImage = syncedProfile?.imageUrl;
    final result = <String, SpotifyPlaylist>{};
    var offset = 0;
    const limit = 50;
    while (true) {
      final response = await _graphql('libraryV3', {
        'filters': ['Playlists'], 'order': null, 'textFilter': '',
        'features': ['LIKED_SONGS', 'YOUR_EPISODES_V2', 'PRERELEASES', 'EVENTS'],
        'limit': limit, 'offset': offset, 'flatten': true,
        'expandedFolders': <String>[], 'folderUri': null,
        'includeFoldersWhenFlattening': false,
      }, [_libraryHash, _previousLibraryHash], token);
      final data = _map(_map(response['data'])?['me']);
      final library = _map(data?['libraryV3']);
      if (library == null) {
        throw SpotifyAccountException(_firstError(response) ?? 'Spotify returned an invalid library response.');
      }
      final items = library['items'] is List ? library['items'] as List : const <dynamic>[];
      for (final item in items) {
        final wrapper = _map(_map(item)?['item']);
        final d = _map(wrapper?['data']);
        if (wrapper == null || d == null) continue;
        final type = (wrapper['__typename'] ?? d['__typename'] ?? '').toString().toLowerCase();
        final uri = (wrapper['_uri'] ?? d['uri'] ?? '').toString();
        if (!type.contains('playlist') || !uri.startsWith('spotify:playlist:')) continue;
        final id = uri.split(':').last;
        final name = d['name']?.toString() ?? '';
        if (id.isEmpty || name.isEmpty) continue;
        final ownerData = _map(_map(d['ownerV2'])?['data']);
        fallbackProfileName ??= ownerData?['name']?.toString();
        fallbackProfileImage ??= _image(ownerData?['images'] ?? ownerData?['image']);
        final content = _map(d['content']);
        result[id] = SpotifyPlaylist(
          id: id, name: name, url: 'https://open.spotify.com/playlist/$id',
          owner: ownerData?['name']?.toString(),
          coverUrl: _image(d['images']),
          trackCount: (content?['totalCount'] as num?)?.toInt() ??
              (d['totalLength'] as num?)?.toInt(),
        );
      }
      if (items.length < limit) break;
      offset += items.length;
      if (offset > 100000) break;
    }
    if (result.isEmpty) {
      throw const SpotifyAccountException('Spotify returned no playlists. The web session or library query may have changed.');
    }
    final playlists = result.values.toList(growable: false);
    if (fallbackProfileName?.trim().isNotEmpty == true) {
      final profileImage = syncedProfile?.imageUrl ?? fallbackProfileImage;
      final profileNeedsMerge =
          syncedProfile == null ||
          (syncedProfile.imageUrl == null && profileImage != null);
      if (profileNeedsMerge) {
        final mergedProfile = SpotifyAccountProfile(
          displayName: syncedProfile?.displayName ?? fallbackProfileName!.trim(),
          username: syncedProfile?.username,
          imageUrl: profileImage,
        );
        await _storage.write(
          key: _profileKey,
          value: jsonEncode(mergedProfile.toJson()),
        );
        profileNotifier.value = mergedProfile;
      }
    }
    await _storage.write(key: _playlistsKey, value: jsonEncode(playlists.map((p) => p.toJson()).toList()));
    await _storage.write(key: _signedInKey, value: 'true');
    return playlists;
  }

  Future<String> _validToken(String spDc, String spKey) async {
    final token = await _storage.read(key: accessTokenKey);
    final expiry = int.tryParse(await _storage.read(key: _expiryKey) ?? '');
    if (token != null && token.isNotEmpty && expiry != null &&
        expiry > DateTime.now().millisecondsSinceEpoch + 60000) {
      return token;
    }
    final nuance = await http.get(Uri.parse(_nuanceUrl));
    if (nuance.statusCode != 200) throw SpotifyAccountException('Could not load Spotify session configuration (${nuance.statusCode}).');
    final raw = jsonDecode(nuance.body);
    if (raw is! List) throw const SpotifyAccountException('Spotify session configuration is invalid.');
    final entries = raw.whereType<Map<dynamic, dynamic>>().map((v) => Map<String, dynamic>.from(v)).where((v) =>
      v['s'] is String && v['v'] is num && _isBase32(v['s'] as String)).toList();
    if (entries.isEmpty) throw const SpotifyAccountException('No valid Spotify session key is available.');
    entries.sort((a,b) => (a['v'] as num).compareTo(b['v'] as num));
    final secret = entries.last['s'] as String;
    final version = (entries.last['v'] as num).toInt();
    final time = await http.get(Uri.parse(_serverTimeUrl));
    if (time.statusCode != 200) throw SpotifyAccountException('Could not get Spotify server time (${time.statusCode}).');
    final timeData = jsonDecode(time.body);
    final serverTime = timeData is Map ? timeData['serverTime'] : null;
    if (serverTime is! num) throw const SpotifyAccountException('Spotify server time response is invalid.');
    final totp = _totp(secret, serverTime.toInt());
    final uri = Uri.parse(_tokenUrl).replace(queryParameters: {
      'reason':'transport','productType':'web-player','totp':totp,'totpServer':totp,'totpVer':'$version',
    });
    final response = await http.get(uri, headers: {
      'Cookie': spKey.isEmpty ? 'sp_dc=$spDc' : 'sp_dc=$spDc; sp_key=$spKey',
      'User-Agent': _userAgent, 'Accept':'application/json, text/plain, */*',
      'Accept-Language':'en',
    });
    if (response.statusCode != 200) throw SpotifyAccountException('Spotify session token request failed (${response.statusCode}).');
    final body = jsonDecode(response.body);
    if (body is! Map || body['isAnonymous'] == true || body['accessToken'] == null) {
      throw const SpotifyAccountException('Spotify returned an invalid or anonymous session token. Log in again.');
    }
    final access = body['accessToken'].toString();
    final expires = (body['accessTokenExpirationTimestampMs'] as num?)?.toInt();
    await _storage.write(key: accessTokenKey, value: access);
    if (expires != null) await _storage.write(key: _expiryKey, value: '$expires');
    return access;
  }

  Future<Map<String, dynamic>> _graphql(String operation, Map<String, dynamic> variables, List<String> hashes, String token) async {
    for (final hash in hashes) {
      final response = await http.post(Uri.parse(_graphqlUrl), headers: {
        'Authorization':'Bearer $token','Content-Type':'application/json;charset=UTF-8',
        'Accept':'application/json','User-Agent':_userAgent,'app-platform':'WebPlayer',
        'Origin':'https://open.spotify.com','Referer':'https://open.spotify.com/',
      }, body: jsonEncode({'variables':variables,'operationName':operation,
        'extensions':{'persistedQuery':{'version':1,'sha256Hash':hash}}}));
      Map<String,dynamic>? decoded;
      try { final d = jsonDecode(response.body); if (d is Map) decoded = Map<String,dynamic>.from(d); } catch (_) {}
      if (response.statusCode == 200 && decoded != null &&
          !(_firstError(decoded)?.contains('PersistedQueryNotFound') ?? false)) {
        return decoded;
      }
    }
    throw SpotifyAccountException('Spotify $operation request failed. Its private web API may have changed.');
  }

  static Map<String,dynamic>? _map(dynamic v) => v is Map ? Map<String,dynamic>.from(v) : null;
  static String? _firstError(Map<String,dynamic> v) {
    final errors = v['errors'];
    if (errors is! List || errors.isEmpty) return null;
    final first = _map(errors.first);
    return first == null ? null : first['message']?.toString();
  }
  static String? _image(dynamic value) {
    final m = _map(value);
    final sources = m?['sources'];
    if (sources is List && sources.isNotEmpty) return _map(sources.first)?['url']?.toString();
    final items = m?['items'];
    if (items is List) { for (final item in items) { final url = _image(item); if (url != null) return url; } }
    return null;
  }
  static const _userAgent = 'Mozilla/5.0 (Linux; Android 16; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36';
  bool _isBase32(String v) => RegExp(r'^[A-Z2-7]+=*$').hasMatch(v);
  String _totp(String secret, int serverTimeSec) {
    final key = _base32Decode(secret);
    final counter = serverTimeSec ~/ 30;
    final bytes = List<int>.filled(8, 0);
    var value = counter;
    for (var i = 7; i >= 0; i--) { bytes[i] = value & 0xff; value >>= 8; }
    final digest = Hmac(sha1, key).convert(bytes).bytes;
    final offset = digest.last & 0x0f;
    final code = ((digest[offset]&0x7f)<<24)|((digest[offset+1]&0xff)<<16)|((digest[offset+2]&0xff)<<8)|(digest[offset+3]&0xff);
    return (code % 1000000).toString().padLeft(6,'0');
  }
  List<int> _base32Decode(String input) {
    const alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; final output=<int>[]; var buffer=0; var bits=0;
    for (final c in input.toUpperCase().replaceAll('=','').split('')) {
      final n=alphabet.indexOf(c); if(n<0) continue; buffer=(buffer<<5)|n; bits+=5;
      if(bits>=8){bits-=8;output.add((buffer>>bits)&0xff);}
    }
    return output;
  }
  Future<void> signOut() async {
    for (final key in [_signedInKey,_spDcKey,_spKeyKey,accessTokenKey,_expiryKey,_playlistsKey,_profileKey]) {
      await _storage.delete(key:key);
    }
    profileNotifier.value = null;
  }
}
