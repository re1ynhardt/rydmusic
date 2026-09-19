import 'dart:async';

import '../models/artist_page.dart';
import '../models/track.dart';
import 'music_source.dart';
import 'youtube_music_bridge.dart';
import 'youtube_po_token_resolver.dart';
import 'youtube_ytdlp_bridge.dart';

/// Источник музыки YouTube (через каталог YouTube Music).
///
/// Поиск и подборка (search/trending) идут через ytmusicapi (см.
/// android/app/src/main/python/ytdlp_bridge.py::search_yt_music) — это
/// специализированная библиотека именно под музыкальный каталог
/// YouTube Music, а не общий YouTube: без клипов/live/реакций в
/// выдаче, с нормальными полями артист/альбом/длительность. Работает
/// неавторизованно, ключ/квота не нужны.
///
/// Резолв самого потока (resolveStreamUrl) — двухшаговый:
/// 1. [YoutubeSessionResolver] — скрытый WebView открывает настоящую
///    youtube.com и подсматривает po_token/visitor_data, которые
///    страница сама отправляет в свой плеерный запрос (настоящая
///    сессия, прошедшая BotGuard как обычный браузер).
/// 2. [YouTubeYtDlpBridge] — эти токены уходят в yt-dlp, вшитый в APK
///    через Chaquopy (android/app/src/main/python/ytdlp_bridge.py).
///    Именно yt-dlp делает финальное извлечение audio-URL.
///
/// po_token — это best-effort обход анти-бот детекции googlevideo, а
/// не гарантия: YouTube регулярно меняет механизм BotGuard, так что
/// часть видео может не резолвиться даже при пойманных токенах. См.
/// комментарии в YoutubeSessionResolver.
class YouTubeService extends MusicSource {
  @override
  String get name => 'YouTube';

  @override
  Future<List<Track>> search(String query, {int limit = 25, int offset = 0}) async {
    // ytmusicapi (в отличие от youtube_explode_dart) не даёт постраничный
    // курсор через этот простой мост — берём offset+limit элементов
    // одним запросом и локально отрезаем нужный диапазон. Не идеально
    // для очень глубокой пагинации, но полностью покрывает обычный
    // сценарий подгрузки при скролле (см. search_screen.dart).
    final tracks = await YtMusicBridge.search(query, count: offset + limit);
    final result = tracks.skip(offset).take(limit).map(_fromYtMusic).toList();
    _prewarmSession(result);
    return result;
  }

  @override
  Future<List<Track>> trending({int limit = 25}) async {
    // У ytmusicapi через этот мост нет отдельного "trending"-эндпоинта
    // без региональной настройки — подборка для главного экрана, как
    // и раньше, это поиск по популярному музыкальному запросу.
    final tracks = await YtMusicBridge.search('trending music', count: limit);
    final result = tracks.take(limit).map(_fromYtMusic).toList();
    _prewarmSession(result);
    return result;
  }

  @override
  Future<Track> resolveStreamUrl(Track track) async {
    // Шаг 0: уже добытая ссылка на этот же трек, если она ещё жива.
    // Именно это убирает повторное ожидание при: повторном включении
    // трека, возврате к нему по кнопке "назад" в очереди и — главное —
    // при сохранении трека в офлайн-кэш (CachedTracksProvider.download
    // вызывает resolveStreamUrl ещё раз; раньше это был второй полный
    // круг WebView + yt-dlp, отсюда и "очень долго кэшируются").
    final cached = _cachedStream(track.id);
    if (cached != null) {
      return track.copyWith(
        streamUrl: cached.url,
        streamHeaders: cached.headers,
      );
    }

    // Резолв одного и того же трека мог быть запрошен дважды подряд
    // (нажали трек и тут же — скачать): второй вызов подхватывает
    // результат первого, а не запускает всё заново.
    final inFlight = _inFlight[track.id];
    if (inFlight != null) {
      final audio = await inFlight;
      return track.copyWith(
        streamUrl: audio.url,
        streamHeaders: audio.headers,
      );
    }

    final future = _extract(track.id);
    _inFlight[track.id] = future;
    try {
      final audio = await future;
      return track.copyWith(
        streamUrl: audio.url,
        streamHeaders: audio.headers,
      );
    } finally {
      _inFlight.remove(track.id);
    }
  }

