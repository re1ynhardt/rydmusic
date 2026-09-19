import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// po_token/visitor_data, пойманные из настоящей сессии youtube.com.
/// Оба поля nullable — WebView мог не успеть их поймать (таймаут,
/// изменившаяся структура плеерного запроса и т.п.); в этом случае
/// yt-dlp всё равно пробует резолвить видео без них (см.
/// YouTubeYtDlpBridge/ytdlp_bridge.py).
class YoutubeSession {
  const YoutubeSession({this.poToken, this.visitorData});
  final String? poToken;
  final String? visitorData;

  bool get isUsable =>
      (poToken != null && poToken!.isNotEmpty) ||
      (visitorData != null && visitorData!.isNotEmpty);
}

/// Скрытый (headless) WebView, который открывает настоящую страницу
/// youtube.com/watch и подсматривает po_token/visitor_data из её
/// собственного запроса к /youtubei/v1/player.
///
/// ВАЖНО, что это НЕ реализация BotGuard: мы не решаем челлендж сами —
/// это делает JS самого youtube.com, запущенный в честном WebView
/// (реальный Chromium-движок системы, а не эмуляция). Мы лишь
/// подглядываем итоговый результат, который страница сама кладёт в
/// тело своего запроса — тем же способом, каким его увидел бы обычный
/// браузер через DevTools.
///
/// ═══ ПОЧЕМУ ЭТО БЫЛО МЕДЛЕННО И ЧТО ИЗМЕНИЛОСЬ ═══
///
/// Раньше этот WebView поднимался ЗАНОВО НА КАЖДЫЙ ТРЕК: полная
/// загрузка youtube.com/watch (несколько мегабайт JS, инициализация
/// плеера) плюс ожидание, пока страница сама сходит в /player —
/// секунд десять, а при промахе ещё и весь таймаут сверху. И всё это
/// последовательно, по одному треку за раз. Отсюда и брались 15 секунд
/// до старта воспроизведения и такое же ожидание при кэшировании
/// трека офлайн (там резолв вызывался повторно).
///
/// Ключевой факт, на котором строится ускорение: **po_token контекста
/// `web.gvs` и visitor_data привязаны к СЕССИИ, а не к конкретному
/// видео**. visitor_data — это идентификатор анонимной сессии, а
/// gvs-токен выдаётся именно под него. Значит, одни и те же токены
/// подходят для любого видео, пока они не протухли. Поэтому теперь:
///
/// - сессия добывается ОДИН раз и переиспользуется для всех треков;
/// - она переживает перезапуск приложения (лежит в SharedPreferences);
/// - её можно прогреть заранее ([prewarm]) — пока пользователь
///   смотрит выдачу поиска, токены уже ловятся в фоне, и к моменту
///   тапа по треку WebView вообще не нужен;
/// - параллельные запросы схлопываются в один общий (single-flight),
///   а не выстраиваются в очередь по 12 секунд каждый;
/// - неудача тоже запоминается на короткое время, чтобы не поднимать
///   WebView заново на каждый следующий трек в очереди.
///
/// НЕНАДЁЖНОСТЬ перехвата — часть контракта, а не баг: YouTube
/// регулярно меняет формат BotGuard/innertube, так что перехват может
/// замолчать после очередного обновления самого youtube.com. На этот
/// случай — таймаут и попытка резолва без токенов ниже по цепочке.
class YoutubeSessionResolver {
  YoutubeSessionResolver._();
  static final instance = YoutubeSessionResolver._();

  /// Сколько ждём перехвата, прежде чем сдаться и отдать пустую сессию.
  /// Меньше прежних 12 секунд: если страница не сходила в /player за
  /// это время, она обычно не сходит туда и за вдвое большее, а ждать
  /// приходится пользователю.
  static const _timeout = Duration(seconds: 8);

  /// Сколько считаем пойманную сессию годной. Реальный срок жизни
  /// gvs-токена — порядка нескольких часов; берём с запасом вниз,
  /// чтобы не наткнуться на 403 из-за протухшего токена.
  static const _sessionTtl = Duration(hours: 3);

  /// Сколько не повторяем попытку после неудачного перехвата — иначе
  /// очередь из 20 треков честно подняла бы WebView 20 раз подряд.
  static const _failureTtl = Duration(minutes: 10);

  static const _prefsTokenKey = 'yt_session_po_token';
  static const _prefsVisitorKey = 'yt_session_visitor_data';
  static const _prefsAtKey = 'yt_session_captured_at';
  static const _prefsSeedKey = 'yt_session_seed_video';

  /// Видео, на котором ловим токены при ручном обновлении, если ни
  /// одного удачного резолва ещё не было («Me at the zoo» — самое
  /// первое видео YouTube, доступно везде).
  static const _fallbackSeedVideoId = 'jNQXAC9IVRw';

