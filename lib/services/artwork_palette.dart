import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

/// Кэш палитр, извлечённых из обложек треков — по track.id, а не по
/// artworkUrl: одна и та же обложка для одного трека, а извлечение —
/// это полное декодирование картинки, дорогая операция, которую не
/// стоит повторять на каждый показ мини-плеера.
class ArtworkPalette {
  ArtworkPalette._();

  /// Обложка ужимается до этого размера ПЕРЕД разбором цветов.
  ///
  /// Это главная оптимизация здесь: квантизация цветов в
  /// palette_generator идёт по КАЖДОМУ пикселю и выполняется в основном
  /// изоляте. Источники отдают обложки 500×500–1400×1400, то есть от
  /// четверти до двух миллионов пикселей — на слабом телефоне это
  /// десятки-сотни миллисекунд подвисшего UI ровно в момент старта
  /// трека (когда и так идёт резолв ссылки и раскрутка плеера). 64×64 —
  /// это 4096 пикселей, на три порядка меньше, а для двух цветов
  /// градиента подложки разницы на глаз нет.
  static const _decodeSize = 64;

  /// Потолок кэша: палитра — лёгкий объект, но за долгую сессию поиска
  /// их могут накопиться тысячи. Держим последние N, самые старые
  /// вытесняем (Map в Dart сохраняет порядок вставки, поэтому "самый
  /// старый" — это просто первый ключ).
  static const _maxEntries = 80;

  static final Map<String, PaletteGenerator> _cache = {};
  static final Map<String, Future<PaletteGenerator?>> _inFlight = {};

  /// Уже готовая палитра, если есть в кэше — синхронно, без ожидания
  /// (чтобы при повторном показе того же трека не мигать нейтральным
  /// фоном один кадр, пока палитра "перезагружается").
  static PaletteGenerator? cached(String trackId) => _cache[trackId];

  static void _put(String trackId, PaletteGenerator palette) {
    _cache[trackId] = palette;
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  static Future<PaletteGenerator?> load(String trackId, String artworkUrl) {
    final cached = _cache[trackId];
    if (cached != null) return Future.value(cached);
    final inFlight = _inFlight[trackId];
    if (inFlight != null) return inFlight;
    if (artworkUrl.isEmpty) return Future.value(null);

    final future = PaletteGenerator.fromImageProvider(
      // ResizeImage — декодирование сразу в уменьшенный битмап, а не
      // "декодируем полностью, потом уменьшаем".
      ResizeImage(
        CachedNetworkImageProvider(artworkUrl),
        width: _decodeSize,
        height: _decodeSize,
        allowUpscaling: false,
      ),
      // Для двух цветов градиента больше и не нужно, а стоимость
      // квантизации напрямую зависит от этого числа.
      maximumColorCount: 8,
      timeout: const Duration(seconds: 8),
    ).then<PaletteGenerator?>((palette) {
      _put(trackId, palette);
      _inFlight.remove(trackId);
      return palette;
    }).catchError((_) {
      // Нет сети / битая обложка / таймаут — просто остаёмся без
      // палитры, мини-плеер покажет нейтральный фон вместо градиента.
      _inFlight.remove(trackId);
      return null;
    });
    _inFlight[trackId] = future;
    return future;
  }
}
