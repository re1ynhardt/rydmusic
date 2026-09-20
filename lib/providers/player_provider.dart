import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_strings.dart';
import '../models/track.dart';
import '../services/audio_player_service.dart';
import '../services/music_source.dart';
import 'cached_tracks_provider.dart';

class PlayerProvider extends ChangeNotifier {
  PlayerProvider({
    required Map<MusicSourceType, MusicSource> sources,
    CachedTracksProvider? cachedTracksProvider,
    // Передаётся из main.dart — тот же самый экземпляр, на который уже
    // подписан PlayerAudioHandler (см. notification_audio_handler.dart).
    // Если не передать (например, в тестах), сервис создастся сам, как
    // и раньше — просто в этом случае системное уведомление не будет
    // видеть события этого плеера.
    AudioPlayerService? audioService,
    AudioHandler? notificationHandler,
  })  : _sources = sources,
        _cachedTracksProvider = cachedTracksProvider,
        _service = audioService ?? AudioPlayerService(),
        _notificationHandler = notificationHandler {
    _service.playerStateStream.listen((state) {
      final playing = state.playing;
      final buffering = state.processingState == ProcessingState.buffering ||
          state.processingState == ProcessingState.loading;
      // Как только реально пошёл звук — сторожевой таймер (см.
      // _armStuckWatchdog) больше не нужен, отменяем его.
      if (playing) _stuckWatchdog?.cancel();
      // ПРОИЗВОДИТЕЛЬНОСТЬ: playerStateStream эмитит событие на каждое
      // изменение внутреннего состояния just_audio, и далеко не каждое
      // из них меняет то, что мы реально показываем. Уведомляем только
      // при фактическом изменении — иначе всё дерево слушателей
      // (мини-плеер, шелл, списки) впустую прогоняет свои селекторы.
      if (playing == _isPlaying && buffering == _isBuffering) return;
      _isPlaying = playing;
      _isBuffering = buffering;
      notifyListeners();
    }, onError: (Object e, StackTrace st) {
      // Ошибка потока состояния не должна "замораживать" UI кнопки паузы —
      // просто остаёмся с последним известным значением _isPlaying.
    });

    // ПРОИЗВОДИТЕЛЬНОСТЬ (главное изменение): позиция больше НЕ идёт
    // через notifyListeners(). just_audio отдаёт её до ~60 раз в секунду,
    // и раньше каждый такой тик будил всех слушателей PlayerProvider во
    // всём приложении — мини-плеер, MainShell, экраны поиска/библиотеки,
    // каждую плитку с select — просто чтобы они сверили значения и
    // ничего не перестроили. Теперь позиция живёт в отдельном
    // ValueNotifier: на неё подписаны ровно два места, которым она
    // нужна (полоса прогресса в Now Playing и подсветка строки текста
    // песни), и только они и перестраиваются.
    _service.positionStream.listen((pos) {
      // Дополнительный троттлинг: шаг меньше 200 мс на глаз неразличим
      // (полоса прогресса сдвинулась бы меньше чем на пиксель), но
      // стоит полного ребилда слайдера.
      final delta = (pos - positionListenable.value).abs();
      if (delta < _positionStep) return;
      positionListenable.value = pos;
    });

    // ВАЖНО (баг "в мини-плеере показан вообще другой трек, а играет
    // правильный"): раньше здесь стояло `_currentTrackId = _queue[index].id`,
    // то есть КАКОЙ трек текущий, определялся по индексу из just_audio,
    // подставленному в НАШ список `_queue`. Но наш список отстаёт от
    // just_audio: фоновый резолв (_resolveRestInBackground) вставляет ранее
    // идущие треки В НАЧАЛО плейлиста, just_audio тут же сдвигает индекс
    // играющего трека (0 -> N) и присылает событие, а `_queue` у нас
    // обновляется только после завершения `await insertAll(...)`. Событие
    // с новым индексом N попадало в старый, ещё не расширенный `_queue`, и
    // `_queue[N]` оказывался ЧУЖИМ треком: его id записывался как текущий,
    // мини-плеер и экран "сейчас играет" показывали его, а звучал
    // по-прежнему настоящий (аудио живёт в just_audio, которому мы
    // подсовывали правильные источники). Дальше _syncIndexToCurrentId
    // ещё и закрепляла эту ошибку, подтягивая индекс под неверный id.
    //
    // Теперь "какой трек играет" берётся из тега самого источника
    // (currentTrackIdStream) — он не зависит от порядка и длины нашего
    // списка. Индекс из события используется только как подсказка для
    // подсветки в очереди и только если указывает на тот же самый трек.
    _service.currentTrackIdStream.listen(_applyPlayingTrackId);

    _service.currentIndexStream.listen((index) {
      // null приходит, только когда источника нет вовсе; трактовать его
      // как "ничего не играет" нельзя — см. комментарий к _currentTrackId.
      if (index == null || _currentTrackId == null) return;
      if (index >= 0 &&
          index < _queue.length &&
          _queue[index].id == _currentTrackId) {
        if (index == _currentIndex) return;
        _currentIndex = index;
        notifyListeners();
        return;
      }
      // Индекс не сходится с нашим списком (он ещё не догнал just_audio или
      // трек сменился) — не гадаем по индексу, а сверяемся с реальным
      // источником сразу после того, как just_audio закончит обновлять
      // своё состояние.
      unawaited(Future<void>.delayed(Duration.zero, () {
        final id = _service.currentSourceTrackId;
        if (id != null) _applyPlayingTrackId(id);
      }));
    });

    _loopMode = _service.loopMode;
    _service.loopModeStream.listen((mode) {
      if (mode == _loopMode) return;
      _loopMode = mode;
      notifyListeners();
    });

    // Раньше ошибка потока просто проглатывалась, и очередь могла
    // молча зависнуть на сломанном треке. Теперь при ошибке показываем
    // её и идём дальше по очереди, вместо тишины.
    _service.playbackErrors.listen(_handlePlaybackError);

    // Кнопка "Стоп" в шторке уведомлений останавливает плеер в обход
    // этого провайдера (см. подробный комментарий в
    // AudioPlayerService._bindPlayer). Без этой подписки _queue и
    // _currentTrackId продолжали бы указывать на трек, который уже не
    // играет и не может быть возобновлён — мини-плеер завис бы на нём
    // навсегда. Реагируем так же, как на обычный ручной stop().
    _service.externalStop.listen((_) => _resetPlaybackState());

    _restoreLoopMode();
    _restoreRecentlyPlayed();
  }

