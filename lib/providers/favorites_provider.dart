import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import '../config/yandex_config.dart';
import '../models/track.dart';
import '../services/yandex_s3_client.dart';

/// Избранные треки текущего пользователя.
///
/// Раньше хранились локально на устройстве (SharedPreferences) — теперь
/// живут в Yandex Object Storage под ключом `library/favorites/<email>.json`,
/// то есть привязаны к аккаунту, а не к устройству: переустановка,
/// смена телефона или выход/вход под другим пользователем больше не
/// теряют и не путают избранное.
///
/// Как и раньше:
/// - вся коллекция читается/пишется ОДНИМ JSON-блобом, а не по объекту
///   на трек — меньше запросов к хранилищу;
/// - запись дебаунсится, чтобы серия быстрых тапов не порождала серию
///   сетевых PUT-запросов;
/// - переключение избранного обновляет UI сразу же (оптимистично),
///   не дожидаясь ответа сети.
class FavoritesProvider extends ChangeNotifier {
  FavoritesProvider({YandexS3Client? client}) : _client = client ?? YandexS3Client();
  final YandexS3Client _client;

  // LinkedHashMap (Map в Dart по умолчанию сохраняет порядок вставки):
  // O(1) добавление/удаление/проверка по id вместо линейного поиска по списку.
  final Map<String, Track> _favorites = <String, Track>{};
  bool _loaded = false;
  Timer? _saveDebounce;
  String? _email;
  int _loadToken = 0;
  String? _error;

  bool get isLoaded => _loaded;

  /// Ошибка последней синхронизации с хранилищем (загрузки или сохранения),
  /// если есть — UI может показать её вместо тихого молчания.
  String? get error => _error;

  List<Track>? _favoritesList;

  /// Новые добавления сверху. Список строится лениво — только когда экран
  /// библиотеки реально его запрашивает, а не при каждом toggle(), — и
  /// после этого кэшируется до следующего изменения: раньше каждая
  /// перестройка экрана библиотеки заново создавала два списка целиком.
  List<Track> get favorites => _favoritesList ??= _favorites.values
      .toList(growable: false)
      .reversed
      .toList(growable: false);

  /// Единая точка сброса кэша: в этом классе любое изменение _favorites
  /// сопровождается уведомлением слушателей, так что список не может
  /// разойтись с данными.
  @override
  void notifyListeners() {
    _favoritesList = null;
    super.notifyListeners();
  }

  int get count => _favorites.length;

  bool isFavorite(String trackId) => _favorites.containsKey(trackId);

  String _keyFor(String email) =>
      '${YandexConfig.favoritesPrefix}${YandexConfig.sanitizeEmail(email)}.json';

  /// Вызывается при входе/выходе/смене пользователя (см. main.dart,
  /// ChangeNotifierProxyProvider на AuthProvider). Для гостя (email == null)
  /// библиотека просто пустая и никуда не пишется.
  Future<void> setUser(String? email) async {
    if (_email == email) return;
    _email = email;
    _favorites.clear();
    _saveDebounce?.cancel();
    _loaded = email == null; // гостю грузить нечего — сразу "загружено"
    _error = null;
    notifyListeners();
    if (email == null) return;

    final token = ++_loadToken;
    try {
      final raw = await _client.getObject(_keyFor(email));
      if (token != _loadToken) return; // пользователя уже сменили за время запроса
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw) as List<dynamic>;
        for (final item in decoded) {
          final track = Track.fromJson(item as Map<String, dynamic>);
          if (track.id.isNotEmpty) _favorites[track.id] = track;
        }
      }
    } catch (e) {
      if (token != _loadToken) return;
      _error = 'Не удалось загрузить избранное: $e';
    } finally {
      if (token == _loadToken) {
        _loaded = true;
        notifyListeners();
      }
    }
  }

  void toggle(Track track) {
    if (_favorites.containsKey(track.id)) {
      _favorites.remove(track.id);
    } else {
      _favorites[track.id] = track;
    }
    notifyListeners();
    _scheduleSave();
  }

  void _scheduleSave() {
    final email = _email;
    if (email == null) return; // гость — сохранять некуда и не для кого
    _saveDebounce?.cancel();
    // Снимок на момент планирования сохранения и токен пользователя —
    // если за время debounce пользователь сменится, отменённая по токену
    // запись не перезапишет библиотеку уже другого аккаунта.
    final snapshot = _favorites.values.map((t) => t.toJson()).toList(growable: false);
    final token = _loadToken;
    _saveDebounce = Timer(const Duration(milliseconds: 300), () async {
      if (token != _loadToken) return;
      try {
        await _client.putObject(_keyFor(email), jsonEncode(snapshot));
        if (token == _loadToken) _error = null;
      } catch (e) {
        if (token == _loadToken) {
          _error = 'Не удалось сохранить избранное: $e';
          notifyListeners();
        }
      }
    });
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    super.dispose();
  }
}
