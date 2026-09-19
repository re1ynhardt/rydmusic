import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import '../models/track.dart';

/// Тонкая обёртка над just_audio: держит текущий плейлист,
/// текущий индекс и прокидывает потоки состояния наверх.
class AudioPlayerService {
  AudioPlayerService() {
    _bindPlayer(_player);
  }

  AudioPlayer _player = AudioPlayer();
  List<Track> _queue = [];
  ConcatenatingAudioSource? _concatSource;

  final StreamController<Object> _errorController =
      StreamController<Object>.broadcast();

  // ВАЖНО: раньше playerStateStream/positionStream/currentIndexStream/
  // loopModeStream отдавались наружу напрямую как `_player.xxxStream`.
  // PlayerProvider подписывается на них ОДИН РАЗ в своём конструкторе и
  // держит эту подписку всё время жизни приложения. Пока `_player` был
  // `final` и никогда не менялся, это работало. Но кнопка "Стоп" в
  // шторке уведомлений останавливает плеер В ОБХОД PlayerProvider —
  // напрямую через just_audio_background/audio_service — и после такого
  // "внешнего" стопа нативный плеер (в отличие от программного stop()
  // из самого приложения, см. PlayerProvider.stop()) остаётся в
  // состоянии, из которого повторный setAudioSource()/play() у него не
  // поднимается: сессия и foreground-сервис уже разобраны системой.
  // Из-за этого следующий же выбранный трек молча не проигрывался, а
  // playTrack() кидал необработанное исключение прямо на setQueue(),
  // оставляя приложение навсегда висеть на сломанном плеере — ЛЮБОЙ
  // следующий трек падал точно так же.
  //
  // Чтобы приложение само восстанавливалось после такого "внешнего"
  // стопа, [_player] стал заменяемым: как только setQueue() видит, что
  // предыдущий стоп пришёл не от нас (см. [_stopRequestedByUs] и
  // [_playerNeedsRecreate]), она молча пересоздаёт AudioPlayer перед
  // тем как грузить новый трек. Чтобы это пересоздание было прозрачным
  // для PlayerProvider (не пришлось бы заново подписываться), потоки
  // ниже — СТАБИЛЬНЫЕ broadcast-контроллеры: они живут всё время жизни
  // AudioPlayerService и просто перевешиваются на текущий `_player`
  // заново при каждом пересоздании (см. [_bindPlayer]).
  final StreamController<PlayerState> _playerStateController =
      StreamController<PlayerState>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<int?> _currentIndexController =
      StreamController<int?>.broadcast();
  final StreamController<LoopMode> _loopModeController =
      StreamController<LoopMode>.broadcast();

  /// id трека, который РЕАЛЬНО стоит текущим в just_audio.
  ///
  /// Берётся не из индекса, а из тега источника (MediaItem.id, см.
  /// [_buildSource]) через `sequenceStateStream`: тег путешествует вместе
  /// со своим источником, поэтому вставка треков в начало плейлиста
  /// (см. [insertAtStart]) или любая другая перестройка очереди не может
  /// подсунуть чужой трек. Индекс же — это позиция в списке, который
  /// PlayerProvider мог ещё не успеть обновить.
  final StreamController<String?> _currentTrackIdController =
      StreamController<String?>.broadcast();

  StreamSubscription<PlaybackEvent>? _eventSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<LoopMode>? _loopSub;
  StreamSubscription<ProcessingState>? _processingSub;
  StreamSubscription<SequenceState?>? _sequenceSub;

  /// true на время нашего собственного вызова [stop] — чтобы отличить
  /// его от "внешнего" стопа, пришедшего из уведомления/системы.
  bool _stopRequestedByUs = false;

  /// true, если после последнего стопа было замечено, что он пришёл НЕ
  /// от нас — перед следующим setQueue() нужно пересоздать плеер.
  bool _playerNeedsRecreate = false;

  /// true на время нашего собственного вызова [AudioPlayer.setAudioSource]
  /// внутри [setQueue] — см. подробный комментарий у места использования
  /// в [_bindPlayer]: без этого флага смена трека периодически (особенно
  /// при переходе SoundCloud → YouTube) ошибочно принималась за внешний
  /// стоп и прятала мини-плеер.
  bool _loadingSource = false;

  ProcessingState _lastProcessingState = ProcessingState.idle;

  /// Сигнал: плеер был остановлен не из кода приложения (кнопка "Стоп" в
  /// уведомлении/системе), а не через [stop]. PlayerProvider слушает это,
  /// чтобы сбросить свой локальный queue/currentTrack — иначе мини-плеер
  /// продолжал бы показывать трек, который на самом деле уже не играет
  /// и не может быть возобновлён без явного выбора трека заново.
  Stream<void> get externalStop => _externalStopController.stream;
  final StreamController<void> _externalStopController =
      StreamController<void>.broadcast();

