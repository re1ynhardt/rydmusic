import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/playlist.dart';
import '../models/track.dart';
import '../models/user_account.dart';
import '../providers/auth_provider.dart';
import '../providers/cached_tracks_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/language_provider.dart';
import '../providers/player_provider.dart';
import '../providers/playlists_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/remote_cover_image.dart';
import 'avatar_crop_screen.dart';
import 'playlist_screen.dart';

const double _bannerHeight = 190;
const double _avatarRadius = 46;

/// Профиль пользователя: баннер и аватар (оба настраиваются прямо тут,
/// с кропом), карточка статистики и быстрый доступ к избранному и
/// плейлистам. Пользователь всегда залогинен на этом экране — MainShell
/// показывается только после AuthGate (см. main.dart).
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.developerEmails,
    required this.onGoToLibrary,
    required this.onOpenSettings,
  });

  final Set<String> developerEmails;
  final VoidCallback onGoToLibrary;

  /// Открывает экран настроек. Кнопка живёт в правом верхнем углу
  /// баннера — раньше там был «фотоаппаратик» для смены баннера, но
  /// сам баннер по-прежнему меняется через «Редактировать профиль».
  final VoidCallback onOpenSettings;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  Uint8List? _avatarBytes;
  Uint8List? _bannerBytes;
  String? _avatarKeyLoaded;
  String? _bannerKeyLoaded;
  bool _avatarUploading = false;
  bool _bannerUploading = false;

  bool _isDeveloper(UserAccount? u) =>
      u != null &&
      widget.developerEmails.contains(u.email.trim().toLowerCase());

  Future<void> _loadImages(AuthProvider auth) async {
    final avatarKey = auth.user?.avatarKey;
    if (avatarKey != null && avatarKey != _avatarKeyLoaded) {
      final bytes = await auth.fetchAvatarBytes(avatarKey);
      if (mounted) {
        setState(() {
          _avatarBytes = bytes == null ? null : Uint8List.fromList(bytes);
          _avatarKeyLoaded = avatarKey;
        });
      }
    }
    final bannerKey = auth.user?.bannerKey;
    if (bannerKey != null && bannerKey != _bannerKeyLoaded) {
      final bytes = await auth.fetchAvatarBytes(bannerKey);
      if (mounted) {
        setState(() {
          _bannerBytes = bytes == null ? null : Uint8List.fromList(bytes);
          _bannerKeyLoaded = bannerKey;
        });
      }
    }
  }

  Future<void> _pickAvatar(AuthProvider auth) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 95,
    );
    if (picked == null) return;
    final rawBytes = await picked.readAsBytes();
    if (!mounted) return;
    final cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => AvatarCropScreen(imageBytes: rawBytes),
        fullscreenDialog: true,
      ),
    );
    if (cropped == null) return;
    setState(() => _avatarUploading = true);
    final ok = await auth.updateAvatar(
      bytes: cropped,
      extension: 'png',
      contentType: 'image/png',
    );
    if (!mounted) return;
    setState(() {
      _avatarUploading = false;
      if (ok) {
        _avatarBytes = cropped;
        _avatarKeyLoaded = auth.user?.avatarKey;
      }
    });
    if (!ok && auth.error != null) _showError(auth.error!);
  }

  Future<void> _pickBanner(AuthProvider auth) async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 2560,
      maxHeight: 2560,
      imageQuality: 95,
    );
    if (picked == null) return;
    final rawBytes = await picked.readAsBytes();
    if (!mounted) return;
    final cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => AvatarCropScreen(
          imageBytes: rawBytes,
          aspectRatio: 2.2,
          withCircleUi: false,
          titleOverride: AppStrings.current.cropBannerTitle,
        ),
        fullscreenDialog: true,
      ),
    );
    if (cropped == null) return;
    setState(() => _bannerUploading = true);
    final ok = await auth.updateBanner(
      bytes: cropped,
      extension: 'png',
      contentType: 'image/png',
    );
    if (!mounted) return;
    setState(() {
      _bannerUploading = false;
      if (ok) {
        _bannerBytes = cropped;
        _bannerKeyLoaded = auth.user?.bannerKey;
      }
    });
    if (!ok && auth.error != null) _showError(auth.error!);
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _openEditSheet(UserAccount user, AuthProvider auth) {
    final l10n = AppStrings.current;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.image_rounded),
                title: Text(l10n.changeAvatar),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickAvatar(auth);
                },
              ),
              ListTile(
                leading: const Icon(Icons.wallpaper_rounded),
                title: Text(l10n.changeBanner),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickBanner(auth);
                },
              ),
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: Text(l10n.changeNickname),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openEditNicknameDialog(user, auth);
                },
              ),
              ListTile(
                leading: const Icon(Icons.lock_outline_rounded),
                title: Text(l10n.changePassword),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openChangePasswordDialog(auth);
                },
              ),
              const Divider(height: 8),
              ListTile(
                leading: Icon(Icons.logout_rounded, color: Colors.redAccent),
                title: Text(l10n.logOutAccount,
                    style: const TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(sheetContext);
                  auth.logout();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openEditNicknameDialog(UserAccount user, AuthProvider auth) {
    final ctrl = TextEditingController(text: user.displayName);
    final l10n = AppStrings.current;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.nickname),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: l10n.enterNickname),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () async {
              final ok = await auth.updateDisplayName(ctrl.text);
              if (!dialogContext.mounted) return;
              Navigator.pop(dialogContext);
              if (!ok && auth.error != null) _showError(auth.error!);
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );
  }

  void _openChangePasswordDialog(AuthProvider auth) {
    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final l10n = AppStrings.current;
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.passwordChangeTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: currentCtrl,
              obscureText: true,
              autofocus: true,
              decoration: InputDecoration(hintText: l10n.currentPassword),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: newCtrl,
              obscureText: true,
              decoration: InputDecoration(hintText: l10n.newPassword),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () async {
              final ok = await auth.changePassword(
                currentPassword: currentCtrl.text,
                newPassword: newCtrl.text,
              );
              if (!dialogContext.mounted) return;
              if (ok) {
                Navigator.pop(dialogContext);
              } else if (auth.error != null) {
                _showError(auth.error!);
              }
            },
            child: Text(l10n.save),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final auth = context.watch<AuthProvider>();
    final user = auth.user;
    if (user == null) return const SizedBox.shrink();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadImages(auth));

    final favorites = context.watch<FavoritesProvider>();
    final playlistsProvider = context.watch<PlaylistsProvider>();
    final cached = context.watch<CachedTracksProvider>();
    final hasMiniPlayer =
        context.select<PlayerProvider, bool>((p) => p.currentTrack != null);
    final bottomInset =
        AppLayout.reservedBottomSpace(hasMiniPlayer: hasMiniPlayer);
    final isDeveloper = _isDeveloper(user);

    return Semantics(
      label: l10n.profileTitle,
      child: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.only(bottom: bottomInset),
          physics: const BouncingScrollPhysics(),
          children: [
            _BannerAndAvatar(
              bannerBytes: _bannerBytes,
              avatarBytes: _avatarBytes,
              bannerUploading: _bannerUploading,
              avatarUploading: _avatarUploading,
              onOpenSettings: widget.onOpenSettings,
              onEditAvatar: () => _pickAvatar(auth),
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                children: [
                  // Почта в профиле НЕ показывается: это личные данные,
                  // а идентифицирует пользователя здесь никнейм. Если
                  // никнейм не задан — показываем нейтральную заглушку,
                  // а не e-mail, как было раньше.
                  Text(
                    user.displayName.isEmpty
                        ? l10n.profileNoNickname
                        : user.displayName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 21,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (isDeveloper) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(.18),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        l10n.developerBadge,
                        style: const TextStyle(
                            color: Colors.amber,
                            fontSize: 9,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Row(
                      children: [
                        _Stat(
                            value: favorites.count,
                            label: l10n.profileFavoritesTitle),
                        const _VDivider(),
                        _Stat(
                            value: playlistsProvider.count,
                            label: l10n.profilePlaylistsTitle),
                        const _VDivider(),
                        _Stat(
                            value: cached.count,
                            label: l10n.profileCachedStat),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: _GradientButton(
                          icon: Icons.edit_rounded,
                          label: l10n.editProfile,
                          onTap: () => _openEditSheet(user, auth),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: auth.logout,
                          icon: const Icon(Icons.logout_rounded, size: 18),
                          label: Text(l10n.logOutAccount,
                              overflow: TextOverflow.ellipsis),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppColors.textPrimary,
                            side: BorderSide(color: AppColors.surfaceElevated),
                            minimumSize: const Size.fromHeight(46),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),
                ],
              ),
            ),
            _SectionHeader(
              title: l10n.profileFavoritesTitle,
              onGoTo: widget.onGoToLibrary,
            ),
            if (!favorites.isLoaded)
              const SizedBox.shrink()
            else if (favorites.favorites.isEmpty)
              _EmptyRow(text: l10n.emptyFavorites)
            else
              _TrackRow(tracks: favorites.favorites),
            const SizedBox(height: 22),
            _SectionHeader(
              title: l10n.profilePlaylistsTitle,
              onGoTo: widget.onGoToLibrary,
            ),
            if (!playlistsProvider.isLoaded)
              const SizedBox.shrink()
            else if (playlistsProvider.playlists.isEmpty)
              _EmptyRow(text: l10n.profileEmptyPlaylists)
            else
              _PlaylistRow(playlists: playlistsProvider.playlists),
          ],
        ),
      ),
    );
  }
}

