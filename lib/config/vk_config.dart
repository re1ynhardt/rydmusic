/// Настройки VK (ВКонтакте) API для парсера треков.
///
/// **ВАЖНО**: VK парсер работает БЕЗ access token!
/// Парсит веб-страницы ВК напрямую, извлекая данные о треках из HTML/JavaScript.
/// 
/// Access token больше не требуется. Оставлен для совместимости/будущего использования.
class VkConfig {
  /// Access token (опционально, не требуется)
  static const String accessToken = String.fromEnvironment(
    'VK_ACCESS_TOKEN',
    defaultValue: '',
  );

  /// Версия VK API (не используется при парсинге HTML)
  static const String apiVersion = String.fromEnvironment(
    'VK_API_VERSION',
    defaultValue: '5.131',
  );

  /// VK парсер всегда включен (работает без токена)
  static bool get isEnabled => true;
}
