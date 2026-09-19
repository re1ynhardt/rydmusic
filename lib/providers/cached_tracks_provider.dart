import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/cached_track.dart';
import '../models/track.dart';
import '../services/music_source.dart';

/// Оффлайн-кэш треков: качает аудио целиком на диск, чтобы трек можно
/// было слушать без интернета.
///
/// Оптимизировано под слабые устройства так же, как остальные провайдеры
/// в приложении:
/// - метаданные кэша хранятся ОДНИМ JSON-блоком в SharedPreferences;
/// - сами аудиофайлы лежат на диске (documents/audio_cache), а не в
///   памяти и не в prefs — иначе на слабом устройстве загрузка списка
///   тащила бы за собой мегабайты аудио в память;
/// - прогресс закачки троттлится: notifyListeners вызывается только
///   когда процент реально изменился, а не на каждый полученный чанк
///   (иначе UI перерисовывался бы сотни раз в секунду);
/// - все мутации (добавление/удаление из кэша) применяются к состоянию
///   сразу же, запись метаданных на диск — с debounce.
class CachedTracksProvider extends ChangeNotifier {
  static const _prefsKey = 'cached_tracks_v1';

  CachedTracksProvider({required Map<MusicSourceType, MusicSource> sources})
      : _sources = sources {
    _load();
  }

  final Map<MusicSourceType, MusicSource> _sources;
  final Dio _dio = Dio();

  // Map сохраняет порядок вставки — как и в остальных провайдерах.
  final Map<String, CachedTrack> _cached = <String, CachedTrack>{};

  // Прогресс 0..1 для треков, которые сейчас качаются.
  final Map<String, double> _progress = <String, double>{};
  final Map<String, int> _lastNotifiedPercent = <String, int>{};
  final Map<String, CancelToken> _cancelTokens = <String, CancelToken>{};

  bool _loaded = false;
  Timer? _saveDebounce;

  bool get isLoaded => _loaded;

  List<Track>? _cachedList;

  /// Кэшируется до следующего изменения: этот геттер дёргают экраны
  /// библиотеки и настроек на каждой перестройке, а во время закачки
  /// уведомления приходят на каждый процент — пересобирать два списка
  /// заново каждый раз незачем.
  List<Track> get cachedTracks => _cachedList ??= _cached.values
      .map((c) => c.track)
      .toList(growable: false)
      .reversed
      .toList(growable: false);

  /// Единая точка сброса кэша: любое изменение _cached в этом классе
  /// сопровождается уведомлением слушателей.
  @override
  void notifyListeners() {
    _cachedList = null;
    super.notifyListeners();
  }

  int get count => _cached.length;

  /// Суммарный размер всех кэшированных аудиофайлов в байтах — для
  /// отображения в настройках. Складывается из уже посчитанных размеров
  /// (см. fileSizeBytes), без похода на диск на каждый ребилд.
  int get totalSizeBytes =>
      _cached.values.fold(0, (sum, c) => sum + c.fileSizeBytes);

  bool isCached(String trackId) => _cached.containsKey(trackId);

  bool isDownloading(String trackId) => _progress.containsKey(trackId);

  /// null — трек сейчас не качается; иначе 0..1 (может застрять на 0,
  /// если сервер не отдаёт Content-Length — тогда просто крутим спиннер
  /// без конкретного процента).
  double? downloadProgress(String trackId) => _progress[trackId];

