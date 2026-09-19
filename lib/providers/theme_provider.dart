import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';

/// Хранит выбранную тему приложения и переживает перезапуск через
/// SharedPreferences. Загрузка настройки — синхронная (кэш уже прогрет
/// в main() до runApp), поэтому нет "мигания" темы при старте.
class ThemeProvider extends ChangeNotifier {
  static const _prefsKey = 'app_theme_mode';

  ThemeProvider._(AppThemeMode initialMode, this._prefs)
      : _mode = initialMode {
    // Синхронизируем статическую палитру AppColors сразу при создании,
    // до первого построения дерева виджетов.
    AppColors.setMode(_mode);
  }

  /// Загружает сохранённый выбор темы до запуска приложения, чтобы
  /// первый кадр уже отрисовался с правильной палитрой.
  static Future<ThemeProvider> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    final mode = saved == 'light' ? AppThemeMode.light : AppThemeMode.dark;
    return ThemeProvider._(mode, prefs);
  }

  final SharedPreferences _prefs;
  AppThemeMode _mode;

  AppThemeMode get mode => _mode;
  bool get isDark => _mode == AppThemeMode.dark;

  void setMode(AppThemeMode mode) {
    if (mode == _mode) return;
    _mode = mode;
    AppColors.setMode(mode);
    notifyListeners();
    // Запись в SharedPreferences не блокирует UI — тема уже применена
    // синхронно строкой выше, сохранение идёт в фоне.
    unawaited(_prefs.setString(_prefsKey, mode == AppThemeMode.light ? 'light' : 'dark'));
  }

  void toggle() => setMode(isDark ? AppThemeMode.light : AppThemeMode.dark);
}