  static const _loopKey = 'loop_mode';
  static const _recentlyPlayedKey = 'recently_played';
  static const _recentlyPlayedMaxCount = 30;

  /// Возвращает сохранённый режим повтора при запуске приложения.
  Future<void> _restoreLoopMode() async {
    try {
      final p = await SharedPreferences.getInstance();
      final i = p.getInt(_loopKey);
      if (i == null) return;
      final mode = LoopMode.values[i.clamp(0, LoopMode.values.length - 1)];
      if (mode == _loopMode) return;
      _loopMode = mode;
      notifyListeners();
      await _service.setLoopMode(mode);
    } catch (_) {
      // Не удалось прочитать — остаёмся на режиме по умолчанию.
    }
  }

  /// Загружает историю прослушанных треков из SharedPreferences.
  /// Вызывается при старте приложения один раз из конструктора.
  Future<void> _restoreRecentlyPlayed() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getStringList(_recentlyPlayedKey);
      if (raw == null || raw.isEmpty) return;
      final loaded = raw
          .map((s) {
            try {
              return Track.fromJson(jsonDecode(s) as Map<String, dynamic>);
            } catch (_) {
              return null;
            }
          })
          .whereType<Track>()
          .toList(growable: false);
      if (loaded.isEmpty) return;
      _recentlyPlayed = loaded;
      notifyListeners();
    } catch (_) {
      // Не удалось прочитать — начинаем с пустого списка.
    }
  }

  /// Добавляет трек в начало истории и сохраняет в SharedPreferences.
  /// Дубликаты (тот же id) удаляются перед вставкой — трек всегда
  /// всплывает наверх, а не дублируется.
  Future<void> _addToRecentlyPlayed(Track track) async {
    final updated = [
      track,
      ..._recentlyPlayed.where((t) => t.id != track.id),
    ];
    if (updated.length > _recentlyPlayedMaxCount) {
      _recentlyPlayed = updated.sublist(0, _recentlyPlayedMaxCount);
    } else {
      _recentlyPlayed = updated;
    }
    notifyListeners();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setStringList(
        _recentlyPlayedKey,
        _recentlyPlayed.map((t) => jsonEncode(t.toJson())).toList(),
      );
    } catch (_) {
      // Сохранение не критично — история просто не переживёт перезапуск.
    }
  }

  /// Сторожевой таймер: если после play() трек за разумное время так и
  /// не начал реально звучать (см. баг с зависшей на 0:00 буферизацией
  /// в AudioPlayerService._buildSource — там же основная причина и её
  /// фикс), это подвисание НЕ породит ни одной ошибки в потоках плеера —
  /// формально всё ещё "грузится". Без этого таймера пользователь так и
  /// остался бы стоять на 0:00 бесконечно. Таймер — просто последняя
  /// страховка на случай любой другой причины зависания (мёртвая ссылка,
  /// недоступный CDN и т.п.), а не основной механизм фикса.
  Timer? _stuckWatchdog;
  static const _stuckTimeout = Duration(seconds: 12);

  final Map<MusicSourceType, MusicSource> _sources;
  final CachedTracksProvider? _cachedTracksProvider;
  final AudioPlayerService _service;
  final AudioHandler? _notificationHandler;

  List<Track> _queue = [];
  int? _currentIndex;

  /// Идентификатор трека, который сейчас считается текущим.
  ///
  /// КЛЮЧЕВОЕ: раньше [currentTrack] зависел ИСКЛЮЧИТЕЛЬНО от индекса,
  /// приходящего из `currentIndexStream` just_audio. Этот поток
  /// отфильтрован по принципу "только изменения": если новый индекс
  /// совпадает с предыдущим, события просто не будет. А наш `_currentIndex`
  /// сбрасывается в null при [stop] — и после этого запуск следующего
  /// трека (он снова встаёт под индексом 0, как и предыдущий) НЕ порождал
  /// ни одного события, `_currentIndex` навсегда оставался null, а
  /// `currentTrack` — null. Внешне это и есть баг "мини-плеер то
  /// появляется, то нет": трек играет, а плеера на экране нет, пока не
  /// перелистнёшь очередь. Та же дыра открывалась на долю секунды при
  /// каждой смене очереди (старый индекс ещё не сброшен, новая очередь
  /// уже короче) и при вставке треков в начало очереди фоновым резолвом.
  ///
  /// Теперь текущий трек привязан к своему id, который мы ставим САМИ и
  /// сразу — ещё до того, как just_audio вообще что-то скажет. Индекс
  /// остался как быстрый путь и для подсветки в очереди, но источником
  /// правды больше не является.
  String? _currentTrackId;

  bool _isPlaying = false;
  bool _isBuffering = false;
  LoopMode _loopMode = LoopMode.off;

  /// Недавно прослушанные треки — новые добавляются в начало.
  /// Сохраняется в SharedPreferences между сессиями.
  List<Track> _recentlyPlayed = const [];

  /// Позиция воспроизведения отдельным слушаемым значением — НЕ через
  /// notifyListeners(). Подробности и причина — в конструкторе.
  final ValueNotifier<Duration> positionListenable =
      ValueNotifier<Duration>(Duration.zero);

  static const _positionStep = Duration(milliseconds: 200);

  List<Track> get queue => _queue;

  Track? get currentTrack {
    final id = _currentTrackId;
    final i = _currentIndex;
    if (id != null) {
      // Быстрый путь: индекс и id согласованы.
      if (i != null && i >= 0 && i < _queue.length && _queue[i].id == id) {
        return _queue[i];
      }
      // Индекс отстал от очереди (её только что пересобрали или в начало
      // вставились дорезолвленные треки) — находим трек по id.
      for (final t in _queue) {
        if (t.id == id) return t;
      }
      // id известен, но в очереди его нет — раньше здесь всё равно
      // возвращался `_queue[i]`, то есть ПРОИЗВОЛЬНЫЙ трек по устаревшему
      // индексу (ещё один источник "чужого" трека в мини-плеере).
      return null;
    }
    // id ещё не выставлен — единственный случай, когда можно опереться
    // на индекс.
    if (i != null && i >= 0 && i < _queue.length) return _queue[i];
    return null;
  }

  int? get currentIndex {
    final id = _currentTrackId;
    final i = _currentIndex;
    if (id == null) return i;
    if (i != null && i >= 0 && i < _queue.length && _queue[i].id == id) {
      return i;
    }
    final found = _queue.indexWhere((t) => t.id == id);
    return found >= 0 ? found : i;
  }

  bool get isPlaying => _isPlaying;
  bool get isBuffering => _isBuffering;
  Duration get position => positionListenable.value;
  LoopMode get loopMode => _loopMode;
  AudioPlayerService get service => _service;

  /// Источник музыки по типу (для страницы исполнителя и т.п.).
  MusicSource? sourceOf(MusicSourceType type) => _sources[type];

  /// Недавно прослушанные треки (новейший первым).
  List<Track> get recentlyPlayed => _recentlyPlayed;

  /// Подтягивает [_currentIndex] под [_currentTrackId] после любой
  /// перестройки очереди — не дожидаясь события от just_audio.
  void _syncIndexToCurrentId() {
    final id = _currentTrackId;
    if (id == null) return;
    bool matches(int? i) =>
        i != null && i >= 0 && i < _queue.length && _queue[i].id == id;
    // Индекс самого плеера — лучший вариант (различает дубликаты одного
    // трека в очереди), но только если он указывает именно на этот трек.
    final nativeIndex = _service.currentIndex;
    if (matches(nativeIndex)) {
      _currentIndex = nativeIndex;
      return;
    }
    if (matches(_currentIndex)) return;
    final found = _queue.indexWhere((t) => t.id == id);
    if (found >= 0) _currentIndex = found;
  }

  /// Применяет id трека, который just_audio сообщил как реально
  /// играющий (по тегу источника). Единственное место, где текущий трек
  /// меняется "снаружи" — по событию плеера (авто-переход, next/previous,
  /// сдвиг индекса после вставки треков в начало).
  void _applyPlayingTrackId(String? id) {
    if (id == null) return;
    // Ничего не играет (после Стопа/свайпа мини-плеера) — поздние события
    // от уже остановленного источника не должны воскрешать мини-плеер.
    // Любое воспроизведение стартует через playTrack(), который сам
    // выставляет _currentTrackId, так что легитимных событий при null нет.
    if (_currentTrackId == null) return;

    // Событие от источника, которого нет в актуальной очереди — остаток
    // предыдущего плейлиста, пока грузится новый. Игнорируем.
    final serviceQueue = _service.queue;
    if (!serviceQueue.any((t) => t.id == id)) return;

    var changed = false;
    // Очередь сервиса обновляется синхронно, до обращения к just_audio, —
    // она всегда не отстаёт от того, что играет. Подтягиваем свою.
    if (!identical(_queue, serviceQueue)) {
      _queue = serviceQueue;
      changed = true;
    }
    if (_currentTrackId != id) {
      _currentTrackId = id;
      changed = true;
    }
    final before = _currentIndex;
    _syncIndexToCurrentId();
    if (before != _currentIndex) changed = true;
    if (changed) notifyListeners();
  }

  bool _isResolving = false;
  bool get isResolving => _isResolving;

  String? _lastError;
  String? get lastError => _lastError;

  // Счётчик "поколений" фонового резолва очереди (см.
  // _resolveRestInBackground). Каждый новый playTrack() увеличивает его —
  // это позволяет предыдущему, ещё не завершившемуся фоновому резолву
  // понять, что он устарел (пользователь уже нажал на другой трек или
  // остановил плеер), и тихо прекратить работу вместо того, чтобы
  // дописать в текущий, уже другой, плейлист треки от старого запроса.
  int _resolveGeneration = 0;

  // Номер последнего нажатия на трек. В отличие от _resolveGeneration его
  // двигает ТОЛЬКО playTrack() — по нему устаревший (вытесненный новым
  // нажатием) вызов понимает, что он уже не главный.
  int _playRequestId = 0;

  /// Резолвит один трек в реально проигрываемый источник — общая логика
  /// для нажатого трека (быстрый путь) и для остальной очереди (фон).
  /// Возвращает null, если трек недоступен, и его нужно просто пропустить.
  Future<Track?> _resolveOne(Track t) async {
    // Закэшированный трек проигрывается прямо с диска — без сети и без
    // резолва streamUrl. Это же и есть офлайн-режим: если сети нет,
    // а трек скачан заранее, он всё равно проиграется.
    final cachedPath = _cachedTracksProvider?.localPathFor(t.id);
    if (cachedPath != null) {
      return t.copyWith(streamUrl: Uri.file(cachedPath).toString());
    }

    final source = _sources[t.source];
    try {
      final resolved = source != null ? await source.resolveStreamUrl(t) : t;
      // Пустой streamUrl (например, у трека вообще нет доступных
      // transcoding'ов) — тоже считаем непроигрываемым и пропускаем.
      return resolved.streamUrl.isNotEmpty ? resolved : null;
    } catch (_) {
      // Один недоступный трек (удалён, гео-блок, протухшая ссылка,
      // отсутствие сети и т.п.) не должен ронять всю очередь —
      // просто пропускаем его.
      return null;
    }
  }

  Future<void> playTrack(Track track, {List<Track>? queue}) async {
    final rawQueue = queue ?? [track];
    final tappedIndex = rawQueue.indexWhere((t) => t.id == track.id);

    final requestId = ++_playRequestId;
    _resolveGeneration++;
    _isResolving = true;
    _lastError = null;
    notifyListeners();

    // ВАЖНО: раньше здесь резолвилась ЦЕЛИКОМ вся очередь (Future.wait по
    // rawQueue) прежде чем начать играть хоть что-то. Для YouTube
    // resolveStreamUrl — это скрытый WebView + yt-dlp мост НА КАЖДЫЙ
    // трек, а все резолвы YouTube физически встают в одну очередь на
    // единственный WebView (см. YoutubeSessionResolver._queueTail) — то
    // есть при списке из 15-45 треков (столько отдаёт страница поиска)
    // это последовательные резолвы по несколько секунд каждый,
    // суммарно — минуты ожидания мини-плеера. Плюс за это время часть
    // уже полученных подписанных URL успевает протухнуть, поэтому к
    // моменту реального play() часть треков уже не играет.
    //
    // Теперь: резолвим и запускаем СРАЗУ только нажатый трек, а
    // остальную очередь дорезолвливаем в фоне и подставляем в уже
    // играющий плейлист по мере готовности (см.
    // _resolveRestInBackground) — next()/previous() продолжают работать,
    // просто соседние треки могут быть готовы чуть позже самого первого.
    final resolvedTapped = await _resolveOne(track);
    // Пока резолвился этот трек, пользователь мог нажать другой (резолв
    // YouTube занимает секунды). Раньше устаревший вызов после резолва
    // всё равно перезаписывал очередь и текущий трек своим, а параллельные
    // setQueue() дрались за один плеер — в итоге интерфейс показывал один
    // трек, а звучал другой. Теперь довести дело до конца может только
    // самое свежее нажатие; _isResolving за него сбросит оно само.
    if (requestId != _playRequestId) return;
    _isResolving = false;

    if (resolvedTapped == null) {
      _lastError = AppStrings.current.trackUnavailable(track.title);
      notifyListeners();
      return;
    }

    // Состояние "что сейчас играет" выставляется СИНХРОННО и ДО
    // обращения к just_audio: мини-плеер появляется в том же кадре, в
    // котором трек резолвнулся, и больше не зависит от того, пришлёт ли
    // just_audio событие о смене индекса (см. _currentTrackId).
    _queue = [resolvedTapped];
    _currentIndex = 0;
    _currentTrackId = resolvedTapped.id;
    positionListenable.value = Duration.zero;
    notifyListeners();

    // Записываем в историю прослушивания.
    unawaited(_addToRecentlyPlayed(resolvedTapped));

    try {
      await _service.setQueue(_queue, startIndex: 0);
    } catch (e) {
      // Загрузку прервало более свежее нажатие (just_audio бросает
      // "Loading interrupted", когда во время setAudioSource приходит
      // следующий setAudioSource). Это не сбой: состояние теперь принадлежит
      // новому вызову, и трогать (а тем более сбрасывать) его нельзя.
      if (requestId != _playRequestId) return;
      // Раньше исключение здесь никак не ловилось: оно улетало наружу
      // необработанным, а _service/_player так и оставался в сломанном
      // состоянии — КАЖДЫЙ следующий тап по треку падал точно так же
      // (это и есть баг "после Стопа в уведомлении вообще ничего не
      // играет"). AudioPlayerService теперь сам пересоздаёт плеер после
      // внешнего стопа (см. _recreatePlayerIfNeeded), так что до этой
      // ветки в норме уже не дойдёт — но она остаётся страховкой на
      // случай любой другой причины сбоя setAudioSource.
      if (kDebugMode) debugPrint('[PlayerProvider] setQueue failed: $e');
      _lastError = AppStrings.current.playbackFailedSkipped(resolvedTapped.title);
      _resetPlaybackState();
      return;
    }
    // Пока грузился источник, могло прийти новое нажатие — тогда и play(),
    // и сторожевой таймер, и дорезолв очереди этого вызова уже не нужны
    // (иначе он дописал бы свои треки в ЧУЖОЙ плейлист).
    if (requestId != _playRequestId) return;

    // play() у just_audio завершается только при паузе/конце трека —
    // ждать его нельзя, иначе остальная очередь не догрузится.
    unawaited(_service.play().catchError((_) {}));
    _armStuckWatchdog(resolvedTapped.id);

    if (rawQueue.length > 1) {
      unawaited(_resolveRestInBackground(
        rawQueue,
        tappedIndex: tappedIndex < 0 ? 0 : tappedIndex,
        generation: _resolveGeneration,
      ));
    }
  }

  /// Дорезолвливает остальную часть очереди (кроме уже играющего
  /// нажатого трека) и подставляет треки в уже играющий плейлист по мере
  /// готовности — сначала те, что идут ПОСЛЕ нажатого (чтобы next()
  /// заработал как можно раньше), затем те, что были ДО него.
  /// Резолвит последовательно, а не через Future.wait: для YouTube
  /// параллелизм всё равно фиктивный (общий WebView сериализует запросы),
  /// а последовательный проход не даёт резким скачкам _queue сбивать
  /// порядок вставки.
  Future<void> _resolveRestInBackground(
    List<Track> rawQueue, {
    required int tappedIndex,
    required int generation,
  }) async {
    bool stale() => generation != _resolveGeneration;

    for (var i = tappedIndex + 1; i < rawQueue.length && !stale(); i++) {
      final resolved = await _resolveOne(rawQueue[i]);
      if (stale()) return;
      if (resolved != null) {
        await _service.appendToQueue([resolved]);
        if (stale()) return;
        _queue = _service.queue;
        _syncIndexToCurrentId();
        notifyListeners();
      }
    }

    final before = <Track>[];
    for (var i = 0; i < tappedIndex && !stale(); i++) {
      final resolved = await _resolveOne(rawQueue[i]);
      if (stale()) return;
      if (resolved != null) before.add(resolved);
    }
    if (before.isNotEmpty && !stale()) {
      await _service.insertAtStart(before);
      if (stale()) return;
      _queue = _service.queue;
      // Текущий трек физически сдвинулся вперёд на before.length позиций.
      // Пересчитываем индекс сами, не дожидаясь события just_audio —
      // иначе между вставкой и событием currentTrack на кадр-другой
      // указывал бы на чужой трек (мигание обложки/названия).
      _syncIndexToCurrentId();
      notifyListeners();
    }
  }

  /// Запускает сторожевой таймер на конкретный трек — см. поле
  /// [_stuckWatchdog]. Если за [_stuckTimeout] звук так и не пошёл, а
  /// пользователь всё ещё смотрит на тот же трек, считаем воспроизведение
  /// зависшим и восстанавливаемся так же, как при обычной ошибке.
  void _armStuckWatchdog(String trackId) {
    _stuckWatchdog?.cancel();
    _stuckWatchdog = Timer(_stuckTimeout, () {
      if (!_isPlaying && currentTrack?.id == trackId) {
        _handlePlaybackError(
          StateError('Воспроизведение зависло на треке $trackId'),
        );
      }
    });
  }

  /// Реакция на ошибку воспроизведения текущего трека (включая зависшую
  /// буферизацию, см. _armStuckWatchdog). Показывает ошибку в UI и
  /// пытается пойти дальше по очереди, а не оставляет плеер молча
  /// висеть на одном треке.
  Future<void> _handlePlaybackError(Object error) async {
    _stuckWatchdog?.cancel();
    // Реальный текст ошибки плеера — только в отладочной сборке: в
    // релизе print() всё равно выполняется, дёргает системный лог и
    // способен подтормаживать как раз в момент сбоя воспроизведения.
    if (kDebugMode) {
      debugPrint('[PlayerProvider] playback error: $error');
    }
    final failed = currentTrack;
    // Источник мог отдать ссылку из собственного кэша (YouTube так и
    // делает) — раз по ней не проигралось, пусть выбросит её и в
    // следующий раз добудет свежую.
    if (failed != null) _sources[failed.source]?.invalidateStream(failed);
    _lastError = failed != null
        ? AppStrings.current.playbackFailedSkipped(failed.title)
        : AppStrings.current.playbackError;
    notifyListeners();

    if (_queue.length > 1) {
      try {
        await _service.next();
      } catch (_) {
        // Если и next() не удался — оставляем как есть, ошибка уже
        // показана через lastError.
      }
    }
  }

  Future<void> togglePlayPause() async {
    // Обновляем состояние сразу же, не дожидаясь события из
    // playerStateStream: на некоторых устройствах/платформах поток
    // just_audio эмитит новое состояние с заметной задержкой, из-за чего
    // казалось, что кнопка паузы "не реагирует" на нажатие.
    final wasPlaying = _isPlaying;
    _isPlaying = !wasPlaying;
    notifyListeners();

    try {
      if (wasPlaying) {
        await _service.pause();
      } else {
        await _service.play();
      }
    } catch (_) {
      // Если системный вызов не удался — откатываем оптимистичное
      // состояние обратно, а playerStateStream досинхронизирует остальное.
      _isPlaying = wasPlaying;
      notifyListeners();
    }
  }

  Future<void> seek(Duration position) => _service.seek(position);
  Future<void> next() => _service.next();
  Future<void> previous() => _service.previous();

  Future<void> skipTo(int i) async {
    if (i < 0 || i >= _queue.length) return;
    // Сразу, не дожидаясь события из потока — UI переключается в том же
    // кадре, в котором пользователь ткнул в трек очереди.
    _currentIndex = i;
    _currentTrackId = _queue[i].id;
    positionListenable.value = Duration.zero;
    notifyListeners();
    await _service.skipTo(i);
    if (!_isPlaying) unawaited(_service.play().catchError((_) {}));
  }

  /// Переключает режим повтора по кругу: выкл → вся очередь → один трек → выкл.
  Future<void> cycleLoopMode() async {
    final next = switch (_loopMode) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    _loopMode = next;
    notifyListeners();
    await _service.setLoopMode(next);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(_loopKey, next.index);
    } catch (_) {}
  }

  /// Полностью останавливает воспроизведение и очищает очередь — после
  /// этого [currentTrack] становится null, и мини-плеер прячется сам
  /// (см. `if (track == null) return const SizedBox.shrink();` в
  /// MiniPlayer). Используется свайпом мини-плеера, чтобы "выключить"
  /// трек, а не просто поставить на паузу.
  Future<void> stop() async {
    await _service.stop();
    _resetPlaybackState();
  }

  /// Вызывается из PlayerAudioHandler.onNotificationInitiatedStop (см.
  /// main.dart, где колбэк подключается) — когда трек остановили СНАРУЖИ,
  /// свайпом самого системного уведомления, а не мини-плеера в
  /// приложении. Плеер к этому моменту уже остановлен самим хендлером —
  /// здесь только синхронизируем локальное состояние приложения с этим
  /// фактом, чтобы мини-плеер тоже спрятался.
  void handleNotificationStop() => _resetPlaybackState();

  /// Сбрасывает локальное состояние "что сейчас играет" — общая часть
  /// для явного [stop] (свайп мини-плеера), для реакции на внешний стоп
  /// из уведомления (см. подписку на `_service.externalStop` в
  /// конструкторе) и для [handleNotificationStop] (свайп самого
  /// уведомления). Сам плеер к этому моменту уже остановлен — либо нами,
  /// либо системой.
  void _resetPlaybackState() {
    if (_currentTrackId == null && _queue.isEmpty) {
      // Уже сброшено. Без этой проверки [handleNotificationStop] и вызов
      // notificationHandler.stop() ниже гоняли бы события друг на друга
      // по кругу: PlayerAudioHandler.stop() → onNotificationInitiatedStop
      // → сюда → notificationHandler.stop() снова → ... (на стороне
      // самого хендлера от этого же эха защищает его собственный флаг
      // _stopAlreadyHandled — это вторая, "своя" защита на всякий случай).
      return;
    }
    _resolveGeneration++; // обрывает недорезолвленный фон из playTrack()
    _stuckWatchdog?.cancel();
    _queue = [];
    _currentIndex = null;
    _currentTrackId = null;
    _isPlaying = false;
    positionListenable.value = Duration.zero;
    notifyListeners();
    // ВАЖНО: это единственное место, которое ТОЧНО знает, что трека
    // больше нет (а не просто идёт временная переходная фаза между
    // треками — все такие фазы уже отфильтрованы выше по стеку). Без
    // этого вызова системное уведомление осталось бы висеть с последним
    // треком после свайпа мини-плеера — currentSourceTrackId у самого
    // AudioPlayerService после player.stop() не обнуляется (см. его
    // комментарии), поэтому PlayerAudioHandler сам эту ситуацию не
    // поймает и должен быть уведомлён явно.
    unawaited(_notificationHandler?.stop());
  }

  @override
  void dispose() {
    _resolveGeneration++;
    _stuckWatchdog?.cancel();
    positionListenable.dispose();
    _service.dispose();
    super.dispose();
  }
}
