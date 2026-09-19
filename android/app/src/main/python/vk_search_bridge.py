"""
VK Search Bridge — поиск по каталогу VK через официальный метод
audio.search, но с access_token, полученным от имени Kate Mobile
(см. vk_auth_bridge.py). Без такого токена audio.search закрыт для
сторонних приложений и вернёт ошибку доступа.

User-Agent обязателен: VK помимо токена сверяет заголовок запроса с
тем клиентом, от имени которого токен был выдан — без правильного
User-Agent audio.get/audio.search могут молча возвращать пустой
результат или ошибку "Access denied" даже с валидным токеном.
"""

import json

import requests

API_VERSION = "5.131"
_TIMEOUT = 15


def _request(method: str, access_token: str, user_agent: str, **params) -> dict:
    query = {"v": API_VERSION, "access_token": access_token, **params}
    headers = {"User-Agent": user_agent} if user_agent else {}
    resp = requests.get(
        f"https://api.vk.com/method/{method}",
        params=query,
        headers=headers,
        timeout=_TIMEOUT,
    )
    resp.raise_for_status()
    return resp.json()


def _track_from_item(item: dict) -> dict:
    return {
        # owner_id_id — стандартный составной идентификатор аудио в VK,
        # нужен, например, для audio.getById.
        "id": f'{item.get("owner_id")}_{item.get("id")}',
        "title": item.get("title") or "Unknown",
        "artist": item.get("artist") or "VK",
        # В секундах, как и everywhere в приложении.
        "duration": item.get("duration"),
        # Может быть как прямой mp3, так и m3u8 (шифрованный HLS) —
        # различить и обработать m3u8 нужно уже на Dart-стороне через
        # VKHLSService/vk_hls_bridge.py.
        "url": item.get("url") or "",
    }


def search(access_token: str, user_agent: str, query: str, count: int = 25, offset: int = 0) -> str:
    try:
        data = _request(
            "audio.search",
            access_token,
            user_agent,
            q=query,
            count=count,
            offset=offset,
        )
    except Exception as exc:
        return json.dumps({"error": True, "message": str(exc)}, ensure_ascii=False)

    if "error" in data:
        err = data["error"]
        return json.dumps(
            {
                "error": True,
                "code": err.get("error_code"),
                "message": err.get("error_msg"),
            },
            ensure_ascii=False,
        )

    items = data.get("response", {}).get("items", [])
    tracks = [_track_from_item(it) for it in items if it.get("url") or it.get("id")]
    return json.dumps({"success": True, "tracks": tracks}, ensure_ascii=False)
