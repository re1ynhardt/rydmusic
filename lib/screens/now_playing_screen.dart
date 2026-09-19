import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/language_provider.dart';
import '../models/track.dart';
import '../services/artwork_url.dart';
import '../theme/app_theme.dart';
import '../widgets/lyrics_view.dart';
import '../widgets/queue_sheet.dart';
import 'artist_screen.dart';

/// Экран Now Playing всегда рисуется поверх тёмной размытой обложки —
/// его текст и иконки НЕ должны зависеть от переключаемой темы
/// приложения (см. AppColors): фон здесь всегда тёмный, поэтому цвет
/// текста тоже всегда светлый, иначе он сливается с фоном в белой теме.
class _PlayerText {
  _PlayerText._();
  static const primary = Colors.white;
  static const secondary = Colors.white70;
  static const tertiary = Colors.white54;
}

/// Большая обложка на экране "Сейчас играет".
///
/// У YouTube-треков в Track.artworkUrl лежит миниатюра 120×120 (её отдаёт
/// ytmusicapi, и для списков/мини-плеера этого хватает), а здесь она
/// растягивается на всю ширину экрана и выглядит размытой. Поэтому для
/// YouTube запрашиваем крупную версию (см. [ArtworkUrl.highRes]).
/// Пока она грузится, показываем уже закэшированную маленькую — тем же
/// URL, что был в мини-плеере/списке, так что пустого места нет. Если
/// крупная не загрузилась — остаёмся на маленькой, как было раньше.
class _HiResCover extends StatelessWidget {
  const _HiResCover({required this.track});

  final Track track;

  // Потолок декода в пикселях по ширине: ~ширина экрана телефона.
  // Источники часто отдают обложки крупнее, чем помещается на экран.
  static const _decodeWidth = 1080;

  @override
  Widget build(BuildContext context) {
    final original = track.artworkUrl;
    final hiRes = track.source == MusicSourceType.youtube
        ? ArtworkUrl.highRes(original)
        : original;

    Widget stub() => Container(
          color: const Color(0xFF1A1A1E),
          child: Icon(Icons.music_note_rounded,
              size: 64, color: _PlayerText.tertiary),
        );

    Widget image(String url,
            {PlaceholderWidgetBuilder? placeholder,
            LoadingErrorWidgetBuilder? errorWidget}) =>
        CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          width: double.infinity,
          memCacheWidth: _decodeWidth,
          fadeInDuration: const Duration(milliseconds: 200),
          placeholder: placeholder,
          errorWidget: errorWidget ?? (_, __, ___) => stub(),
        );

    if (hiRes == original) return image(original);

    Widget lowRes() => image(original);
    return image(
      hiRes,
      placeholder: (_, __) => lowRes(),
      errorWidget: (_, __, ___) => lowRes(),
    );
  }
}

