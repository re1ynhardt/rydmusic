import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/track.dart';
import '../providers/cached_tracks_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/language_provider.dart';
import '../theme/app_theme.dart';

class TrackTile extends StatelessWidget {
  const TrackTile({
    super.key,
    required this.track,
    required this.onTap,
    this.isActive = false,
    this.showFavoriteButton = true,
    this.showCacheButton = true,
    this.onAddToPlaylist,
  });

  final Track track;
  final VoidCallback onTap;
  final bool isActive;

  /// Позволяет спрятать кнопку избранного там, где она не нужна
  /// (например, если экран сам рисует свой набор действий).
  final bool showFavoriteButton;

  /// Позволяет спрятать кнопку офлайн-кэширования (например, на экране
  /// самого списка кэшированных треков — там она не нужна, см. библиотеку).
  final bool showCacheButton;

  /// Если передан — рисуется кнопка «добавить в плейлист». Логика выбора
  /// плейлиста живёт в вызывающем экране (через callback), чтобы сам
  /// тайл не тянул зависимость на PlaylistsProvider там, где это не нужно.
  final VoidCallback? onAddToPlaylist;

  void _notifyUnavailable(BuildContext context) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(AppStrings.current.trackUnavailableShort(track.title)),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final playable = track.isPlayable;
    // Своей RepaintBoundary здесь больше нет: все места, где строится
    // TrackTile, — это ListView.builder/SliverList.builder, а они по
    // умолчанию (addRepaintBoundaries: true) уже оборачивают каждого
    // ребёнка в RepaintBoundary. Вложенная вторая ничего не изолирует
    // дополнительно, зато добавляет каждой плитке лишний слой в слоевом
    // дереве — на длинном списке это заметная трата на ровном месте.
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      // Заведомо непроигрываемый трек (пустой streamUrl уже на этапе
      // поиска — см. Track.isPlayable) не запускает воспроизведение и не
      // тратит сетевой резолв впустую — просто поясняем причину.
      onTap: playable ? onTap : () => _notifyUnavailable(context),
      child: Opacity(
        opacity: playable ? 1 : 0.45,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: CachedNetworkImage(
                  imageUrl: track.artworkUrl,
                  width: 52,
                  height: 52,
                  fit: BoxFit.cover,
                  // Список может быть длинным — декодировать и держать в
                  // памяти полноразмерную обложку под 52×52 плитку было бы
                  // расточительно и на скролле бьёт по плавности.
                  memCacheWidth: 104,
                  memCacheHeight: 104,
                  placeholder: (_, __) => Container(
                    width: 52,
                    height: 52,
                    color: AppColors.surfaceElevated,
                  ),
                  errorWidget: (_, __, ___) => Container(
                    width: 52,
                    height: 52,
                    color: AppColors.surfaceElevated,
                    child: Icon(Icons.music_note_rounded,
                        color: AppColors.textSecondary, size: 20),
                  ),
                ),
              ),
              SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: isActive
                            ? AppColors.accentEnd
                            : AppColors.textPrimary,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      playable
                          ? track.artist
                          : '${track.artist} · ${l10n.unavailableSuffix}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _DurationLabel(duration: track.duration),
              const SizedBox(width: 8),
              _SourceBadge(source: track.source),
              if (onAddToPlaylist != null)
                IconButton(
                  onPressed: playable ? onAddToPlaylist : null,
                  icon: Icon(Icons.playlist_add_rounded,
                      size: 22, color: AppColors.textSecondary),
                  splashRadius: 18,
                  padding: const EdgeInsets.only(left: 2),
                  constraints: const BoxConstraints(),
                  visualDensity: VisualDensity.compact,
                ),
              if (showCacheButton) _CacheButton(track: track, enabled: playable),
              if (showFavoriteButton) _FavoriteButton(track: track),
            ],
          ),
        ),
      ),
    );
  }
}

class _FavoriteButton extends StatelessWidget {
  const _FavoriteButton({required this.track});
  final Track track;

  @override
  Widget build(BuildContext context) {
    // context.select пересобирает только эту иконку — и только когда
    // значение isFavorite именно ДЛЯ ЭТОГО трека реально меняется,
    // а не при любом изменении FavoritesProvider (важно в длинных списках
    // на слабых устройствах).
    final isFav = context.select<FavoritesProvider, bool>(
      (p) => p.isFavorite(track.id),
    );
    return IconButton(
      onPressed: () => context.read<FavoritesProvider>().toggle(track),
      icon: Icon(
        isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        size: 20,
        color: isFav ? AppColors.accentEnd : AppColors.textSecondary,
      ),
      splashRadius: 18,
      padding: const EdgeInsets.only(left: 4),
      constraints: const BoxConstraints(),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _CacheButton extends StatelessWidget {
  const _CacheButton({required this.track, this.enabled = true});
  final Track track;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    // Record как значение select — перестраивается только когда для
    // ЭТОГО трека реально меняется факт кэширования или прогресс закачки,
    // а не при любой мутации CachedTracksProvider.
    final (isCached, progress) =
        context.select<CachedTracksProvider, (bool, double?)>(
      (p) => (p.isCached(track.id), p.downloadProgress(track.id)),
    );

    if (!enabled && !isCached && progress == null) {
      return const SizedBox(width: 20);
    }

    if (progress != null) {
      // Идёт закачка: крутим прогресс, тап отменяет закачку.
      return GestureDetector(
        onTap: () => context.read<CachedTracksProvider>().cancelDownload(track.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: SizedBox(
            width: 20,
            height: 20,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  strokeWidth: 2,
                  value: progress > 0 ? progress : null,
                  color: AppColors.textSecondary,
                ),
                Icon(Icons.close_rounded, size: 10, color: AppColors.textSecondary),
              ],
            ),
          ),
        ),
      );
    }

    return IconButton(
      onPressed: () {
        final provider = context.read<CachedTracksProvider>();
        if (isCached) {
          provider.remove(track.id);
        } else {
          provider.download(track);
        }
      },
      icon: Icon(
        isCached ? Icons.offline_pin_rounded : Icons.download_rounded,
        size: 20,
        color: isCached ? AppColors.accentEnd : AppColors.textSecondary,
      ),
      splashRadius: 18,
      padding: const EdgeInsets.only(left: 2),
      constraints: const BoxConstraints(),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _DurationLabel extends StatelessWidget {
  const _DurationLabel({required this.duration});
  final Duration duration;

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString();
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    // Для ещё не резолвнутых треков длительность может быть неизвестна —
    // в этом случае просто не занимаем место в ряду.
    if (duration <= Duration.zero) return const SizedBox.shrink();

    return Text(
      _fmt(duration),
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: AppColors.textSecondary,
        fontFeatures: [FontFeature.tabularFigures()],
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});
  final MusicSourceType source;

  @override
  Widget build(BuildContext context) {
    final label = switch (source) {
      MusicSourceType.soundcloud => 'SC',
      MusicSourceType.audiomack => 'AM',
      MusicSourceType.deezer => 'DZ',
      MusicSourceType.youtube => 'YT',
      MusicSourceType.vk => 'VK',
      MusicSourceType.local => '',
    };
    if (label.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}
