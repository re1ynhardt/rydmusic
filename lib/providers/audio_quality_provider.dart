import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Желаемое качество аудиопотока.
///
/// Пока SoundCloud- и Audiomack-сервисы отдают только один фиксированный
/// битрейт на трек (см. resolveStreamUrl() в соответствующих сервисах),
/// поэтому выбор здесь пока не переключает реальный поток. Настройка
/// подготовлена по тому же паттерну, что и ThemeProvider, чтобы её было
/// легко подключить к резолву URL, когда источники начнут отдавать
/// несколько вариантов битрейта.
enum AudioQuality { high, dataSaver }

/// Хранит выбранное качество звука и переживает перезапуск через
/// SharedPreferences — так же, как ThemeProvider хранит тему.
class AudioQualityProvider extends ChangeNotifier {
  static const _prefsKey = 'audio_quality';

  AudioQualityProvider._(AudioQuality initialQuality, this._prefs)
      : _quality = initialQuality;

  /// Загружает сохранённый выбор до запуска приложения — как и
  /// ThemeProvider.load(), чтобы не было "мигания" значения при старте.
  static Future<AudioQualityProvider> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    final quality =
        saved == 'dataSaver' ? AudioQuality.dataSaver : AudioQuality.high;
    return AudioQualityProvider._(quality, prefs);
  }

  final SharedPreferences _prefs;
  AudioQuality _quality;

  AudioQuality get quality => _quality;
  bool get isDataSaver => _quality == AudioQuality.dataSaver;

  void setQuality(AudioQuality quality) {
    if (quality == _quality) return;
    _quality = quality;
    notifyListeners();
    // Запись в SharedPreferences не блокирует UI — значение уже применено
    // синхронно строкой выше, сохранение идёт в фоне.
    unawaited(_prefs.setString(
      _prefsKey,
      quality == AudioQuality.dataSaver ? 'dataSaver' : 'high',
    ));
  }
}