  YoutubeSession? _session;
  DateTime? _sessionAt;
  Duration _sessionTtlActual = _sessionTtl;
  Future<YoutubeSession>? _inFlight;
  bool _restored = false;

  YoutubeSession? get _freshSession {
    final session = _session;
    final at = _sessionAt;
    if (session == null || at == null) return null;
    if (DateTime.now().difference(at) > _sessionTtlActual) {
      _session = null;
      _sessionAt = null;
      return null;
    }
    return session;
  }

  /// Уже готовая сессия, если она есть и не протухла — синхронно.
  YoutubeSession? get cachedSession => _freshSession;

  /// Достаёт сессию: из памяти, из прошлого запуска приложения или,
  /// если ничего нет, честным заходом в WebView.
  Future<YoutubeSession> resolveSession(String videoId) async {
    final cached = _freshSession;
    if (cached != null) return cached;

    await _restoreFromDisk();
    final restored = _freshSession;
    if (restored != null) return restored;

    // Single-flight: пока идёт один перехват, все остальные вызовы
    // ждут его результат, а не поднимают ещё по WebView каждый.
    final inFlight = _inFlight;
    if (inFlight != null) return inFlight;

    final future = _resolveOne(videoId).then((session) {
      _store(session, videoId);
      _inFlight = null;
      return session;
    }, onError: (Object _, StackTrace __) {
      _store(const YoutubeSession(), videoId);
      _inFlight = null;
      return const YoutubeSession();
    });
    _inFlight = future;
    return future;
  }

  /// Прогрев: запускает перехват заранее и НЕ заставляет вызывающего
  /// ждать. Вызывается, как только стал известен хоть какой-то videoId
  /// (например, пришли результаты поиска) — к моменту, когда
  /// пользователь ткнёт в трек, сессия уже готова, и резолв сводится к
  /// одному вызову yt-dlp.
  void prewarm([String? videoId]) {
    if (_freshSession != null || _inFlight != null) return;
    unawaited(_prewarm(videoId));
  }

  Future<void> _prewarm(String? videoId) async {
    try {
      await _restoreFromDisk();
      if (_freshSession != null || _inFlight != null) return;
      final seed = videoId ?? await _seedVideoId();
      if (seed == null || seed.isEmpty) return;
      await resolveSession(seed);
    } catch (_) {
      // Прогрев — best effort: не сумели, значит резолв пойдёт обычным
      // путём в момент нажатия на трек.
    }
  }

  /// Для экрана настроек: уже добытая сессия (из памяти или с диска) —
  /// БЕЗ запуска WebView. null, если сессии нет, она протухла или
  /// последний перехват не удался.
  Future<YoutubeSession?> sessionForDisplay() async {
    await _restoreFromDisk();
    final session = _freshSession;
    return (session != null && session.isUsable) ? session : null;
  }

  /// Принудительно ловит новую сессию (кнопка «Обновить сейчас» в
  /// настройках), не дожидаясь протухания старой. Возвращает новую
  /// сессию или null, если перехват не удался — тогда прежняя (если она
  /// ещё жива) остаётся в работе, а не заменяется пустой.
  Future<YoutubeSession?> refreshSession() async {
    // Сначала подтягиваем сессию с диска — иначе resolveSession ниже
    // «восстановил» бы из SharedPreferences именно ту, которую мы
    // собираемся обновить.
    await _restoreFromDisk();
    final previous = _freshSession;
    final previousAt = _sessionAt;
    _session = null;
    _sessionAt = null;

    final stored = await _seedVideoId();
    final seed =
        (stored != null && stored.isNotEmpty) ? stored : _fallbackSeedVideoId;
    final session = await resolveSession(seed);
    if (session.isUsable) return session;

    if (previous != null && previous.isUsable) {
      _session = previous;
      _sessionAt = previousAt;
      _sessionTtlActual = _sessionTtl;
    }
    return null;
  }

