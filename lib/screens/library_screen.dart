import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../providers/cached_tracks_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/language_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlists_provider.dart';
import 'playlist_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/create_playlist_sheet.dart';
import '../widgets/remote_cover_image.dart';
import '../widgets/track_tile.dart';

enum _LibraryTab { music, cached }

/// Библиотека: плейлисты пользователя сверху, ниже — тумблер
/// «Музыка / Кэшированные», переключающий список между избранными
/// треками и треками, скачанными для офлайн-прослушивания.
/// Оба списка короткие по своей природе (личная подборка пользователя),
/// поэтому ListView.builder тут — уже достаточная оптимизация, без
/// дополнительной пагинации/виртуализации.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  _LibraryTab _tab = _LibraryTab.music;
  // Управляет и свайпом между "Музыка"/"Кэшированные", и тапом по
  // пилюле-переключателю — оба способа двигают один и тот же PageView,
  // чтобы состояние (_tab) и то, что реально на экране, не расходились.
  late final PageController _pageController =
      PageController(initialPage: _tab.index);

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onTabChanged(_LibraryTab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    _pageController.animateToPage(
      tab.index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  void _onPageChanged(int index) {
    final tab = _LibraryTab.values[index];
    if (tab == _tab) return;
    setState(() => _tab = tab);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final favoritesProvider = context.watch<FavoritesProvider>();
    final favorites = favoritesProvider.favorites;
    final cachedProvider = context.watch<CachedTracksProvider>();
    final cachedTracks = cachedProvider.cachedTracks;
    final playlistsProvider = context.watch<PlaylistsProvider>();
    final playlists = playlistsProvider.playlists;
    // select, а не watch: экран раньше перестраивался целиком (плейлисты,
    // обе вкладки списка) на каждый тик позиции воспроизведения, потому
    // что PlayerProvider уведомляет слушателей и о позиции тоже. select
    // подписывается только на этот конкретный bool и не реагирует на
    // остальные изменения провайдера.
    final hasMiniPlayer =
        context.select<PlayerProvider, bool>((p) => p.currentTrack != null);
    final bottomInset =
        AppLayout.reservedBottomSpace(hasMiniPlayer: hasMiniPlayer);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
            child: Text(
              l10n.navLibrary,
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          if (playlistsProvider.isLoaded) _PlaylistsRow(playlists: playlists),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
            child: _LibraryTabSwitch(
              tab: _tab,
              onChanged: _onTabChanged,
            ),
          ),
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const BouncingScrollPhysics(),
              onPageChanged: _onPageChanged,
              children: [
                _LibraryTabPage(
                  tab: _LibraryTab.music,
                  tracks: favorites,
                  isLoaded: favoritesProvider.isLoaded,
                  bottomInset: bottomInset,
                ),
                _LibraryTabPage(
                  tab: _LibraryTab.cached,
                  tracks: cachedTracks,
                  isLoaded: cachedProvider.isLoaded,
                  bottomInset: bottomInset,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Содержимое одной вкладки библиотеки (музыка ИЛИ кэшированные) —
/// страница внутри PageView в LibraryScreen. Каждая вкладка держит
/// собственный список независимо от того, какая вкладка сейчас видна:
/// PageView строит обе страницы сразу (детей всего две — дёшево), чтобы
/// свайп между ними не приводил к пересборке списка с нуля каждый раз.
class _LibraryTabPage extends StatelessWidget {
  const _LibraryTabPage({
    required this.tab,
    required this.tracks,
    required this.isLoaded,
    required this.bottomInset,
  });

  final _LibraryTab tab;
  final List<Track> tracks;
  final bool isLoaded;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    if (!isLoaded) return const SizedBox.shrink();
    if (tracks.isEmpty) return _EmptyLibrary(tab: tab);
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(20, 8, 20, bottomInset),
      physics: const BouncingScrollPhysics(),
      itemCount: tracks.length,
      itemBuilder: (context, i) {
        final track = tracks[i];
        return TrackTile(
          key: ValueKey(track.id),
          track: track,
          onAddToPlaylist: () => showAddToPlaylistSheet(context, track),
          onTap: () =>
              context.read<PlayerProvider>().playTrack(track, queue: tracks),
        );
      },
    );
  }
}

/// Сегмент-переключатель в духе iOS: два пилюлеобразных таба внутри одной
/// скруглённой обвязки, активный подсвечен акцентной заливкой.
class _LibraryTabSwitch extends StatelessWidget {
  const _LibraryTabSwitch({required this.tab, required this.onChanged});
  final _LibraryTab tab;
  final ValueChanged<_LibraryTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _SegmentButton(
            label: l10n.libraryTabMusic,
            selected: tab == _LibraryTab.music,
            onTap: () => onChanged(_LibraryTab.music),
          ),
          _SegmentButton(
            label: l10n.libraryTabCached,
            selected: tab == _LibraryTab.cached,
            onTap: () => onChanged(_LibraryTab.cached),
          ),
        ],
      ),
    );
  }
}

class _SegmentButton extends StatelessWidget {
  const _SegmentButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? AppColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.12),
                      blurRadius: 6,
                      offset: const Offset(0, 1),
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: selected ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Горизонтальная лента плейлистов: первая карточка — «Создать плейлист»,
/// дальше — существующие плейлисты. Фиксированная высота, отдельный
/// горизонтальный ListView.builder — не блокирует вертикальный скролл
/// экрана и не тянет за собой лишнюю разметку на слабых устройствах.
class _PlaylistsRow extends StatelessWidget {
  const _PlaylistsRow({required this.playlists});
  final List<Playlist> playlists;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 132,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: playlists.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return _CreatePlaylistCard(
              onTap: () async {
                final playlist = await showCreatePlaylistSheet(context);
                if (playlist != null && context.mounted) {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PlaylistScreen(playlistId: playlist.id),
                  ));
                }
              },
            );
          }
          final playlist = playlists[i - 1];
          return _PlaylistCard(
            key: ValueKey(playlist.id),
            playlist: playlist,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PlaylistScreen(playlistId: playlist.id),
            )),
          );
        },
      ),
    );
  }
}

class _CreatePlaylistCard extends StatelessWidget {
  const _CreatePlaylistCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          width: 92,
          child: Column(
            children: [
              Container(
                width: 92,
                height: 92,
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.add_rounded,
                    color: AppColors.textPrimary, size: 30),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.create,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  const _PlaylistCard({super.key, required this.playlist, required this.onTap});
  final Playlist playlist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          width: 92,
          child: Column(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: playlist.coverPath != null
                    ? SizedBox(
                        width: 92,
                        height: 92,
                        child: RemoteCoverImage(coverKey: playlist.coverPath!),
                      )
                    : Container(
                        width: 92,
                        height: 92,
                        color: AppColors.surfaceElevated,
                        child: Icon(Icons.music_note_rounded,
                            color: AppColors.textSecondary, size: 26),
                      ),
              ),
              const SizedBox(height: 6),
              Text(
                playlist.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.tab});
  final _LibraryTab tab;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final isMusic = tab == _LibraryTab.music;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isMusic
                  ? Icons.favorite_border_rounded
                  : Icons.offline_pin_outlined,
              size: 40,
              color: AppColors.textSecondary,
            ),
            const SizedBox(height: 12),
            Text(
              isMusic
                  ? l10n.emptyFavorites
                  : l10n.emptyCached,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
