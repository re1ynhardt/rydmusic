#!/usr/bin/env python3
"""
VK Audio Parser — Flutter ↔ Python Bridge (v2)

Единая точка входа: читает аргументы и вызывает нужный модуль.

Все ответы — JSON в stdout.
Прогресс и логи — в stderr (Flutter читает stdout отдельным каналом).
"""

import sys
import json
import argparse
import base64
import logging
from dataclasses import asdict
from typing import Optional

from hls_parser import VKHLSParser
from vk_metadata import VKMetadataExtractor

logging.basicConfig(
    level=logging.INFO,
    stream=sys.stderr,
    format="[VK_BRIDGE] %(levelname)s: %(message)s",
)
logger = logging.getLogger(__name__)


def _ok(**kwargs) -> None:
    print(json.dumps({"success": True, **kwargs}, ensure_ascii=False))


def _err(msg: str) -> None:
    print(json.dumps({"error": msg}, ensure_ascii=False))


# ─── Команды ─────────────────────────────────────────────────────────────────

def cmd_parse(url: str) -> None:
    """Парсит M3U8 и возвращает информацию о плейлисте (без загрузки)."""
    parser = VKHLSParser()
    pl = parser.parse_m3u8(url)
    if not pl:
        _err("Не удалось разобрать M3U8")
        return

    has_enc = any(s.key_info and s.key_info.method != "NONE" for s in pl.segments)
    enc_method = (
        pl.segments[0].key_info.method
        if has_enc and pl.segments[0].key_info
        else "NONE"
    )
    _ok(playlist={
        "version": pl.version,
        "target_duration": pl.target_duration,
        "total_duration": round(pl.total_duration, 3),
        "segments_count": len(pl.segments),
        "has_encryption": has_enc,
        "encryption_method": enc_method,
    })


def cmd_download(url: str, output: Optional[str]) -> None:
    """Загружает, дешифрует и либо сохраняет файл, либо отдаёт base64."""
    parser = VKHLSParser()
    pl = parser.parse_m3u8(url)
    if not pl:
        _err("Не удалось разобрать M3U8")
        return

    audio = parser.download_and_decrypt(pl, output_file=output)
    if not audio:
        _err("Не удалось загрузить/расшифровать сегменты")
        return

    if output:
        _ok(output_file=output, size=len(audio))
    else:
        _ok(audio_data=base64.b64encode(audio).decode(), size=len(audio))


def cmd_metadata(url: str, with_lyrics: bool = False) -> None:
    """Извлекает метаданные трека из URL плейлиста."""
    ext = VKMetadataExtractor()
    meta = ext.extract(url)
    d = asdict(meta)
    if with_lyrics and meta.title != "Unknown":
        d["lyrics"] = ext.fetch_lyrics(meta.title, meta.artist)
    print(json.dumps({"success": True, **d}, ensure_ascii=False))


def cmd_cover(url: str, output: Optional[str]) -> None:
    """Скачивает обложку трека."""
    ext = VKMetadataExtractor()
    data = ext.download_cover(url, output)
    if not data:
        _err("Не удалось загрузить обложку")
        return
    if output:
        _ok(output_file=output, size=len(data))
    else:
        _ok(cover_data=base64.b64encode(data).decode(), size=len(data))


# ─── main ────────────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="VK Audio Parser Bridge v2")
    sub = ap.add_subparsers(dest="command")

    # parse
    p = sub.add_parser("parse", help="Парсинг M3U8 манифеста")
    p.add_argument("url")

    # download
    d = sub.add_parser("download", help="Загрузка и дешифровка аудио")
    d.add_argument("url")
    d.add_argument("--output", "-o", default=None)

    # metadata
    m = sub.add_parser("metadata", help="Метаданные трека")
    m.add_argument("url")
    m.add_argument("--lyrics", action="store_true")

    # cover
    c = sub.add_parser("cover", help="Загрузка обложки")
    c.add_argument("url")
    c.add_argument("--output", "-o", default=None)

    args = ap.parse_args()

    try:
        if args.command == "parse":
            cmd_parse(args.url)
        elif args.command == "download":
            cmd_download(args.url, args.output)
        elif args.command == "metadata":
            cmd_metadata(args.url, getattr(args, "lyrics", False))
        elif args.command == "cover":
            cmd_cover(args.url, args.output)
        else:
            ap.print_help(sys.stderr)
            sys.exit(1)
    except Exception as exc:
        logger.error("Необработанная ошибка: %s", exc, exc_info=True)
        _err(str(exc))
        sys.exit(1)


if __name__ == "__main__":
    main()