/// Баннер во всю ширину + аватар, наполовину лежащий на его нижнем крае.
class _BannerAndAvatar extends StatelessWidget {
  const _BannerAndAvatar({
    required this.bannerBytes,
    required this.avatarBytes,
    required this.bannerUploading,
    required this.avatarUploading,
    required this.onOpenSettings,
    required this.onEditAvatar,
  });

  final Uint8List? bannerBytes;
  final Uint8List? avatarBytes;
  final bool bannerUploading;
  final bool avatarUploading;
  final VoidCallback onOpenSettings;
  final VoidCallback onEditAvatar;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _bannerHeight + _avatarRadius,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(28),
            ),
            child: SizedBox(
              width: double.infinity,
              height: _bannerHeight,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  bannerBytes != null
                      ? Image.memory(bannerBytes!, fit: BoxFit.cover)
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                AppColors.surfaceElevated,
                                AppColors.surface,
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                        ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.35),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                  if (bannerUploading)
                    const Center(
                        child: CircularProgressIndicator(color: Colors.white)),
                ],
              ),
            ),
          ),
          Positioned(
            top: 12,
            right: 12,
            child: _RoundIconButton(
              icon: Icons.settings_rounded,
              tooltip: AppStrings.current.openSettings,
              onTap: onOpenSettings,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Center(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: (_avatarRadius + 4) * 2,
                    height: (_avatarRadius + 4) * 2,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.background,
                    ),
                    padding: const EdgeInsets.all(4),
                    child: CircleAvatar(
                      radius: _avatarRadius,
                      backgroundColor: AppColors.surfaceElevated,
                      backgroundImage:
                          avatarBytes != null ? MemoryImage(avatarBytes!) : null,
                      child: avatarBytes == null
                          ? Icon(Icons.person_rounded,
                              size: 40, color: AppColors.textSecondary)
                          : (avatarUploading
                              ? const CircularProgressIndicator(
                                  color: Colors.white)
                              : null),
                    ),
                  ),
                  Positioned(
                    right: 2,
                    bottom: 2,
                    child: _RoundIconButton(
                      icon: Icons.edit_rounded,
                      size: 28,
                      iconSize: 14,
                      onTap: onEditAvatar,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.size = 36,
    this.iconSize = 18,
    this.tooltip,
  });
  final IconData icon;
  final VoidCallback onTap;
  final double size;
  final double iconSize;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: Colors.black.withOpacity(0.45),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: Colors.white, size: iconSize),
        ),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label});
  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text('$value',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(fontSize: 11.5, color: AppColors.textSecondary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

class _VDivider extends StatelessWidget {
  const _VDivider();
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 30, color: AppColors.surfaceElevated);
}

class _GradientButton extends StatelessWidget {
  const _GradientButton(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        height: 46,
        decoration: BoxDecoration(
          gradient: AppColors.accentGradient,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: AppColors.accentStart.withOpacity(0.35),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: AppColors.onAccent),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppColors.onAccent, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.onGoTo});
  final String title;
  final VoidCallback onGoTo;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
          TextButton(
            onPressed: onGoTo,
            child: Text(l10n.profileGoTo,
                style: TextStyle(color: AppColors.textSecondary)),
          ),
        ],
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: Text(text, style: TextStyle(color: AppColors.textSecondary)),
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({required this.tracks});
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    final shown = tracks.take(12).toList(growable: false);
    return SizedBox(
      height: 148,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: shown.length,
        itemBuilder: (context, i) {
          final track = shown[i];
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => context
                  .read<PlayerProvider>()
                  .playTrack(track, queue: shown),
              child: SizedBox(
                width: 96,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: track.artworkUrl.isEmpty
                          ? Container(
                              width: 96,
                              height: 96,
                              color: AppColors.surfaceElevated,
                              child: Icon(Icons.music_note_rounded,
                                  color: AppColors.textSecondary),
                            )
                          : CachedNetworkImage(
                              imageUrl: track.artworkUrl,
                              width: 96,
                              height: 96,
                              fit: BoxFit.cover,
                              memCacheWidth: 288,
                              errorWidget: (_, __, ___) => Container(
                                  width: 96,
                                  height: 96,
                                  color: AppColors.surfaceElevated),
                            ),
                    ),
                    const SizedBox(height: 6),
                    Text(track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w700)),
                    Text(track.artist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({required this.playlists});
  final List<Playlist> playlists;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 132,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        itemCount: playlists.length,
        itemBuilder: (context, i) {
          final playlist = playlists[i];
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PlaylistScreen(playlistId: playlist.id),
              )),
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
                              child:
                                  RemoteCoverImage(coverKey: playlist.coverPath!),
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
                    Text(playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