  void _bindPlayer(AudioPlayer player) {
    _eventSub?.cancel();
    _stateSub?.cancel();
    _positionSub?.cancel();
    _indexSub?.cancel();
    _loopSub?.cancel();
    _processingSub?.cancel();
    _sequenceSub?.cancel();

    _eventSub = player.playbackEventStream.listen((_) {},
        onError: (Object e, StackTrace st) {
      // Раньше ошибка потока просто проглатывалась и никак не
      // обрабатывалась — очередь могла молча зависнуть на сломанном
      // треке. Теперь пробрасываем ошибку наружу, чтобы PlayerProvider
      // мог показать её и пойти дальше по очереди.
      _errorController.add(e);
    });
    _stateSub = player.playerStateStream.listen(_playerStateController.add);
    _positionSub = player.positionStream.listen(_positionController.add);
    _indexSub = player.currentIndexStream.listen(_currentIndexController.add);
    _loopSub = player.loopModeStream.listen(_loopModeController.add);
    _sequenceSub = player.sequenceStateStream.listen((state) {
      final tag = state?.currentSource?.tag;
      if (tag is MediaItem) _currentTrackIdController.add(tag.id);
    }, onError: (Object e, StackTrace st) {});

    _lastProcessingState = player.processingState;
    _processingSub = player.processingStateStream.listen((state) {
      final previous = _lastProcessingState;
      _lastProcessingState = state;
      if (state == ProcessingState.idle &&
          previous != ProcessingState.idle &&
          !_stopRequestedByUs &&
          !_loadingSource) {
        // ВАЖНО: just_audio у себя внутри при КАЖДОМ setAudioSource()
        // (то есть при каждом обычном переключении трека, см. setQueue
        // ниже) может на кадр-другой отдать ProcessingState.idle перед
        // тем, как перейти в loading нового источника — это нормальная
        // часть смены источника, а не остановка плеера системой. Раньше
        // здесь фильтровался только наш явный stop() (_stopRequestedByUs),
        // и такой "мигающий" idle периодически принимался за внешний
        // стоп из уведомления — отсюда баг "мини-плеер то есть, то нет"
        // при переключении между треками. Особенно часто ловилось на
        // переходе SoundCloud → YouTube: из-за других заголовков
        // (см. _buildSource) и более долгой пересборки источника окно,
        // в котором успевает мелькнуть idle, шире. _loadingSource
        // выставляется на время именно нашего вызова setAudioSource
        // (см. setQueue) и глушит эти ложные срабатывания, не трогая
        // обнаружение настоящего внешнего стопа.
        _playerNeedsRecreate = true;
        _externalStopController.add(null);
      }
    });
  }

  /// Пересоздаёт нативный AudioPlayer с нуля. Используется, когда
  /// предыдущий был остановлен системой (см. [_bindPlayer]) и больше не
  /// принимает новые источники — просто пересоздавать без разбора его
  /// зависшего состояния безопаснее и проще, чем гадать, что именно в
  /// нём сломано после внешнего стопа.
  Future<void> _recreatePlayerIfNeeded() async {
    if (!_playerNeedsRecreate) return;
    _playerNeedsRecreate = false;
    final old = _player;
    _concatSource = null;
    _player = AudioPlayer();
    _bindPlayer(_player);
    // Старый плеер больше никому не нужен — закрываем в фоне, не
    // блокируя загрузку нового трека его освобождением ресурсов.
    unawaited(old.dispose().catchError((_) {}));
  }

  /// Ошибки воспроизведения.
  Stream<Object> get playbackErrors => _errorController.stream;

  AudioPlayer get raw => _player;
  List<Track> get queue => _queue;

  Stream<PlayerState> get playerStateStream => _playerStateController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<int?> get currentIndexStream => _currentIndexController.stream;

  /// Поток id трека, который сейчас реально играет (по тегу источника).
  Stream<String?> get currentTrackIdStream => _currentTrackIdController.stream;

  /// Текущий индекс нативного плеера.
  int? get currentIndex => _player.currentIndex;

  /// id трека, стоящего текущим в just_audio прямо сейчас (по тегу).
  String? get currentSourceTrackId {
    final tag = _player.sequenceState?.currentSource?.tag;
    return tag is MediaItem ? tag.id : null;
  }

  bool get isPlaying => _player.playing;

  Future<void> setQueue(List<Track> tracks, {int startIndex = 0}) async {
    await _recreatePlayerIfNeeded();
    _queue = tracks;
    final source = ConcatenatingAudioSource(
      children: tracks.map(_buildSource).toList(),
    );
    _concatSource = source;
    _loadingSource = true;
    try {
      await _player.setAudioSource(source, initialIndex: startIndex);
    } finally {
      // finally, а не просто после await: если setAudioSource бросит
      // исключение (см. обработку в PlayerProvider.playTrack), флаг всё
      // равно должен снятся — иначе следующий реальный внешний стоп
      // перестанет замечаться вовсе.
      _loadingSource = false;
    }
  }

