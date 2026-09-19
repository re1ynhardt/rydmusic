/// Язык интерфейса приложения.
enum AppLanguage {
  ru,
  en;

  /// Код для сохранения в SharedPreferences.
  String get code => name;

  static AppLanguage fromCode(String? code) =>
      code == 'en' ? AppLanguage.en : AppLanguage.ru;
}

/// Все тексты интерфейса на двух языках (русский / английский).
///
/// Осознанно БЕЗ flutter_localizations/intl/ARB и кодогенерации: строк
/// немного, а такой подход не требует ни новых зависимостей, ни
/// `flutter gen-l10n`. Каждый текст — геттер или метод, который сам
/// выбирает нужный вариант через [_t].
///
/// Как пользоваться:
///  * в `build()` виджетов — `context.l10n` (см. language_provider.dart):
///    он подписывает виджет на смену языка, и экран перерисовывается
///    сразу после переключения в настройках;
///  * в коде без BuildContext (провайдеры, сервисы) и в колбэках/диалогах,
///    которые строятся «по нажатию», — [AppStrings.current].
///
/// Чтобы добавить новый текст, заведите здесь геттер с двумя вариантами.
class AppStrings {
  const AppStrings(this.language);

  final AppLanguage language;

  /// Текущий язык для кода без контекста. Выставляется в
  /// LanguageProvider (при загрузке и при каждой смене языка).
  static AppStrings current = const AppStrings(AppLanguage.ru);

  bool get _en => language == AppLanguage.en;
  String _t(String ru, String en) => _en ? en : ru;

  // ─── Общее ─────────────────────────────────────────────────────────
  String get cancel => _t('Отмена', 'Cancel');
  String get save => _t('Сохранить', 'Save');
  String get delete => _t('Удалить', 'Delete');
  String get create => _t('Создать', 'Create');
  String get done => _t('Готово', 'Done');
  String get confirm => _t('Подтвердить', 'Confirm');
  String get copied => _t('Скопировано', 'Copied');
  String get loading => _t('Загрузка…', 'Loading…');
  String get logIn => _t('Войти', 'Log in');
  String get logOut => _t('Выйти', 'Log out');
  String get password => _t('Пароль', 'Password');

  /// «12 треков» / «1 track» — с правильным склонением.
  String tracksCount(int n) {
    if (_en) return n == 1 ? '1 track' : '$n tracks';
    final mod100 = n % 100;
    if (mod100 >= 11 && mod100 <= 14) return '$n треков';
    switch (n % 10) {
      case 1:
        return '$n трек';
      case 2:
      case 3:
      case 4:
        return '$n трека';
      default:
        return '$n треков';
    }
  }

  // ─── Нижняя навигация ──────────────────────────────────────────────
  String get navHome => _t('Главная', 'Home');
  String get navSearch => _t('Поиск', 'Search');
  String get navLibrary => _t('Библиотека', 'Library');
  String get navProfile => _t('Профиль', 'Profile');
  String get navSettings => _t('Настройки', 'Settings');

  // ─── Вход / регистрация ────────────────────────────────────────────
  String get authCreateAccount => _t('Создать аккаунт', 'Create account');
  String get authWelcomeBack => _t('С возвращением', 'Welcome back');
  String get authRegisterHint => _t(
      'Аккаунт хранится в вашем облачном хранилище',
      'Your account is stored in your own cloud storage');
  String get authLoginHint =>
      _t('Войдите, чтобы продолжить', 'Log in to continue');
  String get nameLabel => _t('Имя', 'Name');
  String get signUp => _t('Зарегистрироваться', 'Sign up');
  String get authHaveAccount =>
      _t('Уже есть аккаунт? Войти', 'Already have an account? Log in');
  String get authNoAccount => _t(
      'Нет аккаунта? Зарегистрироваться', 'Don’t have an account? Sign up');

