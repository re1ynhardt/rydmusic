import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_strings.dart';

// Виджетам достаточно одного импорта: вместе с провайдером они получают
// и AppStrings/AppLanguage.
export '../l10n/app_strings.dart';

/// Хранит выбранный язык интерфейса и переживает перезапуск через
/// SharedPreferences — по тому же паттерну, что и ThemeProvider: значение
/// грузится до runApp (см. main.dart), поэтому первый кадр сразу
/// отрисовывается на нужном языке, без «мигания».
///
/// По умолчанию — русский (как и было до появления переключателя).
class LanguageProvider extends ChangeNotifier {
  static const _prefsKey = 'app_language';

  LanguageProvider._(AppLanguage initial, this._prefs) : _language = initial {
    // Как и AppColors.setMode в ThemeProvider: синхронизируем статическое
    // «текущее» значение сразу при создании, до первого построения дерева
    // — им пользуется код без BuildContext (провайдеры, сервисы).
    AppStrings.current = AppStrings(_language);
  }

  static Future<LanguageProvider> load() async {
    final prefs = await SharedPreferences.getInstance();
    final language = AppLanguage.fromCode(prefs.getString(_prefsKey));
    return LanguageProvider._(language, prefs);
  }

  final SharedPreferences _prefs;
  AppLanguage _language;

  AppLanguage get language => _language;

  void setLanguage(AppLanguage language) {
    if (language == _language) return;
    _language = language;
    // Сначала обновляем статику, потом уведомляем: виджеты, которые
    // перестроятся по notifyListeners, уже увидят новый язык и там, где
    // текст берётся через AppStrings.current (например, formatBytes).
    AppStrings.current = AppStrings(language);
    notifyListeners();
    unawaited(_prefs.setString(_prefsKey, language.code));
  }
}

extension AppStringsContext on BuildContext {
  /// Тексты интерфейса на текущем языке. Вызывать из build(): подписывает
  /// виджет на смену языка, так что он перерисуется при переключении.
  AppStrings get l10n =>
      AppStrings(Provider.of<LanguageProvider>(this).language);
}
