import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Достаёт "внутренний" client_id SoundCloud тем же способом, что и
/// их собственный веб-плеер: на soundcloud.com подключены JS-бандлы,
/// в одном из которых зашит client_id, используемый фронтендом для
/// запросов к api-v2.soundcloud.com.
///
/// ВАЖНО:
/// - Это недокументированный, неофициальный способ — SoundCloud его
///   не поддерживает и может сломать в любой момент (смена структуры
///   страницы, обфускация бандлов и т.д.).
/// - Ключ привязан к их веб-плееру, а не выдан вам лично — с точки
///   зрения ToS SoundCloud это зона риска, особенно для приложения,
///   которое вы планируете публиковать/монетизировать.
/// - Используйте это как временное/dev-решение, пока не появится
///   официальный доступ, либо на свой риск.
class SoundCloudClientIdResolver {
  SoundCloudClientIdResolver({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              headers: {
                // Некоторые CDN отдают бандлы иначе без "браузерного" UA.
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
              },
            ));

  final Dio _dio;
  static const _prefsKey = 'soundcloud_internal_client_id';

  final _scriptSrcRegex =
      RegExp(r'<script[^>]+src="([^"]+\.js)"', caseSensitive: false);
  final _clientIdRegex =
      RegExp(r'client_id\s*[:=]\s*"([a-zA-Z0-9]{32})"');

  /// Возвращает закэшированный ключ, если он есть, иначе — null.
  Future<String?> readCached() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefsKey);
  }

  Future<void> _cache(String clientId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, clientId);
  }

  /// Заново парсит soundcloud.com и находит актуальный client_id.
  /// Возвращает null, если найти не удалось (сайт изменился, сеть и т.п.).
  Future<String?> discover() async {
    try {
      final homepage = await _dio.get<String>('https://soundcloud.com');
      final html = homepage.data ?? '';

      final scriptUrls = _scriptSrcRegex
          .allMatches(html)
          .map((m) => m.group(1)!)
          .where((url) => url.contains('sndcdn.com'))
          .toList();

      if (scriptUrls.isEmpty) return null;

      // client_id почти всегда лежит в одном из последних подключаемых
      // бандлов (обычно это основной app-бандл) — начинаем с конца,
      // чтобы не перебирать все скрипты без необходимости.
      for (final url in scriptUrls.reversed) {
        try {
          final js = await _dio.get<String>(url);
          final match = _clientIdRegex.firstMatch(js.data ?? '');
          if (match != null) {
            final clientId = match.group(1)!;
            await _cache(clientId);
            return clientId;
          }
        } catch (_) {
          continue; // пробуем следующий бандл
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Возвращает рабочий client_id: сначала пробует кэш, если его нет —
  /// сразу парсит сайт заново.
  Future<String?> resolve({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = await readCached();
      if (cached != null) return cached;
    }
    return discover();
  }
}
