"""
VK Auth Bridge — получение access_token для VK Audio API прямой
авторизацией (login/password) под видом официального клиента Kate
Mobile, через библиотеку vkaudiotoken.

Официальный audio.search/audio.get закрыт для сторонних приложений с
2016 года, но токен, полученный от имени "доверенного" client_id (Kate
Mobile), сохраняет доступ к этим методам — так работает большинство
неофициальных VK-музыкальных клиентов.

Вызывается из MainActivity.kt (канал "rydmusic/vk_hls", методы
"login"/"search" через vk_search_bridge.py) через Chaquopy.
Все ответы — JSON-строка, чтобы Kotlin не завязывался на Python-типы.
"""

import json

from vkaudiotoken import get_kate_token
from vkaudiotoken.TokenException import TokenException


def _error_json(exc) -> str:
    """
    Аккуратно вытаскивает из TokenException всё, что она реально
    содержит (captcha_sid/captcha_img при need_captcha,
    validation_sid/phone_mask/redirect_uri при need_validation —
    двухфакторка). Библиотека не документирует точный набор атрибутов
    по каждому типу ошибки, поэтому забираем через getattr с
    дефолтом None и кладём в JSON только то, что реально пришло —
    так UI сам поймёт, какой следующий шаг нужен (код по SMS / капча),
    по наличию соответствующих полей.
    """
    payload = {"error": True}
    for attr in (
        "code",
        "message",
        "msg",
        "captcha_sid",
        "captcha_img",
        "validation_sid",
        "validation_type",
        "redirect_uri",
        "phone_mask",
    ):
        value = getattr(exc, attr, None)
        if value is not None:
            payload[attr] = value
    if "message" not in payload and "msg" not in payload:
        payload["message"] = str(exc)
    return json.dumps(payload, ensure_ascii=False)


def login(
    username: str,
    password: str,
    auth_code: str = None,
    captcha_sid: str = None,
    captcha_key: str = None,
) -> str:
    """
    Прямая авторизация под client_id Kate Mobile.

    Первый вызов — только username/password. Если VK потребует код
    по SMS — вернётся error с validation_sid/phone_mask, повторяем
    вызов с тем же username/password и auth_code=<код из SMS>. Если
    потребует капчу — вернётся error с captcha_sid/captcha_img,
    повторяем с captcha_sid + captcha_key=<текст с картинки>.
    """
    try:
        result = get_kate_token(
            username,
            password,
            auth_code=auth_code or None,
            captcha_sid=captcha_sid or None,
            captcha_key=captcha_key or None,
        )
    except TokenException as exc:
        return _error_json(exc)
    except Exception as exc:  # сеть, парсинг и т.п. — не даём упасть в Kotlin как PyException без деталей
        return json.dumps({"error": True, "message": str(exc)}, ensure_ascii=False)

    return json.dumps(
        {
            "success": True,
            "token": result.get("token"),
            "user_agent": result.get("user_agent"),
            "user_id": result.get("user_id"),
        },
        ensure_ascii=False,
    )
