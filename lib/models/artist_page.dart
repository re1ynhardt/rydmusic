import 'track.dart';

/// Альбом (или сингл) исполнителя. Треки альбома подгружаются лениво —
/// см. [MusicSource.loadAlbumTracks].
class ArtistAlbum {
  const ArtistAlbum({
    required this.id,
    required this.title,
    this.artworkUrl = '',
    this.subtitle = '',
  });

  final String id;
  final String title;
  final String artworkUrl;

  /// Год / тип ("2021", "Single • 2021") — что удалось получить.
  final String subtitle;
}

/// Страница исполнителя: все данные берутся из ОДНОГО источника
/// (страница YouTube-исполнителя — только треки YouTube, SoundCloud —
/// только SoundCloud).
class ArtistPage {
  const ArtistPage({
    required this.name,
    this.artworkUrl = '',
    this.albums = const [],
    this.tracks = const [],
  });

  final String name;
  final String artworkUrl;
  final List<ArtistAlbum> albums;

  /// Все треки исполнителя одним списком.
  final List<Track> tracks;
}
