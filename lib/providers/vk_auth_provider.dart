import 'package:flutter/foundation.dart';

import '../l10n/app_strings.dart';
import '../services/vk_auth_bridge.dart';

/// Состояние логина VK для settings screen. Держит промежуточные шаги
/// (капча / код по SMS) отдельно от финальной ошибки, чтобы экран мог
/// показать нужное поле вместо просто текста ошибки.
class VkAuthProvider extends ChangeNotifier {
  VkAuthProvider() {
    _restore();
  }

  bool _initializing = true;
  bool _loading = false;
  String? _token;
  String? _userAgent;
  int? _userId;
  String? _error;
  VkAuthChallenge? _challenge;

  // Логин/пароль держим в памяти только на время прохождения
  // капчи/2FA — VK требует присылать их заново с каждым повторным
  // запросом (см. vk_auth_bridge.py). На диск не сохраняются.
  String? _pendingUsername;
  String? _pendingPassword;

  bool get initializing => _initializing;
  bool get loading => _loading;
  bool get isLoggedIn => _token != null;
  int? get userId => _userId;
  String? get error => _error;
  VkAuthChallenge? get challenge => _challenge;

  Future<void> _restore() async {
    _token = await VkAuthStorage.getToken();
    _userAgent = await VkAuthStorage.getUserAgent();
    _userId = await VkAuthStorage.getUserId();
    _initializing = false;
    notifyListeners();
  }

  Future<bool> login({required String username, required String password}) {
    _pendingUsername = username;
    _pendingPassword = password;
    return _attempt();
  }

  /// Повтор после того, как пользователь ввёл код из SMS.
  Future<bool> submitSmsCode(String code) => _attempt(authCode: code);

  /// Повтор после того, как пользователь ввёл текст с картинки капчи.
  Future<bool> submitCaptcha(String captchaKey) => _attempt(
        captchaSid: _challenge?.captchaSid,
        captchaKey: captchaKey,
      );

  Future<bool> _attempt({
    String? authCode,
    String? captchaSid,
    String? captchaKey,
  }) async {
    final username = _pendingUsername;
    final password = _pendingPassword;
    if (username == null || password == null) {
      _error = AppStrings.current.vkEnterCredentials;
      notifyListeners();
      return false;
    }

    _loading = true;
    _error = null;
    _challenge = null;
    notifyListeners();

    try {
      final result = await VkAuthBridge.login(
        username: username,
        password: password,
        authCode: authCode,
        captchaSid: captchaSid,
        captchaKey: captchaKey,
      );
      await VkAuthStorage.save(result);
      _token = result.token;
      _userAgent = result.userAgent;
      _userId = result.userId;
      _pendingUsername = null;
      _pendingPassword = null;
      return true;
    } on VkAuthChallenge catch (e) {
      _challenge = e;
      return false;
    } on VkAuthException catch (e) {
      _error = e.message;
      _pendingUsername = null;
      _pendingPassword = null;
      return false;
    } catch (e) {
      _error = AppStrings.current.unexpectedError(e);
      _pendingUsername = null;
      _pendingPassword = null;
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  void cancelChallenge() {
    _challenge = null;
    _pendingUsername = null;
    _pendingPassword = null;
    notifyListeners();
  }

  Future<void> logout() async {
    await VkAuthStorage.clear();
    _token = null;
    _userAgent = null;
    _userId = null;
    notifyListeners();
  }
}
