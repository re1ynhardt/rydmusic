import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' show LoopMode, ProcessingState;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/track.dart';
import '../providers/favorites_provider.dart';
import 'artwork_url.dart';
import 'audio_player_service.dart';

/// Мост между уже существующим [AudioPlayerService] (обёртка над
/// just_audio, которой управляет весь остальной код приложения через
/// PlayerProvider) и системным медиа-уведомлением.
///
/// Раньше уведомление собирал `just_audio_background` — простая
/// автоматическая обёртка, которая даёт только play/pause/next/previous
/// и НЕ позволяет добавить свои кнопки (см. её собственную
/// документацию: "нужен больший контроль над кнопками уведомления —
/// используйте audio_service напрямую"). Здесь именно это и сделано.
///
/// Хендлер НЕ содержит собственной логики воспроизведения — он только:
///  1) транслирует состояние [AudioPlayerService] в audio_service, то
///     есть мини-плеер в приложении и системное уведомление в итоге
///     показывают одно и то же состояние одного и того же плеера —
///     второго источника правды не появляется;
///  2) перенаправляет нажатия из уведомления обратно в тот же сервис.
///
/// Кнопки "избранное" (галочка) и "повтор" — кастомные экшены (у
/// audio_service из коробки таких нет). Иконки под них должны лежать в
/// android/app/src/main/res/drawable/ic_notif_*.xml — этот Dart-файл их
/// не создаёт, их нужно добавить в нативный Android-проект отдельно.
class PlayerAudioHandler extends BaseAudioHandler with SeekHandler {
  PlayerAudioHandler(this._service, this._favorites) {
    _service.playerStateStream.listen((_) => _broadcastState());
    _service.currentTrackIdStream.listen((_) => _broadcastState());
    _service.loopModeStream.listen((_) => _broadcastState());
    // Сердечко могли переключить и внутри самого приложения (не из
    // уведомления) — синхронизируем галочку в уведомлении и в этом
    // случае тоже, а не только сразу после нажатия на неё же.
    _favorites.addListener(_broadcastState);
    _broadcastState();
  }

  final AudioPlayerService _service;
  final FavoritesProvider _favorites;

  /// Устанавливается один раз из main.dart сразу после создания
  /// PlayerProvider (см. комментарий там). Стоп, пришедший из уведомления
  /// (свайп или системная кнопка), не проходит через PlayerProvider.stop()
  /// — без этой связи мини-плеер в приложении не узнал бы, что играть
  /// больше нечего, и продолжал бы показывать трек как ни в чём не бывало.
  void Function()? onNotificationInitiatedStop;

  /// Своя, отдельная от AudioPlayerService, защита от бесконечного эха:
  /// PlayerProvider._resetPlaybackState() в ответ на [onNotificationInitiatedStop]
  /// сам вызывает notificationHandler.stop() — без этого флага стоп гонял
  /// бы события туда-обратно между хендлером и провайдером по кругу.
  /// Снимается в [_broadcastState], как только снова появляется реально
  /// играющий трек.
  bool _stopAlreadyHandled = false;

  /// Тот же ключ SharedPreferences, что и в PlayerProvider.cycleLoopMode
  /// — так режим повтора, переключённый из уведомления, тоже переживает
  /// перезапуск приложения.
  static const _loopPrefsKey = 'loop_mode';

  Track? get _currentTrack {
    final id = _service.currentSourceTrackId;
    if (id == null) return null;
    for (final t in _service.queue) {
      if (t.id == id) return t;
    }
    return null;
  }

  MediaControl _favoriteControl(Track track) {
    final isFav = _favorites.isFavorite(track.id);
    return MediaControl.custom(
      androidIcon: isFav
          ? 'drawable/ic_notif_fav_filled'
          : 'drawable/ic_notif_fav_border',
      label: isFav ? 'Убрать из избранного' : 'В избранное',
      name: 'favorite',
    );
  }

  MediaControl _repeatControl() {
    final isOne = _service.loopMode == LoopMode.one;
    return MediaControl.custom(
      androidIcon:
          isOne ? 'drawable/ic_notif_repeat_one' : 'drawable/ic_notif_repeat',
      label: 'Повтор',
      name: 'repeat',
    );
  }

