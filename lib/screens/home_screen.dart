import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shimmer/shimmer.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/track.dart';
import '../providers/home_provider.dart';
import '../providers/language_provider.dart';
import '../providers/player_provider.dart';
import '../services/music_source.dart';
import '../theme/app_theme.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/track_tile.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.sources});
  final Map<MusicSourceType, MusicSource> sources;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Данные живут в HomeProvider (на уровне приложения, см. main.dart),
    // а не в этом State — ensureLoaded() лишь СТАРТУЕТ загрузку при
    // первом реальном открытии вкладки и ничего не делает при повторных
    // построениях виджета (смена темы, возврат из другого экрана): сам
    // провайдер идемпотентен по своему статусу.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<HomeProvider>().ensureLoaded();
    });
  }

  Future<void> _refresh() => context.read<HomeProvider>().refresh();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      child: RefreshIndicator(
        color: AppColors.accentEnd,
        backgroundColor: AppColors.surface,
        onRefresh: _refresh,
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics()),
          // cacheExtent чуть больше вьюпорта: карточки рекомендаций и
          // первые плитки трендов успевают построиться заранее, до того
          // как попадут в кадр — на среднем свайпе не видно "запаздывания"
          // декодирования обложек.
          cacheExtent: 600,
          slivers: const [
            _RecommendedSection(),
            _RecentlyPlayedSection(),
            SliverPadding(padding: EdgeInsets.only(bottom: 120)),
          ],
        ),
      ),
    );
  }
}

/// Горизонтальная лента персональных рекомендаций. Полностью скрывает
/// себя (SliverToBoxAdapter(child: SizedBox.shrink())), если у
/// HomeProvider ещё нет избранного, на котором можно строить подборку —
/// у пользователя без лайков не остаётся пустого блока с заголовком
/// "в никуда".
class _RecommendedSection extends StatelessWidget {
  const _RecommendedSection();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Selector, а не watch на весь HomeProvider: этот виджет пересобирается
    // только когда меняется именно то, что ему нужно (сама подборка или её
    // статус загрузки), а не на каждое обновление трендов рядом.
    final (loading, tracks) = context.select<HomeProvider, (bool, List<Track>)>(
      (p) => (p.isRecommendedLoading, p.recommended),
    );

    if (!loading && tracks.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 2),
              child: Text(
                l10n.recommendedForYou,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                l10n.recommendedSubtitle,
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ),
            SizedBox(
              height: 210,
              child: loading
                  ? const _RecommendedShimmer()
                  // itemExtent фиксирован (см. _RecommendedCard.width):
                  // ListView не тратит время на измерение каждой карточки
                  // перед layout — только на уже известную ширину.
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      itemCount: tracks.length,
                      itemExtent: _RecommendedCard.width + 14,
                      itemBuilder: (context, i) {
                        final t = tracks[i];
                        return _RecommendedCard(
                          key: ValueKey(t.id),
                          track: t,
                          onTap: () => context
                              .read<PlayerProvider>()
                              .playTrack(t, queue: tracks),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecommendedCard extends StatelessWidget {
  const _RecommendedCard({super.key, required this.track, required this.onTap});
  final Track track;
  final VoidCallback onTap;

  static const double width = 138;

  @override
  Widget build(BuildContext context) {
    final playable = track.isPlayable;
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Opacity(
        opacity: playable ? 1 : 0.45,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            width: width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: CachedNetworkImage(
                    imageUrl: track.artworkUrl,
                    width: width,
                    height: width,
                    fit: BoxFit.cover,
                    // Карточка рисуется ~138×138 лог. пикселей — без этого
                    // ограничения декодировались бы полноразмерные обложки
                    // источника (нередко 500–1000px), что на длинной ленте
                    // ощутимо бьёт по памяти и скорости скролла.
                    memCacheWidth: 276,
                    memCacheHeight: 276,
                    placeholder: (_, __) => Container(
                      color: AppColors.surfaceElevated,
                    ),
                    errorWidget: (_, __, ___) => Container(
                      color: AppColors.surfaceElevated,
                      child: Icon(Icons.music_note_rounded,
                          color: AppColors.textSecondary, size: 28),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecommendedShimmer extends StatelessWidget {
  const _RecommendedShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppColors.surface,
      highlightColor: AppColors.surfaceElevated,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        // Ширина ленты одинакова для любого будущего контента — 4
        // плейсхолдера с запасом перекрывают экран любой разумной ширины.
        itemCount: 4,
        itemExtent: _RecommendedCard.width + 14,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(right: 14),
          child: SizedBox(
            width: _RecommendedCard.width,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: _RecommendedCard.width,
                  height: _RecommendedCard.width,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                const SizedBox(height: 8),
                Container(height: 13, width: _RecommendedCard.width * 0.8, color: Colors.white),
                const SizedBox(height: 6),
                Container(height: 11, width: _RecommendedCard.width * 0.5, color: Colors.white),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Секция «Недавно прослушанные» — читает историю прямо из PlayerProvider,
/// не требуя отдельного провайдера. Если история пустая, секция скрывается
/// целиком (SliverToBoxAdapter(SizedBox.shrink())).
class _RecentlyPlayedSection extends StatelessWidget {
  const _RecentlyPlayedSection();

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tracks = context.select<PlayerProvider, List<Track>>(
      (p) => p.recentlyPlayed,
    );

    if (tracks.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

    return SliverMainAxisGroup(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          sliver: SliverToBoxAdapter(
            child: Text(
              l10n.recentlyPlayed,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, i) {
              final t = tracks[i];
              return TrackTile(
                key: ValueKey(t.id),
                track: t,
                onAddToPlaylist: () =>
                    showAddToPlaylistSheet(context, t),
                onTap: () => context
                    .read<PlayerProvider>()
                    .playTrack(t, queue: tracks),
              );
            },
          ),
        ),
      ],
    );
  }
}

