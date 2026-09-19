plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Вшивает Python-интерпретатор прямо в APK — yt-dlp и ytmusicapi
    // вызываются как обычные библиотеки из Kotlin (MainActivity.kt),
    // безо всякого отдельного процесса/файла, который надо было бы
    // запускать руками.
    id("com.chaquo.python")
}

android {
    namespace = "com.example.rydmusic"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.rydmusic"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // ВАЖНО: Chaquopy 17.0.0 требует minSdk >= 24 (Android 7.0) — это
        // единственная причина отступить от flutter.minSdkVersion. На
        // 2026 год теряется исчезающе малая доля устройств.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Chaquopy собирает Python-рантайм под каждую ABI отдельно —
        // без явного списка соберёт вообще под все, раздувая APK.
        // arm64-v8a покрывает все актуальные телефоны, x86_64 — для
        // отладки в эмуляторе. armeabi-v7a (32-бит) убран: Chaquopy не
        // собирает под неё Python 3.14 — см. changelog Chaquopy 17,
        // "Python 3.14 ... currently has very few Android wheels".
        ndk {
            abiFilters.clear()
            abiFilters += setOf("arm64-v8a", "x86_64")
        }

        // ВАЖНО: python{}/pip{} у Chaquopy — это Groovy-DSL (динамические
        // методы), а не типизированные Kotlin-объекты. В build.gradle.kts
        // для них НЕТ автогенерируемых accessor'ов (это известное и
        // довольно старое ограничение Gradle Kotlin DSL для вложенных
        // расширений сторонних Groovy-плагинов — см.
        // https://github.com/gradle/kotlin-dsl/issues/1287), поэтому
        // писать `python { pip { install(...) } }` напрямую НЕЛЬЗЯ —
        // будет "Unresolved reference: python". Обходим официальным
        // способом Gradle для таких случаев — withGroovyBuilder, который
        // вызывает эти методы динамически, так же, как это делает сам
        // Groovy DSL.
        withGroovyBuilder {
            "python" {
                // Chaquopy 17 требует, чтобы buildPython (Python на машине
                // разработчика) совпадал по major.minor с этой версией.
                // 3.13 — под 3.14 у Chaquopy 17 ещё почти нет
                // Android-wheel'ов для нативных пакетов (pycryptodome и
                // т.п.), сборка падала с "versions: none".
                setProperty("version", "3.13")
                "pip" {
                    // yt-dlp — извлечение audio-URL из videoId.
                    // ytmusicapi — поиск именно по каталогу YouTube Music
                    // (чище, чем общий YouTube: без клипов/live/реакций,
                    // с нормальными артистами/альбомами). requests и его
                    // зависимости (urllib3/certifi/charset_normalizer/idna)
                    // чистый Python — ставятся Chaquopy без проблем на
                    // всех ABI.
                    "install"("yt-dlp")
                    "install"("ytmusicapi")
                    // VK: requests — HTTP для audio.search и для
                    // сегментов/ключей HLS; pycryptodome — AES-128-CBC
                    // дешифровка HLS-сегментов (см. vk_hls_bridge.py).
                    // requests уже транзитивная зависимость yt-dlp, но
                    // явное указание фиксирует версию.
                    "install"("requests")
                    "install"("pycryptodome")
                    // vkaudiotoken — получение access_token для VK Audio
                    // API прямой авторизацией (login/password) под видом
                    // официального клиента Kate Mobile. Официальный
                    // audio.search/audio.get для сторонних приложений
                    // закрыт с 2016 года; клиент-id Kate Mobile — одно из
                    // немногих исключений, у которых права на audio.*
                    // не отозваны. См. vk_auth_bridge.py.
                    "install"("vkaudiotoken")
                }
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