  // ─── Ошибки аккаунта ───────────────────────────────────────────────
  String unexpectedError(Object e) =>
      _t('Непредвиденная ошибка: $e', 'Unexpected error: $e');
  String get noActiveSession => _t('Нет активной сессии', 'No active session');
  String get enterValidEmail =>
      _t('Введите корректный e-mail', 'Enter a valid e-mail');
  String get passwordTooShort => _t('Пароль должен быть не короче 6 символов',
      'Password must be at least 6 characters');
  String get accountExists => _t('Аккаунт с таким e-mail уже существует',
      'An account with this e-mail already exists');
  String get accountNotFound => _t('Аккаунт не найден', 'Account not found');
  String get wrongPassword => _t('Неверный пароль', 'Wrong password');
  String get nicknameEmpty =>
      _t('Никнейм не может быть пустым', 'Nickname cannot be empty');
  String get newPasswordTooShort => _t(
      'Новый пароль должен быть не короче 6 символов',
      'New password must be at least 6 characters');
  String get currentPasswordWrong =>
      _t('Текущий пароль указан неверно', 'Current password is incorrect');
  String networkError(Object type, Object? message) =>
      _t('Сеть: $type — $message', 'Network: $type — $message');

  // ─── Ошибки VK ─────────────────────────────────────────────────────
  String get vkEnterCredentials =>
      _t('Введите логин и пароль', 'Enter your login and password');
  String get vkAuthError => _t('Ошибка авторизации VK', 'VK authorization error');
  String get vkEmptyResponse => _t('Пустой ответ от VK', 'Empty response from VK');
  String get vkLoginFailed =>
      _t('Не удалось войти в VK', 'Could not log in to VK');

  // ─── Воспроизведение ───────────────────────────────────────────────
  String trackUnavailable(String title) => _t(
      'Трек «$title» недоступен для стриминга (ограничение источника).',
      'Track “$title” can’t be streamed (source restriction).');
  String trackUnavailableShort(String title) => _t(
      '«$title» недоступен для стриминга (ограничение источника).',
      '“$title” can’t be streamed (source restriction).');
  String playbackFailedSkipped(String title) => _t(
      'Не удалось воспроизвести «$title» — трек пропущен.',
      'Couldn’t play “$title” — track skipped.');
  String get playbackError => _t('Ошибка воспроизведения.', 'Playback error.');
  String get untitled => _t('Без названия', 'Untitled');
  String get unknownArtist => _t('Неизвестный исполнитель', 'Unknown artist');
  String get unavailableSuffix => _t('недоступно', 'unavailable');

  // ─── Главная ───────────────────────────────────────────────────────
  String get today => _t('Сегодня', 'Today');
  String get recentlyPlayed => _t('Недавно прослушанные', 'Recently played');
  String get homeLoadFailed => _t(
      'Не удалось загрузить подборку.\nПроверьте ключи API и подключение.',
      'Couldn’t load the feed.\nCheck your API keys and connection.');
  String get recommendedForYou => _t('Рекомендуем вам', 'Recommended for you');
  String get recommendedSubtitle => _t(
      'На основе вашего избранного', 'Based on your favorites');

  // ─── Поиск ─────────────────────────────────────────────────────────
  String get searchHint =>
      _t('Артисты, треки, плейлисты', 'Artists, tracks, playlists');
  String get searchPrompt => _t('Введите запрос и нажмите «Поиск» на клавиатуре',
      'Type a query and press “Search” on the keyboard');
  String get nothingFound => _t('Ничего не найдено', 'Nothing found');
  String get searchEnd =>
      _t('Это все треки по запросу', 'That’s all the tracks for this query');
  String get recent => _t('Недавние', 'Recent');
  String get clear => _t('Очистить', 'Clear');

  // ─── Библиотека ────────────────────────────────────────────────────
  String get libraryTabMusic => _t('Музыка', 'Music');
  String get libraryTabCached => _t('Кэшированные', 'Cached');
  String get emptyFavorites => _t(
      'Здесь появятся треки, которые вы добавите в избранное',
      'Tracks you add to favorites will appear here');
  String get emptyCached => _t(
      'Здесь появятся треки, скачанные для прослушивания офлайн',
      'Tracks downloaded for offline listening will appear here');

