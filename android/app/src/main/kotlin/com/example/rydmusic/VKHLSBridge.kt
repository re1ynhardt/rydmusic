package com.rydmusic.app

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

/**
 * VKHLSBridge — Android-нативный бридж для Python HLS-парсера.
 *
 * Flutter вызывает MethodChannel "rydmusic/vk_hls" с методами:
 *   • parseM3U8(url)                    → JSON-строка (информация о плейлисте)
 *   • downloadAndDecryptSegments(url, output_file?) → JSON-строка (данные или путь)
 *   • getTrackMetadata(url)             → JSON-строка (метаданные)
 *   • downloadCover(url, output_file?)  → JSON-строка
 *
 * Python-скрипты упакованы в assets и при первом запуске копируются
 * во внутреннее хранилище приложения.
 */
class VKHLSBridge(private val context: Context) {

    companion object {
        private const val CHANNEL_NAME = "rydmusic/vk_hls"
        private const val SCRIPTS_DIR  = "python_scripts/vk_parser"
        private const val TAG          = "VKHLSBridge"

        // Таймаут на весь Python-процесс (мс)
        private const val PROCESS_TIMEOUT_MS = 120_000L
    }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())

    // Директория со скриптами во внутреннем хранилище
    private val scriptsDir: File by lazy {
        File(context.filesDir, SCRIPTS_DIR).also { it.mkdirs() }
    }

    // ── Channel Setup ────────────────────────────────────────────────────────

    fun setupChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            scope.launch {
                val response = try {
                    handleCall(call)
                } catch (e: Exception) {
                    android.util.Log.e(TAG, "Uncaught error in ${call.method}", e)
                    jsonError("Внутренняя ошибка: ${e.message}")
                }
                withContext(Dispatchers.Main) {
                    result.success(response)
                }
            }
        }
    }

    fun cleanup() {
        scope.cancel()
    }

    // ── Dispatch ─────────────────────────────────────────────────────────────

    private suspend fun handleCall(call: MethodCall): String {
        ensureScriptsExtracted()

        return when (call.method) {
            "parseM3U8" -> {
                val url = call.argument<String>("url")
                    ?: return jsonError("Отсутствует параметр url")
                runPython("parse", url)
            }

            "downloadAndDecryptSegments" -> {
                val url = call.argument<String>("url")
                    ?: return jsonError("Отсутствует параметр url")
                val outputFile = call.argument<String>("output_file")
                if (outputFile != null) {
                    runPython("download", url, "--output", outputFile)
                } else {
                    runPython("download", url)
                }
            }

            "getTrackMetadata" -> {
                val url = call.argument<String>("url")
                    ?: return jsonError("Отсутствует параметр url")
                runPython("metadata", url)
            }

            "downloadCover" -> {
                val url = call.argument<String>("url")
                    ?: return jsonError("Отсутствует параметр url")
                val outputFile = call.argument<String>("output_file")
                if (outputFile != null) {
                    runPython("cover", url, "--output", outputFile)
                } else {
                    runPython("cover", url)
                }
            }

            else -> jsonError("Неизвестный метод: ${call.method}")
        }
    }

    // ── Python Runner ─────────────────────────────────────────────────────────

    /**
     * Запускает main.py с переданными аргументами.
     * Stdout → результат (JSON).
     * Stderr → logcat.
     * Возвращает JSON-строку (success или error).
     */
    private suspend fun runPython(vararg args: String): String {
        val python3 = findPython3()
        if (python3 == null) {
            android.util.Log.e(TAG, "Python 3 не найден на устройстве")
            return jsonError("Python 3 не найден. Убедитесь, что Termux или Python установлен.")
        }

        val mainScript = File(scriptsDir, "main.py").absolutePath
        val cmd = buildList {
            add(python3)
            add(mainScript)
            addAll(args)
        }

        android.util.Log.d(TAG, "Запускаем: ${cmd.joinToString(" ")}")

        return withContext(Dispatchers.IO) {
            val process = ProcessBuilder(cmd)
                .directory(scriptsDir)
                .redirectErrorStream(false)   // stderr отдельно
                .start()

            // Читаем stderr в фоне (логируем, не блокируем)
            val stderrJob = launch {
                process.errorStream.bufferedReader().use { reader ->
                    reader.forEachLine { line ->
                        android.util.Log.d(TAG, "[PY] $line")
                    }
                }
            }

            val stdout = process.inputStream.bufferedReader().readText()

            val finished = withTimeoutOrNull(PROCESS_TIMEOUT_MS) {
                withContext(Dispatchers.IO) { process.waitFor() }
            }

            stderrJob.cancel()

            if (finished == null) {
                process.destroyForcibly()
                android.util.Log.e(TAG, "Python процесс завис — убит по таймауту")
                return@withContext jsonError("Таймаут выполнения (${PROCESS_TIMEOUT_MS / 1000}s)")
            }

            if (stdout.isBlank()) {
                android.util.Log.w(TAG, "Python вернул пустой stdout (код $finished)")
                return@withContext jsonError("Пустой ответ от Python (код выхода: $finished)")
            }

            // Если вышел с ненулевым кодом, но JSON есть — доверяем JSON
            stdout.trim()
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /**
     * При первом вызове (или если скрипты устарели) копирует их из assets
     * во внутреннее хранилище. Файл "main.py" — индикатор готовности.
     */
    private fun ensureScriptsExtracted() {
        val markerFile = File(scriptsDir, "main.py")
        // Перезаписываем при каждом запуске (чтобы APK-обновление применялось)
        val assetManager = context.assets
        val assetFiles = assetManager.list(SCRIPTS_DIR) ?: return

        for (filename in assetFiles) {
            val assetPath = "$SCRIPTS_DIR/$filename"
            val destFile = File(scriptsDir, filename)
            try {
                assetManager.open(assetPath).use { input ->
                    FileOutputStream(destFile).use { output ->
                        input.copyTo(output)
                    }
                }
                android.util.Log.d(TAG, "Скопирован: $filename")
            } catch (e: Exception) {
                android.util.Log.w(TAG, "Не удалось скопировать $filename: ${e.message}")
            }
        }
    }

    /**
     * Ищет интерпретатор Python 3 в стандартных местах.
     * На Android с Termux он обычно в /data/data/com.termux/files/usr/bin/python3,
     * либо в /usr/bin/python3 (если рут + busybox).
     */
    private fun findPython3(): String? {
        val candidates = listOf(
            "/data/data/com.termux/files/usr/bin/python3",
            "/data/data/com.termux/files/usr/bin/python",
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "python3",
            "python",
        )
        for (path in candidates) {
            try {
                val process = ProcessBuilder(path, "--version")
                    .redirectErrorStream(true)
                    .start()
                val out = process.inputStream.bufferedReader().readText()
                process.waitFor()
                if (out.startsWith("Python 3")) {
                    android.util.Log.d(TAG, "Python найден: $path ($out.trim())")
                    return path
                }
            } catch (_: Exception) {}
        }
        android.util.Log.e(TAG, "Python 3 не найден ни по одному из путей")
        return null
    }

    private fun jsonError(msg: String): String =
        JSONObject().put("error", msg).toString()
}
