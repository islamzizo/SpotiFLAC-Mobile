import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:spotiflac_android/services/spotify_account_service.dart';

class SpotifyWebTrack {
  const SpotifyWebTrack({
    required this.id, required this.name, required this.artistName,
    this.albumName, this.coverUrl, this.durationMs,
  });
  final String id;
  final String name;
  final String artistName;
  final String? albumName;
  final String? coverUrl;
  final int? durationMs;
}

class SpotifyLibraryExtrasService {
  SpotifyLibraryExtrasService._();
  static final instance = SpotifyLibraryExtrasService._();
  static const _url = 'https://api-partner.spotify.com/pathfinder/v2/query';
  static const _libraryHash = '390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455';
  static const _libraryPreviousHash = '973e511ca44261fda7eebac8b653155e7caee3675abb4fb110cc1b8c78b091c3';
  static const _playlistHash = '86dde7b9d9356e2369414647cf6950cfed96e778e129cfdfc99aea6c1613b3b0';
  static const _playlistPreviousHash = 'e4b2953f160e58e38ac025d79b5a9b3aceee5c4c716598e9830bfceb69faff5f';
  static const _likedTracksHash = '087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240';
  final _storage = const FlutterSecureStorage();

  Future<String> _token() async {
    final value = await _storage.read(key: SpotifyAccountService.accessTokenKey);
    if (value == null || value.isEmpty) throw const SpotifyAccountException('Spotify session token is missing. Sync the account again.');
    return value;
  }

  Future<Map<String,dynamic>> _graphql(String operation, Map<String,dynamic> variables, List<String> hashes) async {
    final token = await _token();
    for (final hash in hashes) {
      final response = await http.post(Uri.parse(_url), headers: {
        'Authorization':'Bearer $token','Content-Type':'application/json;charset=UTF-8',
        'Accept':'application/json','User-Agent':'Mozilla/5.0 (Linux; Android 16; Mobile) AppleWebKit/537.36 Chrome/140.0.0.0 Mobile Safari/537.36',
        'app-platform':'WebPlayer','Origin':'https://open.spotify.com','Referer':'https://open.spotify.com/',
      }, body: jsonEncode({'variables':variables,'operationName':operation,'extensions':{'persistedQuery':{'version':1,'sha256Hash':hash}}}));
      Map<String,dynamic>? body;
      try { final parsed=jsonDecode(response.body); if(parsed is Map) body=Map<String,dynamic>.from(parsed); } catch (_) {}
      final errors = body?['errors'];
      String? error;
      if (errors is List && errors.isNotEmpty) {
        final firstError = _map(errors.first);
        error = firstError == null ? null : firstError['message']?.toString();
      }
      if(response.statusCode==200 && body!=null && !(error?.contains('PersistedQueryNotFound') ?? false)) return body;
    }
    throw SpotifyAccountException('Spotify $operation request failed. The private web API may have changed.');
  }

  Future<SpotifyPlaylist?> fetchLikedSongsEntry() async {
    final body=await _graphql('libraryV3',{
      'filters':<String>[],'order':null,'textFilter':'',
      'features':['LIKED_SONGS','YOUR_EPISODES_V2','PRERELEASES','EVENTS'],
      'limit':50,'offset':0,'flatten':false,'expandedFolders':<String>[],
      'folderUri':null,'includeFoldersWhenFlattening':true,
    },[_libraryHash,_libraryPreviousHash]);
    final items=_map(_map(_map(body['data'])?['me'])?['libraryV3'])?['items'];
    if(items is List) {
      for(final item in items) {
        final wrapper=_map(_map(item)?['item']); final data=_map(wrapper?['data']);
        if(data==null) continue;
        final uri=(wrapper?['_uri']??data['uri']??'').toString();
        final name=data['name']?.toString()??'Liked Songs';
        if(uri=='spotify:collection:tracks' || name.toLowerCase().contains('liked')) {
          return SpotifyPlaylist(id:'liked-songs',name:name,url:'https://open.spotify.com/collection/tracks',coverUrl:_image(data['image']),trackCount:(_map(data['content'])?['totalCount'] as num?)?.toInt());
        }
      }
    }
    return const SpotifyPlaylist(id:'liked-songs',name:'Liked Songs',url:'https://open.spotify.com/collection/tracks');
  }

