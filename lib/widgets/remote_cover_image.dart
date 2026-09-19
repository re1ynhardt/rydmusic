import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/yandex_s3_client.dart';

/// Отображает обложку плейлиста по её ключу в Yandex Object Storage
/// (см. PlaylistsProvider — coverPath теперь хранит ключ объекта, а не
/// путь к файлу на диске). Скачанные байты кэшируются в памяти процесса
/// по ключу, чтобы одна и та же обложка не перекачивалась на каждый
/// ребилд списка/скролл.
class RemoteCoverImage extends StatefulWidget {
  const RemoteCoverImage({
    super.key,
    required this.coverKey,
    this.fit = BoxFit.cover,
    this.cacheSize = 200,
  });

  final String coverKey;
  final BoxFit fit;

  /// Верхняя граница декода в пикселях (по большей стороне). Обложки
  /// плейлистов показываются мелкими карточками (~92 лог. пикселей) —
  /// без ограничения Image.memory декодирует и держит в памяти
  /// исходный, часто куда более крупный битмап.
  final int cacheSize;

  static final Map<String, Uint8List> _cache = <String, Uint8List>{};
  static final YandexS3Client _client = YandexS3Client();

  @override
  State<RemoteCoverImage> createState() => _RemoteCoverImageState();
}

class _RemoteCoverImageState extends State<RemoteCoverImage> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(covariant RemoteCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverKey != widget.coverKey) {
      _future = _load();
    }
  }

  Future<Uint8List?> _load() async {
    final cached = RemoteCoverImage._cache[widget.coverKey];
    if (cached != null) return cached;
    try {
      final bytes = await RemoteCoverImage._client.getBytes(widget.coverKey);
      if (bytes != null) RemoteCoverImage._cache[widget.coverKey] = bytes;
      return bytes;
    } catch (_) {
      // Нет сети/обложка недоступна — просто показываем плейсхолдер,
      // не роняя список плейлистов из-за одной картинки.
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _CoverPlaceholder(loading: true);
        }
        final bytes = snapshot.data;
        if (bytes == null) return const _CoverPlaceholder(loading: false);
        return Image.memory(
          bytes,
          fit: widget.fit,
          cacheWidth: widget.cacheSize,
          cacheHeight: widget.cacheSize,
          // Байты этого же трека уже лежат в памяти (см. _cache выше) —
          // gaplessPlayback убирает мигание пустым кадром при повторном
          // построении виджета с тем же coverKey (например, при скролле
          // ленты плейлистов туда-обратно).
          gaplessPlayback: true,
        );
      },
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder({required this.loading});
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Center(
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                Icons.music_note,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
      ),
    );
  }
}
