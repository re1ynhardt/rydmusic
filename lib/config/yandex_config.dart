/// Настройки Yandex Object Storage для хранения аккаунтов.
///
/// ⚠️ Ключи вшиты прямо в приложение (как и просили — без отдельного
/// бэкенда). Это значит, что при желании их можно вытащить из APK/IPA
/// и работать с бакетом от имени приложения. Для реального продакшена
/// так делать не рекомендуется, но раз бэкенда нет — это неизбежный
/// компромисс архитектуры.
///
/// Можно либо вписать значения ниже напрямую, либо передавать их при
/// сборке: flutter run --dart-define=YC_ACCESS_KEY_ID=... и т.д.
class YandexConfig {
  static const String accessKeyId = String.fromEnvironment(
    'YC_ACCESS_KEY_ID',
    defaultValue: 'YCAJE0POvQbcWw9VSrNflht9s',
  );
  static const String secretAccessKey = String.fromEnvironment(
    'YC_SECRET_ACCESS_KEY',
    defaultValue: 'YCMtrMWWbFX6UB-_dO4VuNa2cAnIBZJvemoAkWic',
  );
  static const String bucket = String.fromEnvironment(
    'YC_BUCKET',
    defaultValue: 'rydmusicinfo',
  );

  static const String region = 'ru-central1';
  static const String endpoint = 'storage.yandexcloud.net';

  /// Префикс, под которым лежат JSON-файлы аккаунтов: users/<email>.json
  static const String usersPrefix = 'users/';

  /// Библиотека пользователя (избранное/плейлисты) — раньше жила только
  /// локально на устройстве (SharedPreferences), из-за чего терялась при
  /// переустановке/смене устройства и не различала разных пользователей
  /// одного устройства. Теперь она лежит в объектном хранилище под этими
  /// префиксами, по одному JSON-файлу на пользователя.
  static const String favoritesPrefix = 'library/favorites/';
  static const String playlistsPrefix = 'library/playlists/';

  /// Обложки плейлистов (как и аватарки) — тоже в хранилище, а не на диске
  /// устройства, чтобы отображались на любом устройстве после входа.
  static const String playlistCoversPrefix = 'covers/playlists/';

  /// Канал обновлений Android: APK-файлы и updates/android/latest.json.
  static const String updatesPrefix = 'updates/';

  /// Общий способ превратить e-mail в безопасное имя объекта — используется
  /// и для аккаунтов, и для библиотеки, и для обложек, чтобы один и тот же
  /// пользователь везде адресовался одинаковым ключом.
  static String sanitizeEmail(String email) =>
      email.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9@._-]'), '_');
}
