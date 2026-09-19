"""
vk_hls_bridge.py — точка входа для Chaquopy.

Кладётся рядом с ytdlp_bridge.py:
  android/app/src/main/python/vk_hls_bridge.py

hls_parser.py и vk_metadata.py тоже должны лежать там же
(Chaquopy добавляет эту папку в sys.path автоматически).

Все функции возвращают строку JSON — MainActivity.kt вызывает
.toString() на результате callAttr() и отдаёт её в Flutter.
"""

import json
import base64
from dataclasses import asdict

from hls_parser import VKHLSParser
from vk_metadata import VKMetadataExtractor

_hls  = VKHLSParser()
_meta = VKMetadataExtractor()


# ── Вызывается из handleVkParseM3U8 ─────────────────────────────────────────
def parse_m3u8(url: str) -> str:
    pl = _hls.parse_m3u8(url)
    if not pl:
        return _err("Не удалось разобрать M3U8")

    has_enc = any(s.key_info and s.key_info.method != "NONE" for s in pl.segments)
    return json.dumps({
        "success": True,
        "playlist": {
            "version":          pl.version,
            "target_duration":  pl.target_duration,
            "total_duration":   round(pl.total_duration, 3),
            "segments_count":   len(pl.segments),
            "has_encryption":   has_enc,
            "encryption_method": (
                pl.segments[0].key_info.method
                if has_enc and pl.segments[0].key_info else "NONE"
            ),
        },
    }, ensure_ascii=False)


# ── Вызывается из handleVkDownload ───────────────────────────────────────────
def download_and_decrypt(url: str, output_file=None) -> str:
    pl = _hls.parse_m3u8(url)
    if not pl:
        return _err("Не удалось разобрать M3U8")

    audio = _hls.download_and_decrypt(pl, output_file=output_file)
    if not audio and not output_file:
        return _err("Не удалось загрузить/расшифровать сегменты")

    if output_file:
        return json.dumps({"success": True, "output_file": output_file,
                           "size": len(audio) if audio else 0},
                          ensure_ascii=False)
    else:
        return json.dumps({"success": True,
                           "audio_data": base64.b64encode(audio).decode(),
                           "size": len(audio)},
                          ensure_ascii=False)


# ── Вызывается из handleVkMetadata ───────────────────────────────────────────
def get_metadata(url: str) -> str:
    meta = _meta.extract(url)
    return json.dumps({"success": True, **asdict(meta)}, ensure_ascii=False)


# ── Вызывается из handleVkCover ──────────────────────────────────────────────
def download_cover(url: str, output_file=None) -> str:
    data = _meta.download_cover(url, output_file)
    if not data:
        return _err("Не удалось загрузить обложку")

    if output_file:
        return json.dumps({"success": True, "output_file": output_file,
                           "size": len(data)},
                          ensure_ascii=False)
    else:
        return json.dumps({"success": True,
                           "cover_data": base64.b64encode(data).decode(),
                           "size": len(data)},
                          ensure_ascii=False)


def _err(msg: str) -> str:
    return json.dumps({"error": msg}, ensure_ascii=False)
