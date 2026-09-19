package com.example.rydmusic

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.content.FileProvider
import com.chaquo.python.PyException
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import java.io.File

/**
 * MethodChannel "rydmusic/yt_dlp" — мост в Python-интерпретатор,
 * вшитый в APK через Chaquopy. Dart-сторона шлёт сюда:
 *  - "searchYtMusic": query/count -> ytmusicapi ищет по каталогу
 *    YouTube Music (см. lib/services/youtube_music_bridge.dart).
 *  - "extractAudio": videoId + po_token/visitor_data, добытые скрытым
 *    WebView (см. lib/services/youtube_po_token_resolver.dart), ->
 *    yt-dlp извлекает финальный проигрываемый audio-URL
 *    (см. lib/services/youtube_ytdlp_bridge.dart).
 * Вся Python-логика — в android/app/src/main/python/ytdlp_bridge.py.
 *
 * MethodChannel "rydmusic/vk_hls" — мост для всего, что касается VK:
 *  - "login": прямая авторизация под client_id Kate Mobile
 *    (vk_auth_bridge.py) — получение access_token для audio.search.
 *  - "search": поиск по каталогу VK этим токеном (vk_search_bridge.py).
 *  - "parseM3U8"/"downloadAndDecryptSegments"/"getTrackMetadata"/
 *    "downloadCover": HLS-парсер с AES-128-CBC дешифровкой
 *    (vk_hls_bridge.py) — часть найденных audio.search треков отданы
 *    VK как зашифрованный HLS, а не прямой mp3.
 *
 * ВАЖНО: наследуемся от AudioServiceActivity (а не голого
 * FlutterActivity) и в AndroidManifest.xml активность называется
 * ".MainActivity" (а не "com.ryanheise.audioservice.AudioServiceActivity"
 * напрямую) — иначе Android запускает вообще ДРУГОЙ класс (встроенный
 * в audio_service), у которого нет наших MethodChannel'ов, и Dart-сторона
 * получает MissingPluginException на любой вызов сюда. См.
 * https://github.com/ryanheise/audio_service/issues/937.
 */
