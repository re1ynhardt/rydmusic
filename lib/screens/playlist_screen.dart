import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/playlist.dart';
import '../providers/language_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlists_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/playlist_actions_sheet.dart';
import '../widgets/remote_cover_image.dart';
import '../widgets/track_tile.dart';

/// Экран одного плейлиста: обложка, имя (можно переименовать), список
/// треков (можно убрать трек свайпом), плюс смена обложки и удаление
/// плейлиста целиком через красивый шит действий.
class PlaylistScreen extends StatelessWidget {
  const PlaylistScreen({super.key, required this.playlistId});
  final String playlistId;

  Future<void> _pickCover(BuildContext context) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 600,
      maxHeight: 600,
      imageQuality: 85,
    );
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    if (!context.mounted) return;
    context.read<PlaylistsProvider>().updateCover(playlistId, bytes);
  }

  Future<void> _rename(BuildContext context, String currentName) async {
    final newName =
        await showRenamePlaylistDialog(context, currentName: currentName);
    if (newName != null && newName.trim().isNotEmpty && context.mounted) {
      context.read<PlaylistsProvider>().rename(playlistId, newName);
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final confirmed = await showDeletePlaylistDialog(context);
    if (confirmed && context.mounted) {
      await context.read<PlaylistsProvider>().delete(playlistId);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  void _openActionsSheet(BuildContext context, String currentName) {
    showPlaylistActionsSheet(
      context,
      onRename: () => _rename(context, currentName),
      onChangeCover: () => _pickCover(context),
      onDelete: () => _confirmDelete(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // select по конкретному плейлисту — экран перестраивается только когда
    // реально меняется ЭТОТ плейлист, а не при любой мутации провайдера.
    final playlist = context.select<PlaylistsProvider, Playlist?>(
      (p) => p.byId(playlistId),
    );

    if (playlist == null) {
      // Плейлист мог быть удалён (например, с другого места) — просто
      // закрываем экран, не рисуя пустое состояние.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      });
      return const Scaffold(body: SizedBox.shrink());
    }

    final tracks = playlist.trackList;

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: CustomScrollView(
          physics: const BouncingScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.arrow_back_rounded,
                          color: AppColors.textPrimary),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: () => _openActionsSheet(context, playlist.name),
                      icon: Icon(Icons.more_horiz_rounded,
                          color: AppColors.textPrimary),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Column(
                  children: [
                    GestureDetector(
                      onTap: () => _pickCover(context),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: playlist.coverPath != null
                                ? SizedBox(
                                    width: 160,
                                    height: 160,
                                    child: RemoteCoverImage(coverKey: playlist.coverPath!),
                                  )
                                : Container(
                                    width: 160,
                                    height: 160,
                                    color: AppColors.surfaceElevated,
                                    child: Icon(Icons.music_note_rounded,
                                        size: 48,
                                        color: AppColors.textSecondary),
                                  ),
                          ),
                          Positioned(
                            right: 6,
                            bottom: 6,
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: AppColors.surface,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.25),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                              child: Icon(Icons.camera_alt_rounded,
                                  size: 16, color: AppColors.textPrimary),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      playlist.name,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l10n.tracksCount(playlist.trackCount),
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
            ),
            if (tracks.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
                  child: Center(
                    child: Text(
                      l10n.playlistEmpty,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                sliver: SliverList.builder(
                  itemCount: tracks.length,
                  itemBuilder: (context, i) {
                    final track = tracks[i];
                    return Dismissible(
                      key: ValueKey(track.id),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 16),
                        child: Icon(Icons.delete_outline_rounded,
                            color: AppColors.textSecondary),
                      ),
                      onDismissed: (_) => context
                          .read<PlaylistsProvider>()
                          .removeTrack(playlistId, track.id),
                      child: TrackTile(
                        track: track,
                        showFavoriteButton: false,
                        onTap: () => context
                            .read<PlayerProvider>()
                            .playTrack(track, queue: tracks),
                      ),
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
