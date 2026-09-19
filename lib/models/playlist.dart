import 'track.dart';

/// Пользовательский плейлист: имя, опциональная обложка (путь к файлу
/// на диске) и список треков.
///
/// Треки хранятся встроенно (не просто id) — как и в FavoritesProvider —
/// чтобы плейлист можно было отрисовать сразу после загрузки из
/// SharedPreferences, без похода в сеть за метаданными.
class Playlist {
  final String id;
  final String name;

  /// Путь к файлу обложки в locale-каталоге приложения, либо null —
  /// тогда UI рисует плейсхолдер (или коллаж из первых треков).
  final String? coverPath;

  // LinkedHashMap-порядок важен: новые треки добавляются в конец.
  final Map<String, Track> tracks;

  const Playlist({
    required this.id,
    required this.name,
    required this.tracks,
    this.coverPath,
  });

  List<Track> get trackList => tracks.values.toList(growable: false);

  int get trackCount => tracks.length;

  Playlist copyWith({
    String? name,
    String? coverPath,
    bool clearCover = false,
    Map<String, Track>? tracks,
  }) {
    return Playlist(
      id: id,
      name: name ?? this.name,
      coverPath: clearCover ? null : (coverPath ?? this.coverPath),
      tracks: tracks ?? this.tracks,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'coverPath': coverPath,
        'tracks': tracks.values.map((t) => t.toJson()).toList(growable: false),
      };

  factory Playlist.fromJson(Map<String, dynamic> json) {
    final tracksJson = json['tracks'] as List<dynamic>? ?? const [];
    final tracks = <String, Track>{};
    for (final item in tracksJson) {
      final track = Track.fromJson(item as Map<String, dynamic>);
      if (track.id.isNotEmpty) tracks[track.id] = track;
    }
    return Playlist(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      coverPath: json['coverPath'] as String?,
      tracks: tracks,
    );
  }
}