class NowPlayingScreen extends StatefulWidget {
  const NowPlayingScreen({super.key});

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen>
    with SingleTickerProviderStateMixin {
  // Драг-жест "потянуть вниз, чтобы закрыть" — вместо тапа по ручке.
  late final AnimationController _dragController;

  // Смещение "потянуть вниз, чтобы закрыть" — в ValueNotifier, а не в
  // поле + setState. Раньше каждый кадр жеста перестраивал ВЕСЬ экран:
  // два BackdropFilter'а с sigma=70, Hero-обложку, все кнопки,
  // StreamBuilder громкости. Теперь на смещение подписаны только
  // затемнение фона и внешний Transform, а содержимое экрана
  // передаётся внутрь готовым child.
  final ValueNotifier<double> _dragExtent = ValueNotifier<double>(0);
  bool _showLyrics = false;

  @override
  void initState() {
    super.initState();
    _dragController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
  }

  @override
  void dispose() {
    _dragController.dispose();
    _dragExtent.dispose();
    super.dispose();
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _dragController.stop();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    // Тянуть можно только вниз (отрицательную дельту тоже принимаем,
    // чтобы можно было "довести" карточку назад пальцем без рывка).
    _dragExtent.value =
        (_dragExtent.value + details.primaryDelta!).clamp(0.0, double.infinity);
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final screenHeight = MediaQuery.sizeOf(context).height;
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss =
        _dragExtent.value > screenHeight * 0.22 || velocity > 800;
    if (shouldDismiss) {
      _animateTo(screenHeight * 1.1, thenPop: true);
    } else {
      _animateTo(0);
    }
  }

  void _animateTo(double target, {bool thenPop = false}) {
    final animation =
        Tween<double>(begin: _dragExtent.value, end: target).animate(
      CurvedAnimation(
        parent: _dragController,
        curve: thenPop ? Curves.easeIn : Curves.easeOutCubic,
      ),
    );
    void listener() => _dragExtent.value = animation.value;
    animation.addListener(listener);
    _dragController
      ..value = 0
      ..forward().whenComplete(() {
        animation.removeListener(listener);
        if (thenPop && mounted) Navigator.of(context).pop();
      });
  }

  /// 0..1 — насколько экран уже утянут вниз.
  double _closeProgress(double drag, double screenHeight) =>
      (drag / (screenHeight * 0.6)).clamp(0.0, 1.0);

  static String _fmt(Duration d) {
    final neg = d.isNegative;
    final abs = neg ? -d : d;
    final m = abs.inMinutes.remainder(60).toString();
    final s = abs.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '${neg ? '-' : ''}$m:$s';
  }

  static String _sourceLabel(MusicSourceType t) => switch (t) {
        MusicSourceType.soundcloud => 'SoundCloud',
        MusicSourceType.audiomack => 'Audiomack',
        MusicSourceType.deezer => 'Deezer',
        MusicSourceType.youtube => 'YouTube',
        MusicSourceType.vk => 'VK',
        MusicSourceType.local => AppStrings.current.sourceLocal,
      };

  /// Копирует "Артист — Название" в буфер обмена и показывает
  /// подтверждение снек-баром — как и остальные всплывающие сообщения
  /// на этом экране (см. _showTrackMenu выше).
  Future<void> _copyTrackInfo(BuildContext context, Track track) async {
    await Clipboard.setData(
      ClipboardData(text: '${track.artist} — ${track.title}'),
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
          SnackBar(content: Text(AppStrings.current.copiedToClipboard)));
  }

  void _showTrackMenu(BuildContext context, Track track) {
    final fav = context.read<FavoritesProvider>();
    final l10n = AppStrings.current;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => ClipRRect(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
          child: Container(
            color: AppColors.surfaceElevated.withOpacity(0.92),
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  ListTile(
                    leading: AnimatedBuilder(
                      animation: fav,
                      builder: (_, __) => Icon(
                        fav.isFavorite(track.id)
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    title: Text(fav.isFavorite(track.id)
                        ? l10n.removeFromFavorites
                        : l10n.addToFavorites),
                    onTap: () {
                      fav.toggle(track);
                      Navigator.of(sheetContext).pop();
                    },
                  ),
                  ListTile(
                    leading:
                        Icon(Icons.info_outline_rounded, color: AppColors.textPrimary),
                    title: Text(l10n.sourceLabel(_sourceLabel(track.source))),
                    onTap: () => Navigator.of(sheetContext).pop(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Есть ли у источника этого трека вообще страница исполнителя — от
  /// этого зависит, стоит ли показывать подсказку про свайп. Дешёвая
  /// проверка (просто чтение из уже готовой карты источников), можно
  /// звать прямо в build().
  bool _supportsArtist(Track track) {
    final source = context.read<PlayerProvider>().sourceOf(track.source);
    return source?.supportsArtistPage ?? false;
  }

  /// Открывает страницу исполнителя, если источник трека её поддерживает.
  void _openArtist(Track track) {
    final source = context.read<PlayerProvider>().sourceOf(track.source);
    if (source == null || !source.supportsArtistPage) return;
    // Пользователь только что сам воспользовался переходом на исполнителя —
    // жест уже освоен, дальше повторять подсказку незачем (см.
    // _ArtistSwipeHint.markDiscovered).
    unawaited(_ArtistSwipeHint.markDiscovered());
    Navigator.of(context).push(CupertinoPageRoute<void>(
      builder: (_) => ArtistScreen(track: track, source: source),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // ВАЖНО для плавности: PlayerProvider уведомляет слушателей на каждый
    // тик позиции воспроизведения (несколько раз в секунду). Раньше
    // context.watch() здесь перестраивал ВЕСЬ экран на каждый такой тик —
    // включая два дорогих BackdropFilter-блюра (sigma 70!) и Hero-обложку.
    // player нужен и для методов (seek/next/...), и для полей, которые
    // реально меняются редко — читаем его без подписки (read), а те поля,
    // что должны реактивно обновлять именно эту часть экрана, подписываем
    // точечно через select. Сама позиция вынесена в отдельный виджет
    // _ProgressSection ниже, чтобы её тики не трогали всё остальное.
    final player = context.read<PlayerProvider>();
    final track = context.select<PlayerProvider, Track?>((p) => p.currentTrack);

    if (track == null) {
      return Scaffold(body: Center(child: Text(l10n.nothingPlaying)));
    }

    final isPlaying = context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final loopMode = context.select<PlayerProvider, LoopMode>((p) => p.loopMode);
    final isFav = context.select<FavoritesProvider, bool>(
      (f) => f.isFavorite(track.id),
    );
    final favorites = context.read<FavoritesProvider>();
    final screenHeight = MediaQuery.sizeOf(context).height;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Размытая обложка фоном — фирменный приём Apple Music.
          RepaintBoundary(
            child: CachedNetworkImage(
              imageUrl: track.artworkUrl,
              fit: BoxFit.cover,
              fadeInDuration: Duration(milliseconds: 200),
              // Картинка тут же размывается sigma=70 — детали всё равно
              // теряются, поэтому нет смысла декодировать и держать в
              // памяти полноразмерную обложку ради фонового блюра.
              memCacheWidth: 200,
              errorWidget: (_, __, ___) => Container(color: const Color(0xFF0A0A0C)),
            ),
          ),
          BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 70, sigmaY: 70),
            // Затемнение чуть слабеет по мере утягивания экрана вниз.
            // Перестраивается только этот ColoredBox, а не блюр над ним.
            child: ValueListenableBuilder<double>(
              valueListenable: _dragExtent,
              builder: (context, drag, _) => ColoredBox(
                color: Colors.black.withOpacity(
                    0.62 * (1 - _closeProgress(drag, screenHeight) * 0.5)),
                child: const SizedBox.expand(),
              ),
            ),
          ),
          // Весь контент двигается пальцем вниз и уходит с экрана —
          // тап по ручке больше ничего не делает, закрытие только свайпом.
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: _onVerticalDragStart,
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onVerticalDragEnd: _onVerticalDragEnd,
            child: ValueListenableBuilder<double>(
              valueListenable: _dragExtent,
              builder: (context, drag, child) {
                if (drag == 0) return child!;
                final closeProgress = _closeProgress(drag, screenHeight);
                return Transform.translate(
                  offset: Offset(0, drag),
                  child: Transform.scale(
                    scale: 1 - closeProgress * 0.06,
                    alignment: Alignment.topCenter,
                    child: child,
                  ),
                );
              },
              child: SafeArea(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    SizedBox(height: 4),
                    // Ручка-индикатор — чисто визуальная, тап по ней не закрывает экран.
                    Center(
                      child: Container(
                        width: 36,
                        height: 5,
                        margin: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.35),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    SizedBox(height: 6),
                  Expanded(
                    // Свайп влево — страница исполнителя.
                    child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragEnd: (d) {
                      if ((d.primaryVelocity ?? 0) < -300) _openArtist(track);
                    },
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: _showLyrics
                          ? RepaintBoundary(
                              key: ValueKey('lyr_${track.id}'),
                              child: LyricsView(track: track, player: player),
                            )
                          : Hero(
                      key: const ValueKey('art'),
                      tag: 'artwork_${track.id}',
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.45),
                              blurRadius: 40,
                              offset: const Offset(0, 20),
                            ),
                          ],
                        ),
                        child: Stack(
                          fit: StackFit.passthrough,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: _HiResCover(track: track),
                            ),
                            // Подсказка про свайп к исполнителю: рисуется
                            // только если у источника трека вообще есть
                            // страница исполнителя, и лишь до первого
                            // раза, когда пользователь её увидел — сама
                            // проверяет и запоминает это через
                            // SharedPreferences (см. _ArtistSwipeHint).
                            if (_supportsArtist(track))
                              const Positioned(
                                left: 0,
                                right: 0,
                                bottom: 14,
                                child: _ArtistSwipeHint(),
                              ),
                          ],
                        ),
                      ),
                    ),
                    ),
                    ),
                  ),
                  SizedBox(height: 26),
                  // Заголовок + избранное + меню — в один ряд, как в Apple Music.
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w800,
                                  height: 1.25,
                                  color: _PlayerText.primary),
                            ),
                            SizedBox(height: 2),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _openArtist(track),
                              child: Text(
                                track.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 15,
                                    color: _PlayerText.secondary),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: 8),
                      IconButton(
                        splashRadius: 22,
                        icon: Icon(
                          isFav ? Icons.star_rounded : Icons.star_border_rounded,
                          color: isFav ? Colors.amber : _PlayerText.primary,
                          size: 24,
                        ),
                        onPressed: () => favorites.toggle(track),
                      ),
                      IconButton(
                        splashRadius: 22,
                        icon: const Icon(Icons.more_horiz_rounded,
                            color: Colors.white, size: 24),
                        onPressed: () => _showTrackMenu(context, track),
                      ),
                    ],
                  ),
                  SizedBox(height: 10),
                  // Вынесено в отдельный виджет и обёрнуто в RepaintBoundary:
                  // это единственная часть экрана, которой ДЕЙСТВИТЕЛЬНО
                  // нужно перерисовываться на каждый тик позиции — слайдер
                  // и таймкоды. Изолируя её, мы не перестраиваем и не
                  // перерисовываем background-блюр, Hero-обложку и кнопки
                  // управления несколько раз в секунду.
                  RepaintBoundary(
                    child: _ProgressSection(player: player, track: track),
                  ),
                  SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        splashRadius: 24,
                        icon: Icon(
                          loopMode == LoopMode.one
                              ? Icons.repeat_one_rounded
                              : Icons.repeat_rounded,
                          size: 24,
                          color: loopMode == LoopMode.off
                              ? _PlayerText.secondary
                              : Colors.greenAccent,
                        ),
                        onPressed: player.cycleLoopMode,
                      ),
                      IconButton(
                        splashRadius: 30,
                        icon: const Icon(Icons.skip_previous_rounded,
                            size: 42, color: Colors.white),
                        onPressed: player.previous,
                      ),
                      Semantics(
                        button: true,
                        label: isPlaying ? l10n.pause : l10n.play,
                        child: GestureDetector(
                          onTap: player.togglePlayPause,
                          child: Container(
                            width: 74,
                            height: 74,
                            alignment: Alignment.center,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                            ),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 150),
                              child: Icon(
                                isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                key: ValueKey(isPlaying),
                                color: Colors.black,
                                size: 36,
                              ),
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        splashRadius: 30,
                        icon: const Icon(Icons.skip_next_rounded,
                            size: 42, color: Colors.white),
                        onPressed: player.next,
                      ),
                      const SizedBox(
                        width: 40,
                        child: SizedBox.shrink(),
                      ),
                    ],
                  ),
                  SizedBox(height: 30),
                  // Громкость.
                  Row(
                    children: [
                      Icon(Icons.volume_down_rounded,
                          size: 18, color: _PlayerText.secondary),
                      Expanded(
                        child: StreamBuilder<double>(
                          stream: player.service.volumeStream,
                          initialData: player.service.volume,
                          builder: (context, snap) {
                            final v = (snap.data ?? 1.0).clamp(0.0, 1.0);
                            return SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 3,
                                overlayShape: SliderComponentShape.noOverlay,
                                thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 5),
                                activeTrackColor: Colors.white70,
                                inactiveTrackColor: Colors.white.withOpacity(0.2),
                                thumbColor: Colors.white70,
                              ),
                              child: Slider(
                                min: 0,
                                max: 1,
                                value: v,
                                onChanged: (nv) => player.service.setVolume(nv),
                              ),
                            );
                          },
                        ),
                      ),
                      Icon(Icons.volume_up_rounded,
                          size: 18, color: _PlayerText.secondary),
                    ],
                  ),
                  SizedBox(height: 18),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        splashRadius: 22,
                        icon: Icon(
                            _showLyrics
                                ? Icons.chat_bubble_rounded
                                : Icons.chat_bubble_outline_rounded,
                            size: 22,
                            color: _showLyrics
                                ? Colors.white
                                : _PlayerText.secondary),
                        onPressed: () =>
                            setState(() => _showLyrics = !_showLyrics),
                      ),
                      IconButton(
                        splashRadius: 22,
                        icon: Icon(Icons.copy_rounded,
                            size: 22, color: _PlayerText.secondary),
                        onPressed: () => _copyTrackInfo(context, track),
                      ),
                      IconButton(
                        splashRadius: 22,
                        icon: Icon(Icons.queue_music_rounded,
                            size: 22, color: _PlayerText.secondary),
                        onPressed: () => showQueueSheet(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Изолированная часть Now Playing: слайдер прогресса и таймкоды —
/// единственное, что реально должно перестраиваться на каждый тик
/// позиции воспроизведения. Вынесена в отдельный виджет и обёрнута в
/// RepaintBoundary в build() выше, чтобы фон-блюр, Hero-обложка и кнопки
/// управления не пересобирались и не перерисовывались вместе с ней
/// несколько раз в секунду.
class _ProgressSection extends StatefulWidget {
  const _ProgressSection({required this.player, required this.track});

  final PlayerProvider player;
  final Track track;

  @override
  State<_ProgressSection> createState() => _ProgressSectionState();
}

class _ProgressSectionState extends State<_ProgressSection> {
  /// Позиция, которую пользователь сейчас выбирает пальцем (мс).
  ///
  /// Раньше слайдер брал значение напрямую из позиции плеера, а на
  /// каждое движение пальца слал seek(). Это плохо с обеих сторон:
  /// seek'ов уходили десятки в секунду (каждый — реальная операция
  /// нативного плеера, вплоть до перезапроса куска потока по сети), а
  /// ползунок при этом ехал рывками, потому что ждал ответа плеера.
  /// Теперь во время перетаскивания ползунок ведётся локальным
  /// состоянием, а seek уходит ОДИН раз — когда палец отпущен.
  double? _dragMs;

  @override
  Widget build(BuildContext context) {
    // Позиция приходит из отдельного ValueNotifier, а не через
    // notifyListeners() провайдера (см. PlayerProvider): тики
    // воспроизведения теперь перестраивают ровно этот кусок экрана и
    // больше ничего во всём приложении.
    return StreamBuilder<Duration?>(
      stream: widget.player.service.durationStream,
      builder: (context, durationSnap) {
        final total = durationSnap.data ?? widget.track.duration;
        final maxMs = total.inMilliseconds.toDouble().clamp(1, double.infinity);
        return ValueListenableBuilder<Duration>(
          valueListenable: widget.player.positionListenable,
          builder: (context, pos, _) {
            final clampedPos = pos > total ? total : pos;
            final shownMs = _dragMs ??
                clampedPos.inMilliseconds.toDouble().clamp(0, maxMs);
            final shown = Duration(milliseconds: shownMs.toInt());
            final remaining = shown - total;
            return Column(
              children: [
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    overlayShape: SliderComponentShape.noOverlay,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white.withOpacity(0.24),
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    min: 0,
                    max: maxMs.toDouble(),
                    value: shownMs.toDouble(),
                    onChangeStart: (v) => setState(() => _dragMs = v),
                    onChanged: (v) => setState(() => _dragMs = v),
                    onChangeEnd: (v) {
                      setState(() => _dragMs = null);
                      widget.player.seek(Duration(milliseconds: v.toInt()));
                    },
                  ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(_NowPlayingScreenState._fmt(shown),
                        style: const TextStyle(
                            fontSize: 12, color: _PlayerText.secondary)),
                    const Spacer(),
                    // Бейдж источника — просто подпись, без иконки.
                    Text(
                      _NowPlayingScreenState._sourceLabel(widget.track.source),
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2,
                          color: _PlayerText.secondary),
                    ),
                    const Spacer(),
                    Text(_NowPlayingScreenState._fmt(remaining),
                        style: const TextStyle(
                            fontSize: 12, color: _PlayerText.secondary)),
                  ],
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Плавающая пилюля-подсказка «Смахните к исполнителю» поверх обложки.
///
/// Показывается не один раз навсегда, а ПЕРИОДИЧЕСКИ — не чаще, чем раз
/// в [_cooldown]: если с прошлого показа прошло меньше этого срока,
/// подсказка молчит, если больше — появляется снова. Это подсказка про
/// малозаметный жест, а не разовая онбординг-плашка: часть пользователей
/// вполне могла забыть про неё за недели использования приложения.
/// Исключение — как только пользователь реально свайпнул на страницу
/// исполнителя хоть раз, напоминать уже незачем: это отмечается отдельным
/// постоянным флагом (см. [markDiscovered]) и подсказка перестаёт
/// появляться совсем.
///
/// Про плавность: анимация — не бесконечный луп, а один цикл
/// (проявиться → мягко покачнуться пару раз → уйти) на одном
/// AnimationController, который создаётся только пока подсказка видна и
/// сразу же уничтожается насовсем (виджет схлопывается в
/// SizedBox.shrink) — то есть лишней работы на кадр после первых
/// ~2.5 секунд жизни экрана он не создаёт.
class _ArtistSwipeHint extends StatefulWidget {
  const _ArtistSwipeHint();

  static const _lastShownKey = 'now_playing_artist_hint_last_shown_ms';
  static const _discoveredKey = 'now_playing_artist_hint_discovered';

  /// Раз в сколько подсказка имеет право появиться снова.
  static const _cooldown = Duration(days: 3);

  /// Вызывается из [_openArtist] при успешном свайпе/тапе на исполнителя —
  /// после этого пользователь жест уже освоил, и подсказка больше не
  /// нужна ни разу, независимо от cooldown'а.
  static Future<void> markDiscovered() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_discoveredKey, true);
  }

  @override
  State<_ArtistSwipeHint> createState() => _ArtistSwipeHintState();
}

class _ArtistSwipeHintState extends State<_ArtistSwipeHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _dx;

  // null — ещё не знаем, показывать ли подсказку (идёт чтение
  // SharedPreferences); false — точно не показываем; true — показываем.
  bool? _shouldShow;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
    _opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: 1), weight: 12),
      TweenSequenceItem(tween: ConstantTween(1), weight: 66),
      TweenSequenceItem(tween: Tween(begin: 1, end: 0), weight: 22),
    ]).animate(_controller);
    // Лёгкое покачивание влево-вправо — намёк на направление жеста,
    // а не декоративная анимация ради анимации.
    _dx = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -6), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -6, end: 2), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 2, end: -6), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -6, end: 0), weight: 1),
    ]).animate(CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.12, 0.78, curve: Curves.easeInOut),
    ));
    _checkAndMaybeShow();
  }

  Future<void> _checkAndMaybeShow() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;

    if (prefs.getBool(_ArtistSwipeHint._discoveredKey) ?? false) {
      setState(() => _shouldShow = false);
      return;
    }

    final lastShownMs = prefs.getInt(_ArtistSwipeHint._lastShownKey) ?? 0;
    final elapsed = DateTime.now().millisecondsSinceEpoch - lastShownMs;
    if (elapsed < _ArtistSwipeHint._cooldown.inMilliseconds) {
      setState(() => _shouldShow = false);
      return;
    }

    setState(() => _shouldShow = true);
    // Запоминаем момент показа сразу, а не по завершении анимации: если
    // пользователь свайпнёт раньше, чем она доиграет, следующий отсчёт
    // cooldown'а всё равно должен идти от этого показа, а не начинаться
    // заново при случайном повторном открытии экрана через секунду.
    unawaited(prefs.setInt(
      _ArtistSwipeHint._lastShownKey,
      DateTime.now().millisecondsSinceEpoch,
    ));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_shouldShow != true) return const SizedBox.shrink();

    return IgnorePointer(
      // Подсказка не должна перехватывать сам жест свайпа — он обрабатывается
      // GestureDetector'ом выше по дереву, на всей области обложки.
      child: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) => Opacity(
            opacity: _opacity.value,
            child: Transform.translate(
              offset: Offset(_dx.value, 0),
              child: child,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.55),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.swipe_left_alt_rounded,
                      size: 17, color: Colors.white),
                  const SizedBox(width: 7),
                  Text(
                    context.l10n.swipeForArtistHint,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