  // ─── Экран «Сейчас играет» ─────────────────────────────────────────
  String get sourceLocal => _t('Локально', 'Local');
  String get copiedToClipboard =>
      _t('Скопировано в буфер обмена', 'Copied to clipboard');
  String get removeFromFavorites =>
      _t('Убрать из избранного', 'Remove from favorites');
  String get addToFavorites => _t('Добавить в избранное', 'Add to favorites');
  String sourceLabel(String source) => _t('Источник: $source', 'Source: $source');
  String get nothingPlaying => _t('Ничего не играет', 'Nothing is playing');
  String get artistAlbums => _t('Альбомы', 'Albums');
  String get artistTracks => _t('Треки', 'Tracks');
  String get artistLoadFailed =>
      _t('Не удалось загрузить исполнителя', 'Could not load the artist');
  String get artistNothingFound => _t('Ничего не найдено', 'Nothing found');

  /// «12 релизов» / «1 release» — с правильным склонением.
  String releasesCount(int n) {
    if (_en) return n == 1 ? '1 release' : '$n releases';
    final mod100 = n % 100;
    if (mod100 >= 11 && mod100 <= 14) return '$n релизов';
    switch (n % 10) {
      case 1:
        return '$n релиз';
      case 2:
      case 3:
      case 4:
        return '$n релиза';
      default:
        return '$n релизов';
    }
  }

  String get artistPlayAll => _t('Слушать', 'Play');
  String get artistShuffle => _t('Перемешать', 'Shuffle');
  String get swipeForArtistHint =>
      _t('Смахните к исполнителю', 'Swipe for the artist');
  String get retry => _t('Повторить', 'Retry');
  String get pause => _t('Пауза', 'Pause');
  String get play => _t('Играть', 'Play');
  String queueTitle(int n) => _t('Очередь · $n', 'Queue · $n');
  String get lyricsLoadFailed =>
      _t('Не удалось загрузить. Повторить', 'Couldn’t load. Retry');
  String get lyricsNotFound => _t('Текст не найден', 'Lyrics not found');

  // ─── Плейлисты ─────────────────────────────────────────────────────
  String get playlistEmpty => _t(
      'В плейлисте пока нет треков.\nДобавляйте их кнопкой ⊕ рядом с треком.',
      'This playlist has no tracks yet.\nAdd them with the ⊕ button next to a track.');
  String get addToPlaylist => _t('Добавить в плейлист', 'Add to playlist');
  String get newPlaylist => _t('Новый плейлист', 'New playlist');
  String get noPlaylistsYet => _t('Пока нет плейлистов — создайте первый выше',
      'No playlists yet — create the first one above');
  String get playlistNameHint => _t('Название плейлиста', 'Playlist name');
  String get rename => _t('Переименовать', 'Rename');
  String get changeCover => _t('Сменить обложку', 'Change cover');
  String get deletePlaylist => _t('Удалить плейлист', 'Delete playlist');
  String get renamePlaylist => _t('Переименовать плейлист', 'Rename playlist');
  String get deletePlaylistQuestion =>
      _t('Удалить плейлист?', 'Delete playlist?');
  String get deletePlaylistBody => _t(
      'Треки останутся в избранном, если были там добавлены. Это действие нельзя отменить.',
      'Tracks will stay in your favorites if they were added there. This can’t be undone.');

  // ─── Аватарка ──────────────────────────────────────────────────────
  String get cropAvatarTitle => _t('Обрезка аватарки', 'Crop avatar');

