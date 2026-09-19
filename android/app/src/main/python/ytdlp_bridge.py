"""
Мост между Flutter/Kotlin и yt-dlp/ytmusicapi.

Вызывается из MainActivity.kt через Chaquopy — сам Python-интерпретатор
и обе библиотеки живут прямо внутри APK. Никакого отдельного
файла/процесса, который нужно было бы запускать вручную, — просто
модуль, который Kotlin дёргает синхронно в фоновом потоке.

po_token / visitor_data приходят с Dart-стороны (см.
YoutubeSessionResolver в lib/services/youtube_po_token_resolver.dart) —
это данные из НАСТОЯЩЕЙ сессии youtube.com в скрытом WebView, прошедшей
проверку BotGuard так же, как в обычном браузере. yt-dlp сам BotGuard
не проходит и проходить не умеет — мы просто отдаём ему уже готовые
токены через extractor_args, а дальше именно yt-dlp делает свою
основную работу: выбор лучшего audio-формата, разбор throttling/cipher
параметров и т.п.

Если po_token/visitor_data не передали (WebView не успел их поймать) —
всё равно пробуем: часть роликов у yt-dlp резолвится и без них.
"""

import json
import os
import tempfile

import yt_dlp


def _cache_dir():
    """Куда yt-dlp складывает свой кэш.

    Это важнее, чем кажется. Для веб-клиента YouTube yt-dlp разбирает
    player-JS (десигнер nsig) — на телефоне это делает ЧИСТО
    ПИТОНОВСКИЙ интерпретатор JS, и стоит такая разборка секунды. yt-dlp
    умеет кэшировать результат, но только если ему есть куда писать:
    без доступного каталога кэша он молча его отключает и разбирает JS
    заново НА КАЖДЫЙ трек. Внутри Android-приложения домашний каталог
    не всегда выставлен так, как ожидает yt-dlp, поэтому выбираем
    первый реально доступный на запись вариант сами.
    """
    candidates = []
    home = os.environ.get('HOME')
    if home:
        candidates.append(os.path.join(home, '.cache', 'yt-dlp'))
    try:
        candidates.append(os.path.join(tempfile.gettempdir(), 'yt-dlp-cache'))
    except Exception:
        pass
    for path in candidates:
        try:
            os.makedirs(path, exist_ok=True)
            probe = os.path.join(path, '.writable')
            with open(probe, 'w') as f:
                f.write('1')
            os.remove(probe)
            return path
        except Exception:
            continue
    return None


_CACHE_DIR = None
_CACHE_DIR_READY = False


def _base_opts(youtube_args):
    global _CACHE_DIR, _CACHE_DIR_READY
    if not _CACHE_DIR_READY:
        _CACHE_DIR = _cache_dir()
        _CACHE_DIR_READY = True

    opts = {
        'format': 'bestaudio/best',
        'quiet': True,
        'no_warnings': True,
        'skip_download': True,
        'noplaylist': True,
        # Быстрее сдаёмся на залипшем соединении вместо дефолтных
        # десятков секунд: пользователь всё это время смотрит на
        # неподвижный 0:00.
        'socket_timeout': 10,
        'retries': 2,
        'extractor_args': {'youtube': youtube_args} if youtube_args else {},
    }
    if _CACHE_DIR:
        opts['cachedir'] = _CACHE_DIR
    return opts


def _pick_audio(info):
    """audio-URL из ответа yt-dlp (или None, если пригодного нет)."""
    url = info.get('url')
    headers = info.get('http_headers') or {}
    if url:
        return url, headers

    # 'bestaudio/best' иногда указывает на формат, для которого
    # нужна склейка video+audio через ffmpeg — на телефоне ffmpeg
    # не ставим, поэтому вручную берём лучший ОТДЕЛЬНЫЙ audio-only
    # формат из списка альтернатив.
    best = None
    for fmt in info.get('formats', []):
        if fmt.get('vcodec') != 'none':
            continue
        if not fmt.get('url'):
            continue
        if best is None or (fmt.get('abr') or 0) > (best.get('abr') or 0):
            best = fmt
    if best is not None:
        return best['url'], (best.get('http_headers') or headers)
    return None, headers


