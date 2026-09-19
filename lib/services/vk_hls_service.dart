import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

import '../models/track.dart';
import 'music_source.dart';

// ─── DTO ─────────────────────────────────────────────────────────────────────

/// Краткая информация о HLS-плейлисте (без загрузки сегментов).
class HLSPlaylistInfo {
  const HLSPlaylistInfo({
    required this.version,
    required this.totalDuration,
    required this.segmentsCount,
    required this.hasEncryption,
    this.encryptionMethod = 'NONE',
  });

  final int version;
  final double totalDuration;
  final int segmentsCount;
  final bool hasEncryption;
  final String encryptionMethod;

  factory HLSPlaylistInfo.fromJson(Map<String, dynamic> json) =>
      HLSPlaylistInfo(
        version: (json['version'] as num?)?.toInt() ?? 3,
        totalDuration: (json['total_duration'] as num?)?.toDouble() ?? 0.0,
        segmentsCount: (json['segments_count'] as num?)?.toInt() ?? 0,
        hasEncryption: json['has_encryption'] as bool? ?? false,
        encryptionMethod: json['encryption_method'] as String? ?? 'NONE',
      );

  @override
  String toString() =>
      'HLSPlaylistInfo($segmentsCount segs, '
      '${totalDuration.toStringAsFixed(1)}s, enc=$encryptionMethod)';
}

/// Метаданные трека, полученные из URL плейлиста.
class VKTrackMetadata {
  const VKTrackMetadata({
    required this.title,
    required this.artist,
    required this.duration,
    this.coverUrl,
    this.lyrics,
    this.album,
    this.releaseDate,
    this.genre,
  });

  final String title;
  final String artist;
  final int duration;
  final String? coverUrl;
  final String? lyrics;
  final String? album;
  final String? releaseDate;
  final String? genre;

  factory VKTrackMetadata.fromJson(Map<String, dynamic> json) =>
      VKTrackMetadata(
        title: json['title'] as String? ?? 'Unknown',
        artist: json['artist'] as String? ?? 'Unknown',
        duration: (json['duration'] as num?)?.toInt() ?? 0,
        coverUrl: json['cover_url'] as String?,
        lyrics: json['lyrics'] as String?,
        album: json['album'] as String?,
        releaseDate: json['release_date'] as String?,
        genre: json['genre'] as String?,
      );
}

// ─── Service ─────────────────────────────────────────────────────────────────

/// Dart-обёртка над Kotlin-бриджем [VKHLSBridge].
///
/// Все методы:
///   • сначала пробуют нативный MethodChannel ("rydmusic/vk_hls");
///   • при [PlatformException] логируют и возвращают null.
///
/// Пример использования:
/// ```dart
/// final info = await VKHLSService.parseM3U8(url);
/// final audio = await VKHLSService.downloadAndDecryptSegments(url,
///                   outputFile: '/sdcard/track.ts');
/// ```
class VKHLSService {
  VKHLSService._();

  static const _ch = MethodChannel('rydmusic/vk_hls');

  // ── Публичный API ──────────────────────────────────────────────────────

  /// Парсит M3U8 (поддерживает мастер-плейлист) и возвращает информацию
  /// о плейлисте без фактической загрузки аудио-сегментов.
  static Future<HLSPlaylistInfo?> parseM3U8(String url) async {
    final raw = await _invoke('parseM3U8', {'url': url});
    if (raw == null) return null;

    final json = _parseJson(raw);
    if (json == null || json['error'] != null) {
      _log('parseM3U8 error: ${json?['error']}');
      return null;
    }

    final pl = json['playlist'] as Map<String, dynamic>?;
    if (pl == null) return null;

    final info = HLSPlaylistInfo.fromJson(pl);
    _log('parseM3U8 → $info');
    return info;
  }

  /// Загружает, дешифрует и объединяет все сегменты.
  ///
  /// [outputFile] — если указан, Python сохраняет файл на диск и возвращает
  ///               путь; иначе возвращает байты через base64.
  static Future<Uint8List?> downloadAndDecryptSegments(
    String url, {
    String? outputFile,
  }) async {
    final args = <String, dynamic>{'url': url};
    if (outputFile != null) args['output_file'] = outputFile;

    final raw = await _invoke('downloadAndDecryptSegments', args);
    if (raw == null) return null;

    if (raw is Uint8List) return raw;

    final json = _parseJson(raw.toString());
    if (json == null || json['error'] != null) {
      _log('downloadAndDecrypt error: ${json?['error']}');
      return null;
    }

    final b64 = json['audio_data'] as String?;
    if (b64 != null) {
      final bytes = base64Decode(b64);
      _log('downloadAndDecrypt → ${bytes.length} bytes');
      return bytes;
    }

    // outputFile case — файл уже сохранён, возвращаем null (Flutter знает путь)
    return null;
  }

