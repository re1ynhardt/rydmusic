import 'track.dart';

/// Трек, полностью скачанный на диск для оффлайн-прослушивания.
/// Хранит оригинальные метаданные трека (для отображения в UI без сети)
/// плюс путь к локальному аудиофайлу и его размер (для отображения
/// суммарного места, занимаемого кэшем, в настройках без похода на
/// диск за каждым файлом по отдельности).
class CachedTrack {
  final Track track;
  final String localPath;
  final int fileSizeBytes;

  const CachedTrack({
    required this.track,
    required this.localPath,
    this.fileSizeBytes = 0,
  });

  Map<String, dynamic> toJson() => {
        'track': track.toJson(),
        'localPath': localPath,
        'fileSizeBytes': fileSizeBytes,
      };

  factory CachedTrack.fromJson(Map<String, dynamic> json) => CachedTrack(
        track: Track.fromJson(json['track'] as Map<String, dynamic>),
        localPath: json['localPath'] as String? ?? '',
        fileSizeBytes: json['fileSizeBytes'] as int? ?? 0,
      );
}
