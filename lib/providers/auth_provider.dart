import 'package:flutter/foundation.dart';

import '../l10n/app_strings.dart';
import '../models/user_account.dart';
import '../services/account_service.dart';
import '../services/yandex_s3_client.dart';

class AuthProvider extends ChangeNotifier {
  AuthProvider({AccountService? service})
      : _service = service ?? AccountService() {
    _restore();
  }

  final AccountService _service;

  UserAccount? _user;
  bool _initializing = true;
  bool _loading = false;
  String? _error;

  UserAccount? get user => _user;
  bool get isLoggedIn => _user != null;
  // Только восстановление сессии при старте приложения — на время
  // действия (логин/регистрация) AuthGate НЕ должен сносить экран входа,
  // иначе теряются введённые данные и текст ошибки (см. loading).
  bool get initializing => _initializing;
  // Флаг конкретного действия (логин/регистрация/смена пароля и т.п.),
  // используется экраном для показа спиннера на кнопке — не влияет на
  // то, показан ли AuthGate вместо AuthScreen.
  bool get loading => _loading;
  String? get error => _error;

  Future<void> _restore() async {
    _user = await _service.restoreSession();
    _initializing = false;
    notifyListeners();
  }

  Future<bool> register({
    required String email,
    required String password,
    required String displayName,
  }) => _run(() => _service.register(
        email: email,
        password: password,
        displayName: displayName,
      ));

  Future<bool> login({
    required String email,
    required String password,
  }) => _run(() => _service.login(email: email, password: password));

  Future<bool> _run(Future<UserAccount> Function() action) async {
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      _user = await action();
      return true;
    } on AccountException catch (e) {
      _error = e.message;
      return false;
    } on S3Exception catch (e) {
      // Реальная причина от Yandex Object Storage (код ответа/тело) или
      // тип сетевого сбоя — показываем как есть, а не общей фразой,
      // иначе невозможно понять, что именно сломано (ключи/бакет/сеть).
      _error = e.message;
      return false;
    } catch (e) {
      _error = AppStrings.current.unexpectedError(e);
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    await _service.logout();
    _user = null;
    notifyListeners();
  }

  Future<bool> updateDisplayName(String displayName) => _run(() {
        final email = _user?.email;
        if (email == null) throw AccountException(AppStrings.current.noActiveSession);
        return _service.updateDisplayName(
          email: email,
          displayName: displayName,
        );
      });

  Future<bool> changePassword({
    required String currentPassword,
    required String newPassword,
  }) =>
      _run(() {
        final email = _user?.email;
        if (email == null) throw AccountException(AppStrings.current.noActiveSession);
        return _service.changePassword(
          email: email,
          currentPassword: currentPassword,
          newPassword: newPassword,
        );
      });

  Future<bool> updateAvatar({
    required List<int> bytes,
    required String extension,
    required String contentType,
  }) =>
      _run(() {
        final email = _user?.email;
        if (email == null) throw AccountException(AppStrings.current.noActiveSession);
        return _service.uploadAvatar(
          email: email,
          bytes: bytes,
          extension: extension,
          contentType: contentType,
        );
      });

  Future<bool> updateBanner({
    required List<int> bytes,
    required String extension,
    required String contentType,
  }) =>
      _run(() {
        final email = _user?.email;
        if (email == null) throw AccountException(AppStrings.current.noActiveSession);
        return _service.uploadBanner(
          email: email,
          bytes: bytes,
          extension: extension,
          contentType: contentType,
        );
      });

  Future<List<int>?> fetchAvatarBytes(String avatarKey) =>
      _service.fetchAvatarBytes(avatarKey);
}