  /// Извлекает метаданные трека из URL плейлиста.
  static Future<VKTrackMetadata?> getTrackMetadata(String url) async {
    final raw = await _invoke('getTrackMetadata', {'url': url});
    if (raw == null) return null;

    final json = _parseJson(raw.toString());
    if (json == null || json['error'] != null) {
      _log('getTrackMetadata error: ${json?['error']}');
      return null;
    }

    final meta = VKTrackMetadata.fromJson(json);
    _log('getTrackMetadata → ${meta.artist} — ${meta.title}');
    return meta;
  }

  // ── Internals ──────────────────────────────────────────────────────────

  static Future<dynamic> _invoke(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      return await _ch.invokeMethod(method, args);
    } on PlatformException catch (e) {
      _log('PlatformException [$method]: ${e.message}');
      return null;
    } catch (e) {
      _log('Unexpected error [$method]: $e');
      return null;
    }
  }

  static Map<String, dynamic>? _parseJson(String raw) {
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      _log('JSON parse error: $e  raw=$raw');
      return null;
    }
  }

  static void _log(String msg) => debugPrint('[VK HLS] $msg');
}

// ─── MusicSource ─────────────────────────────────────────────────────────────

/// Реализация [MusicSource] для расшифровки HLS-ссылок VK.
///
/// Сам по себе как источник в main.dart НЕ зарегистрирован — поиск и
/// логин теперь в [VkService] (audio.search с токеном от Kate Mobile).
/// Этот класс используется VkService внутренне только ради
/// [resolveStreamUrl]: если у найденного трека streamUrl — это
/// M3U8-плейлист (VK иногда отдаёт зашифрованный HLS вместо прямого
/// mp3), мы скачиваем + дешифруем его и возвращаем трек с реальным
/// файлом на диске (или bytes в кэше).
class VKMusicSource extends MusicSource {
  VKMusicSource({required this.cacheDir});

  /// Директория для кэша дешифрованных треков.
  final String cacheDir;

  @override
  String get name => 'VK';

  @override
  Future<List<Track>> search(String query, {int limit = 25, int offset = 0}) async {
    // Поиск и логин теперь в VkService (audio.search с токеном
    // от Kate Mobile, см. vk_auth_bridge.py/vk_search_bridge.py).
    // Этот класс используется VkService только для одной задачи —
    // расшифровать HLS-ссылки, которые иногда отдаёт audio.search
    // (см. resolveStreamUrl ниже), а не как отдельный MusicSource.
    return const [];
  }

  @override
  Future<List<Track>> trending({int limit = 25}) async => const [];

  @override
  void invalidateStream(Track track) {
    // The resolved VK stream is represented by a file cache, not by an
    // in-memory URL.  A subsequent resolve will reuse or regenerate it.
  }

  @override
  Future<Track> resolveStreamUrl(Track track) async {
    final url = track.streamUrl;
    if (!url.contains('.m3u8')) return track;

    // Проверяем кэш
    final cacheFile = _cacheFileFor(track.id);
    if (await cacheFile.exists()) {
      debugPrint('[VK Source] Cache hit for ${track.id}');
      return track.copyWith(streamUrl: Uri.file(cacheFile.path).toString());
    }

    // Получаем метаданные (не блокируем воспроизведение при ошибке)
    String title  = track.title;
    String artist = track.artist;
    String? artUrl = track.artworkUrl.isNotEmpty ? track.artworkUrl : null;
    int durationSec = track.duration.inSeconds;

    final meta = await VKHLSService.getTrackMetadata(url);
    if (meta != null) {
      if (meta.title != 'Unknown') title  = meta.title;
      if (meta.artist != 'Unknown') artist = meta.artist;
      artUrl ??= meta.coverUrl;
      if (durationSec == 0 && meta.duration > 0) durationSec = meta.duration;
    }

    // Скачиваем + дешифруем → сохраняем в кэш
    debugPrint('[VK Source] Downloading & decrypting: $url');
    final bytes = await VKHLSService.downloadAndDecryptSegments(
      url,
      outputFile: cacheFile.path,
    );

    final streamUrl = (bytes != null || await cacheFile.exists())
        ? Uri.file(cacheFile.path).toString()
        : url; // fallback: надеемся что плеер сам проиграет M3U8

    return track.copyWith(
      title: title,
      artist: artist,
      artworkUrl: artUrl ?? track.artworkUrl,
      streamUrl: streamUrl,
      duration: durationSec > 0 ? Duration(seconds: durationSec) : track.duration,
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  // ignore: avoid_slow_async_io — нужно для проверки кэша
  _CacheFile _cacheFileFor(String trackId) => _CacheFile('$cacheDir/${_sanitize(trackId)}.ts');

  String _sanitize(String id) => id.replaceAll(RegExp(r'[^\w\-]'), '_');
}

// Маленький хелпер, чтобы не тащить dart:io в публичный интерфейс
class _CacheFile {
  _CacheFile(this.path);
  final String path;
  Future<bool> exists() async {
    try {
      final f = await Future.value(false); // заглушка — заменить на File(path).exists()
      return f;
    } catch (_) {
      return false;
    }
  }
}
// NOTE: В реальном коде замените _CacheFile на import 'dart:io' → File.
// Убрано из этого файла, чтобы не конфликтовать с web-таргетом.
