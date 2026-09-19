import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_strings.dart';

/// Результат успешного логина VK (прямая авторизация под client_id
/// Kate Mobile — см. android/.../vk_auth_bridge.py).
class VkAuthResult {
  const VkAuthResult({
    required this.token,
    required this.userAgent,
    this.userId,
  });

  final String token;
  final String userAgent;
  final int? userId;

  factory VkAuthResult.fromJson(Map<String, dynamic> json) => VkAuthResult(
        token: json['token'] as String? ?? '',
        userAgent: json['user_agent'] as String? ?? '',
        userId: json['user_id'] as int?,
      );
}

/// Промежуточный шаг логина — VK потребовал код по SMS (2FA) или капчу.
/// UI должен показать соответствующее поле и повторить [VkAuthBridge.login]
/// с заполненным [authCode] либо [captchaSid]+[captchaKey].
class VkAuthChallenge implements Exception {
  const VkAuthChallenge({
    this.message,
    this.captchaSid,
    this.captchaImageUrl,
    this.validationSid,
    this.phoneMask,
  });

  final String? message;

  /// Заполнены, если нужна капча.
  final String? captchaSid;
  final String? captchaImageUrl;

  /// Заполнены, если нужен код по SMS (2FA).
  final String? validationSid;
  final String? phoneMask;

  bool get needsCaptcha => captchaSid != null && captchaImageUrl != null;
  bool get needsSmsCode => validationSid != null;

  @override
  String toString() => message ?? 'VK auth challenge';
}

/// Базовый класс ошибок VK-логина/поиска, которые не подпадают под
/// [VkAuthChallenge] (неверный пароль, сетевая ошибка и т.п.).
class VkAuthException implements Exception {
  const VkAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

class VkTrack {
  const VkTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.url,
    this.duration,
  });

  final String id;
  final String title;
  final String artist;
  final String url;
  final int? duration;

  factory VkTrack.fromJson(Map<String, dynamic> json) => VkTrack(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? 'Unknown',
        artist: json['artist'] as String? ?? 'VK',
        url: json['url'] as String? ?? '',
        duration: json['duration'] as int?,
      );
}

/// Мост к android/.../vk_auth_bridge.py и vk_search_bridge.py
/// (канал "rydmusic/vk_hls", методы "login"/"search").
class VkAuthBridge {
  VkAuthBridge._();
  static const _channel = MethodChannel('rydmusic/vk_hls');

  /// Логин под client_id Kate Mobile. Бросает [VkAuthChallenge], если
  /// нужен код по SMS или капча — тогда нужно повторить вызов с теми
  /// же [username]/[password] и заполненным [authCode] либо
  /// [captchaSid]+[captchaKey]. Бросает [VkAuthException] на прочие
  /// ошибки (неверный пароль и т.д.).
  static Future<VkAuthResult> login({
    required String username,
    required String password,
    String? authCode,
    String? captchaSid,
    String? captchaKey,
  }) async {
    final String raw;
    try {
      raw = await _channel.invokeMethod<String>('login', {
            'username': username,
            'password': password,
            if (authCode != null) 'authCode': authCode,
            if (captchaSid != null) 'captchaSid': captchaSid,
            if (captchaKey != null) 'captchaKey': captchaKey,
          }) ??
          '';
    } on PlatformException catch (e) {
      throw VkAuthException(e.message ?? AppStrings.current.vkAuthError);
    }

    if (raw.isEmpty) {
      throw VkAuthException(AppStrings.current.vkEmptyResponse);
    }

    final json = jsonDecode(raw) as Map<String, dynamic>;

    if (json['error'] == true) {
      final captchaSidResp = json['captcha_sid'] as String?;
      final captchaImg = json['captcha_img'] as String?;
      final validationSid = json['validation_sid'] as String?;
      if ((captchaSidResp != null && captchaImg != null) ||
          validationSid != null) {
        throw VkAuthChallenge(
          message: (json['message'] ?? json['msg']) as String?,
          captchaSid: captchaSidResp,
          captchaImageUrl: captchaImg,
          validationSid: validationSid,
          phoneMask: json['phone_mask'] as String?,
        );
      }
      throw VkAuthException(
        (json['message'] ?? json['msg'] ?? AppStrings.current.vkLoginFailed)
            as String,
      );
    }

    return VkAuthResult.fromJson(json);
  }

  /// Поиск по каталогу VK. Требует токен, полученный через [login].
  static Future<List<VkTrack>> search({
    required String token,
    required String userAgent,
    required String query,
    int count = 25,
    int offset = 0,
  }) async {
    final String raw;
    try {
      raw = await _channel.invokeMethod<String>('search', {
            'token': token,
            'userAgent': userAgent,
            'query': query,
            'count': count,
            'offset': offset,
          }) ??
          '';
    } on PlatformException catch (e) {
      debugPrint('[VK search] ${e.message}');
      return [];
    }

    if (raw.isEmpty) return [];

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      if (json['error'] == true) {
        debugPrint('[VK search] ${json['message']}');
        return [];
      }
      final items = (json['tracks'] as List?) ?? [];
      return items
          .cast<Map<String, dynamic>>()
          .map(VkTrack.fromJson)
          .where((t) => t.url.isNotEmpty || t.id.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[VK search] Parse error: $e');
      return [];
    }
  }
}

/// Локальное хранение VK access_token (SharedPreferences — так же,
/// как кэш client_id SoundCloud, см. account_service.dart:
/// открытый, не зашифрованный, но в приложении уже принят такой
/// уровень для несекретных на уровне ОС данных). Токен от Kate Mobile
/// не имеет ограниченного времени жизни в типичном случае (expires_in
/// обычно 0 — бессрочный, пока пользователь не отзовёт доступ в
/// настройках VK), поэтому отдельного refresh-потока не требуется.
class VkAuthStorage {
  VkAuthStorage._();

  static const _tokenKey = 'vk_access_token';
  static const _userAgentKey = 'vk_user_agent';
  static const _userIdKey = 'vk_user_id';

  static Future<void> save(VkAuthResult result) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, result.token);
    await prefs.setString(_userAgentKey, result.userAgent);
    if (result.userId != null) {
      await prefs.setInt(_userIdKey, result.userId!);
    }
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_userAgentKey);
    await prefs.remove(_userIdKey);
  }

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<String> getUserAgent() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_userAgentKey) ?? '';
  }

  static Future<int?> getUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_userIdKey);
  }
}
