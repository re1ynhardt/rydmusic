#!/usr/bin/env python3
"""
VK Audio Metadata Extractor — v2

Что умеет:
  • Разбирает параметры из CDN-URL VK (/audios/{owner_id}_{audio_id})
  • Извлекает title/artist из query-string плейлиста (VK кладёт их туда)
  • Если метаданных нет — возвращает всё что нашлось, не None
  • Загружает обложку по URL
  • Ищет текст через Lyrics.ovh (бесплатный публичный API, не требует токена)
"""

import sys
import json
import re
import logging
from dataclasses import dataclass, asdict
from typing import Optional, Dict
from urllib.parse import urlparse, parse_qs, unquote_plus

import requests

logging.basicConfig(
    level=logging.INFO,
    stream=sys.stderr,
    format="[VK_META] %(levelname)s: %(message)s",
)
logger = logging.getLogger(__name__)

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)
REQUEST_TIMEOUT = 10


@dataclass
class TrackMetadata:
    title: str
    artist: str
    duration: int                   # секунды
    cover_url: Optional[str] = None
    lyrics: Optional[str] = None
    album: Optional[str] = None
    release_date: Optional[str] = None
    genre: Optional[str] = None


class VKMetadataExtractor:
    """Извлекает метаданные VK-трека из URL плейлиста."""

    # VK CDN-URL обычно выглядит так:
    #   https://cs1-XX.vkuseraudio.net/.../index.m3u8?
    #       extra=...&siren=1&title=Song+Name&performer=Artist&...
    # Иногда title/performer кодированы в URL.
    _RE_DURATION_IN_URL = re.compile(r"[?&]dur(?:ation)?=(\d+)")

    def __init__(self) -> None:
        self._s = requests.Session()
        self._s.headers["User-Agent"] = USER_AGENT

    # ── Публичный API ────────────────────────────────────────────────────
    def extract(self, playlist_url: str) -> TrackMetadata:
        """
        Извлекает всё что можно из URL плейлиста.
        НИКОГДА не возвращает None — только TrackMetadata с тем что есть.
        """
        meta = self._from_url_params(playlist_url)

        # Если из query-string ничего не вышло — делаем HEAD/GET запрос
        # и смотрим на заголовки (VK иногда их выставляет)
        if meta.title == "Unknown" or meta.artist == "Unknown":
            headers_meta = self._from_response_headers(playlist_url)
            if headers_meta.title != "Unknown":
                meta.title = headers_meta.title
            if headers_meta.artist != "Unknown":
                meta.artist = headers_meta.artist

        logger.info("Метаданные: %s — %s (%ds)", meta.artist, meta.title, meta.duration)
        return meta

    def fetch_lyrics(self, title: str, artist: str) -> Optional[str]:
        """Ищет текст через lyrics.ovh (бесплатный, без токена)."""
        if title == "Unknown" or artist == "Unknown":
            return None
        try:
            url = f"https://api.lyrics.ovh/v1/{requests.utils.quote(artist)}/{requests.utils.quote(title)}"
            r = self._s.get(url, timeout=REQUEST_TIMEOUT)
            if r.status_code == 200:
                data = r.json()
                lyrics = data.get("lyrics", "").strip()
                return lyrics or None
        except Exception as exc:
            logger.debug("Не удалось получить текст: %s", exc)
        return None

    def download_cover(self, cover_url: str, output_file: Optional[str] = None) -> Optional[bytes]:
        """Загружает обложку. Возвращает байты или None."""
        if not cover_url:
            return None
        try:
            r = self._s.get(cover_url, timeout=REQUEST_TIMEOUT)
            r.raise_for_status()
            data = r.content
            if output_file:
                with open(output_file, "wb") as fh:
                    fh.write(data)
                logger.info("Обложка сохранена: %s", output_file)
            return data
        except Exception as exc:
            logger.error("Ошибка загрузки обложки: %s", exc)
            return None

    # ── Внутренние методы ────────────────────────────────────────────────
    def _from_url_params(self, url: str) -> TrackMetadata:
        """Парсит query-string VK CDN URL."""
        parsed = urlparse(url)
        params = parse_qs(parsed.query, keep_blank_values=False)

        def get(*keys: str) -> str:
            for k in keys:
                vals = params.get(k)
                if vals:
                    return unquote_plus(vals[0])
            return "Unknown"

        title    = get("title", "t")
        artist   = get("performer", "artist", "a")
        album    = get("album", "al") if get("album", "al") != "Unknown" else None
        cover    = get("cover_url", "thumb", "photo") if get("cover_url", "thumb", "photo") != "Unknown" else None
        genre    = get("genre") if get("genre") != "Unknown" else None
        rel_date = get("release_date", "year") if get("release_date", "year") != "Unknown" else None

        dur_raw = get("duration", "dur", "d")
        try:
            duration = int(dur_raw)
        except (ValueError, TypeError):
            m = self._RE_DURATION_IN_URL.search(url)
            duration = int(m.group(1)) if m else 0

        return TrackMetadata(
            title=title,
            artist=artist,
            duration=duration,
            cover_url=cover,
            album=album,
            genre=genre,
            release_date=rel_date,
        )

    def _from_response_headers(self, url: str) -> TrackMetadata:
        """Делает HEAD-запрос и смотрит на нестандартные заголовки VK."""
        try:
            r = self._s.head(url, timeout=REQUEST_TIMEOUT, allow_redirects=True)
            h = r.headers
            title  = h.get("X-Track-Title",  h.get("x-track-title",  "Unknown"))
            artist = h.get("X-Track-Artist", h.get("x-track-artist", "Unknown"))
            dur_s  = h.get("X-Track-Duration", "0")
            try:
                duration = int(dur_s)
            except ValueError:
                duration = 0
            return TrackMetadata(title=title, artist=artist, duration=duration)
        except Exception as exc:
            logger.debug("HEAD запрос не удался: %s", exc)
            return TrackMetadata(title="Unknown", artist="Unknown", duration=0)


# ─── CLI ─────────────────────────────────────────────────────────────────────
def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(description="VK Metadata Extractor")
    sub = ap.add_subparsers(dest="cmd")

    ex = sub.add_parser("extract", help="Извлечь метаданные из URL плейлиста")
    ex.add_argument("url")
    ex.add_argument("--lyrics", action="store_true", help="Также получить текст")

    cv = sub.add_parser("cover", help="Скачать обложку")
    cv.add_argument("url")
    cv.add_argument("--output", "-o")

    args = ap.parse_args()
    ext = VKMetadataExtractor()

    if args.cmd == "extract":
        meta = ext.extract(args.url)
        d = asdict(meta)
        if args.lyrics:
            d["lyrics"] = ext.fetch_lyrics(meta.title, meta.artist)
        print(json.dumps(d, ensure_ascii=False, indent=2))

    elif args.cmd == "cover":
        data = ext.download_cover(args.url, args.output)
        if data:
            import base64
            result: dict = {"success": True, "size": len(data)}
            if args.output:
                result["output_file"] = args.output
            else:
                result["cover_data"] = base64.b64encode(data).decode()
            print(json.dumps(result))
        else:
            print(json.dumps({"error": "Не удалось загрузить обложку"}))
            sys.exit(1)

    else:
        ap.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