  // ─── Профиль ───────────────────────────────────────────────────────
  String get profileTitle => _t('Профиль', 'Profile');
  String get changeBanner => _t('Изменить баннер', 'Change banner');
  String get cropBannerTitle => _t('Обрезка баннера', 'Crop banner');
  String get editProfile => _t('Редактировать профиль', 'Edit profile');
  String get profileFavoritesTitle => _t('Избранное', 'Favorites');
  String get profilePlaylistsTitle => _t('Плейлисты', 'Playlists');
  String get profileCachedStat => _t('Кэш', 'Cached');
  String get profileGoTo => _t('Все', 'See all');
  String get profileEmptyPlaylists =>
      _t('Плейлистов пока нет', 'No playlists yet');
  String get profileNoNickname => _t('Без никнейма', 'No nickname');
  String get openSettings => _t('Открыть настройки', 'Open settings');

  // ─── Настройки ─────────────────────────────────────────────────────
  String get settingsTitle => _t('Настройки', 'Settings');
  String get sectionAccount => _t('Аккаунт', 'Account');
  String get logOutAccount => _t('Выйти из аккаунта', 'Log out of account');
  String get changeAvatar => _t('Изменить аватарку', 'Change avatar');
  String get changeNickname => _t('Изменить никнейм', 'Change nickname');
  String get changePassword => _t('Сменить пароль', 'Change password');
  String get nickname => _t('Никнейм', 'Nickname');
  String get enterNickname => _t('Введите никнейм', 'Enter a nickname');
  String get passwordChangeTitle => _t('Смена пароля', 'Change password');
  String get currentPassword => _t('Текущий пароль', 'Current password');
  String get newPassword => _t('Новый пароль', 'New password');

  String get sectionTheme => _t('Тема', 'Theme');
  String get themeStandard => _t('Стандартная', 'Standard');
  String get themeStandardSub =>
      _t('Чёрный фон, белые акценты', 'Black background, white accents');
  String get themeLight => _t('Белая', 'Light');
  String get themeLightSub =>
      _t('Светлый фон, тёмный текст', 'Light background, dark text');

  String get sectionLanguage => _t('Язык', 'Language');
  // Названия языков всегда на своём языке — так их находят, даже если
  // интерфейс случайно переключён на непонятный.
  String get languageRu => 'Русский';
  String get languageRuSub => 'Интерфейс на русском языке';
  String get languageEn => 'English';
  String get languageEnSub => 'Interface in English';

  String get sectionSources => _t('Источники музыки', 'Music sources');
  String get scConnected => _t('Client ID подключён', 'Client ID connected');
  String get amConnected => _t('API-ключ подключён', 'API key connected');
  String get ytConnected => _t('yt-dlp подключён', 'yt-dlp connected');
  String get vkLoggedInShort => _t('Вы вошли', 'Logged in');
  String get vkNotConnected => _t('Не подключён — войдите, чтобы искать',
      'Not connected — log in to search');

  String get sectionPlayback => _t('Воспроизведение', 'Playback');
  String get qualityHigh => _t('Высокое качество', 'High quality');
  String get qualityHighSub => _t('Лучший доступный битрейт, больше трафика',
      'Best available bitrate, more data usage');
  String get qualityDataSaver => _t('Экономия трафика', 'Data saver');
  String get qualityDataSaverSub => _t(
      'Меньше данных, ниже качество на слабой сети',
      'Less data, lower quality on a weak network');
  String get cacheOffline => _t('Кэш и офлайн', 'Cache & offline');

  String get sectionAbout => _t('О приложении', 'About');
  String get version => _t('Версия', 'Version');
  String get buildLabel => _t('Сборка', 'Build');

