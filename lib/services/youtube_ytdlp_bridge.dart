import 'dart:convert';
import 'package:flutter/services.dart';

/// Результат извлечения audio-URL для YouTube-видео через yt-dlp.
class YouTubeAudio {
  const YouTubeAudio({
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

/// Тонкая Dart-обёртка над yt-dlp (вшит в APK через Chaquopy, см.
/// android/app/src/main/python/ytdlp_bridge.py) для финального
/// извлечения проигрываемого audio-URL по videoId.
class YouTubeYtDlpBridge {
  YouTubeYtDlpBridge._();
  static const _channel = MethodChannel('rydmusic/yt_dlp');

  /// Извлекает audio-URL и заголовки, с которыми CDN его отдаёт.
  /// [poToken]/[visitorData] — см. YoutubeSessionResolver; можно не
  /// передавать (null), часть видео резолвится и без них.
  static Future<YouTubeAudio> extractAudio(
    String videoId, {
    String? poToken,
    String? visitorData,
  }) async {
    final String raw;
    try {
      raw = await _channel.invokeMethod<String>('extractAudio', {
            'videoId': videoId,
            'poToken': poToken,
            'visitorData': visitorData,
          }) ??
          '';
    } on PlatformException catch (e) {
      throw Exception('yt-dlp extractAudio error: ${e.message}');
    }

    if (raw.isEmpty) {
      throw Exception('yt-dlp вернул пустой ответ для $videoId');
    }

    final json = jsonDecode(raw) as Map<String, dynamic>;
    final url = json['url'] as String?;
    if (url == null || url.isEmpty) {
      throw Exception('yt-dlp не нашёл audio-URL для $videoId');
    }

    final rawHeaders = (json['headers'] as Map?) ?? const {};
    final headers = rawHeaders.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );

    return YouTubeAudio(
      url: url,
      headers: headers,
      title: json['title'] as String?,
      duration: json['duration'] as int?,
    );
  }
}
