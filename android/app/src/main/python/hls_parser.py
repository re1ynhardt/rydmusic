#!/usr/bin/env python3
"""
VK Audio HLS Parser & Decryptor — v2
Парсер HLS-манифестов с AES-128-CBC дешифровкой.

Улучшения по сравнению с v1:
  • Поддержка мастер-плейлиста (один .m3u8 ссылается на другой .m3u8)
  • Параллельная загрузка сегментов (ThreadPoolExecutor)
  • Per-segment IV (счётчик сегментов по умолчанию, если IV не указан явно)
  • Прогресс-коллбэк (JSON-строки в stderr, чтобы не ломать stdout-ответ)
  • Корректный PKCS7-unpadding с проверкой
  • Retry (3 попытки) на каждый сегмент
  • Единственный публичный класс: VKHLSParser
"""

import sys
import json
import re
import io
import logging
import struct
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from typing import Optional, Dict, List, Callable
from urllib.parse import urljoin, urlparse

import requests
from Crypto.Cipher import AES

# ─── Логирование ────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    stream=sys.stderr,
    format="[VK_HLS] %(levelname)s: %(message)s",
)
logger = logging.getLogger(__name__)

# ─── Константы ──────────────────────────────────────────────────────────────
DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)
REQUEST_TIMEOUT = 15        # секунд
MAX_PARALLEL_SEGMENTS = 6   # потоков для загрузки
SEGMENT_RETRY = 3           # попыток на один сегмент


# ─── Датаклассы ─────────────────────────────────────────────────────────────
@dataclass
class KeyInfo:
    method: str                     # AES-128 | NONE | SAMPLE-AES
    uri: Optional[str] = None
    iv: Optional[bytes] = None      # явный IV из манифеста (16 байт) или None


@dataclass
class AudioSegment:
    index: int
    uri: str
    duration: float
    key_info: Optional[KeyInfo] = None


@dataclass
class HLSPlaylist:
    version: int
    target_duration: float
    segments: List[AudioSegment]
    base_url: str
    # Кэш ключей: uri → bytes
    key_cache: Dict[str, bytes] = field(default_factory=dict)
    total_duration: float = 0.0


