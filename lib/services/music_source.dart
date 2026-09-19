import '../models/artist_page.dart';
import '../models/track.dart';

/// Общий контракт для любого источника музыки (SoundCloud, Audiomack, ...).
/// Благодаря этой абстракции UI не знает и не должен знать,
/// откуда именно приходят треки.
abstract class MusicSource {
  /// Короткое имя источника для UI (бейджи, фильтры и т.д.)
  String get name;

  /// Поиск треков по строке запроса. [offset] — сколько результатов
  /// пропустить (для постраничной подгрузки при скролле).
  Future<List<Track>> search(String query, {int limit = 25, int offset = 0});

  /// Подборка треков для главного экрана (тренды/рекомендации).
  Future<List<Track>> trending({int limit = 25});

  /// Иногда прямой stream-url нужно "разрешить" отдельным запросом
  /// (актуально для SoundCloud, где ссылка на трек != ссылка на поток).
  /// По умолчанию просто возвращает исходный трек.
  Future<Track> resolveStreamUrl(Track track) async => track;

  /// Сообщение от плеера: по ранее выданной ссылке проиграть не
  /// удалось. Источникам, которые кэшируют разрешённые ссылки (см.
  /// YouTubeService), это шанс выбросить протухшую запись, чтобы
  /// следующая попытка пошла за свежей. По умолчанию — ничего не
  /// делаем: у источников без кэша и выбрасывать нечего.
  void invalidateStream(Track track) {}

  /// Умеет ли источник показывать страницу исполнителя.
  bool get supportsArtistPage => false;

  /// Страница исполнителя трека [track] (альбомы + все треки) или null,
  /// если исполнитель не найден.
  Future<ArtistPage?> loadArtist(Track track) async => null;

  /// Треки альбома [album] в порядке следования.
  Future<List<Track>> loadAlbumTracks(ArtistAlbum album) async => const [];
}
