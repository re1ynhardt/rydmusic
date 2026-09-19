import 'package:dio/dio.dart';
import '../models/track.dart';

class LyricLine {
  final int ms;
  final String text;
  const LyricLine(this.ms, this.text);
}

/// [lines] — построчный текст с таймингами (может быть пустым),
/// [plain] — обычный текст без таймингов (запасной вариант).
class Lyrics {
  final List<LyricLine> lines;
  final String plain;
  const Lyrics(this.lines, this.plain);
  bool get isSynced => lines.isNotEmpty;
}

/// Тексты берём из LRCLIB (lrclib.net): бесплатно, без ключа, есть тайминги.
/// Результаты держим в небольшом кэше в памяти. Ошибки сети НЕ кэшируем
/// (бросаем наверх, чтобы UI мог предложить повтор), «не найдено» — кэшируем.
class LyricsService {
  LyricsService._();
  static final instance = LyricsService._();

  final _dio = Dio(BaseOptions(
    baseUrl: 'https://lrclib.net/api',
    connectTimeout: const Duration(seconds: 6),
    receiveTimeout: const Duration(seconds: 8),
    headers: {'User-Agent': 'rydmusic/1.0'},
  ));
  final _cache = <String, Lyrics?>{};

  // «(Speed Up)», «[Remix]», « - Remastered» и т.п. мешают поиску.
  static final _noise = RegExp(r'\s*[\(\[][^\)\]]*[\)\]]|\s+-\s+.*$');
  static final _ts = RegExp(r'\[(\d+):(\d+(?:\.\d+)?)\]');

  Future<Lyrics?> fetch(Track t) async {
    if (_cache.containsKey(t.id)) return _cache[t.id];
    var title = t.title.replaceAll(_noise, '').trim();
    if (title.isEmpty) title = t.title;
    var res = await _search({'track_name': title, 'artist_name': t.artist});
    res ??= await _search({'q': '$title ${t.artist}'});
    if (_cache.length >= 20) _cache.remove(_cache.keys.first);
    _cache[t.id] = res;
    return res;
  }

  Future<Lyrics?> _search(Map<String, String> q) async {
    final r = await _dio.get<List<dynamic>>('/search', queryParameters: q);
    String? plain;
    for (final e in r.data ?? const <dynamic>[]) {
      final m = e as Map;
      final s = m['syncedLyrics'];
      if (s is String && s.isNotEmpty) {
        final lines = _parse(s);
        if (lines.isNotEmpty) return Lyrics(lines, '');
      }
      final p = m['plainLyrics'];
      if (plain == null && p is String && p.isNotEmpty) plain = p;
    }
    return plain == null ? null : Lyrics(const [], plain);
  }

  static List<LyricLine> _parse(String s) {
    final out = <LyricLine>[];
    for (final raw in s.split('\n')) {
      final ms = _ts.allMatches(raw).toList();
      if (ms.isEmpty) continue;
      final text = raw.substring(ms.last.end).trim();
      if (text.isEmpty) continue;
      for (final m in ms) {
        final t = (int.parse(m[1]!) * 60 + double.parse(m[2]!)) * 1000;
        out.add(LyricLine(t.round(), text));
      }
    }
    out.sort((a, b) => a.ms.compareTo(b.ms));
    return out;
  }
}
