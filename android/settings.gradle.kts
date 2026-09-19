pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
        // Репозиторий Chaquopy (Python-интерпретатор для Android) — сам
        // плагин отсюда, пакеты pip (yt-dlp, ytmusicapi) качаются
        // отдельно во время сборки, это не тут.
        maven("https://chaquo.com/maven")
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.13.0" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
    // Chaquopy 17.0.0 официально поддерживает AGP 7.3–9.2 и именно такое
    // объявление плагинов (через settings.gradle, как у Flutter) — см.
    // https://chaquo.com/chaquopy/doc/current/versions.html и changelog.
    id("com.chaquo.python") version "17.0.0" apply false
}

include(":app")