  String? localPathFor(String trackId) => _cached[trackId]?.localPath;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        var needsResave = false;
        for (final item in decoded) {
          var cached = CachedTrack.fromJson(item as Map<String, dynamic>);
          if (cached.track.id.isEmpty || cached.localPath.isEmpty) continue;
          // Проверяем, что файл реально ещё на диске (мог быть стёрт
          // системой или вручную). Коллекция закачек личная и обычно
          // небольшая, так что несколько File.exists() при старте дёшевы.
          final file = File(cached.localPath);
          if (await file.exists()) {
            // Записи, сохранённые до появления fileSizeBytes, донабирают
            // размер один раз здесь же — дальше он просто хранится в JSON.
            if (cached.fileSizeBytes <= 0) {
              try {
                cached = CachedTrack(
                  track: cached.track,
                  localPath: cached.localPath,
                  fileSizeBytes: await file.length(),
                );
                needsResave = true;
              } catch (_) {
                // Не критично — просто останется 0 в сумме для этого файла.
              }
            }
            _cached[cached.track.id] = cached;
          }
        }
        if (needsResave) _scheduleSave();
      }
    } catch (_) {
      // Битые/устаревшие локальные данные не должны ронять приложение.
    } finally {
      _loaded = true;
      notifyListeners();
    }
  }

  /// Качает трек целиком на диск. Для источников с непрямым streamUrl
  /// (например SoundCloud) сначала резолвит настоящую ссылку на аудио —
  /// без сети на этом шаге не обойтись, зато после скачивания трек
  /// проигрывается полностью офлайн.
  Future<void> download(Track track) async {
    if (_cached.containsKey(track.id) || _progress.containsKey(track.id)) {
      return;
    }
    _progress[track.id] = 0;
    _lastNotifiedPercent[track.id] = -1;
    notifyListeners();

    try {
      final source = _sources[track.source];
      final resolved =
          source != null ? await source.resolveStreamUrl(track) : track;
      if (resolved.streamUrl.isEmpty) {
        throw StateError('Пустой stream url');
      }

      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = Directory('${dir.path}/audio_cache');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      final path = '${cacheDir.path}/${track.id}${_extensionFor(resolved.streamUrl)}';

      final cancelToken = CancelToken();
      _cancelTokens[track.id] = cancelToken;

      void onProgress(int received, int total) {
        if (total <= 0) return;
        final ratio = received / total;
        final percent = (ratio * 100).floor();
        // Троттлинг: перерисовываем только когда процент реально
        // сдвинулся, а не на каждый полученный сетевой чанк.
        if (percent != _lastNotifiedPercent[track.id]) {
          _lastNotifiedPercent[track.id] = percent;
          _progress[track.id] = ratio;
          notifyListeners();
        }
      }

      if (track.source == MusicSourceType.youtube) {
        // См. _downloadYoutubeChunked ниже: googlevideo троттлит один
        // длинный непрерывный GET — из-за этого скачивание трека
        // растягивалось на минуту и дольше, хотя само воспроизведение
        // идёт без проблем (плееру достаточно небольшого забега вперёд,
        // а не всего файла разом).
        await _downloadYoutubeChunked(
          url: resolved.streamUrl,
          path: path,
          headers: resolved.streamHeaders,
          cancelToken: cancelToken,
          onProgress: onProgress,
        );
      } else {
        await _dio.download(
          resolved.streamUrl,
          path,
          cancelToken: cancelToken,
          // ВАЖНО для YouTube: подписанная ссылка googlevideo отдаётся
          // только тому клиенту, которым она была подписана — без его
          // User-Agent CDN отвечает 403 (ровно та же причина, по которой
          // заголовки прокидываются в плеер, см. AudioPlayerService.
          // _buildSource). Остальные источники заголовков не задают —
          // для них сюда по-прежнему не уходит ничего, поведение то же.
          options: (resolved.streamHeaders?.isNotEmpty ?? false)
              ? Options(headers: Map<String, String>.from(resolved.streamHeaders!))
              : null,
          onReceiveProgress: onProgress,
        );
      }

      _cancelTokens.remove(track.id);
      _progress.remove(track.id);
      _lastNotifiedPercent.remove(track.id);
      int sizeBytes = 0;
      try {
        sizeBytes = await File(path).length();
      } catch (_) {
        // Не критично — просто не будет учтён в суммарном размере кэша.
      }
      // В метаданных храним оригинальный трек (с исходным streamUrl) —
      // локальный путь используется отдельно, только для офлайн-плейбека.
      _cached[track.id] = CachedTrack(
        track: track,
        localPath: path,
        fileSizeBytes: sizeBytes,
      );
      notifyListeners();
      _scheduleSave();
    } catch (_) {
      // Отмена или сетевая ошибка — просто убираем индикатор загрузки,
      // не оставляя UI в подвешенном состоянии.
      _progress.remove(track.id);
      _lastNotifiedPercent.remove(track.id);
      _cancelTokens.remove(track.id);
      notifyListeners();
    }
  }

  void cancelDownload(String trackId) {
    _cancelTokens[trackId]?.cancel();
  }

  Future<void> remove(String trackId) async {
    final cached = _cached.remove(trackId);
    if (cached == null) return;
    notifyListeners();
    _scheduleSave();
    try {
      final file = File(cached.localPath);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Неважно, если не удалилось — не блокируем пользователя.
    }
  }

  /// Удаляет ВСЕ кэшированные треки разом: все файлы с диска и все
  /// метаданные. Активные закачки при этом тоже отменяются — иначе
  /// закачка, которая вот-вот завершится, тут же воссоздала бы запись
  /// сразу после очистки.
  Future<void> clearAll() async {
    if (_cached.isEmpty && _progress.isEmpty) return;

    for (final token in _cancelTokens.values) {
      token.cancel();
    }
    _cancelTokens.clear();
    _progress.clear();
    _lastNotifiedPercent.clear();

    final toDelete = _cached.values.toList(growable: false);
    _cached.clear();
    notifyListeners();

    _saveDebounce?.cancel();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);

    for (final cached in toDelete) {
      try {
        final file = File(cached.localPath);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Неважно, если какой-то файл не удалился — метаданных о нём
        // уже нет, при следующем запуске он просто не попадёт в список
        // (см. проверку File.exists() в _load) и место на диске не
        // будет учитываться в totalSizeBytes.
      }
    }
  }

  /// Размер одного диапазона при чанкованной закачке YouTube-трека.
  /// Значение выбрано по образцу официального `--http-chunk-size` у
  /// самого yt-dlp: в его документации этот параметр так и описан —
  /// "may be useful for bypassing bandwidth throttling imposed by a
  /// webserver". Разница в том, что там его применяет сам yt-dlp
  /// (когда именно ОН качает файл), а здесь файл на диск кладёт Dio на
  /// стороне Flutter — той же схемой чанков, но своими руками.
  static const int _youtubeChunkSize = 10 * 1024 * 1024;

  /// Скачивает YouTube-трек ПОСЛЕДОВАТЕЛЬНЫМИ Range-запросами вместо
  /// одного длинного GET.
  ///
  /// ПОЧЕМУ ПРОСТОЙ GET БЫЛ МЕДЛЕННЫМ. У googlevideo (CDN, который
  /// отдаёт сам аудио-поток) есть троттлинг, рассчитанный так, чтобы
  /// хватало ровно на воспроизведение в реальном времени, и не больше:
  /// один непрерывный запрос "отдай мне всё" сервер сознательно душит
  /// до скорости чуть выше битрейта трека. Из-за этого 3-4-минутный
  /// трек размером в несколько мегабайт закачивался по минуте и дольше
  /// — хотя ПРОИГРЫВАНИЕ того же самого URL работает нормально: плееру
  /// достаточно читать с той скоростью, с которой он и так проигрывает
  /// звук, троттлинг ему попросту не мешает.
  ///
  /// Каждый новый Range-запрос — это для сервера новое соединение с
  /// чистого листа, и троттлинг применяется заново от нуля внутри
  /// каждого диапазона: пока идёт закачка одного 10-мегабайтного куска,
  /// скорость может быть ограничена, но время на весь трек уходит на
  /// порядок меньше, потому что таких кусков мало и каждый начинает
  /// разгон заново, а не продолжает уже задушенное соединение. Именно
  /// поэтому у самого yt-dlp есть штатная опция `--http-chunk-size`
  /// ровно под этот случай — здесь воспроизведена та же идея, но своими
  /// силами, поскольку сам файл на диск кладёт не yt-dlp, а Dio на
  /// стороне Flutter (yt-dlp у нас в Python-мосте только резолвит
  /// ссылку, см. android/.../ytdlp_bridge.py, и на реальное скачивание
  /// никак не влияет).
  ///
  /// Если сервер вдруг не поддерживает Range (ответит целиком, статус
  /// 200) — просто сохраняем то, что прислали, одним куском: это
  /// штатный, а не аварийный случай для этого метода.
  Future<void> _downloadYoutubeChunked({
    required String url,
    required String path,
    required Map<String, String>? headers,
    required CancelToken cancelToken,
    required void Function(int received, int total) onProgress,
  }) async {
    final sink = File(path).openWrite();
    var rangeStart = 0;
    int? total;
    try {
      while (true) {
        final rangeEnd = rangeStart + _youtubeChunkSize - 1;
        final response = await _dio.get<List<int>>(
          url,
          options: Options(
            headers: {
              if (headers != null) ...headers,
              'Range': 'bytes=$rangeStart-$rangeEnd',
            },
            responseType: ResponseType.bytes,
            // 200 (Range проигнорирован) и 416 (диапазон за концом
            // файла — сигнал, что всё уже скачано) — оба штатные ответы
            // в этой схеме, а не ошибки транспорта; разбираем их сами
            // ниже, а не через try/catch на DioException.
            validateStatus: (code) => code != null && code > 0 && code < 500,
          ),
          cancelToken: cancelToken,
          onReceiveProgress: (received, _) {
            onProgress(rangeStart + received, total ?? -1);
          },
        );

        final status = response.statusCode ?? 0;

        if (status == 416) {
          // Предыдущий чанк уже был последним — весь файл на диске.
          break;
        }

        final data = response.data ?? const <int>[];

        if (status == 200) {
          // Range не поддержан — сервер отдал сразу всё содержимое.
          sink.add(data);
          onProgress(data.length, data.length);
          break;
        }

        if (status != 206) {
          throw DioException(
            requestOptions: response.requestOptions,
            response: response,
            type: DioExceptionType.badResponse,
            error: 'Неожиданный статус $status при чанкованной закачке',
          );
        }

        sink.add(data);
        total ??= _parseContentRangeTotal(response.headers.value('content-range'));
        rangeStart += data.length;
        onProgress(rangeStart, total ?? -1);

        final isLastChunk =
            data.length < _youtubeChunkSize || (total != null && rangeStart >= total);
        if (isLastChunk) break;
      }
    } finally {
      await sink.flush();
      await sink.close();
    }
  }

  /// Разбирает заголовок `Content-Range: bytes start-end/total` и
  /// возвращает `total` — единственное, что нам из него нужно.
  int? _parseContentRangeTotal(String? headerValue) {
    if (headerValue == null) return null;
    final match = RegExp(r'/(\d+)$').firstMatch(headerValue);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }

  String _extensionFor(String url) {
    try {
      final path = Uri.parse(url).path;
      final dot = path.lastIndexOf('.');
      if (dot != -1 && path.length - dot <= 5) {
        return path.substring(dot);
      }
    } catch (_) {
      // Некорректный URL — используем расширение по умолчанию.
    }
    return '.mp3';
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () async {
      final prefs = await SharedPreferences.getInstance();
      final list =
          _cached.values.map((c) => c.toJson()).toList(growable: false);
      await prefs.setString(_prefsKey, jsonEncode(list));
    });
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }
}