  // ─── Обновления ────────────────────────────────────────────────────
  String get sectionUpdates => _t('Обновления', 'Updates');
  String get checkForUpdates => _t('Проверить обновления', 'Check for updates');
  String get updateInProgress => _t('Выполняется…', 'In progress…');
  String get getLatestFromCloud => _t(
      'Получить последнюю версию из Yandex Cloud',
      'Get the latest version from Yandex Cloud');
  String get publishUpdate => _t('Опубликовать обновление', 'Publish update');
  String get uploadApkForAllUsers => _t(
      'Загрузить APK в Yandex Cloud для всех пользователей',
      'Upload the APK to Yandex Cloud for all users');
  String get upToDateVersion =>
      _t('У вас установлена актуальная версия.', 'You already have the latest version.');
  String updateAvailableTitle(String version, int buildNumber) => _t(
      'Доступно обновление $version+$buildNumber',
      'Update $version+$buildNumber available');
  String get updateReadyToInstall =>
      _t('Новая версия готова к установке.', 'The new version is ready to install.');
  String get later => _t('Позже', 'Later');
  String get downloadAndInstall =>
      _t('Скачать и установить', 'Download and install');
  String updateInstallFailed(Object e) =>
      _t('Не удалось установить обновление: $e', 'Couldn’t install the update: $e');
  String updateCheckFailed(Object e) => _t(
      'Не удалось проверить обновления: $e', 'Couldn’t check for updates: $e');
  String get publishAndroidUpdateTitle =>
      _t('Опубликовать обновление Android', 'Publish Android update');
  String get versionFieldHint =>
      _t('Версия (например, 2.0.2)', 'Version (e.g. 2.0.2)');
  String get buildNumberLabel => _t('Номер сборки', 'Build number');
  String get whatChangedLabel => _t('Что изменилось', 'What changed');
  String get selectApk => _t('Выбрать APK', 'Select APK');
  String get buildNumberMustBeNumber =>
      _t('Номер сборки должен быть числом.', 'Build number must be a number.');
  String updatePublishedMessage(String version, int buildNumber) => _t(
      'Обновление $version+$buildNumber опубликовано.',
      'Update $version+$buildNumber published.');
  String updatePublishFailed(Object e) => _t(
      'Не удалось опубликовать обновление: $e',
      'Couldn’t publish the update: $e');
  String get developerBadge => _t('РАЗРАБОТЧИК', 'DEVELOPER');
  String get androidOnlyAutoUpdate => _t(
      'Автообновление APK доступно только на Android',
      'Automatic APK updates are only available on Android');
  String get updateFileNotFoundInCloud =>
      _t('Файл обновления не найден в облаке', 'Update file not found in the cloud');
  String get versionFormatError =>
      _t('Версия должна иметь вид 2.0.2', 'Version must look like 2.0.2');
  String get buildNumberMustBePositive => _t(
      'Номер сборки должен быть больше нуля', 'Build number must be greater than zero');
  String get emptyApkSelected =>
      _t('Выбран пустой APK-файл', 'The selected APK file is empty');

  // ─── Шторки источников (SoundCloud / Audiomack / YouTube) ──────────
  String get notSet => _t('Не задан', 'Not set');
  String get refreshNow => _t('Обновить сейчас', 'Refresh now');
  String get refreshing => _t('Обновляем…', 'Refreshing…');
  String get refreshFailed => _t(
      'Не удалось обновить — нет сети или источник изменился',
      'Couldn’t refresh — no connection or the source has changed');

  String get scDescription => _t(
      'Client ID добывается автоматически — приложение '
          'парсит веб-плеер soundcloud.com и достаёт ключ, которым '
          'пользуется он сам. Способ неофициальный: если SoundCloud '
          'обновит свои бандлы, ключ протухнет — тогда приложение само '
          'перезапросит новый при следующем обращении, либо это можно '
          'сделать вручную кнопкой ниже.',
      'The Client ID is obtained automatically — the app parses the '
          'soundcloud.com web player and extracts the key it uses itself. '
          'This is unofficial: if SoundCloud updates its bundles, the key '
          'will expire — the app will then request a new one on the next '
          'request, or you can do it manually with the button below.');

