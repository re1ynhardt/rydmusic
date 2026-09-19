import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import '../services/music_source.dart';

enum _FeedStatus { initial, loading, loaded, error }

/// Данные и подборки для главного экрана: тренды по всем источникам и
/// персональные рекомендации на основе избранного.
///
/// Живёт на уровне приложения (см. main.dart), а не внутри State самого
/// HomeScreen — благодаря этому:
/// - результат переживает пересоздание виджета экрана (например, смену
///   темы) и не грузится заново там, где уже есть валидный кэш;
/// - на переключение вкладок ничего не тратится вообще: IndexedStack и
///   так не убивает HomeScreen, но с провайдером не зависим от этого —
///   данные не привязаны к жизненному циклу конкретного State;
/// - реагирует на изменения избранного централизованно, одним слушателем
///   на FavoritesProvider, а не подпиской из каждого места, которому
///   нужны рекомендации.
class HomeProvider extends ChangeNotifier {
  HomeProvider({required Map<MusicSourceType, MusicSource> sources})
      : _sources = sources;

  final Map<MusicSourceType, MusicSource> _sources;

  /// Сколько ждать один источник, прежде чем считать его недоступным.
  /// Без этого лимита один зависший источник (протухший токен, битый
  /// DNS и т.п.) держал бы весь Future.wait, и лента не показалась бы
  /// вовсе, пока не истечёт таймаут HTTP-клиента источника (иногда —
  /// минуты).
  static const _perSourceTimeout = Duration(seconds: 8);

  /// Сколько треков каждого артиста запрашивать у одного источника при
  /// построении рекомендаций — не больше, чтобы не заспамить выдачу
  /// одним исполнителем и не тратить лишний трафик.
  static const _perArtistLimit = 6;

  /// Сколько последних уникальных артистов из избранного использовать
  /// как основу для рекомендаций. Берутся самые НЕДАВНИЕ (favorites уже
  /// отсортирован новыми сверху) — так подборка отражает текущий вкус,
  /// а не тонет в артистах, добавленных год назад.
  static const _seedArtistsCount = 5;

  _FeedStatus _trendingStatus = _FeedStatus.initial;
  _FeedStatus _recommendedStatus = _FeedStatus.initial;
  List<Track> _trending = const [];
  List<Track> _recommended = const [];

  /// Набор артистов, для которого уже посчитаны текущие [_recommended] —
  /// используется, чтобы не пересчитывать подборку заново, если список
  /// избранного изменился (например, снят/поставлен лайк тому же треку
  /// дважды), а сами топ-артисты остались теми же.
  Set<String> _recommendedSeed = const {};

  int _trendingToken = 0;
  int _recommendedToken = 0;
  Timer? _recommendDebounce;

  /// Пока пользователь ни разу не открыл главную, нет смысла тратить
  /// сетевые запросы на рекомендации — они могли бы пересчитываться при
  /// каждом лайке ещё до первого визита на экран. Вместо этого просто
  /// запоминаем самый свежий список избранного и считаем подборку один
  /// раз, когда экран реально открывается (см. ensureLoaded).
  bool _everOpened = false;
  List<Track> _latestFavorites = const [];

  bool get isTrendingLoading => _trendingStatus == _FeedStatus.loading;
  bool get isTrendingError =>
      _trendingStatus == _FeedStatus.error && _trending.isEmpty;
  List<Track> get trending => _trending;

  bool get isRecommendedLoading => _recommendedStatus == _FeedStatus.loading;
  List<Track> get recommended => _recommended;

  /// Есть ли вообще смысл показывать блок рекомендаций — не показываем
  /// его до первой успешной загрузки И если он в итоге оказался пустым
  /// (пользователь без избранного получает только тренды).
  bool get showRecommended =>
      _recommendedStatus != _FeedStatus.initial && _recommended.isNotEmpty;

  /// Вызывается один раз из HomeScreen.initState — идемпотентно: если
  /// тренды уже загружены (или грузятся), повторный вызов ничего не
  /// делает. Явный вызов вместо загрузки прямо в конструкторе, потому
  /// что конструктор провайдера выполняется в момент старта приложения,
  /// а сетевой запрос на главную выгоднее откладывать до первого реально
  /// открытого экрана.
  void ensureLoaded() {
    _everOpened = true;
    if (_trendingStatus == _FeedStatus.initial) {
      _loadTrending();
    }
    if (_recommendedStatus == _FeedStatus.initial) {
      _loadRecommended(_latestFavorites);
    }
  }

  /// Запоминает актуальный список избранного и, если главная уже
  /// открывалась хотя бы раз, планирует пересчёт рекомендаций под него.
  /// Вызывается из main.dart при КАЖДОМ изменении FavoritesProvider
  /// (лайк/дизлайк, загрузка библиотеки при входе, смена аккаунта) — с
  /// дебаунсом, чтобы серия быстрых лайков не породила серию
  /// параллельных пересчётов (каждый — это N сетевых запросов на
  /// источник).
  void scheduleRecommendationsRefresh(List<Track> favorites) {
    _latestFavorites = favorites;
    if (!_everOpened) return; // экран ещё не открывали — считать нечего показывать
    _recommendDebounce?.cancel();
    _recommendDebounce = Timer(const Duration(milliseconds: 900), () {
      _loadRecommended(_latestFavorites);
    });
  }