  void _broadcastState() {
    final track = _currentTrack;
    final playing = _service.isPlaying;

    // Что-то реально играет/загружено — снимаем защиту от эха в stop():
    // следующий настоящий стоп снова должен быть обработан, а не тихо
    // проигнорирован как "уже обработанный".
    if (track != null) _stopAlreadyHandled = false;

    if (track != null) {
      // track.artworkUrl у YouTube-треков — миниатюра 120×120 (см.
      // ArtworkUrl), её и на лок-скрине, и в развёрнутом уведомлении
      // растягивает и получается "мыльно". Тут же (и в
      // _HiResCover на экране "Сейчас играет") подменяем на крупную
      // версию тем же способом — для не-Google URL ArtworkUrl.highRes
      // возвращает исходную ссылку без изменений, так что для остальных
      // источников ничего не меняется.
      final artUrl = ArtworkUrl.highRes(track.artworkUrl);
      mediaItem.add(MediaItem(
        id: track.id,
        title: track.title,
        artist: track.artist,
        duration: track.duration,
        artUri: artUrl.isNotEmpty ? Uri.parse(artUrl) : null,
      ));
    }

    playbackState.add(PlaybackState(
      // Порядок = порядок в уведомлении. Компактный (свёрнутый) вид
      // показывает 3 кнопки — см. androidCompactActionIndices ниже.
      controls: track == null
          ? const []
          : [
              _favoriteControl(track),
              playing ? MediaControl.pause : MediaControl.play,
              MediaControl.skipToNext,
              _repeatControl(),
            ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: _mapProcessingState(_service.raw.processingState),
      playing: playing,
      updatePosition: _service.raw.position,
      bufferedPosition: _service.raw.bufferedPosition,
      speed: _service.raw.speed,
      queueIndex: _service.raw.currentIndex,
    ));
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  @override
  Future<void> play() => _service.play();

  @override
  Future<void> pause() => _service.pause();

  @override
  Future<void> skipToNext() => _service.next();

  @override
  Future<void> skipToPrevious() => _service.previous();

  @override
  Future<void> seek(Duration position) => _service.seek(position);

  /// Вызывается: (1) системой — BaseAudioHandler.onNotificationDeleted()
  /// по умолчанию вызывает именно stop() при свайпе уведомления; (2)
  /// явно из PlayerProvider._resetPlaybackState() при свайпе мини-плеера
  /// в самом приложении.
  ///
  /// ВАЖНО: раньше здесь ещё стоял mediaItem.add(null) — и уведомление
  /// вместо того чтобы закрыться, "подвисало" в обрезанном виде (заголовок
  /// остаётся, кнопки и прогресс пропадают). Механизм тот же, что в
  /// официальном примере Google UAMP (issue про "notification is stuck"):
  /// сборщик уведомления на Android, увидев mediaItem == null, молча
  /// пропускает пересборку и не трогает уведомление — а вот следующее за
  /// этим обновление playbackState (уже с пустыми controls) он собирает
  /// как обычно, подставляя туда ПОСЛЕДНИЙ валидный (ещё не null)
  /// mediaItem. В сумме — реальные название/артист остаются, а кнопки и
  /// прогресс обнуляются: ровно то самое "висит и всё". Раз система и так
  /// снимает уведомление сама, как только playbackState уходит в
  /// processingState.idle, отдельно обнулять mediaItem не нужно и вредно.
  @override
  Future<void> stop() async {
    // Защита от эха: PlayerProvider._resetPlaybackState() в ответ на
    // onNotificationInitiatedStop ниже сам вызывает notificationHandler
    // .stop() ещё раз — без этого флага стоп гонял бы события туда-обратно
    // по кругу между хендлером и провайдером.
    if (_stopAlreadyHandled) return;
    _stopAlreadyHandled = true;
    await _service.stop();
    playbackState.add(PlaybackState(
      controls: const [],
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
    // Свайп/системный стоп из уведомления не проходит через
    // PlayerProvider.stop() — сообщаем ему явно, иначе мини-плеер в
    // приложении не узнает, что играть больше нечего (см. main.dart,
    // где этот колбэк подключается сразу после создания PlayerProvider).
    onNotificationInitiatedStop?.call();
    await super.stop();
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    switch (name) {
      case 'favorite':
        final track = _currentTrack;
        // FavoritesProvider.toggle сам вызовет notifyListeners — этого
        // достаточно, чтобы _favorites.addListener(_broadcastState) выше
        // перерисовал галочку, отдельно её обновлять не нужно.
        if (track != null) _favorites.toggle(track);
        break;
      case 'repeat':
        final next = switch (_service.loopMode) {
          LoopMode.off => LoopMode.all,
          LoopMode.all => LoopMode.one,
          LoopMode.one => LoopMode.off,
        };
        await _service.setLoopMode(next);
        try {
          final p = await SharedPreferences.getInstance();
          await p.setInt(_loopPrefsKey, next.index);
        } catch (_) {
          // Не сохранилось — не критично, останется дефолтным при
          // следующем запуске, как и в PlayerProvider.cycleLoopMode.
        }
        break;
    }
  }
}
