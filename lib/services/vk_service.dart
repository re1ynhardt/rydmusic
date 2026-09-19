import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'music_source.dart';
import 'vk_auth_bridge.dart';
import 'vk_hls_service.dart';

/// VK как источник музыки. Поиск идёт через audio.search с токеном,
/// полученным логином под client_id Kate Mobile (см. VkAuthProvider /
/// android/.../vk_auth_bridge.py) — без такого токена официальный
/// audio.search закрыт для сторонних приложений, поэтому пока
/// пользователь не залогинен в настройках, search()/trending() честно
/// возвращают пустой список, а не бросают ошибку в UI.
class VkService extends MusicSource {
  VkService();

  Future<VKMusicSource>? _hlsSourceFuture;

  /// VKMusicSource кэширует и дешифрует HLS-сегменты в файлы — ему
  /// нужна директория на диске, поэтому создаём его лениво при первом
  /// обращении, а не в конструкторе (тот вызывается синхронно при
  /// старте приложения, см. main.dart).
  Future<VKMusicSource> get _hlsSource =>
      _hlsSourceFuture ??= _createHlsSource();

  Future<VKMusicSource> _createHlsSource() async {
    final dir = await getApplicationDocumentsDirectory();
    return VKMusicSource(cacheDir: '${dir.path}/vk_hls_cache');
  }

  @override
  String get name => 'VK';

  @override
  Future<List<Track>> search(
    String query, {
    int limit = 25,
    int offset = 0,
  }) async {
    final token = await VkAuthStorage.getToken();
    if (token == null) {
      debugPrint('[VK] Not logged in — see settings');
      return [];
    }
    final userAgent = await VkAuthStorage.getUserAgent();

    final vkTracks = await VkAuthBridge.search(
      token: token,
      userAgent: userAgent,
      query: query,
      count: limit,
      offset: offset,
    );

    return vkTracks.map(_toTrack).toList();
  }

  @override
  Future<List<Track>> trending({int limit = 25}) async {
    // У VK нет отдельного публичного метода "популярное" для токенов
    // от Kate Mobile (audio.getCatalog из официального клиента
    // устроен сложнее — отдаёт блоки, а не плоский список, и не
    // проверялся с этим типом токена). Пока просто не показываем
    // ничего вместо того, чтобы выдавать неверный список под видом
    // трендов.
    return [];
  }

  @override
  Future<Track> resolveStreamUrl(Track track) async {
    // Часть треков VK отдаёт как прямой mp3 — тогда резолвить нечего.
    if (!track.streamUrl.contains('.m3u8')) {
      return track;
    }
    // Остальное — зашифрованный HLS, расшифровкой занимается
    // VKMusicSource (тот же пайплайн, что и для ссылок, вставленных
    // вручную, — см. vk_hls_service.dart).
    try {
      final hls = await _hlsSource;
      return await hls.resolveStreamUrl(track);
    } catch (e) {
      debugPrint('[VK] HLS resolve error: $e');
      return track;
    }
  }

  Track _toTrack(VkTrack t) => Track(
        id: 'vk_${t.id}',
        title: t.title,
        artist: t.artist,
        artworkUrl: '',
        duration: t.duration != null
            ? Duration(seconds: t.duration!)
            : const Duration(minutes: 3),
        source: MusicSourceType.vk,
        streamUrl: t.url,
      );
}
