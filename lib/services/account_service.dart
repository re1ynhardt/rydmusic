import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/yandex_config.dart';
import '../l10n/app_strings.dart';
import '../models/user_account.dart';
import 'yandex_s3_client.dart';

class AccountException implements Exception {
  AccountException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AccountService {
  AccountService({YandexS3Client? client})
      : _client = client ?? YandexS3Client();
  final YandexS3Client _client;

  static const _sessionKey = 'session_user_json';

  String _keyFor(String email) =>
      '${YandexConfig.usersPrefix}${YandexConfig.sanitizeEmail(email)}.json';

  String _sanitize(String email) => YandexConfig.sanitizeEmail(email);

  String _hash(String password, String salt) =>
      sha256.convert(utf8.encode('$salt:$password')).toString();

  String _newSalt() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(16, (_) => rnd.nextInt(256));
    return base64UrlEncode(bytes);
  }

  Future<UserAccount> register({
    required String email,
    required String password,
    required String displayName,
  }) async {
    if (email.trim().isEmpty || !email.contains('@')) {
      throw AccountException(AppStrings.current.enterValidEmail);
    }
    if (password.length < 6) {
      throw AccountException(AppStrings.current.passwordTooShort);
    }

    final key = _keyFor(email);
    final alreadyExists = await _client.exists(key);
    if (alreadyExists) {
      throw AccountException(AppStrings.current.accountExists);
    }

    final salt = _newSalt();
    final account = UserAccount(
      email: email.trim().toLowerCase(),
      displayName: displayName.trim().isEmpty ? email : displayName.trim(),
      passwordHash: _hash(password, salt),
      salt: salt,
      createdAt: DateTime.now(),
    );

    await _client.putObject(key, jsonEncode(account.toJson()));
    await _saveSession(account);
    return account;
  }

  Future<UserAccount> login({
    required String email,
    required String password,
  }) async {
    final key = _keyFor(email);
    final raw = await _client.getObject(key);
    if (raw == null) {
      throw AccountException(AppStrings.current.accountNotFound);
    }
    final account = UserAccount.fromJson(
        jsonDecode(raw) as Map<String, dynamic>);
    final hash = _hash(password, account.salt);
    if (hash != account.passwordHash) {
      throw AccountException(AppStrings.current.wrongPassword);
    }
    await _saveSession(account);
    return account;
  }

  /// Достаёт полную запись (с хэшем пароля) из хранилища — нужна для
  /// операций, требующих проверки текущего пароля или пересохранения
  /// всей записи (смена ника/пароля/аватарки), т.к. в сессии на устройстве
  /// хэш и соль не хранятся.
  Future<UserAccount> _fetchFull(String email) async {
    final raw = await _client.getObject(_keyFor(email));
    if (raw == null) {
      throw AccountException(AppStrings.current.accountNotFound);
    }
    return UserAccount.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Меняет никнейм (displayName).
  Future<UserAccount> updateDisplayName({
    required String email,
    required String displayName,
  }) async {
    if (displayName.trim().isEmpty) {
      throw AccountException(AppStrings.current.nicknameEmpty);
    }
    final full = await _fetchFull(email);
    final updated = full.copyWith(displayName: displayName.trim());
    await _client.putObject(_keyFor(email), jsonEncode(updated.toJson()));
    await _saveSession(updated);
    return updated;
  }

  /// Меняет пароль, предварительно проверяя текущий.
  Future<UserAccount> changePassword({
    required String email,
    required String currentPassword,
    required String newPassword,
  }) async {
    if (newPassword.length < 6) {
      throw AccountException(AppStrings.current.newPasswordTooShort);
    }
    final full = await _fetchFull(email);
    if (_hash(currentPassword, full.salt) != full.passwordHash) {
      throw AccountException(AppStrings.current.currentPasswordWrong);
    }
    final newSalt = _newSalt();
    final updated = full.copyWith(
      passwordHash: _hash(newPassword, newSalt),
      salt: newSalt,
    );
    await _client.putObject(_keyFor(email), jsonEncode(updated.toJson()));
    await _saveSession(updated);
    return updated;
  }

  /// Загружает аватарку (сырые байты изображения) и привязывает её к
  /// аккаунту.
  Future<UserAccount> uploadAvatar({
    required String email,
    required List<int> bytes,
    required String extension,
    required String contentType,
  }) async {
    final avatarKey = 'avatars/${_sanitize(email)}.$extension';
    await _client.putBytes(avatarKey, bytes, contentType);

    final full = await _fetchFull(email);
    final updated = full.copyWith(avatarKey: avatarKey);
    await _client.putObject(_keyFor(email), jsonEncode(updated.toJson()));
    await _saveSession(updated);
    return updated;
  }

  /// Загружает баннер профиля — та же логика, что и uploadAvatar, но
  /// под ключом banners/<email>.<ext>.
  Future<UserAccount> uploadBanner({
    required String email,
    required List<int> bytes,
    required String extension,
    required String contentType,
  }) async {
    final bannerKey = 'banners/${_sanitize(email)}.$extension';
    await _client.putBytes(bannerKey, bytes, contentType);

    final full = await _fetchFull(email);
    final updated = full.copyWith(bannerKey: bannerKey);
    await _client.putObject(_keyFor(email), jsonEncode(updated.toJson()));
    await _saveSession(updated);
    return updated;
  }

  /// Скачивает байты картинки (аватарки или баннера) по её ключу.
  Future<List<int>?> fetchAvatarBytes(String avatarKey) =>
      _client.getBytes(avatarKey);

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
  }

  /// Восстанавливает сохранённую локально сессию (без пароля — только
  /// публичные данные, чтобы не держать пароль на устройстве).
  Future<UserAccount?> restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sessionKey);
    if (raw == null) return null;
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return UserAccount(
      email: json['email'] as String,
      displayName: json['displayName'] as String? ?? '',
      passwordHash: '',
      salt: '',
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      avatarKey: json['avatarKey'] as String?,
      bannerKey: json['bannerKey'] as String?,
    );
  }

  Future<void> _saveSession(UserAccount account) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sessionKey, jsonEncode(account.toPublicJson()));
  }
}
