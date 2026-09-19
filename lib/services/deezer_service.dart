import 'package:dio/dio.dart';
import '../l10n/app_strings.dart';
import '../models/track.dart';
import 'music_source.dart';

/// Источник музыки Deezer.
///
/// Использует официальный публичный API Deezer (api.deezer.com) —
/// он открыт без ключа, токена и регистрации приложения: обычные
/// GET-запросы, отдающие JSON. Это принципиально проще и надёжнее, чем
/// прежние источники VK/YouTube, которые держались на неофициальном
/// парсинге HTML/innertube и постоянно ломались.
///
/// ВАЖНО про качество звука: без OAuth и лицензионного партнёрства
/// Deezer отдаёт только `preview` — честные 30-секундные превью-клипы
/// в mp3, а не полные треки. Это официальное и единственное, что
/// доступно публичному API (полноценный стриминг целых треков требует
/// коммерческого соглашения с Deezer). Поэтому [duration] у треков из
/// этого источника намеренно ограничен длиной самого превью — иначе
/// прогресс-бар в плеере показывал бы полную длительность песни, а
/// звук обрывался бы на 30-й секунде.
class DeezerService extends MusicSource {
  DeezerService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://api.deezer.com',
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
            ));

  final Dio _dio;

  static const _previewDuration = Duration(seconds: 30);

  @override
  String get name => 'Deezer';

  @override
  Future<List<Track>> search(String query, {int limit = 25, int offset = 0}) async {
    final response = await _dio.get('/search', queryParameters: {
      'q': query,
      'index': offset,
      'limit': limit,
    });

    final items = (response.data['data'] as List?) ?? [];
    return items.map(_fromJson).whereType<Track>().toList();
  }

  @override
  Future<List<Track>> trending({int limit = 25}) async {
    // У Deezer нет отдельного постранично-поискового "trending" —
    // /chart/0/tracks отдаёт глобальный топ треков без параметра offset,
    // но с limit этого достаточно для подборки на главном экране.
    final response = await _dio.get('/chart/0/tracks', queryParameters: {
      'limit': limit,
    });

    final items = (response.data['data'] as List?) ?? [];
    return items.map(_fromJson).whereType<Track>().toList();
  }

  @override
  Future<Track> resolveStreamUrl(Track track) async {
    // preview-ссылка уже приходит готовой и напрямую проигрываемой в
    // ответе /search и /chart — дополнительный резолв не нужен.
    return track;
  }

  Track? _fromJson(dynamic json) {
    if (json == null) return null;
    try {
      final preview = json['preview'] as String? ?? '';
      return Track(
        id: 'dz_${json['id']}',
        title: json['title'] as String? ?? AppStrings.current.untitled,
        artist: (json['artist'] as Map?)?['name'] as String? ??
            AppStrings.current.unknownArtist,
        artworkUrl: (json['album'] as Map?)?['cover_medium'] as String? ?? '',
        duration: _previewDuration,
        source: MusicSourceType.deezer,
        streamUrl: preview,
      );
    } catch (_) {
      return null;
    }
  }
}
