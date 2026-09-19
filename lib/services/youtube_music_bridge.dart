import 'dart:convert';
import 'package:flutter/services.dart';

/// Трек, найденный через ytmusicapi (каталог YouTube Music, а не
/// общий YouTube — без клипов/live/реакций).
class YtMusicTrack {
  const YtMusicTrack({
    required this.videoId,
    required this.title,
    required this.artist,
    this.thumbnail,
    this.duration,
    this.artistId,
  });

  final String videoId;
  final String title;
  final String artist;
  final String? thumbnail;
  final int? duration;
  final String? artistId;

  factory YtMusicTrack.fromJson(Map<String, dynamic> json) => YtMusicTrack(
        videoId: json['videoId'] as String? ?? '',
        title: json['title'] as String? ?? 'Unknown',
        artist: json['artist'] as String? ?? 'Unknown',
        thumbnail: json['thumbnail'] as String?,
        duration: json['duration'] as int?,
        artistId: json['artistId'] as String?,
      );
}

/// Тонкая Dart-обёртка над ytmusicapi (вшит в APK через Chaquopy, см.
/// android/app/src/main/python/ytdlp_bridge.py::search_yt_music).
class YtMusicBridge {
  YtMusicBridge._();
  static const _channel = MethodChannel('rydmusic/yt_dlp');

  static Future<Map<String, dynamic>?> _call(
      String method, Map<String, dynamic> args) async {
    try {
      final raw = await _channel.invokeMethod<String>(method, args) ?? '';
      if (raw.isEmpty) return null;
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return json['error'] != null ? null : json;
    } catch (e) {
      print('[YT Music] $method error: $e');
      return null;
    }
  }

  /// Страница исполнителя: name, thumbnail, albums[], tracks[].
  /// Ищет по [channelId], а если его нет — по [name].
  static Future<Map<String, dynamic>?> artist({String? channelId, String? name}) =>
      _call('getArtistYtMusic', {'channelId': channelId, 'name': name});

  /// Треки альбома: tracks[].
  static Future<Map<String, dynamic>?> album(String browseId) =>
      _call('getAlbumYtMusic', {'browseId': browseId});

  static Future<List<YtMusicTrack>> search(String query, {int count = 25}) async {
    final String raw;
    try {
      raw = await _channel.invokeMethod<String>('searchYtMusic', {
            'query': query,
            'count': count,
          }) ??
          '';
    } on PlatformException catch (e) {
      print('[YT Music] Search error: ${e.message}');
      return [];
    }

    if (raw.isEmpty) {
      print('[YT Music] Empty response');
      return [];
    }

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;

      if (json['error'] != null) {
        print('[YT Music] Error from ytmusicapi: ${json['error']}');
        return [];
      }

      final tracksList = (json['tracks'] as List?) ?? [];
      final tracks = tracksList
          .cast<Map<String, dynamic>>()
          .map(YtMusicTrack.fromJson)
          .where((t) => t.videoId.isNotEmpty)
          .toList();

      print('[YT Music] Found ${tracks.length} tracks');
      return tracks;
    } catch (e) {
      print('[YT Music] Parse error: $e');
      return [];
    }
  }
}