  /// Ссылка, выданная раньше, не проигралась (например, сменилась сеть
  /// и googlevideo перестал принимать подписанный URL) — убираем её из
  /// кэша, чтобы следующая попытка пошла за новой.
  @override
  void invalidateStream(Track track) {
    _streams.remove(track.id);
    _streamExpiry.remove(track.id);
  }

  Future<YouTubeAudio> _extract(String videoId) async {
    // Шаг 1: po_token/visitor_data. Теперь это почти всегда мгновенно —
    // сессия общая на всё приложение и живёт часами (см.
    // YoutubeSessionResolver), WebView поднимается только если её ещё
    // нет или она протухла.
    final session =
        await YoutubeSessionResolver.instance.resolveSession(videoId);

    // Шаг 2: отдаём их yt-dlp (Python внутри APK через Chaquopy) —
    // именно он извлекает финальный audio-URL.
    final audio = await YouTubeYtDlpBridge.extractAudio(
      videoId,
      poToken: session.poToken,
      visitorData: session.visitorData,
    );
    _putStream(videoId, audio);
    return audio;
  }

  // ─── Кэш готовых ссылок ────────────────────────────────────────────
  //
  // Ссылка googlevideo живёт ограниченное время и сама сообщает, до
  // какого момента: в её query лежит параметр expire (unix-время).
  // Берём срок годности прямо оттуда, с запасом в пять минут, чтобы не
  // отдать ссылку, которая протухнет посреди воспроизведения.

  static final Map<String, YouTubeAudio> _streams = {};
  static final Map<String, DateTime> _streamExpiry = {};
  static final Map<String, Future<YouTubeAudio>> _inFlight = {};
  static const _maxStreams = 200;

  static YouTubeAudio? _cachedStream(String videoId) {
    final expiry = _streamExpiry[videoId];
    if (expiry == null) return null;
    if (DateTime.now().isAfter(expiry)) {
      _streams.remove(videoId);
      _streamExpiry.remove(videoId);
      return null;
    }
    return _streams[videoId];
  }

  static void _putStream(String videoId, YouTubeAudio audio) {
    _streams[videoId] = audio;
    _streamExpiry[videoId] = _expiryOf(audio.url);
    while (_streams.length > _maxStreams) {
      final oldest = _streams.keys.first;
      _streams.remove(oldest);
      _streamExpiry.remove(oldest);
    }
  }

