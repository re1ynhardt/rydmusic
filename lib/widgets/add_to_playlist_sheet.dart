import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/track.dart';
import '../providers/language_provider.dart';
import '../providers/playlists_provider.dart';
import '../theme/app_theme.dart';
import 'create_playlist_sheet.dart';
import 'remote_cover_image.dart';

/// Показывает список плейлистов для добавления/удаления [track].
/// Тап по плейлисту переключает наличие трека в нём — шит не закрывается,
/// чтобы можно было раскидать трек сразу в несколько плейлистов.
Future<void> showAddToPlaylistSheet(BuildContext context, Track track) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _AddToPlaylistSheet(track: track),
  );
}

class _AddToPlaylistSheet extends StatelessWidget {
  const _AddToPlaylistSheet({required this.track});
  final Track track;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // watch: список должен перерисовываться сразу после создания нового
    // плейлиста прямо из этого шита.
    final playlists = context.watch<PlaylistsProvider>().playlists;
    final bottomInset = MediaQuery.of(context).padding.bottom;

    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceElevated,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  l10n.addToPlaylist,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.add_rounded, color: AppColors.textPrimary),
            ),
            title: Text(l10n.newPlaylist,
                style: TextStyle(
                    color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
            onTap: () async {
              final playlist = await showCreatePlaylistSheet(context);
              if (playlist != null && context.mounted) {
                context.read<PlaylistsProvider>().addTrack(playlist.id, track);
              }
            },
          ),
          Flexible(
            child: playlists.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                    child: Text(
                      l10n.noPlaylistsYet,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.only(bottom: bottomInset + 12),
                    itemCount: playlists.length,
                    itemBuilder: (context, i) {
                      final playlist = playlists[i];
                      final contains = playlist.tracks.containsKey(track.id);
                      return ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: playlist.coverPath != null
                              ? SizedBox(
                                  width: 44,
                                  height: 44,
                                  child: RemoteCoverImage(coverKey: playlist.coverPath!),
                                )
                              : Container(
                                  width: 44,
                                  height: 44,
                                  color: AppColors.surfaceElevated,
                                  child: Icon(Icons.music_note_rounded,
                                      color: AppColors.textSecondary, size: 18),
                                ),
                        ),
                        title: Text(
                          playlist.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: AppColors.textPrimary),
                        ),
                        subtitle: Text(l10n.tracksCount(playlist.trackCount),
                            style: TextStyle(color: AppColors.textSecondary)),
                        trailing: Icon(
                          contains
                              ? Icons.check_circle_rounded
                              : Icons.circle_outlined,
                          color: contains
                              ? AppColors.accentEnd
                              : AppColors.textSecondary,
                        ),
                        onTap: () {
                          final provider = context.read<PlaylistsProvider>();
                          if (contains) {
                            provider.removeTrack(playlist.id, track.id);
                          } else {
                            provider.addTrack(playlist.id, track);
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
