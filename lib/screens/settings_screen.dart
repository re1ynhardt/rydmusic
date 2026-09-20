import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/track.dart';
import '../models/user_account.dart';
import '../providers/auth_provider.dart';
import '../providers/audio_quality_provider.dart';
import '../providers/cached_tracks_provider.dart';
import '../providers/language_provider.dart';
import '../providers/player_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/vk_auth_provider.dart';
import '../services/audiomack_service.dart';
import '../services/music_source.dart';
import '../services/soundcloud_service.dart';
import '../services/youtube_po_token_resolver.dart';
import '../services/update_service.dart';
import '../theme/app_theme.dart';
import '../widgets/cache_settings_sheet.dart';
import '../widgets/vk_login_sheet.dart';
import 'avatar_crop_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.sources,
    required this.developerEmails,
    this.showBackButton = false,
  });
  final Map<MusicSourceType, MusicSource> sources;
  final Set<String> developerEmails;

  /// Настройки больше не вкладка, а отдельный экран, открываемый из
  /// профиля через Navigator.push — там нужна кнопка «назад».
  final bool showBackButton;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Uint8List? _avatarBytes;
  String? _avatarKeyLoaded;
  bool _avatarUploading = false;
  final UpdateService _updateService = UpdateService();
  bool _updateBusy = false;

  bool _isDeveloper(UserAccount? user) =>
      user != null &&
      widget.developerEmails.contains(user.email.trim().toLowerCase());

  Future<void> _checkForUpdate({bool silentIfNone = false}) async {
    final l10n = AppStrings.current;
    setState(() => _updateBusy = true);
    try {
      final update = await _updateService.latest();
      if (!mounted) return;
      if (update == null || !_updateService.isNewer(update)) {
        if (!silentIfNone) _showError(l10n.upToDateVersion);
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: Text(
            l10n.updateAvailableTitle(update.version, update.buildNumber),
          ),
          content: Text(
            update.releaseNotes.isEmpty
                ? l10n.updateReadyToInstall
                : update.releaseNotes,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n.later),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(dialogContext);
                setState(() => _updateBusy = true);
                try {
                  await _updateService.downloadAndInstall(update);
                } catch (e) {
                  if (mounted) _showError(l10n.updateInstallFailed(e));
                } finally {
                  if (mounted) setState(() => _updateBusy = false);
                }
              },
              child: Text(l10n.downloadAndInstall),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted && !silentIfNone) {
        _showError(l10n.updateCheckFailed(e));
      }
    } finally {
      if (mounted) setState(() => _updateBusy = false);
    }
  }

  Future<void> _publishUpdate() async {
    final l10n = AppStrings.current;
    final version = TextEditingController(text: '2.0.2');
    final build = TextEditingController(text: '2');
    final notes = TextEditingController();
    final publish = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l10n.publishAndroidUpdateTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: version,
              decoration: InputDecoration(
                labelText: l10n.versionFieldHint,
              ),
            ),
            TextField(
              controller: build,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l10n.buildNumberLabel),
            ),
            TextField(
              controller: notes,
              maxLines: 3,
              decoration: InputDecoration(labelText: l10n.whatChangedLabel),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.selectApk),
          ),
        ],
      ),
    );
    if (publish != true) return;
    // withData: true заставляет file_picker целиком прогонять файл через
    // platform channel (base64 туда-обратно между нативной и Dart
    // стороной) ещё до того, как мы получим управление — на файле
    // размером с APK (десятки/сотни МБ) это удваивает пиковое
    // потребление памяти и приложение падает по OOM прямо в момент
    // выбора файла, до входа в try/catch ниже. Берём только путь и
    // читаем байты сами через dart:io — один буфер вместо двух.
    final file = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['apk'],
    );
    final path = file?.files.single.path;
    if (path == null) return;
    final buildNumber = int.tryParse(build.text);
    if (buildNumber == null) {
      _showError(l10n.buildNumberMustBeNumber);
      return;
    }
    setState(() => _updateBusy = true);
    try {
      final bytes = await File(path).readAsBytes();
      final update = await _updateService.publishAndroidApk(
        apkBytes: bytes,
        version: version.text,
        buildNumber: buildNumber,
        releaseNotes: notes.text,
      );
      if (mounted) {
        _showError(
          l10n.updatePublishedMessage(update.version, update.buildNumber),
        );
      }
    } catch (e) {
      if (mounted) _showError(l10n.updatePublishFailed(e));
    } finally {
      if (mounted) setState(() => _updateBusy = false);
    }
  }

  Future<void> _loadAvatar(AuthProvider auth) async {
    final key = auth.user?.avatarKey;
    if (key == null || key == _avatarKeyLoaded) return;
    final bytes = await auth.fetchAvatarBytes(key);
    if (!mounted) return;
    setState(() {
      _avatarBytes = bytes == null ? null : Uint8List.fromList(bytes);
      _avatarKeyLoaded = key;
    });
  }

  Future<void> _pickAvatar(AuthProvider auth) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      // Отдаём кропперу картинку покрупнее — сжимать/квадратить будем сами.
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
    if (cropped == null) return; // отменили кроп

    // Формат всегда фиксированный (PNG) — иначе при смене расширения
    // между загрузками в бакете остаются "осиротевшие" старые файлы,
    // т.к. ключ объекта строится из email + extension.
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
    if (!ok && auth.error != null) {
      _showError(auth.error!);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _openAccountSheet(UserAccount user) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        final auth = sheetContext.read<AuthProvider>();
        final l10n = AppStrings.current;
        return SafeArea(
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
                  leading: const Icon(Icons.badge_outlined),
                  title: Text(l10n.changeNickname),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openEditNicknameDialog(user);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.lock_outline_rounded),
                  title: Text(l10n.changePassword),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _openChangePasswordDialog();
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openEditNicknameDialog(UserAccount user) {
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
              final auth = context.read<AuthProvider>();
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

  void _openChangePasswordDialog() {
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
              final auth = context.read<AuthProvider>();
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

  void _openSoundCloudInfoSheet() {
    final soundcloud =
        widget.sources[MusicSourceType.soundcloud] as SoundCloudService?;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _SourceInfoSheet(
        icon: Icons.cloud_queue_rounded,
        title: 'SoundCloud',
        description: AppStrings.current.scDescription,
        fields: [
          _SourceInfoField(
            label: 'CLIENT ID',
            loader: () =>
                soundcloud?.clientIdForDisplay() ?? Future.value(null),
          ),
        ],
        onRefresh: soundcloud?.refreshClientIdForDisplay,
      ),
    );
  }

  void _openAudiomackInfoSheet() {
    final audiomack =
        widget.sources[MusicSourceType.audiomack] as AudiomackService?;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _SourceInfoSheet(
        icon: Icons.graphic_eq_rounded,
        title: 'Audiomack',
        description: AppStrings.current.amDescription,
        fields: [
          _SourceInfoField(
            label: 'API KEY',
            loader: () => Future.value(
              audiomack != null && audiomack.apiKey.isNotEmpty
                  ? audiomack.apiKey
                  : null,
            ),
          ),
          _SourceInfoField(
            label: 'API SECRET',
            loader: () => Future.value(
              audiomack != null && audiomack.apiSecret.isNotEmpty
                  ? audiomack.apiSecret
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  void _openYouTubeInfoSheet() {
    final resolver = YoutubeSessionResolver.instance;

    // Пустая строка (токен не пойман, но в SharedPreferences лежит '')
    // — то же самое, что «не задан».
    String? nonEmpty(String? v) => (v == null || v.isEmpty) ? null : v;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _SourceInfoSheet(
        icon: Icons.smart_display_rounded,
        title: 'YouTube',
        description: AppStrings.current.ytDescription,
        fields: [
          _SourceInfoField(
            label: 'PO TOKEN',
            loader: () async =>
                nonEmpty((await resolver.sessionForDisplay())?.poToken),
          ),
          _SourceInfoField(
            label: 'VISITOR DATA',
            loader: () async =>
                nonEmpty((await resolver.sessionForDisplay())?.visitorData),
          ),
        ],
        // Обновляет обе строки сразу, поэтому onRefreshAll, а не onRefresh
        // (тот обновляет только первое поле — как client_id у SoundCloud).
        onRefreshAll: () async => (await resolver.refreshSession()) != null,
      ),
    );
  }

  void _openVkLoginSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => const VkLoginSheet(),
    );
  }

  void _openAboutSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => const _AboutSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final language = l10n.language;
    final auth = context.watch<AuthProvider>();
    final vkAuth = context.watch<VkAuthProvider>();
    final user = auth.user;
    final isDeveloper = _isDeveloper(user);
    final themeMode = context.watch<ThemeProvider>().mode;
    final audioQuality = context.watch<AudioQualityProvider>().quality;
    // select, а не watch — см. пояснение в library_screen.dart: иначе
    // весь экран настроек перестраивался бы на каждый тик позиции
    // воспроизведения.
    final hasMiniPlayer = context.select<PlayerProvider, bool>(
      (p) => p.currentTrack != null,
    );
    final cachedTracks = context.watch<CachedTracksProvider>();
    final bottomInset = AppLayout.reservedBottomSpace(
      hasMiniPlayer: hasMiniPlayer,
    );

    if (user != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadAvatar(auth));
    }

    return SafeArea(
      child: ListView(
        padding: EdgeInsets.fromLTRB(20, 24, 20, bottomInset),
        physics: BouncingScrollPhysics(),
        children: [
          Row(
            children: [
              if (widget.showBackButton) ...[
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back_rounded),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  l10n.settingsTitle,
                  style: Theme.of(context).textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          SizedBox(height: 24),
          if (user != null) ...[
            _SectionTitle(l10n.sectionAccount),
            _AccountTile(
              user: user,
              avatarBytes: _avatarBytes,
              uploading: _avatarUploading,
              isDeveloper: isDeveloper,
              onTap: () => _openAccountSheet(user),
            ),
            Container(
              margin: EdgeInsets.only(bottom: 10),
              child: OutlinedButton.icon(
                onPressed: () => context.read<AuthProvider>().logout(),
                icon: Icon(Icons.logout_rounded, size: 18),
                label: Text(l10n.logOutAccount),
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
            const SizedBox(height: 14),
          ],
          _SectionTitle(l10n.sectionTheme),
          _ThemeTile(
            icon: Icons.dark_mode_rounded,
            title: l10n.themeStandard,
            subtitle: l10n.themeStandardSub,
            selected: themeMode == AppThemeMode.dark,
            onTap: () =>
                context.read<ThemeProvider>().setMode(AppThemeMode.dark),
          ),
          _ThemeTile(
            icon: Icons.light_mode_rounded,
            title: l10n.themeLight,
            subtitle: l10n.themeLightSub,
            selected: themeMode == AppThemeMode.light,
            onTap: () =>
                context.read<ThemeProvider>().setMode(AppThemeMode.light),
          ),
          const SizedBox(height: 24),
          _SectionTitle(l10n.sectionLanguage),
          _ThemeTile(
            icon: Icons.translate_rounded,
            title: l10n.languageRu,
            subtitle: l10n.languageRuSub,
            selected: language == AppLanguage.ru,
            onTap: () =>
                context.read<LanguageProvider>().setLanguage(AppLanguage.ru),
          ),
          _ThemeTile(
            icon: Icons.language_rounded,
            title: l10n.languageEn,
            subtitle: l10n.languageEnSub,
            selected: language == AppLanguage.en,
            onTap: () =>
                context.read<LanguageProvider>().setLanguage(AppLanguage.en),
          ),
          const SizedBox(height: 24),
          _SectionTitle(l10n.sectionSources),
          _SettingsTile(
            icon: Icons.cloud_queue_rounded,
            title: 'SoundCloud',
            subtitle: l10n.scConnected,
            onTap: _openSoundCloudInfoSheet,
          ),
          _SettingsTile(
            icon: Icons.graphic_eq_rounded,
            title: 'Audiomack',
            subtitle: l10n.amConnected,
            onTap: _openAudiomackInfoSheet,
          ),
          _SettingsTile(
            icon: Icons.smart_display_rounded,
            title: 'YouTube',
            subtitle: l10n.ytConnected,
            onTap: _openYouTubeInfoSheet,
          ),
          _SettingsTile(
            icon: Icons.groups_rounded,
            title: 'VK',
            subtitle: vkAuth.isLoggedIn
                ? l10n.vkLoggedInShort
                : l10n.vkNotConnected,
            onTap: _openVkLoginSheet,
          ),
          const SizedBox(height: 24),
          _SectionTitle(l10n.sectionPlayback),
          _ThemeTile(
            icon: Icons.high_quality_rounded,
            title: l10n.qualityHigh,
            subtitle: l10n.qualityHighSub,
            selected: audioQuality == AudioQuality.high,
            onTap: () => context.read<AudioQualityProvider>().setQuality(
              AudioQuality.high,
            ),
          ),
          _ThemeTile(
            icon: Icons.data_saver_on_rounded,
            title: l10n.qualityDataSaver,
            subtitle: l10n.qualityDataSaverSub,
            selected: audioQuality == AudioQuality.dataSaver,
            onTap: () => context.read<AudioQualityProvider>().setQuality(
              AudioQuality.dataSaver,
            ),
          ),
          _SettingsTile(
            icon: Icons.download_for_offline_rounded,
            title: l10n.cacheOffline,
            subtitle: cachedTracks.isLoaded
                ? '${l10n.tracksCount(cachedTracks.count)} · '
                      '${formatBytes(cachedTracks.totalSizeBytes)}'
                : l10n.loading,
            onTap: () => showCacheSettingsSheet(context),
          ),
          const SizedBox(height: 24),
          _SectionTitle(l10n.sectionUpdates),
          _SettingsTile(
            icon: Icons.system_update_rounded,
            title: l10n.checkForUpdates,
            subtitle: _updateBusy
                ? l10n.updateInProgress
                : l10n.getLatestFromCloud,
            onTap: _updateBusy ? null : _checkForUpdate,
          ),
          if (isDeveloper)
            _SettingsTile(
              icon: Icons.publish_rounded,
              title: l10n.publishUpdate,
              subtitle: l10n.uploadApkForAllUsers,
              onTap: _updateBusy ? null : _publishUpdate,
            ),
          const SizedBox(height: 24),
          _SectionTitle(l10n.sectionAbout),
          _SettingsTile(
            icon: Icons.info_outline_rounded,
            title: l10n.version,
            subtitle: UpdateService.currentVersion,
            onTap: _openAboutSheet,
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _AccountTile extends StatelessWidget {
  const _AccountTile({
    required this.user,
    required this.avatarBytes,
    required this.uploading,
    required this.isDeveloper,
    required this.onTap,
  });

  final UserAccount user;
  final Uint8List? avatarBytes;
  final bool uploading;
  final bool isDeveloper;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Row(
              children: [
                Stack(
                  clipBehavior: Clip.none,
                  children: [
                    CircleAvatar(
                      radius: 22,
                      backgroundColor: AppColors.surfaceElevated,
                      backgroundImage: avatarBytes != null
                          ? MemoryImage(avatarBytes!)
                          : null,
                      child: avatarBytes == null
                          ? Icon(
                              Icons.person_rounded,
                              color: AppColors.textSecondary,
                            )
                          : null,
                    ),
                    if (uploading)
                      Positioned.fill(
                        child: CircleAvatar(
                          radius: 22,
                          backgroundColor: Colors.black45,
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          gradient: AppColors.accentGradient,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.surface,
                            width: 2,
                          ),
                        ),
                        child: Icon(
                          Icons.edit_rounded,
                          size: 11,
                          color: AppColors.onAccent,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        user.displayName.isEmpty
                            ? user.email
                            : user.displayName,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      SizedBox(height: 2),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              user.email,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: AppColors.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          if (isDeveloper) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.amber.withOpacity(.18),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                context.l10n.developerBadge,
                                style: TextStyle(
                                  color: Colors.amber,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: selected
            ? Border.all(color: AppColors.accentStart.withOpacity(0.6))
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: AppColors.accentGradient,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 18, color: AppColors.onAccent),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  color: selected
                      ? AppColors.accentStart
                      : AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: AppColors.accentGradient,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 18, color: AppColors.onAccent),
                ),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Шторка с информацией о текущей версии приложения — открывается тапом
/// по пункту "Версия" в разделе "О приложении". Значения версии и сборки
/// берутся из pubspec.yaml (version: 1.0.0+1) — при бампе версии перед
/// релизом их нужно обновить и здесь.
class _AboutSheet extends StatelessWidget {
  const _AboutSheet();

  static const _version = UpdateService.currentVersion;
  static const _buildNumber = '1';

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              l10n.sectionAbout,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 18),
            _AboutRow(label: l10n.version.toUpperCase(), value: _version),
            const SizedBox(height: 10),
            _AboutRow(
              label: l10n.buildLabel.toUpperCase(),
              value: _buildNumber,
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка "лейбл слева — значение справа" в [_AboutSheet], визуально
/// повторяет карточки полей в [_SourceInfoSheet], но без маскирования/
/// копирования — здесь нет секретных значений.
class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

/// Одно поле для показа в [_SourceInfoSheet] (например "CLIENT ID" или
/// "API KEY") вместе со способом его асинхронно получить — из памяти,
/// SharedPreferences или просто статического поля сервиса.
class _SourceInfoField {
  const _SourceInfoField({required this.label, required this.loader});

  final String label;
  final Future<String?> Function() loader;
}

/// Шторка с информацией об источнике музыки: описание того, откуда берётся
/// ключ/ID, сами значения (замаскированные по умолчанию, со скрытием и
/// копированием в буфер) и, если передан [onRefresh], кнопка ручного
/// обновления первого поля — используется для SoundCloud, где client_id
/// можно перепарсить заново прямо из настроек.
class _SourceInfoSheet extends StatefulWidget {
  const _SourceInfoSheet({
    required this.icon,
    required this.title,
    required this.description,
    required this.fields,
    this.onRefresh,
    this.onRefreshAll,
  });

  final IconData icon;
  final String title;
  final String description;
  final List<_SourceInfoField> fields;

  /// Обновляет ПЕРВОЕ поле и возвращает его новое значение (null — не
  /// удалось). Так работает SoundCloud: у него одно поле, client_id.
  final Future<String?> Function()? onRefresh;

  /// Для источников с несколькими полями (YouTube: po_token +
  /// visitor_data): обновляет всё разом и возвращает true при успехе;
  /// после него ВСЕ поля перечитываются своими loader'ами.
  final Future<bool> Function()? onRefreshAll;

  @override
  State<_SourceInfoSheet> createState() => _SourceInfoSheetState();
}

class _SourceInfoSheetState extends State<_SourceInfoSheet> {
  late final Map<String, String?> _values;
  late final Set<String> _loading;
  final Set<String> _revealed = {};
  bool _refreshing = false;

  @override
  void initState() {
    super.initState();
    _values = {for (final f in widget.fields) f.label: null};
    _loading = {for (final f in widget.fields) f.label};
    for (final field in widget.fields) {
      field.loader().then((value) {
        if (!mounted) return;
        setState(() {
          _values[field.label] = value;
          _loading.remove(field.label);
        });
      });
    }
  }

  Future<void> _refresh() async {
    final onRefresh = widget.onRefresh;
    final onRefreshAll = widget.onRefreshAll;
    if ((onRefresh == null && onRefreshAll == null) || widget.fields.isEmpty) {
      return;
    }
    setState(() => _refreshing = true);

    final bool ok;
    if (onRefreshAll != null) {
      ok = await onRefreshAll();
      if (!mounted) return;
      // Значения могли измениться в любом поле — перечитываем все.
      final loaded = await Future.wait(widget.fields.map((f) => f.loader()));
      if (!mounted) return;
      setState(() {
        _refreshing = false;
        for (var i = 0; i < widget.fields.length; i++) {
          _values[widget.fields[i].label] = loaded[i];
        }
      });
    } else {
      final result = await onRefresh!();
      if (!mounted) return;
      setState(() {
        _refreshing = false;
        _values[widget.fields.first.label] = result;
      });
      ok = result != null;
    }

    if (!ok) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(AppStrings.current.refreshFailed)));
    }
  }

  void _copy(String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(AppStrings.current.copied)));
  }

  String _mask(String value) {
    if (value.length <= 8) return '•' * value.length;
    final start = value.substring(0, 4);
    final end = value.substring(value.length - 4);
    return '$start${'•' * (value.length - 8)}$end';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 18),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    gradient: AppColors.accentGradient,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(widget.icon, size: 18, color: AppColors.onAccent),
                ),
                const SizedBox(width: 12),
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              widget.description,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            for (final field in widget.fields) ...[
              _buildFieldRow(field),
              const SizedBox(height: 10),
            ],
            if (widget.onRefresh != null || widget.onRefreshAll != null) ...[
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _refreshing ? null : _refresh,
                  icon: _refreshing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(_refreshing ? l10n.refreshing : l10n.refreshNow),
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
          ],
        ),
      ),
    );
  }

  Widget _buildFieldRow(_SourceInfoField field) {
    final l10n = context.l10n;
    final loading = _loading.contains(field.label);
    final value = _values[field.label];
    final revealed = _revealed.contains(field.label);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  field.label,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 3),
                if (loading)
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Text(
                    value == null
                        ? l10n.notSet
                        : (revealed ? value : _mask(value)),
                    style: TextStyle(
                      fontSize: 13,
                      fontFamily: 'monospace',
                      color: value == null
                          ? AppColors.textSecondary
                          : AppColors.textPrimary,
                    ),
                  ),
              ],
            ),
          ),
          if (!loading && value != null) ...[
            IconButton(
              icon: Icon(
                revealed
                    ? Icons.visibility_off_rounded
                    : Icons.visibility_rounded,
                size: 18,
                color: AppColors.textSecondary,
              ),
              onPressed: () => setState(() {
                if (revealed) {
                  _revealed.remove(field.label);
                } else {
                  _revealed.add(field.label);
                }
              }),
            ),
            IconButton(
              icon: Icon(
                Icons.copy_rounded,
                size: 18,
                color: AppColors.textSecondary,
              ),
              onPressed: () => _copy(value),
            ),
          ],
        ],
      ),
    );
  }
}