  String get amDescription => _t(
      'API key и API secret задаются при сборке приложения '
          'через --dart-define=AUDIOMACK_API_KEY=... и '
          '--dart-define=AUDIOMACK_API_SECRET=... (см. README.md). '
          'Поменять их из самого приложения нельзя — только пересобрать '
          'с новыми значениями.',
      'The API key and API secret are set when the app is built via '
          '--dart-define=AUDIOMACK_API_KEY=... and '
          '--dart-define=AUDIOMACK_API_SECRET=... (see README.md). '
          'They can’t be changed from within the app — only by rebuilding '
          'with new values.');

  String get ytDescription => _t(
      'Поиск идёт через каталог YouTube Music, а сам поток достаёт yt-dlp, '
          'вшитый в приложение. Чтобы YouTube не принимал запросы за бота, '
          'приложение само берёт po_token и visitor_data: скрытый WebView '
          'открывает youtube.com и подсматривает их у настоящей страницы. '
          'Токены живут несколько часов и обновляются автоматически; если '
          'треки перестали играть — обновите их вручную кнопкой ниже.',
      'Search goes through the YouTube Music catalog, and the stream itself '
          'is extracted by yt-dlp, which is bundled into the app. So that '
          'YouTube doesn’t treat requests as a bot, the app gets po_token '
          'and visitor_data on its own: a hidden WebView opens youtube.com '
          'and picks them up from the real page. The tokens last a few hours '
          'and refresh automatically; if tracks stop playing, refresh them '
          'manually with the button below.');

  // ─── Кэш и офлайн ──────────────────────────────────────────────────
  List<String> get byteUnits => _en
      ? const ['B', 'KB', 'MB', 'GB']
      : const ['Б', 'КБ', 'МБ', 'ГБ'];
  String get deleteCacheQuestion =>
      _t('Удалить весь кэш?', 'Delete all cache?');
  String get deleteCacheBody => _t(
      'Все скачанные треки будут удалены с устройства. Слушать их'
          ' офлайн больше не получится, пока не скачаете заново.'
          ' Это действие нельзя отменить.',
      'All downloaded tracks will be removed from your device. You won’t be'
          ' able to listen to them offline until you download them again.'
          ' This can’t be undone.');
  String get cacheTracks => _t('Треков в кэше', 'Tracks in cache');
  String get cacheSpaceUsed => _t('Занято места', 'Space used');
  String get deleting => _t('Удаляем…', 'Deleting…');
  String get deleteAllCache => _t('Удалить весь кэш', 'Delete all cache');
  String get cacheEmpty => _t('Кэш пуст — скачанных треков пока нет.',
      'Cache is empty — no downloaded tracks yet.');

  // ─── Вход в VK ─────────────────────────────────────────────────────
  String vkLoggedInWithId(Object id) =>
      _t('Вы вошли (ID $id)', 'Logged in (ID $id)');
  String get vkLoggedInLong => _t('Вы вошли в VK', 'Logged in to VK');
  String get vkLoginInfo => _t(
      'Вход выполняется как в официальном приложении Kate Mobile — '
          'это единственный способ получить доступ к поиску по VK, '
          'т.к. официальный audio.search закрыт для сторонних '
          'приложений. Логин и пароль никуда, кроме VK, не уходят.',
      'Login works the same way as in the official Kate Mobile app — '
          'it’s the only way to get access to VK search, since the '
          'official audio.search is closed to third-party apps. Your '
          'login and password are sent nowhere except VK.');
  String get vkLoginLabel =>
      _t('Логин, e-mail или телефон', 'Login, e-mail or phone');
  String vkSmsSentTo(String mask) =>
      _t('VK отправил код по SMS на $mask', 'VK sent an SMS code to $mask');
  String get vkSmsRequested =>
      _t('VK запросил код подтверждения (SMS)', 'VK requested a confirmation code (SMS)');
  String get vkSmsCodeLabel => _t('Код из SMS', 'SMS code');
  String get vkCaptchaPrompt => _t('VK попросил ввести текст с картинки',
      'VK asked you to enter the text from the image');
  String get vkCaptchaLabel => _t('Текст с картинки', 'Text from image');
}
