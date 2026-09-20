import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_audio/just_audio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:palette_generator/palette_generator.dart';
import '../models/track.dart';
import '../providers/player_provider.dart';
import '../providers/now_playing_visibility.dart';
import '../navigation.dart';
import '../services/artwork_palette.dart';
import '../theme/app_theme.dart';
import '../screens/now_playing_screen.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer>
    with SingleTickerProviderStateMixin {
  // Свайп в сторону, чтобы выключить трек — реализован вручную через
  // GestureDetector, а не через встроенный Dismissible: тот конфликтует
  // с вложенным GestureDetector(onTap: openNowPlaying) внутри общего
  // Stack-оверлея мини-плеера (см. MaterialApp.builder в main.dart) и
  // жест до него просто не доходит. Тот же приём (ручной drag +
  // AnimationController для доводки/возврата), что уже рабочий для
  // вертикального свайпа в now_playing_screen.dart.
  late final AnimationController _dragController;

  // Смещение свайпа живёт в ValueNotifier, а НЕ в поле + setState.
  // Раньше каждое движение пальца вызывало setState и перестраивало
  // всю карточку целиком — вместе с BackdropFilter, CachedNetworkImage
  // и пересчётом градиента, до 60 раз в секунду. Теперь на изменение
  // подписан только внешний Transform/Opacity, а сама карточка
  // передаётся в него готовым child и не пересобирается вовсе.
  final ValueNotifier<double> _dragX = ValueNotifier<double>(0);
  String? _lastTrackId;

  // Палитра текущей обложки для градиента фона карточки — см.
  // _ensurePalette ниже и services/artwork_palette.dart.
  PaletteGenerator? _palette;
  String? _paletteTrackId;
  // Готовые цвета градиента: пересчитываются только при смене палитры,
  // а не на каждый ребилд.
  List<Color>? _gradientCache;

  @override
  void initState() {
    super.initState();
    _dragController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
  }

  @override
  void dispose() {
    _dragController.dispose();
    _dragX.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    _dragX.value += details.delta.dx;
  }

  void _onDragEnd(DragEndDetails details, double width, PlayerProvider player) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldDismiss =
        _dragX.value.abs() > width * 0.3 || velocity.abs() > 700;
    if (shouldDismiss) {
      final direction = _dragX.value < 0 ? -1.0 : 1.0;
      _animateTo(direction * width * 1.2, thenStop: player);
    } else {
      _animateTo(0);
    }
  }

  void _animateTo(double target, {PlayerProvider? thenStop}) {
    final animation = Tween<double>(begin: _dragX.value, end: target).animate(
      CurvedAnimation(
        parent: _dragController,
        curve: thenStop != null ? Curves.easeIn : Curves.easeOutCubic,
      ),
    );
    void listener() => _dragX.value = animation.value;
    animation.addListener(listener);
    _dragController
      ..value = 0
      ..forward().whenComplete(() {
        animation.removeListener(listener);
        // ВАЖНО: при закрытии свайпом карточка НЕ возвращается в центр
        // здесь. player.stop() — это `Future<void>` (сначала
        // останавливается сам плеер, и только потом currentTrack
        // становится null), так что между концом этой анимации и
        // реальным исчезновением мини-плеера (когда track == null и
        // build() вернёт SizedBox.shrink()) проходит заметный async-зазор.
        // Раньше здесь стояло `_dragX.value = 0`, и ровно в этот зазор
        // карточка на кадр-другой прыгала обратно в центр экрана, а уже
        // потом исчезала — то самое дёрганье "туда-обратно". Карточка
        // просто остаётся за краем экрана (там, куда её докрутил target)
        // до тех пор, пока трек не исчезнет целиком; сброс в 0 для
        // СЛЕДУЮЩЕГО трека и так делается отдельно — при обнаружении
        // смены _lastTrackId в build() (см. ниже).
        if (thenStop != null) {
          thenStop.stop();
        }
      });
  }

  /// Подхватывает палитру под новый трек: сперва то, что уже в кэше (без
  /// ожидания — не мигаем нейтральным фоном, если обложка уже была
  /// разобрана раньше в этой сессии), затем догружает и просит перерисовку.
  void _ensurePalette(String trackId, String artworkUrl) {
    if (_paletteTrackId == trackId) return;
    _paletteTrackId = trackId;
    _palette = ArtworkPalette.cached(trackId);
    _gradientCache = null;
    ArtworkPalette.load(trackId, artworkUrl).then((palette) {
      if (!mounted || _paletteTrackId != trackId) return;
      if (identical(palette, _palette)) return;
      setState(() {
        _palette = palette;
        _gradientCache = null;
      });
    });
  }

  /// Пара цветов для градиента фона карточки: яркий акцент обложки сверху
  /// и затемнённый снизу. Оба цвета намеренно затемняем к чёрному —
  /// сырые цвета из палитры (особенно vibrant) сами по себе слишком
  /// светлые/насыщенные, чтобы поверх них разборчиво читался белый текст
  /// названия трека.
  List<Color> _gradientColors() {
    final cached = _gradientCache;
    if (cached != null) return cached;
    return _gradientCache = _computeGradientColors();
  }

  List<Color> _computeGradientColors() {
    final palette = _palette;
    final fallback = AppColors.surfaceElevated.withOpacity(0.78);
    if (palette == null) return [fallback, fallback];

    final primary = palette.vibrantColor?.color ??
        palette.lightVibrantColor?.color ??
        palette.dominantColor?.color ??
        palette.mutedColor?.color;
    if (primary == null) return [fallback, fallback];
    final secondary = palette.darkVibrantColor?.color ??
        palette.darkMutedColor?.color ??
        palette.mutedColor?.color ??
        primary;

    Color darken(Color c, double amount) => Color.lerp(c, Colors.black, amount)!;
    return [
      darken(primary, 0.35).withOpacity(0.82),
      darken(secondary, 0.6).withOpacity(0.82),
    ];
  }

  @override
  Widget build(BuildContext context) {
    // ВАЖНО для плавности: MiniPlayer — это глобальный оверлей, висящий
    // поверх ВСЕГО приложения почти всё время работы (см. main.dart), и
    // внутри у него дорогой BackdropFilter-блюр + AnimatedContainer.
    // PlayerProvider дёргает notifyListeners() на каждый тик позиции
    // воспроизведения (несколько раз в секунду), а MiniPlayer позицию
    // вообще нигде не показывает — раньше context.watch() всё равно
    // перестраивал весь виджет на каждый такой тик. select подписывает
    // нас только на реально используемые поля, так что позиция больше
    // не вызывает ни одной лишней перерисовки блюра.
    final player = context.read<PlayerProvider>();
    final track = context.select<PlayerProvider, Track?>((p) => p.currentTrack);
    if (track == null) {
      // ВАЖНО (баг "смахнул трек, включил его же заново — играет, а
      // мини-плеера не видно"): раньше здесь просто возвращался
      // SizedBox.shrink(), а _lastTrackId ниже не трогался. При
      // повторном запуске ТОГО ЖЕ трека track.id совпадал со старым
      // _lastTrackId, блок сброса _dragX (см. ниже) считал, что трек не
      // менялся, и не сбрасывал координату свайпа — карточка так и
      // оставалась утащенной за край экрана с нулевой прозрачностью.
      // Для любого ДРУГОГО трека бага не было: id отличался, и сброс
      // срабатывал как обычно. Обнуляя _lastTrackId здесь, делаем так,
      // чтобы следующее появление плеера — с любым треком, включая тот
      // же самый — всегда проходило по ветке "трек сменился" и сбрасывало
      // хвост свайпа.
      _lastTrackId = null;
      return const SizedBox.shrink();
    }
    final isPlaying = context.select<PlayerProvider, bool>((p) => p.isPlaying);
    final loopMode = context.select<PlayerProvider, LoopMode>((p) => p.loopMode);

    // Если заиграл другой трек, пока в поле _dragX ещё лежит "хвост" от
    // предыдущего свайпа (например, свайп чуть-чуть сдвинул карточку, но
    // не докрутился до отмены) — сбрасываем без анимации, иначе новая
    // карточка появится смещённой.
    if (_lastTrackId != track.id) {
      _lastTrackId = track.id;
      if (_dragX.value != 0) {
        // Сброс откладываем до конца кадра: изменение ValueNotifier
        // прямо во время build() заставило бы подписанный на него
        // ValueListenableBuilder перестроиться в середине построения
        // дерева (то самое "markNeedsBuild called during build").
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _dragX.value = 0;
        });
      }
    }
    _ensurePalette(track.id, track.artworkUrl);

    void openNowPlaying() => rootNavigatorKey.currentState!.push(
          PageRouteBuilder(
            // Имя роута — единственный сигнал для NowPlayingRouteObserver
            // (см. providers/now_playing_visibility.dart), по которому
            // глобальный мини-плеер понимает, что нужно спрятаться.
            settings: const RouteSettings(
              name: NowPlayingRouteObserver.routeName,
            ),
            pageBuilder: (_, __, ___) => const NowPlayingScreen(),
            transitionDuration: const Duration(milliseconds: 160),
            reverseTransitionDuration: const Duration(milliseconds: 140),
            transitionsBuilder: (_, animation, __, child) {
              // Блюр просто появляется (fade), без "выезда" снизу — так
              // BackdropFilter не двигается по экрану во время анимации
              // (дороже по фреймтайму), а переход ощущается мгновенным.
              return FadeTransition(
                opacity: CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOut,
                  reverseCurve: Curves.easeIn,
                ),
                child: child,
              );
            },
          ),
        );

    final card = ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
          height: AppLayout.miniPlayerHeight,
          margin: EdgeInsets.symmetric(horizontal: 10),
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _gradientColors(),
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
          ),
          child: Row(
            children: [
              // Тап открывает полноэкранный плеер только в зоне обложки и
              // текста — кнопки ниже НЕ обёрнуты в этот жест, иначе они
              // конкурируют с ним за один и тот же тап и перестают
              // реагировать на нажатия (классический баг вложенных
              // GestureDetector'ов во Flutter).
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: openNowPlaying,
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedNetworkImage(
                          imageUrl: track.artworkUrl,
                          width: 42,
                          height: 42,
                          fit: BoxFit.cover,
                          // Обложки с источников обычно приходят в разы
                          // крупнее, чем нужно для 42×42 плитки — без этого
                          // GPU/CPU каждый раз декодирует и держит в памяти
                          // полноразмерный битмап ради маленькой иконки.
                          memCacheWidth: 84,
                          memCacheHeight: 84,
                          errorWidget: (_, __, ___) => Container(
                            width: 42,
                            height: 42,
                            color: AppColors.surface,
                          ),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        // ExcludeSemantics + отключённое выделение: строка
                        // текущего трека — единственное место, где текст
                        // МЕНЯЕТСЯ сам по себе (при смене трека) без ввода
                        // пользователя. Именно это отличает мини-плеер от
                        // всего остального текста в приложении и делает
                        // его целью системных функций Android, которые
                        // сканируют экран и подсвечивают распознанный текст
                        // (сущности вроде названия трека) — цветным
                        // подчёркиванием, независимо от клавиатуры.
                        // Убираем его из семантического дерева и из
                        // выделяемого текста, чтобы такие сканеры вообще
                        // не видели этот Text как кандидата.
                        child: ExcludeSemantics(
                          child: SelectionContainer.disabled(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  track.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: AppColors.textPrimary,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                      decoration: TextDecoration.none),
                                ),
                                Text(
                                  track.artist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                      decoration: TextDecoration.none),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                constraints: BoxConstraints(),
                icon: Icon(
                  loopMode == LoopMode.one
                      ? Icons.repeat_one_rounded
                      : Icons.repeat_rounded,
                  size: 18,
                  color: loopMode == LoopMode.off
                      ? AppColors.textSecondary
                      : AppColors.accentEnd,
                ),
                onPressed: player.cycleLoopMode,
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: Icon(
                  isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 28,
                ),
                onPressed: player.togglePlayPause,
              ),
              IconButton(
                icon: const Icon(Icons.skip_next_rounded, size: 26),
                onPressed: player.next,
              ),
            ],
          ),
        ),
      ),
    );

    // MediaQuery вместо LayoutBuilder: мини-плеер и так растянут на всю
    // ширину экрана (Positioned left/right: 0), а LayoutBuilder — это
    // лишняя граница перелэйаута на каждом кадре свайпа.
    final width = MediaQuery.sizeOf(context).width;

    return GestureDetector(
      onHorizontalDragUpdate: _onDragUpdate,
      onHorizontalDragEnd: (details) => _onDragEnd(details, width, player),
      child: ValueListenableBuilder<double>(
        valueListenable: _dragX,
        // Карточка передаётся как child: при свайпе перестраивается
        // только обёртка из Transform/Opacity, а не её содержимое.
        child: card,
        builder: (context, dragX, child) {
          if (dragX == 0) return child!;
          // Прогресс свайпа 0..1 — на нём затухает прозрачность карточки,
          // чтобы она визуально "улетала", а не просто уезжала за край.
          final progress = width == 0
              ? 0.0
              : (dragX.abs() / (width * 0.7)).clamp(0.0, 1.0);
          return Transform.translate(
            offset: Offset(dragX, 0),
            child: Opacity(opacity: 1 - progress, child: child),
          );
        },
      ),
    );
  }
}