  Future<List<SpotifyWebTrack>> fetchLikedSongsTracks() async {
    const pageSize=50; var offset=0; final result=<SpotifyWebTrack>[];
    while(true) {
      final body=await _graphql('fetchLibraryTracks',{'offset':offset,'limit':pageSize},[_likedTracksHash]);
      final tracks=_map(_map(_map(body['data'])?['me'])?['library'])?['tracks'];
      final items=_map(tracks)?['items'];
      if(items is! List || items.isEmpty) break;
      for(final item in items) {
        final wrapper=_map(_map(item)?['track']); final data=_map(wrapper?['data']);
        if(data==null) continue;
        final uri=(wrapper?['_uri']??wrapper?['uri']??data['uri']??'').toString();
        final id=uri.startsWith('spotify:track:')?uri.substring('spotify:track:'.length):'';
        final track=_parseTrack(id,data); if(track!=null) result.add(track);
      }
      if(items.length<pageSize) break;
      offset+=items.length;
    }
    return result;
  }

  Future<List<SpotifyWebTrack>> fetchPlaylistTracks(String playlistId) async {
    if (playlistId.isEmpty || playlistId == 'liked-songs') return const [];
    const pageSize = 100;
    var offset = 0;
    final tracks = <SpotifyWebTrack>[];
    while (true) {
      final body = await _graphql('fetchPlaylist', {
        'uri': 'spotify:playlist:$playlistId',
        'offset': offset,
        'limit': pageSize,
        'enableWatchFeedEntrypoint': false,
      }, [_playlistHash, _playlistPreviousHash]);
      final playlist = _map(_map(body['data'])?['playlistV2']);
      final content = _map(playlist?['content']);
      final items = content?['items'];
      if (items is! List || items.isEmpty) break;
      for (final item in items) {
        final wrapper = _map(_map(item)?['itemV2']);
        final trackData = _map(wrapper?['data']);
        if (wrapper == null || trackData == null) continue;
        final uri = (wrapper['_uri'] ?? wrapper['uri'] ?? trackData['uri'] ?? '').toString();
        final id = uri.startsWith('spotify:track:') ? uri.substring('spotify:track:'.length) : '';
        final track = _parseTrack(id, trackData);
        if (track != null) tracks.add(track);
      }
      if (items.length < pageSize) break;
      offset += items.length;
      if (offset > 100000) break;
    }
    return tracks;
  }

  SpotifyWebTrack? _parseTrack(String id, Map<String,dynamic> data) {
    final name=data['name']?.toString()??'';
    if(id.isEmpty || name.isEmpty) return null;
    final artists=data['artists'];
    var artistName='';
    if(artists is Map<dynamic, dynamic> && artists['items'] is List) {
      artistName=(artists['items'] as List).whereType<Map<dynamic, dynamic>>().map((a)=>_map(a['profile'])?['name']?.toString()??'').where((s)=>s.isNotEmpty).join(', ');
    } else if(artists is List) {
      artistName=artists.whereType<Map<dynamic, dynamic>>().map((a)=>_map(a['profile'])?['name']?.toString()??a['name']?.toString()??'').where((s)=>s.isNotEmpty).join(', ');
    }
    final album=_map(data['albumOfTrack'])??_map(data['album']);
    final duration=_map(data['duration']);
    return SpotifyWebTrack(id:id,name:name,artistName:artistName,
      albumName:album?['name']?.toString(),coverUrl:_image(album?['coverArt']??album?['images']),
      durationMs:(duration?['totalMilliseconds'] as num?)?.toInt() ?? (data['durationMs'] as num?)?.toInt());
  }

  static Map<String,dynamic>? _map(dynamic v)=>v is Map?Map<String,dynamic>.from(v):null;
  static String? _image(dynamic value) {
    final m=_map(value); if(m==null)return null;
    final sources=m['sources'];
    if(sources is List && sources.isNotEmpty)return _map(sources.first)?['url']?.toString();
    final items=m['items']; if(items is List) for(final item in items){final url=_image(item);if(url!=null)return url;}
    return null;
  }
}