class MainActivity : AudioServiceActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(applicationContext))
        }

        // ── Канал 1: yt-dlp (без изменений) ────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rydmusic/yt_dlp")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "extractAudio"   -> handleExtractAudio(call, result)
                    "searchYtMusic"  -> handleSearchYtMusic(call, result)
                    "getArtistYtMusic" -> callYtBridge(result, "get_artist_yt_music",
                        call.argument<String>("channelId"), call.argument<String>("name"))
                    "getAlbumYtMusic"  -> callYtBridge(result, "get_album_yt_music",
                        call.argument<String>("browseId"))
                    else             -> result.notImplemented()
                }
            }

        // ── Канал 2: VK HLS (новый) ─────────────────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rydmusic/vk_hls")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "login"                      -> handleVkLogin(call, result)
                    "search"                     -> handleVkSearch(call, result)
                    "parseM3U8"                  -> handleVkParseM3U8(call, result)
                    "downloadAndDecryptSegments" -> handleVkDownload(call, result)
                    "getTrackMetadata"           -> handleVkMetadata(call, result)
                    "downloadCover"              -> handleVkCover(call, result)
                    else                         -> result.notImplemented()
                }
            }

        // ── Канал 3: установка обновления APK ──────────────────────────
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rydmusic/app_update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> installApk(call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun installApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        val apk = path?.let(::File)
        if (apk == null || !apk.exists()) {
            result.error("BAD_ARGS", "APK file was not found", null)
            return
        }
        try {
            // Android 8+ выдаёт это право отдельно для каждого приложения.
            // Если оно ещё не дано, отправляем пользователя в штатные настройки.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                startActivity(Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName"),
                ))
                result.success(null)
                return
            }
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                apk,
            )
            startActivity(Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
            result.success(null)
        } catch (e: Exception) {
            result.error("INSTALL_ERROR", e.message, null)
        }
    }

    // ════════════════════════════════════════════════════════════════════
    //  yt-dlp handlers (оригинальный код, не тронут)
    // ════════════════════════════════════════════════════════════════════

    private fun handleExtractAudio(call: MethodCall, result: MethodChannel.Result) {
        val videoId     = call.argument<String>("videoId")
        val poToken     = call.argument<String>("poToken")
        val visitorData = call.argument<String>("visitorData")

        if (videoId.isNullOrEmpty()) {
            result.error("BAD_ARGS", "videoId is required", null)
            return
        }

        Thread {
            try {
                val py     = Python.getInstance()
                val module = py.getModule("ytdlp_bridge")
                val json   = module.callAttr("extract_audio", videoId, poToken, visitorData).toString()
                mainHandler.post { result.success(json) }
            } catch (e: PyException) {
                mainHandler.post { result.error("YTDLP_ERROR",  e.message, null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("NATIVE_ERROR", e.message, null) }
            }
        }.start()
    }

    /** Универсальный вызов функции из ytdlp_bridge.py в фоновом потоке. */
    private fun callYtBridge(result: MethodChannel.Result, fn: String, vararg args: Any?) {
        Thread {
            try {
                val module = Python.getInstance().getModule("ytdlp_bridge")
                val json = module.callAttr(fn, *args).toString()
                mainHandler.post { result.success(json) }
            } catch (e: PyException) {
                mainHandler.post { result.error("YTDLP_ERROR", e.message, null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("NATIVE_ERROR", e.message, null) }
            }
        }.start()
    }

    private fun handleSearchYtMusic(call: MethodCall, result: MethodChannel.Result) {
        val query = call.argument<String>("query")
        val count = call.argument<Int>("count") ?: 25

        if (query.isNullOrEmpty()) {
            result.error("BAD_ARGS", "query is required", null)
            return
        }

        Thread {
            try {
                val py     = Python.getInstance()
                val module = py.getModule("ytdlp_bridge")
                val json   = module.callAttr("search_yt_music", query, count).toString()
                mainHandler.post { result.success(json) }
            } catch (e: PyException) {
                mainHandler.post { result.error("YTDLP_ERROR",  e.message, null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("NATIVE_ERROR", e.message, null) }
            }
        }.start()
    }

    // ════════════════════════════════════════════════════════════════════
    //  VK auth / search handlers
    //  Все вызовы идут в vk_auth_bridge.py / vk_search_bridge.py через
    //  Chaquopy, так же, как ytdlp_bridge.py, никаких ProcessBuilder.
    // ════════════════════════════════════════════════════════════════════

    /**
     * Прямая авторизация под client_id Kate Mobile.
     * authCode/captchaSid/captchaKey — опциональны, нужны только на
     * повторном вызове, если первый вернул need_validation (2FA) или
     * need_captcha (см. vk_auth_bridge.py).
     */
    private fun handleVkLogin(call: MethodCall, result: MethodChannel.Result) {
        val username   = call.argument<String>("username")
        val password   = call.argument<String>("password")
        val authCode   = call.argument<String>("authCode")
        val captchaSid = call.argument<String>("captchaSid")
        val captchaKey = call.argument<String>("captchaKey")

        if (username.isNullOrEmpty() || password.isNullOrEmpty()) {
            result.error("BAD_ARGS", "username and password are required", null)
            return
        }

        Thread {
            try {
                val json = Python.getInstance()
                    .getModule("vk_auth_bridge")
                    .callAttr("login", username, password, authCode, captchaSid, captchaKey)
                    .toString()
                mainHandler.post { result.success(json) }
            } catch (e: PyException) {
                mainHandler.post { result.error("VK_AUTH_ERROR", e.message, null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("NATIVE_ERROR", e.message, null) }
            }
        }.start()
    }

    /** Поиск по каталогу VK. Требует token+userAgent, полученные через "login". */
    private fun handleVkSearch(call: MethodCall, result: MethodChannel.Result) {
        val token     = call.argument<String>("token")
        val userAgent = call.argument<String>("userAgent") ?: ""
        val query     = call.argument<String>("query")
        val count     = call.argument<Int>("count") ?: 25
        val offset    = call.argument<Int>("offset") ?: 0

        if (token.isNullOrEmpty() || query.isNullOrEmpty()) {
            result.error("BAD_ARGS", "token and query are required", null)
            return
        }

        Thread {
            try {
                val json = Python.getInstance()
                    .getModule("vk_search_bridge")
                    .callAttr("search", token, userAgent, query, count, offset)
                    .toString()
                mainHandler.post { result.success(json) }
            } catch (e: PyException) {
                mainHandler.post { result.error("VK_SEARCH_ERROR", e.message, null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("NATIVE_ERROR", e.message, null) }
            }
        }.start()
    }

    // ════════════════════════════════════════════════════════════════════
    //  VK HLS handlers
    //  Все вызовы идут в vk_hls_bridge.py через Chaquopy —
    //  так же, как ytdlp_bridge.py, никаких ProcessBuilder.
    // ════════════════════════════════════════════════════════════════════

    /** Парсит M3U8 манифест, возвращает JSON с инфо о плейлисте. */
    private fun handleVkParseM3U8(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrEmpty()) {
            result.error("BAD_ARGS", "url is required", null)
            return
        }

        Thread {
            try {
                val json = vkBridge().callAttr("parse_m3u8", url).toString()
                mainHandler.post { result.success(json) }
            } catch (e: PyException) {
                mainHandler.post { result.error("VK_HLS_ERROR", e.message, null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("NATIVE_ERROR", e.message, null) }
            }
        }.start()
    }

    /**
     * Загружает и дешифрует все сегменты.
     * [output_file] — опциональный путь для сохранения на диск.
     * Если не передан — Python вернёт данные base64 в JSON.
     */
    private fun handleVkDownload(call: MethodCall, result: MethodChannel.Result) {
        val url        = call.argument<String>("url")
        val outputFile = call.argument<String>("output_file")  // может быть null

        if (url.isNullOrEmpty()) {
            result.error("BAD_ARGS", "url is required", null)
            return
        }

        Thread {
            try {
                // Python-функция принимает output_file как None если не задан
                val json = vkBridge()
                    .callAttr("download_and_decrypt", url, outputFile)
                    .toString()
                mainHandler.post { result.success(json) }
            } catch (e: PyException) {
                mainHandler.post { result.error("VK_HLS_ERROR", e.message, null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("NATIVE_ERROR", e.message, null) }
            }
        }.start()
    }

    /** Извлекает title/artist/duration/cover из URL плейлиста. */
    private fun handleVkMetadata(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url.isNullOrEmpty()) {
            result.error("BAD_ARGS", "url is required", null)
            return
        }

        Thread {
            try {
                val json = vkBridge().callAttr("get_metadata", url).toString()
                mainHandler.post { result.success(json) }
            } catch (e: PyException) {
                mainHandler.post { result.error("VK_HLS_ERROR", e.message, null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("NATIVE_ERROR", e.message, null) }
            }
        }.start()
    }

    /** Скачивает обложку трека. */
    private fun handleVkCover(call: MethodCall, result: MethodChannel.Result) {
        val url        = call.argument<String>("url")
        val outputFile = call.argument<String>("output_file")

        if (url.isNullOrEmpty()) {
            result.error("BAD_ARGS", "url is required", null)
            return
        }

        Thread {
            try {
                val json = vkBridge()
                    .callAttr("download_cover", url, outputFile)
                    .toString()
                mainHandler.post { result.success(json) }
            } catch (e: PyException) {
                mainHandler.post { result.error("VK_HLS_ERROR", e.message, null) }
            } catch (e: Exception) {
                mainHandler.post { result.error("NATIVE_ERROR", e.message, null) }
            }
        }.start()
    }

    /**
     * Возвращает Python-модуль vk_hls_bridge.
     * Chaquopy ищет его в android/app/src/main/python/vk_hls_bridge.py.
     */
    private fun vkBridge() = Python.getInstance().getModule("vk_hls_bridge")
}
