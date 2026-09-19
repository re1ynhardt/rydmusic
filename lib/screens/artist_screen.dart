import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:provider/provider.dart';

import '../models/artist_page.dart';
import '../models/track.dart';
import '../providers/language_provider.dart';
import '../providers/player_provider.dart';
import '../services/artwork_palette.dart';
import '../services/music_source.dart';
import '../theme/app_theme.dart';
import '../widgets/track_tile.dart';

/// Страница исполнителя: круглый аватар, имя, счётчики, кнопки
/// воспроизведения, переключатель «Альбомы / Треки» и список.
/// Данные — только из источника, откуда играет текущий трек.
/// Открывается свайпом влево на экране «Сейчас играет».
///
/// ── Про плавность ──
/// Фон — статичный градиент по палитре ИГРАЮЩЕГО СЕЙЧАС трека (той же,
/// что у мини-плеера и Now Playing), поэтому экран выглядит продолжением
/// плеера. Это именно градиент, а не BackdropFilter: блюр пересчитывает
/// всё под собой каждый кадр, и на прокручиваемом списке съедал бы
/// больше, чем весь остальной экран. Градиент живёт в отдельном
/// виджете с собственным состоянием — смена трека перерисовывает только
/// подложку, а не список.
/// Списки ленивые (ListView.builder), раскрытие альбома держится в самой
/// карточке (тап не перестраивает список), обложки декодируются под свой
/// фактический размер.
class ArtistScreen extends StatefulWidget {
  const ArtistScreen({super.key, required this.track, required this.source});

  final Track track;
  final MusicSource source;

  @override
  State<ArtistScreen> createState() => _ArtistScreenState();
}

class _ArtistScreenState extends State<ArtistScreen> {
  late Future<ArtistPage?> _future;
  bool _albumsView = true;

  // Треки альбомов грузятся один раз, при первом раскрытии.
  final Map<String, Future<List<Track>>> _albumTracks = {};

  // Какие альбомы раскрыты. Меняется БЕЗ setState: карточка
  // перерисовывает себя сама, списку об этом знать незачем.
  final Set<String> _expandedAlbums = {};

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// Таймаут — чтобы экран не висел вечно на крутилке, если источник не
  /// ответил: вместо бесконечной загрузки покажем «Повторить».
  Future<ArtistPage?> _load() => widget.source
      .loadArtist(widget.track)
      .timeout(const Duration(seconds: 25), onTimeout: () => null);

  void _retry() => setState(() {
        _albumTracks.clear();
        _expandedAlbums.clear();
        _future = _load();
      });

  /// Окно очереди вокруг нажатого трека: PlayerProvider резолвит очередь
  /// целиком, а у исполнителя может быть под 200 треков — столько
  /// резолвов (особенно YouTube) ни к чему.
  void _play(Track t, List<Track> list) {
    final i = list.indexWhere((e) => e.id == t.id);
    final from = (i - 10).clamp(0, list.length);
    final to = (i + 30).clamp(0, list.length);
    context.read<PlayerProvider>().playTrack(t, queue: list.sublist(from, to));
  }

  void _playAll(List<Track> tracks) {
    if (tracks.isEmpty) return;
    _play(tracks.first, tracks);
  }

