import 'dart:math' as math;

import 'package:dio/dio.dart';
import '../l10n/app_strings.dart';
import '../models/artist_page.dart';
import '../models/track.dart';
import 'music_source.dart';
import 'soundcloud_client_id_resolver.dart';

/// Источник музыки SoundCloud.
///
/// Использует "внутренний" client_id, который добывается парсингом
/// веб-плеера SoundCloud через [SoundCloudClientIdResolver] — см. подробные
/// предупреждения в этом классе про риски ToS и хрупкость метода.
/// При ответе 401/403 клиент автоматически перепарсивает сайт и повторяет
/// запрос один раз с новым ключом — так приложение переживает ситуацию,
/// когда SoundCloud обновляет свои бандлы и старый ключ перестаёт работать.
class SoundCloudService extends MusicSource {
  SoundCloudService({SoundCloudClientIdResolver? resolver, Dio? dio})
      : _resolver = resolver ?? SoundCloudClientIdResolver(),
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: 'https://api-v2.soundcloud.com',
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
            ));

  final SoundCloudClientIdResolver _resolver;
  final Dio _dio;
  String? _clientId;

  @override
  String get name => 'SoundCloud';

  Future<String> _ensureClientId({bool forceRefresh = false}) async {
    if (!forceRefresh && _clientId != null) return _clientId!;
    final id = await _resolver.resolve(forceRefresh: forceRefresh);
    if (id == null) {
      throw StateError(
        'Не удалось получить client_id SoundCloud (сайт изменился или нет сети).',
      );
    }
    _clientId = id;
    return id;
  }

  /// Текущий client_id для отображения в UI (например, в настройках):
  /// сперва то, что уже держим в памяти этой сессии, иначе — то, что
  /// осело в SharedPreferences с прошлого запуска. Ничего не качает по
  /// сети — для этого есть [refreshClientIdForDisplay].
  Future<String?> clientIdForDisplay() async {
    if (_clientId != null) return _clientId;
    return _resolver.readCached();
  }

  /// Принудительно перепарсивает soundcloud.com и обновляет client_id —
  /// используется кнопкой "Обновить" в настройках. Возвращает null вместо
  /// исключения, если это не удалось (нет сети, сайт изменился и т.п.),
  /// чтобы UI мог просто показать понятную ошибку.
  Future<String?> refreshClientIdForDisplay() async {
    try {
      return await _ensureClientId(forceRefresh: true);
    } catch (_) {
      return null;
    }
  }

  /// Выполняет GET-запрос и, если SoundCloud ответил 401/403
  /// (протухший/невалидный client_id), один раз перепарсивает сайт
  /// и повторяет запрос с новым ключом.
  Future<Response<dynamic>> _getWithAutoRefresh(
    String path, {
    Map<String, dynamic> queryParameters = const {},
  }) async {
    var clientId = await _ensureClientId();
    try {
      return await _dio.get(path,
          queryParameters: {...queryParameters, 'client_id': clientId});
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        clientId = await _ensureClientId(forceRefresh: true);
        return _dio.get(path,
            queryParameters: {...queryParameters, 'client_id': clientId});
      }
      rethrow;
    }
  }

  @override
  Future<List<Track>> search(String query, {int limit = 25, int offset = 0}) async {
    final response = await _getWithAutoRefresh('/search/tracks', queryParameters: {
      'q': query,
      'limit': limit,
      'offset': offset,
    });

    final items = (response.data['collection'] as List?) ?? [];
    return items.map(_fromJson).whereType<Track>().toList();
  }

  @override
  Future<List<Track>> trending({int limit = 25}) async {
    final response = await _getWithAutoRefresh(
      'https://api-v2.soundcloud.com/charts',
      queryParameters: {
        'kind': 'trending',
        'genre': 'soundcloud:genres:all-music',
        'limit': limit,
      },
    );

    final items = (response.data['collection'] as List?) ?? [];
    return items
        .map((e) => e['track'])
        .map(_fromJson)
        .whereType<Track>()
        .toList();
  }

  @override
  Future<Track> resolveStreamUrl(Track track) async {
    if (track.streamUrl.isEmpty) return track;

    var clientId = await _ensureClientId();
    try {
      final response = await _dio
          .get(track.streamUrl, queryParameters: {'client_id': clientId});
      final resolvedUrl = response.data['url'] as String?;
      if (resolvedUrl == null) return track;
      return track.copyWith(streamUrl: resolvedUrl);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        clientId = await _ensureClientId(forceRefresh: true);
        final response = await _dio
            .get(track.streamUrl, queryParameters: {'client_id': clientId});
        final resolvedUrl = response.data['url'] as String?;
        if (resolvedUrl == null) return track;
        return track.copyWith(streamUrl: resolvedUrl);
      }
      rethrow;
    }
  }

  // ── Страница исполнителя ────────────────────────────────────────────

  @override
  bool get supportsArtistPage => true;

  /// Собирает все страницы коллекции (следуя next_href), но не больше
  /// [maxPages] запросов.
  Future<List<dynamic>> _collect(String path, Map<String, dynamic> params,
      {int maxPages = 5}) async {
    final out = <dynamic>[];
    String? next = path;
    var query = params;
    for (var i = 0; next != null && i < maxPages; i++) {
      final r = await _getWithAutoRefresh(next, queryParameters: query);
      out.addAll((r.data['collection'] as List?) ?? const []);
      next = r.data['next_href'] as String?;
      query = const {};
    }
    return out;
  }

  String _art(dynamic v) =>
      (v ?? '').toString().replaceAll('-large.jpg', '-t500x500.jpg');

  @override
  Future<ArtistPage?> loadArtist(Track track) async {
    var uid = track.artistId;
    if (uid == null || uid.isEmpty) {
      // Старый сохранённый трек без id исполнителя — ищем по имени.
      final r = await _getWithAutoRefresh('/search/users',
          queryParameters: {'q': track.artist, 'limit': 1});
      final found = (r.data['collection'] as List?) ?? const [];
      if (found.isEmpty) return null;
      uid = '${found.first['id']}';
    }
    // Профиль и альбомы — "необязательные" части: если их запрос упал,
    // страница всё равно откроется (хотя бы со списком треков).
    final (userData, tracksRaw, albumsRaw) = await (
      _getWithAutoRefresh('/users/$uid')
          .then<dynamic>((r) => r.data)
          .catchError((_) => <String, dynamic>{}),
      _collect('/users/$uid/tracks', {'limit': 100}),
      _collect('/users/$uid/albums', {'limit': 50}, maxPages: 3)
          .catchError((_) => <dynamic>[]),
    ).wait;

    final albums = albumsRaw.whereType<Map>().map((a) {
      final date = (a['release_date'] ?? a['created_at'] ?? '').toString();
      return ArtistAlbum(
        id: '${a['id']}',
        title: (a['title'] ?? '').toString(),
        artworkUrl: _art(a['artwork_url'] ?? a['user']?['avatar_url']),
        subtitle: date.length >= 4 ? date.substring(0, 4) : '',
      );
    }).toList();

    return ArtistPage(
      name: (userData['username'] ?? track.artist).toString(),
      artworkUrl: _art(userData['avatar_url']),
      albums: albums,
      tracks: tracksRaw.map(_fromJson).whereType<Track>().toList(),
    );
  }

  @override
  Future<List<Track>> loadAlbumTracks(ArtistAlbum album) async {
    final r = await _getWithAutoRefresh('/playlists/${album.id}');
    final raw = (r.data['tracks'] as List?) ?? const [];
    // В плейлисте полностью описаны только первые треки, остальные —
    // голые {id}. Дозапрашиваем их пачками.
    final missing =
        raw.where((t) => t['title'] == null).map((t) => t['id']).toList();
    final full = <String, dynamic>{};
    for (var i = 0; i < missing.length; i += 30) {
      final ids = missing.sublist(i, math.min(i + 30, missing.length));
      final rr = await _getWithAutoRefresh('/tracks',
          queryParameters: {'ids': ids.join(',')});
      for (final t in (rr.data as List)) {
        full['${t['id']}'] = t;
      }
    }
    return raw
        .map((t) => _fromJson(t['title'] == null ? full['${t['id']}'] : t))
        .whereType<Track>()
        .toList();
  }

  Track? _fromJson(dynamic json) {
    if (json == null) return null;
    try {
      final transcodings =
          (json['media']?['transcodings'] as List?) ?? const [];
      final progressive = transcodings.firstWhere(
        (t) => t['format']?['protocol'] == 'progressive',
        orElse: () => transcodings.isNotEmpty ? transcodings.first : null,
      );

      return Track(
        id: 'sc_${json['id']}',
        title: json['title'] ?? AppStrings.current.untitled,
        artist: json['user']?['username'] ?? AppStrings.current.unknownArtist,
        artworkUrl: (json['artwork_url'] ?? json['user']?['avatar_url'] ?? '')
            .toString()
            .replaceAll('-large.jpg', '-t500x500.jpg'),
        duration: Duration(milliseconds: (json['duration'] ?? 0) as int),
        source: MusicSourceType.soundcloud,
        streamUrl: progressive?['url'] ?? '',
        artistId: json['user']?['id']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}