def extract_audio(video_id, po_token=None, visitor_data=None):
    youtube_args = {}
    if po_token:
        # Формат аргумента yt-dlp: "<client>.<context>+<token>".
        # web.gvs — токен именно для самого стриминга (GVS-запросов),
        # где чаще всего и ловится 403 без него.
        youtube_args['po_token'] = ['web.gvs+' + po_token]
    if visitor_data:
        youtube_args['visitor_data'] = [visitor_data]
    if po_token or visitor_data:
        # У нас есть токен именно под клиент 'web' (см.
        # YoutubeSessionResolver — WebView подсматривает его из настоящей
        # web-сессии youtube.com). Без этого ограничения yt-dlp по
        # умолчанию опрашивает ЕЩЁ и другие innertube-клиенты (ios,
        # android, tv и т.п.) — для них наш web-токен не подходит, так
        # что эти запросы почти всегда просто тратятся впустую. На
        # телефоне это стабильно добавляет пару лишних секунд на
        # КАЖДЫЙ трек. Ограничиваем клиентом, под который токен
        # реально есть — резолв идёт одним запросом вместо нескольких.
        # Без токенов клиент не трогаем: тогда работает обычный перебор
        # yt-dlp, которым иногда резолвится и совсем без токена.
        youtube_args['player_client'] = ['web']

    url = None
    headers = {}
    info = None

    # ── Быстрый путь ────────────────────────────────────────────────
    # Пропускаем разбор DASH- и HLS-манифестов. Это отдельные HTTP-
    # запросы и разбор XML/плейлистов ради форматов, которые нам всё
    # равно не нужны: звуковые дорожки (itag 140/251 и прочие
    # audio-only) приходят прямо в ответе плеера. На телефоне это
    # стабильно экономит несколько секунд на трек.
    fast_args = dict(youtube_args)
    fast_args['skip'] = ['dash', 'hls']
    try:
        with yt_dlp.YoutubeDL(_base_opts(fast_args)) as ydl:
            info = ydl.extract_info(
                'https://www.youtube.com/watch?v=' + video_id,
                download=False,
            )
        url, headers = _pick_audio(info)
    except Exception:
        url = None

    # ── Обычный путь ────────────────────────────────────────────────
    # Если на быстром пути ничего не вышло (редкий формат, ролик,
    # у которого звук только в манифесте, изменившийся ответ YouTube) —
    # честно повторяем ровно тем же способом, что и раньше, без
    # пропусков. Медленнее, зато поведение в точности прежнее.
    if not url:
        with yt_dlp.YoutubeDL(_base_opts(youtube_args)) as ydl:
            info = ydl.extract_info(
                'https://www.youtube.com/watch?v=' + video_id,
                download=False,
            )
        url, headers = _pick_audio(info)

    if not url:
        raise RuntimeError('yt-dlp не нашёл проигрываемый audio-формат для этого видео')

    return json.dumps({
        'url': url,
        'headers': headers,
        'title': info.get('title'),
        'duration': info.get('duration'),
    })


def _yt_music_client():
    # Ленивая инициализация: неавторизованный YTMusic() достаточен для
    # обычного поиска по каталогу (search()), авторизация нужна только
    # для персональных данных пользователя (плейлисты, история и т.п.),
    # которые здесь не используются.
    #
    # language/location — задаём явно, а не полагаемся на автоопределение
    # системной локали: на некоторых сборках Android/Chaquopy locale
    # Python-рантайма отличается от локали устройства, а ytmusicapi
    # использует её для выбора файла с текстовыми constants (см.
    # ytmusicapi/locales) — при рассинхроне это может тихо сломать поиск.
    from ytmusicapi import YTMusic
    return YTMusic(language='en', location='US')


def _best_thumbnail(thumbnails):
    if not thumbnails:
        return None
    # ytmusicapi отдаёт список миниатюр по возрастанию размера —
    # последняя обычно самая крупная.
    return thumbnails[-1].get('url')


