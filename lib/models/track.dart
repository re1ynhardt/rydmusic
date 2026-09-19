enum MusicSourceType { soundcloud, audiomack, deezer, youtube, vk, local }

/// Единая модель трека независимо от того, откуда он пришёл —
/// SoundCloud, Audiomack или локальный кэш.
class Track {
  final String id;
  final String title;
  final String artist;
  final String artworkUrl;
  final Duration duration;
  final MusicSourceType source;

  /// URL, по которому реально можно стримить аудио.
  /// Для SoundCloud/Audiomack получается через соответствующий сервис
  /// (может требовать дополнительного резолва перед воспроизведением).
  final String streamUrl;

  /// Заголовки, с которыми нужно запрашивать [streamUrl] у CDN.
  ///
  /// Нужны для YouTube: манифест резолвится через yt-dlp с конкретным
  /// клиентом (см. YouTubeService.resolveStreamUrl), и googlevideo CDN
  /// проверяет User-Agent запроса на стрим против того, что клиент
  /// заявлял при резолве манифеста. ExoPlayer по умолчанию шлёт свой
  /// собственный UA ("AndroidXMedia3/..."), который CDN не пропускает —
  /// именно это источник 403 Response code при воспроизведении без
  /// этих заголовков. Остальные источники (SoundCloud/Audiomack/Deezer)
  /// это поле не используют.
  final Map<String, String>? streamHeaders;

  /// Id исполнителя в источнике (SoundCloud user id / YouTube channelId) —
  /// нужен для страницы исполнителя. У старых сохранённых треков его нет:
  /// тогда исполнитель ищется по имени.
  final String? artistId;

  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.artworkUrl,
    required this.duration,
    required this.source,
    required this.streamUrl,
    this.streamHeaders,
    this.artistId,
  });

  /// true, если у трека вообще есть с чем работать (streamUrl непустой).
  /// Источники (SoundCloud/Audiomack) уже сейчас проставляют пустой
  /// streamUrl прямо в момент парсинга search/trending, если у трека нет
  /// ни одного проигрываемого transcoding'а (частая история для
  /// лейбловых/монетизируемых треков, заблокированных для публичного
  /// client_id). Такие треки заведомо не проиграются при тапе — удобнее
  /// показать это в списке сразу, чем дать пользователю тапнуть и словить
  /// ошибку после сетевого резолва.
  bool get isPlayable => streamUrl.isNotEmpty;

  Track copyWith({
    String? title,
    String? artist,
    String? artworkUrl,
    Duration? duration,
    String? streamUrl,
    Map<String, String>? streamHeaders,
    String? artistId,
  }) {
    return Track(
      id: id,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      artworkUrl: artworkUrl ?? this.artworkUrl,
      duration: duration ?? this.duration,
      source: source,
      streamUrl: streamUrl ?? this.streamUrl,
      streamHeaders: streamHeaders ?? this.streamHeaders,
      artistId: artistId ?? this.artistId,
    );
  }

  /// Компактное представление для локального хранения (избранное).
  /// streamUrl для SoundCloud — это стабильный metadata-endpoint, а не
  /// протухающая подписанная ссылка, поэтому его безопасно сохранять и
  /// переиспользовать при повторном resolveStreamUrl().
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'artworkUrl': artworkUrl,
        'durationMs': duration.inMilliseconds,
        'source': source.name,
        'streamUrl': streamUrl,
        if (artistId != null) 'artistId': artistId,
      };

  factory Track.fromJson(Map<String, dynamic> json) => Track(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        artist: json['artist'] as String? ?? '',
        artworkUrl: json['artworkUrl'] as String? ?? '',
        duration: Duration(milliseconds: json['durationMs'] as int? ?? 0),
        source: MusicSourceType.values.firstWhere(
          (e) => e.name == json['source'],
          orElse: () => MusicSourceType.local,
        ),
        streamUrl: json['streamUrl'] as String? ?? '',
        artistId: json['artistId'] as String?,
      );
}