# ─── Парсер ─────────────────────────────────────────────────────────────────
class VKHLSParser:
    """Парсер HLS-манифестов и дешифровщик сегментов для VK Audio."""

    # ── Регулярки ────────────────────────────────────────────────────────
    _RE_EXTINF   = re.compile(r"#EXTINF:([\d.]+)")
    _RE_KEY      = re.compile(r"#EXT-X-KEY:(.+)")
    _RE_ATTR     = re.compile(r'(\w[\w-]*)=(?:"([^"]*?)"|([^,\s"]+))')
    _RE_VERSION  = re.compile(r"#EXT-X-VERSION:(\d+)")
    _RE_DURATION = re.compile(r"#EXT-X-TARGETDURATION:(\d+)")
    _RE_M3U8_URL = re.compile(r"https?://\S+\.m3u8\S*")

    def __init__(self) -> None:
        self._session = requests.Session()
        self._session.headers["User-Agent"] = DEFAULT_USER_AGENT

    # ── Публичный API ────────────────────────────────────────────────────
    def parse_m3u8(self, url: str) -> Optional[HLSPlaylist]:
        """
        Парсит M3U8 (поддерживает мастер-плейлист).
        Возвращает HLSPlaylist или None при ошибке.
        """
        try:
            content, resolved_url = self._fetch_text(url)
            if content is None:
                return None

            # Мастер-плейлист? → находим лучший медиа-поток
            if "#EXT-X-STREAM-INF" in content or (
                "#EXTM3U" in content and "#EXTINF" not in content
            ):
                logger.info("Обнаружен мастер-плейлист, выбираем лучшее качество")
                resolved_url = self._pick_best_variant(content, resolved_url)
                if not resolved_url:
                    logger.error("Не найден медиа-поток в мастер-плейлисте")
                    return None
                content, resolved_url = self._fetch_text(resolved_url)
                if content is None:
                    return None

            base_url = resolved_url.rsplit("/", 1)[0] + "/"
            return self._build_playlist(content, base_url)

        except Exception as exc:
            logger.error("parse_m3u8: %s", exc, exc_info=True)
            return None

    def download_and_decrypt(
        self,
        playlist: HLSPlaylist,
        output_file: Optional[str] = None,
        progress_cb: Optional[Callable[[int, int], None]] = None,
    ) -> Optional[bytes]:
        """
        Параллельно загружает сегменты, дешифрует и склеивает в один поток.
        Возвращает сырые байты (MPEG-TS) или None.
        """
        n = len(playlist.segments)
        logger.info("Загружаем %d сегментов (параллельно, до %d потоков)", n, MAX_PARALLEL_SEGMENTS)

        # Заранее загружаем все уникальные ключи (чтобы не делать это параллельно
        # и не создавать гонки при кэшировании)
        for seg in playlist.segments:
            if seg.key_info and seg.key_info.uri:
                self._load_key(seg.key_info.uri, playlist)

        # Параллельная загрузка + дешифровка
        results: Dict[int, Optional[bytes]] = {}
        with ThreadPoolExecutor(max_workers=MAX_PARALLEL_SEGMENTS) as pool:
            future_to_index = {
                pool.submit(self._fetch_and_decrypt, seg, playlist): seg.index
                for seg in playlist.segments
            }
            done_count = 0
            for future in as_completed(future_to_index):
                idx = future_to_index[future]
                try:
                    results[idx] = future.result()
                except Exception as exc:
                    logger.warning("Сегмент %d упал с ошибкой: %s", idx, exc)
                    results[idx] = None
                done_count += 1
                if progress_cb:
                    progress_cb(done_count, n)
                # Прогресс в stderr
                pct = int(done_count / n * 100)
                logger.info("Прогресс: %d/%d (%d%%)", done_count, n, pct)

        # Склеиваем в порядке сегментов
        buf = io.BytesIO()
        for seg in playlist.segments:
            chunk = results.get(seg.index)
            if chunk:
                buf.write(chunk)
            else:
                logger.warning("Сегмент %d пропущен (ошибка загрузки/дешифровки)", seg.index)

        data = buf.getvalue()
        if not data:
            logger.error("Результирующий буфер пуст")
            return None

        logger.info("Склеено %d байт", len(data))

        if output_file:
            with open(output_file, "wb") as fh:
                fh.write(data)
            logger.info("Сохранено в %s", output_file)

        return data

    # ── Внутренние методы ────────────────────────────────────────────────
    def _fetch_text(self, url: str):
        """Загружает текстовый ресурс. Возвращает (text, final_url) или (None, None)."""
        try:
            r = self._session.get(url, timeout=REQUEST_TIMEOUT)
            r.raise_for_status()
            return r.text, r.url
        except Exception as exc:
            logger.error("Ошибка загрузки %s: %s", url, exc)
            return None, None

    def _pick_best_variant(self, master_content: str, base_url: str) -> Optional[str]:
        """
        Из мастер-плейлиста выбирает медиа-поток с максимальным битрейтом.
        """
        best_bw = -1
        best_uri = None
        lines = master_content.splitlines()
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith("#EXT-X-STREAM-INF"):
                attrs = self._parse_attrs(line)
                bw = int(attrs.get("BANDWIDTH", "0"))
                if i + 1 < len(lines):
                    uri = lines[i + 1].strip()
                    if uri and not uri.startswith("#"):
                        if not uri.startswith("http"):
                            uri = urljoin(base_url, uri)
                        if bw > best_bw:
                            best_bw, best_uri = bw, uri
            i += 1
        return best_uri

    def _build_playlist(self, content: str, base_url: str) -> Optional[HLSPlaylist]:
        """Парсит медиа-плейлист и возвращает HLSPlaylist."""
        ver_m = self._RE_VERSION.search(content)
        dur_m = self._RE_DURATION.search(content)
        version = int(ver_m.group(1)) if ver_m else 3
        target_dur = float(dur_m.group(1)) if dur_m else 10.0

        segments = self._parse_segments(content, base_url)
        if not segments:
            logger.error("Не найдены сегменты в плейлисте")
            return None

        total_dur = sum(s.duration for s in segments)
        logger.info(
            "Распарсено %d сегментов, суммарно %.2f с", len(segments), total_dur
        )
        return HLSPlaylist(
            version=version,
            target_duration=target_dur,
            segments=segments,
            base_url=base_url,
            total_duration=total_dur,
        )

    def _parse_segments(self, content: str, base_url: str) -> List[AudioSegment]:
        segments: List[AudioSegment] = []
        lines = content.splitlines()
        cur_dur = 0.0
        cur_key: Optional[KeyInfo] = None
        seg_idx = 0

        for line in lines:
            line = line.strip()
            if not line:
                continue

            if line.startswith("#EXT-X-KEY:"):
                cur_key = self._parse_key_tag(line)

            elif line.startswith("#EXTINF:"):
                m = self._RE_EXTINF.match(line)
                if m:
                    cur_dur = float(m.group(1))

            elif not line.startswith("#"):
                uri = line if line.startswith("http") else urljoin(base_url, line)

                # Per-segment IV: если явный IV не задан в манифесте,
                # используем номер сегмента (big-endian 16 байт) — стандарт HLS §6.3.3
                key_info = None
                if cur_key:
                    explicit_iv = cur_key.iv
                    if explicit_iv is None:
                        # IV = segment sequence number
                        implicit_iv = struct.pack(">16B", *([0] * 12 + list(struct.pack(">I", seg_idx))))
                        key_info = KeyInfo(
                            method=cur_key.method,
                            uri=cur_key.uri,
                            iv=implicit_iv,
                        )
                    else:
                        key_info = cur_key

                segments.append(AudioSegment(
                    index=seg_idx,
                    uri=uri,
                    duration=cur_dur,
                    key_info=key_info,
                ))
                seg_idx += 1
                cur_dur = 0.0

        return segments

    def _parse_key_tag(self, line: str) -> Optional[KeyInfo]:
        """Парсит #EXT-X-KEY:METHOD=AES-128,URI="...",IV=0x..."""
        attrs = self._parse_attrs(line[len("#EXT-X-KEY:"):])
        method = attrs.get("METHOD", "NONE")
        if method == "NONE":
            return None

        uri = attrs.get("URI")
        iv_str = attrs.get("IV")
        iv_bytes: Optional[bytes] = None
        if iv_str:
            iv_hex = iv_str.replace("0x", "").replace("0X", "").strip()
            try:
                iv_bytes = bytes.fromhex(iv_hex.zfill(32))  # дополняем до 16 байт
            except ValueError:
                logger.warning("Не удалось разобрать IV: %s", iv_str)

        return KeyInfo(method=method, uri=uri, iv=iv_bytes)

    def _parse_attrs(self, attrs_str: str) -> Dict[str, str]:
        """Парсит строку атрибутов HLS вида KEY=VALUE,KEY2="VALUE2"."""
        result = {}
        for m in self._RE_ATTR.finditer(attrs_str):
            key = m.group(1)
            val = m.group(2) if m.group(2) is not None else m.group(3)
            result[key] = val
        return result

    def _load_key(self, key_uri: str, playlist: HLSPlaylist) -> Optional[bytes]:
        """Загружает ключ и кэширует его в playlist.key_cache."""
        if key_uri in playlist.key_cache:
            return playlist.key_cache[key_uri]
        try:
            logger.info("Загружаем ключ AES: %s", key_uri)
            r = self._session.get(key_uri, timeout=REQUEST_TIMEOUT)
            r.raise_for_status()
            key = r.content
            if len(key) < 16:
                logger.error("Ключ слишком короткий: %d байт", len(key))
                return None
            playlist.key_cache[key_uri] = key
            return key
        except Exception as exc:
            logger.error("Ошибка загрузки ключа %s: %s", key_uri, exc)
            return None

    def _fetch_and_decrypt(
        self, seg: AudioSegment, playlist: HLSPlaylist
    ) -> Optional[bytes]:
        """Загружает один сегмент (с retry) и дешифрует его."""
        data = None
        for attempt in range(1, SEGMENT_RETRY + 1):
            try:
                r = self._session.get(seg.uri, timeout=REQUEST_TIMEOUT)
                r.raise_for_status()
                data = r.content
                break
            except Exception as exc:
                logger.warning(
                    "Сегмент %d, попытка %d/%d: %s",
                    seg.index, attempt, SEGMENT_RETRY, exc,
                )
        if data is None:
            return None

        if not seg.key_info or seg.key_info.method == "NONE":
            return data

        if seg.key_info.method != "AES-128":
            logger.warning(
                "Метод %s не поддерживается, возвращаем raw", seg.key_info.method
            )
            return data

        key = self._load_key(seg.key_info.uri, playlist) if seg.key_info.uri else None
        if not key:
            logger.error("Ключ не доступен для сегмента %d", seg.index)
            return None

        return self._aes_cbc_decrypt(data, key[:16], seg.key_info.iv or b"\x00" * 16)

    @staticmethod
    def _aes_cbc_decrypt(data: bytes, key: bytes, iv: bytes) -> Optional[bytes]:
        """AES-128-CBC дешифровка + PKCS7 unpadding с валидацией."""
        try:
            cipher = AES.new(key, AES.MODE_CBC, iv)
            plain = cipher.decrypt(data)

            # PKCS7 unpadding
            pad_len = plain[-1]
            if not (1 <= pad_len <= 16):
                logger.warning("Некорректный PKCS7 padding byte: %d — пропускаем unpadding", pad_len)
                return plain
            # Проверяем, что все байты паддинга одинаковы
            if plain[-pad_len:] != bytes([pad_len]) * pad_len:
                logger.warning("PKCS7 padding не прошёл проверку — возвращаем без unpadding")
                return plain
            return plain[:-pad_len]

        except Exception as exc:
            logger.error("AES дешифровка упала: %s", exc)
            return None


