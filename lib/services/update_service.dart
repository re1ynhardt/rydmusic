import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../config/yandex_config.dart';
import '../l10n/app_strings.dart';
import '../models/app_update.dart';
import 'yandex_s3_client.dart';

/// Публикует и получает релизы через тот же Yandex Object Storage, что и
/// аккаунты. APK кладётся раньше манифеста: клиент никогда не увидит
/// опубликованное обновление, пока его файл не загружен полностью.
class UpdateService {
  UpdateService({YandexS3Client? client})
    : _client = client ?? YandexS3Client();
  final YandexS3Client _client;

  static const currentVersion = '2.0.1';
  static const currentBuildNumber = 1;
  static const _manifestKey =
      '${YandexConfig.updatesPrefix}android/latest.json';

  Future<AppUpdate?> latest() async {
    final raw = await _client.getObject(_manifestKey);
    if (raw == null) return null;
    return AppUpdate.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  bool isNewer(AppUpdate update) {
    final versionComparison = _compareVersions(update.version, currentVersion);
    return versionComparison > 0 ||
        (versionComparison == 0 && update.buildNumber > currentBuildNumber);
  }

  Future<AppUpdate> publishAndroidApk({
    required Uint8List apkBytes,
    required String version,
    required int buildNumber,
    required String releaseNotes,
  }) async {
    final normalizedVersion = version.trim();
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(normalizedVersion)) {
      throw ArgumentError(AppStrings.current.versionFormatError);
    }
    if (buildNumber < 1)
      throw ArgumentError(AppStrings.current.buildNumberMustBePositive);
    if (apkBytes.isEmpty) throw ArgumentError(AppStrings.current.emptyApkSelected);

    final apkKey =
        '${YandexConfig.updatesPrefix}android/'
        'rydmusic-$normalizedVersion+$buildNumber.apk';
    await _client.putBytes(
      apkKey,
      apkBytes,
      'application/vnd.android.package-archive',
    );
    final update = AppUpdate(
      version: normalizedVersion,
      buildNumber: buildNumber,
      apkKey: apkKey,
      publishedAt: DateTime.now(),
      releaseNotes: releaseNotes.trim(),
    );
    await _client.putObject(_manifestKey, jsonEncode(update.toJson()));
    return update;
  }

  /// Скачивает APK во временный каталог и передаёт Android системному
  /// установщику. На iOS обновление должно идти через App Store.
  Future<void> downloadAndInstall(AppUpdate update) async {
    if (!Platform.isAndroid) {
      throw UnsupportedError(AppStrings.current.androidOnlyAutoUpdate);
    }
    final bytes = await _client.getBytes(update.apkKey);
    if (bytes == null || bytes.isEmpty) {
      throw StateError(AppStrings.current.updateFileNotFoundInCloud);
    }
    final target = File('${Directory.systemTemp.path}/rydmusic-update.apk');
    await target.writeAsBytes(bytes, flush: true);
    await const MethodChannel(
      'rydmusic/app_update',
    ).invokeMethod<void>('installApk', {'path': target.path});
  }

  int _compareVersions(String left, String right) {
    final a = left.split('.').map(int.parse).toList();
    final b = right.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      final result = a[i].compareTo(b[i]);
      if (result != 0) return result;
    }
    return 0;
  }
}
