import 'package:dio/dio.dart';
import '../l10n/app_strings.dart';
import '../models/track.dart';
import 'music_source.dart';

/// Источник музыки Audiomack.
///
/// ВАЖНО: Audiomack Data API (https://audiomack.com/data-api) использует
/// OAuth 1.0a (api key + api secret). Для реального продакшена нужно
/// подписывать каждый запрос (HMAC-SHA1) — здесь оставлен простой
/// заголовок-заглушка [apiKey]/[apiSecret], которые нужно подставить
/// после регистрации приложения в кабинете разработчика Audiomack.
class AudiomackService extends MusicSource {
  AudiomackService({
    required this.apiKey,
    required this.apiSecret,
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://api.audiomack.com/v1',
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
            ));

  final String apiKey;
  final String apiSecret;
  final Dio _dio;

  @override
  String get name => 'Audiomack';

  Map<String, dynamic> get _authParams => {
        'api_key': apiKey,
        // TODO: заменить на настоящую OAuth1-подпись запроса.
      };

  @override
  Future<List<Track>> search(String query, {int limit = 25, int offset = 0}) async {
    // Audiomack Data API постранично адресуется через 'page' (с 1), а не
    // offset — переводим один в другой, чтобы наружу интерфейс оставался
    // единым для всех источников.
    final page = (offset ~/ (limit == 0 ? 1 : limit)) + 1;
    final response = await _dio.get('/search/songs', queryParameters: {
      'q': query,
      'limit': limit,
      'page': page,
      ..._authParams,
    });

    final items = (response.data['results'] as List?) ?? [];
    return items.map(_fromJson).whereType<Track>().toList();
  }

  @override
  Future<List<Track>> trending({int limit = 25}) async {
    final response = await _dio.get('/music/trending/songs', queryParameters: {
      'limit': limit,
      ..._authParams,
    });

    final items = (response.data['results'] as List?) ?? [];
    return items.map(_fromJson).whereType<Track>().toList();
  }

  @override
  Future<Track> resolveStreamUrl(Track track) async {
    // У Audiomack ссылка на аудио уже приходит готовой в ответе search/trending,
    // дополнительный resolve-запрос не нужен — просто возвращаем трек как есть.
    return track;
  }

  Track? _fromJson(dynamic json) {
    if (json == null) return null;
    try {
      return Track(
        id: 'am_${json['id']}',
        title: json['title'] ?? AppStrings.current.untitled,
        artist: json['artist'] ?? AppStrings.current.unknownArtist,
        artworkUrl: json['image'] ?? json['image_base'] ?? '',
        duration: Duration(seconds: (json['duration'] ?? 0) as int),
        source: MusicSourceType.audiomack,
        streamUrl: json['url'] ?? json['streaming_url'] ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}
