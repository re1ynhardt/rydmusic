/// Подбор версии обложки нужного размера.
///
/// YouTube Music (ytmusicapi) отдаёт для треков список миниатюр вида
/// `https://lh3.googleusercontent.com/<id>=w120-h120-l90-rj`, максимум —
/// 120×120 пикселей (см. `_best_thumbnail` в ytdlp_bridge.py). Для
/// списка и мини-плеера этого достаточно, но на весь экран
/// "Сейчас играет" (~1000 px по ширине) такая картинка растягивается
/// почти в 9 раз и выглядит мыльной.
///
/// Серверы Google отдают одну и ту же картинку в любом размере — размер
/// задаётся суффиксом после `=` в самом URL. Поэтому крупную версию
/// можно получить простой подменой суффикса, без новых запросов к API и
/// без изменений в Python-мосту. Подмена делается в момент показа, а не
/// при парсинге: так она работает и для треков, уже сохранённых в
/// избранном/истории со старой маленькой ссылкой.
class ArtworkUrl {
  ArtworkUrl._();

  // `=w120-h120-l90-rj` — прямоугольный вариант (обложки песен/альбомов).
  static final RegExp _sizeWH = RegExp(r'=w\d+-h\d+[^/?#]*$');

  // `=s88-c-k-c0x00ffffff-no-rj` — квадратный вариант (аватарки каналов).
  static final RegExp _sizeS = RegExp(r'=s\d+([^/?#]*)$');

  /// Возвращает ссылку на версию обложки размером до [size] пикселей.
  /// Для чужих хостов и нераспознанных форматов возвращает [url] как есть.
  static String highRes(String url, {int size = 1200}) {
    if (url.isEmpty) return url;
    final host = Uri.tryParse(url)?.host ?? '';
    final isGoogleImage =
        host.endsWith('googleusercontent.com') || host.endsWith('ggpht.com');
    if (!isGoogleImage) return url;

    if (_sizeWH.hasMatch(url)) {
      // l90 — качество JPEG 90, rj — отдавать JPEG.
      return url.replaceFirst(_sizeWH, '=w$size-h$size-l90-rj');
    }
    if (_sizeS.hasMatch(url)) {
      return url.replaceFirstMapped(_sizeS, (m) => '=s$size${m[1]}');
    }
    return url;
  }
}