  /// videoId с прошлого успешного резолва — им можно прогреть сессию
  /// на старте приложения, когда никакого другого id ещё нет.
  Future<String?> _seedVideoId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_prefsSeedKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _restoreFromDisk() async {
    if (_restored) return;
    _restored = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final at = prefs.getInt(_prefsAtKey);
      if (at == null) return;
      final capturedAt = DateTime.fromMillisecondsSinceEpoch(at);
      if (DateTime.now().difference(capturedAt) > _sessionTtl) return;
      final session = YoutubeSession(
        poToken: prefs.getString(_prefsTokenKey),
        visitorData: prefs.getString(_prefsVisitorKey),
      );
      if (!session.isUsable) return;
      _session = session;
      _sessionAt = capturedAt;
      _sessionTtlActual = _sessionTtl;
    } catch (_) {
      // Нет доступа к настройкам — просто работаем без переживания
      // сессии между запусками.
    }
  }

  void _store(YoutubeSession session, String videoId) {
    _session = session;
    _sessionAt = DateTime.now();
    // Пустую (неудачную) сессию тоже кэшируем, но ненадолго — см.
    // _failureTtl.
    _sessionTtlActual = session.isUsable ? _sessionTtl : _failureTtl;
    if (!session.isUsable) return;
    unawaited(_persist(session, videoId));
  }

  Future<void> _persist(YoutubeSession session, String videoId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsTokenKey, session.poToken ?? '');
      await prefs.setString(_prefsVisitorKey, session.visitorData ?? '');
      await prefs.setInt(
          _prefsAtKey, DateTime.now().millisecondsSinceEpoch);
      if (videoId.isNotEmpty) {
        await prefs.setString(_prefsSeedKey, videoId);
      }
    } catch (_) {
      // Не сохранили — потеряем только возможность прогреться на
      // следующем запуске, на текущую сессию это не влияет.
    }
  }

  Future<YoutubeSession> _resolveOne(String videoId) async {
    final completer = Completer<YoutubeSession>();
    HeadlessInAppWebView? headless;
    Timer? timer;

    void finish(YoutubeSession session) {
      if (completer.isCompleted) return;
      completer.complete(session);
      timer?.cancel();
      // dispose асинхронный, но нам не нужно его дожидаться — сессия
      // уже возвращена вызывающему коду.
      headless?.dispose();
    }

    timer = Timer(_timeout, () => finish(const YoutubeSession()));

    headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('https://www.youtube.com/watch?v=$videoId'),
      ),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        // Мобильный UA — тот же класс клиента, для которого yt-dlp
        // запрашивает po_token контекстом 'web.gvs' в ytdlp_bridge.py.
        userAgent: 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
        // Нам нужен ровно один сетевой запрос страницы — тот, что уходит
        // в /youtubei/v1/player. Всё остальное (обложки, аватарки,
        // превью из ленты рекомендаций, автозапуск самого видео) — это
        // мегабайты трафика и лишние секунды до того, как страница
        // доберётся до плеерного запроса. Отключаем картинки и запрещаем
        // автостарт медиа: на перехват токенов это не влияет, а грузится
        // страница ощутимо быстрее.
        blockNetworkImage: true,
        loadsImagesAutomatically: false,
        mediaPlaybackRequiresUserGesture: true,
        cacheEnabled: true,
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: _interceptScript,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      onWebViewCreated: (controller) {
        controller.addJavaScriptHandler(
          handlerName: 'ytSession',
          callback: (args) {
            if (args.isEmpty) return null;
            try {
              final data = jsonDecode(args.first as String) as Map<String, dynamic>;
              finish(YoutubeSession(
                poToken: data['poToken'] as String?,
                visitorData: data['visitorData'] as String?,
              ));
            } catch (_) {
              // Не удалось распарсить — просто ждём таймаут ниже.
            }
            return null;
          },
        );
      },
    );

    try {
      await headless.run();
    } catch (_) {
      finish(const YoutubeSession());
    }

    return completer.future;
  }

  // Перехватывает и fetch(), и XHR — плеер youtube.com исторически
  // использовал оба способа в разных версиях innertube-клиента, а мы
  // не контролируем, какой именно достанется в момент запроса.
  static const _interceptScript = r'''
    (function () {
      if (window.__ytSessionHooked) return;
      window.__ytSessionHooked = true;

      function report(body) {
        try {
          var parsed = typeof body === 'string' ? JSON.parse(body) : body;
          var poToken = parsed && parsed.serviceIntegrityDimensions &&
            parsed.serviceIntegrityDimensions.poToken;
          var visitorData = parsed && parsed.context &&
            parsed.context.client && parsed.context.client.visitorData;
          if (poToken || visitorData) {
            window.flutter_inappwebview.callHandler(
              'ytSession',
              JSON.stringify({ poToken: poToken, visitorData: visitorData })
            );
          }
        } catch (e) {}
      }

      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function (input, init) {
          try {
            var url = typeof input === 'string' ? input : (input && input.url);
            if (url && url.indexOf('/youtubei/v1/player') !== -1 && init && init.body) {
              report(init.body);
            }
          } catch (e) {}
          return origFetch.apply(this, arguments);
        };
      }

      var origSend = XMLHttpRequest.prototype.send;
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__ytUrl = url;
        return origOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function (body) {
        try {
          if (this.__ytUrl && this.__ytUrl.indexOf('/youtubei/v1/player') !== -1 && body) {
            report(body);
          }
        } catch (e) {}
        return origSend.apply(this, arguments);
      };
    })();
  ''';
}