def search_yt_music(query, count=25):
    """Поиск треков по каталогу YouTube Music через ytmusicapi."""
    import sys
    import traceback

    try:
        print('[ytdlp_bridge] search_yt_music: initializing YTMusic()', file=sys.stderr)
        yt = _yt_music_client()

        print(f'[ytdlp_bridge] search_yt_music: querying "{query}"', file=sys.stderr)
        # filter='songs' — только треки, без клипов/альбомов/плейлистов
        # /артистов, которые ytmusicapi тоже умеет искать, но здесь не
        # нужны.
        results = yt.search(query, filter='songs', limit=count)
        print(f'[ytdlp_bridge] search_yt_music: got {len(results)} raw results', file=sys.stderr)

        tracks = []
        for item in results[:count]:
            video_id = item.get('videoId')
            if not video_id:
                continue
            artists = item.get('artists') or []
            artist_name = ', '.join(
                a.get('name', '') for a in artists if a.get('name')
            ) or 'Unknown'
            tracks.append({
                'videoId': video_id,
                'title': item.get('title', 'Unknown'),
                'artist': artist_name,
                'thumbnail': _best_thumbnail(item.get('thumbnails')),
                'duration': item.get('duration_seconds'),
                'artistId': next(
                    (a.get('id') for a in artists if a.get('id')), None),
            })

        print(f'[ytdlp_bridge] search_yt_music: {len(tracks)} usable tracks', file=sys.stderr)
        return json.dumps({'tracks': tracks})
    except Exception:
        # ВАЖНО: тут раньше был только str(e) — этого достаточно для
        # "что" сломалось, но не для "где". Кладём полный traceback и в
        # ответ (виден в Dart-консоли через YtMusicBridge), и в stderr
        # (виден в logcat по тегу "System.err"/"python.stderr" даже
        # если сообщение из Dart почему-то не долетело) — иначе
        # диагностика превращается в гадание.
        tb = traceback.format_exc()
        print(f'[ytdlp_bridge] search_yt_music FAILED:\n{tb}', file=sys.stderr)
        return json.dumps({
            'error': tb,
            'tracks': []
        })


def _yt_track(t, fallback_thumb=None, fallback_artist=None):
    """Трек из get_playlist/get_album -> формат search_yt_music."""
    artists = t.get('artists') or []
    names = ', '.join(a.get('name', '') for a in artists if a.get('name'))
    return {
        'videoId': t.get('videoId'),
        'title': t.get('title', 'Unknown'),
        'artist': names or fallback_artist or 'Unknown',
        'thumbnail': _best_thumbnail(t.get('thumbnails')) or fallback_thumb,
        'duration': t.get('duration_seconds'),
        'artistId': next((a.get('id') for a in artists if a.get('id')), None),
    }


def get_artist_yt_music(channel_id=None, name=None):
    """Страница исполнителя: альбомы+синглы и все песни (только YT Music)."""
    import sys
    import traceback

    try:
        yt = _yt_music_client()
        if not channel_id:
            found = yt.search(name, filter='artists', limit=1)
            if not found:
                return json.dumps({'error': 'artist not found'})
            channel_id = found[0].get('browseId')
        a = yt.get_artist(channel_id)

        albums = []
        for key in ('albums', 'singles'):
            sec = a.get(key) or {}
            items = sec.get('results') or []
            # В get_artist только первые несколько — полный список
            # отдельным запросом (если у секции есть params).
            if sec.get('browseId') and sec.get('params'):
                try:
                    items = yt.get_artist_albums(
                        sec['browseId'], sec['params']) or items
                except Exception:
                    pass
            for it in items:
                if not it.get('browseId'):
                    continue
                albums.append({
                    'id': it['browseId'],
                    'title': it.get('title', ''),
                    'year': it.get('year'),
                    'type': 'Single' if key == 'singles' else 'Album',
                    'thumbnail': _best_thumbnail(it.get('thumbnails')),
                })

        sec = a.get('songs') or {}
        songs = sec.get('results') or []
        if sec.get('browseId'):
            try:
                songs = yt.get_playlist(
                    sec['browseId'], limit=None).get('tracks') or songs
            except Exception:
                pass
        tracks = [_yt_track(t) for t in songs if t.get('videoId')]

        thumbs = a.get('thumbnails') or []
        return json.dumps({
            'name': a.get('name'),
            'thumbnail': thumbs[0].get('url') if thumbs else None,
            'albums': albums,
            'tracks': tracks,
        })
    except Exception:
        tb = traceback.format_exc()
        print(f'[ytdlp_bridge] get_artist_yt_music FAILED:\n{tb}', file=sys.stderr)
        return json.dumps({'error': tb})


def get_album_yt_music(browse_id):
    """Треки альбома."""
    import sys
    import traceback

    try:
        al = _yt_music_client().get_album(browse_id)
        thumb = _best_thumbnail(al.get('thumbnails'))
        artist = ', '.join(
            a.get('name', '') for a in (al.get('artists') or []) if a.get('name'))
        tracks = [_yt_track(t, thumb, artist)
                  for t in (al.get('tracks') or []) if t.get('videoId')]
        return json.dumps({'tracks': tracks})
    except Exception:
        tb = traceback.format_exc()
        print(f'[ytdlp_bridge] get_album_yt_music FAILED:\n{tb}', file=sys.stderr)
        return json.dumps({'error': tb})