  /// Полный сброс кэша обеих подборок и загрузка заново — используется
  /// pull-to-refresh на главной. Список избранного берём из
  /// [_latestFavorites] (актуализируется на каждое изменение
  /// FavoritesProvider), а не через параметр — HomeScreen не обязан
  /// знать, что рекомендациям вообще нужно избранное.
  Future<void> refresh() {
    _recommendDebounce?.cancel();
    return Future.wait([
      _loadTrending(),
      _loadRecommended(_latestFavorites, force: true),
    ]);
  }

  Future<void> _loadTrending() async {
    final token = ++_trendingToken;
    _trendingStatus = _FeedStatus.loading;
    notifyListeners();

    final tracks = await _fetchFromAllSources(
      (source) => source.trending(limit: 15),
    );
    if (token != _trendingToken) return; // обогнал более новый запрос

    _trending = tracks;
    _trendingStatus = _FeedStatus.loaded;
    notifyListeners();
  }

  Future<void> _loadRecommended(List<Track> favorites, {bool force = false}) async {
    final seedArtists = _topArtists(favorites, _seedArtistsCount);
    if (seedArtists.isEmpty) {
      // Нет избранного — рекомендательному блоку не на чем строиться.
      // Не трогаем предыдущую подборку токеном "loading", просто гасим
      // её — showRecommended сам решит, показывать ли секцию вообще.
      if (_recommended.isNotEmpty || _recommendedStatus == _FeedStatus.initial) {
        _recommended = const [];
        _recommendedSeed = const {};
        _recommendedStatus = _FeedStatus.loaded;
        notifyListeners();
      }
      return;
    }

    final seedKey = seedArtists.toSet();
    if (!force && seedKey.length == _recommendedSeed.length && seedKey.containsAll(_recommendedSeed)) {
      return; // топ-артисты не изменились — прошлая подборка всё ещё актуальна
    }

    final token = ++_recommendedToken;
    _recommendedStatus = _FeedStatus.loading;
    notifyListeners();

    final favoriteIds = favorites.map((t) => t.id).toSet();
    final perArtistResults = await Future.wait(seedArtists.map(
      (artist) => _fetchFromAllSources(
        (source) => source.search(artist, limit: _perArtistLimit),
      ),
    ));

    if (token != _recommendedToken) return;

    // Интерливинг вместо простой конкатенации: по одному треку с каждого
    // артиста по кругу — так в начале подборки сразу видно разнообразие
    // вкуса, а не сплошной блок из одного исполнителя, у которого
    // источники ответили быстрее остальных.
    final merged = <Track>[];
    final seenIds = <String>{...favoriteIds};
    var remaining = true;
    var round = 0;
    while (remaining) {
      remaining = false;
      for (final bucket in perArtistResults) {
        if (round >= bucket.length) continue;
        remaining = true;
        final track = bucket[round];
        // Не рекомендуем то, что и так уже в избранном, и убираем
        // дубликаты одного трека, вернувшегося от нескольких артистов
        // (например, совместный трек двух любимых исполнителей).
        if (seenIds.add(track.id)) merged.add(track);
      }
      round++;
    }

    // Показываем ТОЛЬКО треки из YouTube в блоке рекомендаций.
    _recommended = merged
        .where((t) => t.source == MusicSourceType.youtube)
        .toList(growable: false);
    _recommendedSeed = seedKey;
    _recommendedStatus = _FeedStatus.loaded;
    notifyListeners();
  }

  /// Запрашивает [fetch] параллельно у всех источников с ограничением по
  /// времени на каждый и мягкой деградацией: упавший/не успевший источник
  /// просто отдаёт пустой список вместо провала всей подборки.
  Future<List<Track>> _fetchFromAllSources(
    Future<List<Track>> Function(MusicSource source) fetch,
  ) async {
    final results = await Future.wait(_sources.values.map((source) {
      return fetch(source).timeout(_perSourceTimeout, onTimeout: () => const <Track>[])
          .catchError((_) => const <Track>[]);
    }));
    return results.expand((e) => e).toList(growable: false);
  }

  /// Топ-[n] артистов из избранного по частоте, при равной частоте —
  /// более недавние (favorites уже в порядке "новые сверху") идут раньше.
  /// Один проход по списку вместо sort по всей карте: избранное может
  /// быть большим, а нам нужна лишь верхушка.
  List<String> _topArtists(List<Track> favorites, int n) {
    if (favorites.isEmpty) return const [];
    final order = <String>[]; // порядок первого появления = недавность
    final recency = <String, int>{}; // индекс первого появления — O(1) на чтение при сортировке
    final counts = <String, int>{};
    for (final t in favorites) {
      final artist = t.artist.trim();
      if (artist.isEmpty) continue;
      final existing = counts[artist];
      if (existing != null) {
        counts[artist] = existing + 1;
      } else {
        counts[artist] = 1;
        recency[artist] = order.length;
        order.add(artist);
      }
    }
    order.sort((a, b) {
      final byCount = counts[b]!.compareTo(counts[a]!);
      if (byCount != 0) return byCount;
      return recency[a]!.compareTo(recency[b]!);
    });
    return order.take(min(n, order.length)).toList(growable: false);
  }

  @override
  void dispose() {
    _recommendDebounce?.cancel();
    super.dispose();
  }
}
