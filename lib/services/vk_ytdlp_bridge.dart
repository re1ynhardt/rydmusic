import 'dart:convert';
import 'package:flutter/services.dart';

/// Результат поиска ВК треков
class VkTrack {
  const VkTrack({
    required this.url,
    required this.title,
    this.duration,
  });

  final String url;
  final String title;
  final int? duration;

  factory VkTrack.fromJson(Map<String, dynamic> json) {
    return VkTrack(
      url: json['url'] as String? ?? '',
      title: json['title'] as String? ?? 'Unknown',
      duration: json['duration'] as int?,
    );
  }
}

/// Результат резолва ВК URL
class VkAudio {
  const VkAudio({
    required this.url,
    required this.headers,
    this.title,
    this.duration,
  });

  final String url;
  final Map<String, String> headers;
  final String? title;
  final int? duration;
}

/// Тонкая Dart-обёртка над yt-dlp для работы с ВК аудио.
/// yt-dlp поддерживает ВК нативно и может парсить аудиотреки и получать прямые ссылки.
class VkYtDlpBridge {
  VkYtDlpBridge._();
  static const _channel = MethodChannel('rydmusic/yt_dlp');

  /// Поиск треков в ВК
  static Future<List<VkTrack>> searchTracks(
    String query, {
    int count = 25,
  }) async {
    final String raw;
    try {
      raw = await _channel.invokeMethod<String>('searchVkTracks', {
        'query': query,
        'count': count,
      }) ??
          '';
    } on PlatformException catch (e) {
      print('[VK yt-dlp] Search error: ${e.message}');
      return [];
    }

    if (raw.isEmpty) {
      print('[VK yt-dlp] Empty response');
      return [];
    }

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      
      if (json['error'] != null) {
        print('[VK yt-dlp] Error from yt-dlp: ${json['error']}');
        return [];
      }

      final tracksList = (json['tracks'] as List?) ?? [];
      final tracks = tracksList
          .cast<Map<String, dynamic>>()
          .map(VkTrack.fromJson)
          .where((t) => t.url.isNotEmpty)
          .toList();

      print('[VK yt-dlp] Found ${tracks.length} tracks');
      return tracks;
    } catch (e) {
      print('[VK yt-dlp] Parse error: $e');
      return [];
    }
  }

  /// Резолв ВК URL до прямой MP3 ссылки
  static Future<VkAudio?> resolveUrl(String vkUrl) async {
    final String raw;
    try {
      raw = await _channel.invokeMethod<String>('resolveVkUrl', {
        'url': vkUrl,
      }) ??
          '';
    } on PlatformException catch (e) {
      print('[VK yt-dlp] Resolve error: ${e.message}');
      return null;
    }

    if (raw.isEmpty) {
      print('[VK yt-dlp] Empty resolve response');
      return null;
    }

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final url = json['url'] as String?;
      
      if (url == null || url.isEmpty) {
        print('[VK yt-dlp] No URL in response');
        return null;
      }

      final rawHeaders = (json['headers'] as Map?) ?? const {};
      final headers = rawHeaders.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );

      return VkAudio(
        url: url,
        headers: headers,
        title: json['title'] as String?,
        duration: json['duration'] as int?,
      );
    } catch (e) {
      print('[VK yt-dlp] Parse error: $e');
      return null;
    }
  }
}