  void _shuffle(List<Track> tracks) {
    if (tracks.isEmpty) return;
    // Перемешиваем копию и берём окно: очередь всё равно ограничена,
    // а резолвить 200 ссылок ради шаффла незачем.
    final pool = List<Track>.of(tracks)..shuffle(math.Random());
    final window = pool.sublist(0, math.min(40, pool.length));
    context.read<PlayerProvider>().playTrack(window.first, queue: window);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // select, а не watch: PlayerProvider дёргает слушателей на каждый тик
    // позиции — без этого экран перестраивался бы несколько раз в секунду.
    final activeId =
        context.select<PlayerProvider, String?>((p) => p.currentTrack?.id);
    final hasMiniPlayer =
        context.select<PlayerProvider, bool>((p) => p.currentTrack != null);
    final bottomInset =
        AppLayout.reservedBottomSpace(hasMiniPlayer: hasMiniPlayer);

    Widget tile(Track t, List<Track> list) => TrackTile(
          track: t,
          isActive: t.id == activeId,
          onTap: () => _play(t, list),
        );

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(
        children: [
          // Подложка — градиент от обложки играющего трека.
          const Positioned.fill(child: PlayingTrackBackdrop()),
          SafeArea(
            child: FutureBuilder<ArtistPage?>(
              future: _future,
              builder: (context, snap) {
                final page = snap.data;
                final loading = snap.connectionState != ConnectionState.done;
                final failed = !loading && (snap.hasError || page == null);

                return Column(
                  children: [
                    // Шапка рисуется СРАЗУ, ещё до ответа источника:
                    // имя и обложка берутся из текущего трека (она уже в
                    // кэше), поэтому экран не мигает пустотой.
                    _ArtistHeader(
                      name: page?.name ?? widget.track.artist,
                      artworkUrl: (page?.artworkUrl.isNotEmpty ?? false)
                          ? page!.artworkUrl
                          : widget.track.artworkUrl,
                      albums: page?.albums.length ?? 0,
                      tracks: page?.tracks.length ?? 0,
                      enabled: page != null,
                      onPlay: () => _playAll(page?.tracks ?? const []),
                      onShuffle: () => _shuffle(page?.tracks ?? const []),
                    ),
                    if (page != null)
                      _Segments(
                        albumsView: _albumsView,
                        albumsLabel: l10n.artistAlbums,
                        tracksLabel: l10n.artistTracks,
                        onChanged: (albums) {
                          if (albums == _albumsView) return;
                          setState(() => _albumsView = albums);
                        },
                      ),
                    Expanded(
                      child: _body(
                        loading: loading,
                        failed: failed,
                        page: page,
                        tile: tile,
                        l10n: l10n,
                        bottomInset: bottomInset,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _body({
    required bool loading,
    required bool failed,
    required ArtistPage? page,
    required Widget Function(Track, List<Track>) tile,
    required AppStrings l10n,
    required double bottomInset,
  }) {
    if (loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (failed || page == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l10n.artistLoadFailed,
                style: TextStyle(color: AppColors.textSecondary)),
            TextButton(onPressed: _retry, child: Text(l10n.retry)),
          ],
        ),
      );
    }

    final empty = _albumsView ? page.albums.isEmpty : page.tracks.isEmpty;
    if (empty) {
      return Center(
        child: Text(l10n.artistNothingFound,
            style: TextStyle(color: AppColors.textSecondary)),
      );
    }

    if (_albumsView) {
      return ListView.builder(
        key: const PageStorageKey<String>('artist_albums'),
        padding: EdgeInsets.fromLTRB(12, 4, 12, bottomInset),
        physics: const BouncingScrollPhysics(),
        itemCount: page.albums.length,
        itemBuilder: (_, i) {
          final album = page.albums[i];
          return _AlbumCard(
            // Ключ по id — состояние раскрытия не «прилипает» к соседней
            // строке при переиспользовании элемента списка.
            key: ValueKey<String>('album_${album.id}'),
            album: album,
            initiallyExpanded: _expandedAlbums.contains(album.id),
            onExpandChanged: (open) => open
                ? _expandedAlbums.add(album.id)
                : _expandedAlbums.remove(album.id),
            loadTracks: () => _albumTracks.putIfAbsent(
                album.id, () => widget.source.loadAlbumTracks(album)),
            onRetry: () => _albumTracks.remove(album.id),
            tileBuilder: tile,
          );
        },
      );
    }

    return ListView.builder(
      key: const PageStorageKey<String>('artist_tracks'),
      padding: EdgeInsets.fromLTRB(4, 4, 4, bottomInset),
      physics: const BouncingScrollPhysics(),
      itemCount: page.tracks.length,
      itemBuilder: (_, i) => tile(page.tracks[i], page.tracks),
    );
  }
}

/// Неподвижная подложка: мягкий градиент по цветам обложки трека,
/// который играет ПРЯМО СЕЙЧАС — те же цвета, что у мини-плеера, так что
/// страница выглядит продолжением экрана «Сейчас играет».
///
/// Отдельный StatefulWidget не случайно: так смена трека (или доезд
/// палитры) перерисовывает ровно эту подложку, а не весь экран со
/// списком. Внутри — RepaintBoundary, поэтому прокрутка списка её вообще
/// не перерисовывает.
class PlayingTrackBackdrop extends StatefulWidget {
  const PlayingTrackBackdrop({super.key});

  @override
  State<PlayingTrackBackdrop> createState() => _PlayingTrackBackdropState();
}

class _PlayingTrackBackdropState extends State<PlayingTrackBackdrop> {
  String? _trackId;
  PaletteGenerator? _palette;

  void _sync(Track? track) {
    if (track == null || track.id == _trackId) return;
    _trackId = track.id;
    // Синхронно — то, что уже посчитано мини-плеером: цвет появляется
    // в первом же кадре, без мигания серым.
    final cached = ArtworkPalette.cached(track.id);
    if (cached != null) {
      _palette = cached;
      return;
    }
    _palette = null;
    final id = track.id;
    ArtworkPalette.load(id, track.artworkUrl).then((palette) {
      if (!mounted || _trackId != id || palette == null) return;
      setState(() => _palette = palette);
    });
  }

  List<Color> _colors() {
    final palette = _palette;
    if (palette == null) {
      return [AppColors.surfaceElevated, AppColors.background];
    }
    final primary = palette.vibrantColor?.color ??
        palette.lightVibrantColor?.color ??
        palette.dominantColor?.color ??
        palette.mutedColor?.color;
    if (primary == null) {
      return [AppColors.surfaceElevated, AppColors.background];
    }
    final secondary = palette.darkVibrantColor?.color ??
        palette.darkMutedColor?.color ??
        palette.mutedColor?.color ??
        primary;
    Color darken(Color c, double amount) => Color.lerp(c, Colors.black, amount)!;
    return [darken(primary, 0.38), darken(secondary, 0.7)];
  }

  @override
  Widget build(BuildContext context) {
    // Подписка точечная: только на сам трек, не на позицию.
    final track = context.select<PlayerProvider, Track?>((p) => p.currentTrack);
    _sync(track);
    final colors = _colors();

    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedContainer(
          // Одноразовая анимация на случай, если палитра доехала после
          // открытия экрана.
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                colors.first,
                colors.last,
                AppColors.background,
              ],
              stops: const [0.0, 0.38, 0.78],
            ),
          ),
        ),
      ),
    );
  }
}

/// Компактная шапка: круглый аватар, имя, счётчики и кнопки.
/// Без баннера во весь экран — страница начинается сразу с сути.
class _ArtistHeader extends StatelessWidget {
  const _ArtistHeader({
    required this.name,
    required this.artworkUrl,
    required this.albums,
    required this.tracks,
    required this.enabled,
    required this.onPlay,
    required this.onShuffle,
  });

  final String name;
  final String artworkUrl;
  final int albums;
  final int tracks;
  final bool enabled;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final parts = <String>[
      if (albums > 0) l10n.releasesCount(albums),
      if (tracks > 0) l10n.tracksCount(tracks),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            icon: Icon(Icons.arrow_back_ios_new_rounded,
                color: AppColors.textPrimary, size: 20),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _Avatar(url: artworkUrl, size: 84),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 25,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                          height: 1.1,
                        ),
                      ),
                      if (parts.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          parts.join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Expanded(
                  child: _PrimaryButton(
                    icon: Icons.play_arrow_rounded,
                    label: l10n.artistPlayAll,
                    onTap: enabled ? onPlay : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _GhostButton(
                    icon: Icons.shuffle_rounded,
                    label: l10n.artistShuffle,
                    onTap: enabled ? onShuffle : null,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.url, required this.size});
  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.surfaceElevated,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: url.isEmpty
          ? Icon(Icons.person_rounded,
              size: size * 0.5, color: AppColors.textSecondary)
          : CachedNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              // Декодируем ровно под размер на экране, а не в оригинал.
              memCacheWidth: (size * dpr).round(),
              fadeInDuration: const Duration(milliseconds: 150),
              errorWidget: (_, __, ___) => Icon(Icons.person_rounded,
                  size: size * 0.5, color: AppColors.textSecondary),
            ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          height: 46,
          decoration: BoxDecoration(
            gradient: AppColors.accentGradient,
            borderRadius: BorderRadius.circular(14),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 22, color: AppColors.onAccent),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.onAccent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.45 : 1,
      child: Material(
        color: AppColors.textPrimary.withOpacity(0.10),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            height: 46,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 20, color: AppColors.textPrimary),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Переключатель «Альбомы / Треки» — две пилюли.
class _Segments extends StatelessWidget {
  const _Segments({
    required this.albumsView,
    required this.albumsLabel,
    required this.tracksLabel,
    required this.onChanged,
  });

  final bool albumsView;
  final String albumsLabel;
  final String tracksLabel;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
      child: Row(
        children: [
          _Segment(
            label: albumsLabel,
            selected: albumsView,
            onTap: () => onChanged(true),
          ),
          const SizedBox(width: 8),
          _Segment(
            label: tracksLabel,
            selected: !albumsView,
            onTap: () => onChanged(false),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.textPrimary.withOpacity(0.92)
              : AppColors.textPrimary.withOpacity(0.10),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppColors.background : AppColors.textPrimary,
            fontSize: 13.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// Карточка альбома, раскрывающаяся по тапу.
///
/// Состояние раскрытия — своё, поэтому тап перестраивает ровно эту
/// карточку, а не весь список. Треки запрашиваются лениво, при первом
/// раскрытии, и кэшируются на уровне экрана.
class _AlbumCard extends StatefulWidget {
  const _AlbumCard({
    super.key,
    required this.album,
    required this.initiallyExpanded,
    required this.onExpandChanged,
    required this.loadTracks,
    required this.onRetry,
    required this.tileBuilder,
  });

  final ArtistAlbum album;
  final bool initiallyExpanded;
  final ValueChanged<bool> onExpandChanged;
  final Future<List<Track>> Function() loadTracks;
  final VoidCallback onRetry;
  final Widget Function(Track, List<Track>) tileBuilder;

  @override
  State<_AlbumCard> createState() => _AlbumCardState();
}

class _AlbumCardState extends State<_AlbumCard> {
  late bool _expanded = widget.initiallyExpanded;
  Future<List<Track>>? _tracks;

  @override
  void initState() {
    super.initState();
    if (_expanded) _tracks = widget.loadTracks();
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      // Запрос уходит строго по первому раскрытию.
      if (_expanded) _tracks ??= widget.loadTracks();
    });
    widget.onExpandChanged(_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final album = widget.album;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.textPrimary.withOpacity(0.055),
        borderRadius: BorderRadius.circular(16),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _toggle,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: _AlbumCover(url: album.artworkUrl, size: 56),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            album.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 14.5,
                            ),
                          ),
                          if (album.subtitle.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(
                              album.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: Icon(Icons.keyboard_arrow_down_rounded,
                          color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Содержимое не строится вовсе, пока альбом свёрнут — никакого
          // скрытого, но живого поддерева.
          if (_expanded)
            FutureBuilder<List<Track>>(
              future: _tracks,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final tracks = snap.data ?? const <Track>[];
                if (tracks.isEmpty) {
                  return TextButton(
                    onPressed: () {
                      widget.onRetry();
                      setState(() => _tracks = widget.loadTracks());
                    },
                    child: Text(context.l10n.retry),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final t in tracks) widget.tileBuilder(t, tracks),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _AlbumCover extends StatelessWidget {
  const _AlbumCover({required this.url, required this.size});
  final String url;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return Container(
        width: size,
        height: size,
        color: AppColors.surfaceElevated,
        child: Icon(Icons.album_rounded, color: AppColors.textSecondary),
      );
    }
    return CachedNetworkImage(
      imageUrl: url,
      width: size,
      height: size,
      fit: BoxFit.cover,
      // Декодируем под физический размер плитки (логический × DPR), а не
      // в оригинальные 1400px: на списке из десятков альбомов это
      // десятки мегабайт памяти изображений.
      memCacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
      fadeInDuration: const Duration(milliseconds: 150),
      errorWidget: (_, __, ___) => Container(
        width: size,
        height: size,
        color: AppColors.surfaceElevated,
      ),
    );
  }
}