  static DateTime _expiryOf(String url) {
    final expire = Uri.tryParse(url)?.queryParameters['expire'];
    final seconds = int.tryParse(expire ?? '');
    if (seconds != null && seconds > 0) {
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000)
          .subtract(const Duration(minutes: 5));
    }
    // Параметра нет (изменился формат ссылки) — берём осторожный
    // фиксированный срок.
    return DateTime.now().add(const Duration(minutes: 30));
  }

  /// Как только стал известен хоть один videoId из выдачи — просим
  /// прогреть сессию в фоне. Пока пользователь смотрит список и
  /// выбирает трек, токены уже ловятся; к моменту тапа резолв сводится
  /// к одному вызову yt-dlp.
  ///
  /// ВАЖНО: раньше на этом прогрев и заканчивался — сам yt-dlp-запрос
  /// (единственный оставшийся сетевой шаг, секунда-другая даже с тёплой
  /// сессией) всё равно происходил только ПОСЛЕ тапа. Отсюда и
  /// оставшаяся задержка перед стартом первого трека нового списка.
  /// Теперь заодно прогреваем и сам audio-URL для первых нескольких
  /// позиций (см. [_prewarmStreams]) — пока пользователь долистывает
  /// список или просто смотрит на него, извлечение уже идёт в фоне, и
  /// к моменту тапа по одному из этих треков resolveStreamUrl отдаёт
  /// готовую ссылку из кэша (см. [_cachedStream]) мгновенно.
  void _prewarmSession(List<Track> tracks) {
    if (tracks.isEmpty) return;
    YoutubeSessionResolver.instance.prewarm(tracks.first.id);
    _prewarmStreams(tracks);
  }

  /// Сколько первых треков списка прогреваем целиком (сессия + audio-URL).
  /// Именно по ним тап наиболее вероятен; прогревать всю выдачу означало
  /// бы десятки лишних yt-dlp-запросов ради треков, которые, возможно,
  /// никогда не откроют — только зря жечь трафик и батарею.
  static const _prewarmStreamCount = 3;

  void _prewarmStreams(List<Track> tracks) {
    for (final t in tracks.take(_prewarmStreamCount)) {
      if (_cachedStream(t.id) != null || _inFlight.containsKey(t.id)) {
        continue;
      }
      unawaited(_prewarmOne(t.id));
    }
  }

  Future<void> _prewarmOne(String videoId) async {
    final future = _extract(videoId);
    _inFlight[videoId] = future;
    try {
      await future;
    } catch (_) {
      // Прогрев — best effort: не получилось сейчас, обычный резолв по
      // тапу честно попробует ещё раз своим путём.
    } finally {
      _inFlight.remove(videoId);
    }
  }

  @override
  bool get supportsArtistPage => true;

  List<Track> _tracksFrom(dynamic list) => ((list as List?) ?? const [])
      .cast<Map<String, dynamic>>()
      .map(YtMusicTrack.fromJson)
      .where((t) => t.videoId.isNotEmpty)
      .map(_fromYtMusic)
      .toList();

  @override
  Future<ArtistPage?> loadArtist(Track track) async {
    final j = await YtMusicBridge.artist(
      channelId: track.artistId,
      // "A, B" — берём первого исполнителя.
      name: track.artist.split(',').first.trim(),
    );
    if (j == null) return null;
    final albums = ((j['albums'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .map((a) => ArtistAlbum(
              id: a['id'] as String? ?? '',
              title: a['title'] as String? ?? '',
              artworkUrl: a['thumbnail'] as String? ?? '',
              subtitle: [a['type'], a['year']]
                  .whereType<String>()
                  .where((e) => e.isNotEmpty)
                  .join(' • '),
            ))
        .where((a) => a.id.isNotEmpty)
        .toList();
    return ArtistPage(
      name: j['name'] as String? ?? track.artist,
      artworkUrl: j['thumbnail'] as String? ?? '',
      albums: albums,
      tracks: _tracksFrom(j['tracks']),
    );
  }

  @override
  Future<List<Track>> loadAlbumTracks(ArtistAlbum album) async {
    final j = await YtMusicBridge.album(album.id);
    return j == null ? const [] : _tracksFrom(j['tracks']);
  }

  Track _fromYtMusic(YtMusicTrack t) {
    return Track(
      id: t.videoId,
      title: t.title,
      artist: t.artist,
      artworkUrl: t.thumbnail ?? '',
      artistId: t.artistId,
      duration: t.duration != null ? Duration(seconds: t.duration!) : Duration.zero,
      source: MusicSourceType.youtube,
      // ВАЖНО: тут НЕЛЬЗЯ ставить streamUrl: '' — Track.isPlayable
      // считает пустой streamUrl признаком "источник сам сказал, что
      // играть нечего" (см. track_tile.dart) и тогда TrackTile вообще
      // не даст тапнуть по треку, до resolveStreamUrl дело не дойдёт.
      // Кладём сюда ссылку на страницу видео как маркер "ещё не
      // резолвнуто" — реальный проигрываемый URL появляется только в
      // resolveStreamUrl.
      streamUrl: 'https://www.youtube.com/watch?v=${t.videoId}',
    );
  }
}