# ─── CLI ─────────────────────────────────────────────────────────────────────
def main() -> None:
    import argparse

    ap = argparse.ArgumentParser(description="VK HLS Parser — AES-128 decryptor")
    ap.add_argument("url", help="URL .m3u8 манифеста")
    ap.add_argument("--output", "-o", help="Путь для сохранения (MPEG-TS / .ts)")
    ap.add_argument("--info", action="store_true", help="Только вывести информацию о плейлисте")
    args = ap.parse_args()

    parser = VKHLSParser()
    playlist = parser.parse_m3u8(args.url)
    if not playlist:
        print(json.dumps({"error": "Не удалось разобрать M3U8"}))
        sys.exit(1)

    if args.info:
        has_enc = any(s.key_info and s.key_info.method != "NONE" for s in playlist.segments)
        print(json.dumps({
            "success": True,
            "playlist": {
                "version": playlist.version,
                "target_duration": playlist.target_duration,
                "total_duration": playlist.total_duration,
                "segments_count": len(playlist.segments),
                "has_encryption": has_enc,
                "encryption_method": (
                    playlist.segments[0].key_info.method
                    if has_enc and playlist.segments[0].key_info
                    else "NONE"
                ),
            },
        }, ensure_ascii=False, indent=2))
        return

    audio = parser.download_and_decrypt(playlist, output_file=args.output)
    if not audio:
        print(json.dumps({"error": "Не удалось загрузить/расшифровать сегменты"}))
        sys.exit(1)

    import base64
    result: dict = {
        "success": True,
        "size": len(audio),
        "total_duration": playlist.total_duration,
        "segments_count": len(playlist.segments),
    }
    if args.output:
        result["output_file"] = args.output
    else:
        result["audio_data"] = base64.b64encode(audio).decode()

    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