  /// Дописывает уже разрешённые (resolveStreamUrl прошёл) треки в КОНЕЦ
  /// текущего плейлиста, пока он играет — не трогая то, что уже звучит.
  /// Используется, чтобы не заставлять пользователя ждать резолва всей
  /// очереди целиком перед стартом нажатого трека (см. PlayerProvider._
  /// resolveRestInBackground): подыгрывающие треки подъезжают по мере
  /// готовности.
  Future<void> appendToQueue(List<Track> tracks) async {
    final src = _concatSource;
    if (src == null || tracks.isEmpty) return;
    _queue = [..._queue, ...tracks];
    await src.addAll(tracks.map(_buildSource).toList());
  }

  /// Вставляет уже разрешённые треки в НАЧАЛО текущего плейлиста (треки,
  /// которые в исходной очереди шли раньше нажатого). just_audio сам
  /// корректно сдвигает currentIndex, не прерывая то, что уже играет.
  Future<void> insertAtStart(List<Track> tracks) async {
    final src = _concatSource;
    if (src == null || tracks.isEmpty) return;
    _queue = [...tracks, ..._queue];
    await src.insertAll(0, tracks.map(_buildSource).toList());
  }

  /// Строит источник аудио для одного трека.
  ///
  /// ВАЖНО: сетевые треки играются напрямую через `AudioSource.uri(...)`,
  /// БЕЗ автоматического дискового кэша на лету.
  ///
  /// Раньше (см. историю) они оборачивались в just_audio'шный
  /// [LockCachingAudioSource] — он одновременно стримит и пишет байты на
  /// диск, чтобы повтор трека читался с диска, а не заново с сети. Именно
  /// это и было источником бага "песни перестали воспроизводиться":
  /// LockCachingAudioSource берёт файловую блокировку на время закачки, и
  /// если предыдущая закачка того же кэш-файла не завершилась штатно
  /// (сеть пропала, приложение свёрнуто/убито ОС, hot restart во время
  /// закачки) — блокировка на диске остаётся висеть навсегда. Любая
  /// следующая попытка проиграть тот же трек тут же утыкается в эту
  /// мёртвую блокировку и ждёт её освобождения БЕСКОНЕЧНО — без единой
  /// ошибки в потоках плеера, просто вечная буферизация. Внешне это
  /// выглядит ровно как в баг-репорте: экран трека открывается, позиция
  /// стоит на 0:00 и не двигается.
  ///
  /// Прямое стриминговое воспроизведение этой проблемы не имеет: данные
  /// просто проигрываются по мере поступления, никакой блокировки на
  /// диске нет. Возможность "повтор трека работает без сети" (ради
  /// которой и добавляли LockCachingAudioSource) сознательно принесена в
  /// жертву надёжности обычного воспроизведения — офлайн-прослушивание
  /// как отдельная функция уже есть и работает через явный ручной кэш
  /// (см. CachedTracksProvider): такие треки приходят сюда уже с
  /// streamUrl вида `file://...` и играются прямо с диска.
  AudioSource _buildSource(Track t) {
    final uri = Uri.parse(t.streamUrl);
    final tag = MediaItem(
      id: t.id,
      title: t.title,
      artist: t.artist,
      duration: t.duration,
      artUri: t.artworkUrl.isNotEmpty ? Uri.parse(t.artworkUrl) : null,
    );
    // ВАЖНО: для YouTube-треков t.streamHeaders содержит User-Agent того
    // клиента, которым был подписан этот CDN-URL (см.
    // YouTubeService.resolveStreamUrl / ytdlp_bridge.py). Без него
    // googlevideo отдаёт 403 на сам GET аудио-потока, даже если
    // манифест только что успешно резолвнулся — именно это было
    // причиной "InvalidResponseCodeException: Response code: 403" в
    // логах. Остальные источники (SoundCloud/Audiomack/Deezer) headers
    // не задают, и здесь просто передаётся null.
    return AudioSource.uri(uri, tag: tag, headers: t.streamHeaders);
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> seek(Duration position) => _player.seek(position);
  Future<void> next() => _player.seekToNext();
  Future<void> previous() => _player.seekToPrevious();
  Future<void> skipTo(int index) => _player.seek(Duration.zero, index: index);
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);
  Future<void> setLoopMode(LoopMode mode) => _player.setLoopMode(mode);
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  double get volume => _player.volume;
  Stream<double> get volumeStream => _player.volumeStream;

  Stream<LoopMode> get loopModeStream => _loopModeController.stream;
  LoopMode get loopMode => _player.loopMode;

  Future<void> stop() async {
    _stopRequestedByUs = true;
    try {
      await _player.stop();
    } finally {
      _stopRequestedByUs = false;
    }
  }

  Future<void> dispose() {
    _eventSub?.cancel();
    _stateSub?.cancel();
    _positionSub?.cancel();
    _indexSub?.cancel();
    _loopSub?.cancel();
    _processingSub?.cancel();
    _sequenceSub?.cancel();
    _errorController.close();
    _currentTrackIdController.close();
    _playerStateController.close();
    _positionController.close();
    _currentIndexController.close();
    _loopModeController.close();
    _externalStopController.close();
    return _player.dispose();
  }
}
