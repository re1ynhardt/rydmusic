import 'dart:math' as math;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/track.dart';
import '../providers/language_provider.dart';
import '../providers/player_provider.dart';

void showQueueSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1A1A1E),
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    constraints:
        BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
    builder: (_) => const _QueueSheet(),
  );
}

/// Очередь без BackdropFilter (дорогой на слабых GPU), с фиксированной
/// высотой строки и подпиской только на список и индекс (тики позиции
/// её не перестраивают).
class _QueueSheet extends StatefulWidget {
  const _QueueSheet();
  @override
  State<_QueueSheet> createState() => _QueueSheetState();
}

class _QueueSheetState extends State<_QueueSheet> {
  static const _h = 64.0;
  static const _maxNext = 30; // сколько следующих треков показывать

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final player = context.read<PlayerProvider>();
    final queue =
        context.select<PlayerProvider, List<Track>>((p) => p.queue);
    final cur = context.select<PlayerProvider, int>((p) => p.currentIndex ?? 0);
    // Текущий трек + не более _maxNext следующих; прошлые не показываем.
    final start = cur.clamp(0, queue.length);
    final count = math.min(queue.length - start, _maxNext + 1);
    return Column(
      children: [
        Container(
          width: 36,
          height: 4,
          margin: const EdgeInsets.only(top: 10, bottom: 12),
          decoration: BoxDecoration(
              color: Colors.white24, borderRadius: BorderRadius.circular(2)),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(l10n.queueTitle(math.max(0, count - 1)),
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white)),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemExtent: _h,
            itemCount: count,
            itemBuilder: (_, n) {
              final i = start + n;
              final t = queue[i];
              final isCur = n == 0;
              return InkWell(
                onTap: () => player.skipTo(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CachedNetworkImage(
                              imageUrl: t.artworkUrl,
                              width: 44,
                              height: 44,
                              fit: BoxFit.cover,
                              memCacheWidth: 88,
                              fadeInDuration: Duration.zero,
                              placeholder: (_, __) =>
                                  const ColoredBox(color: Color(0xFF2A2A2E)),
                              errorWidget: (_, __, ___) =>
                                  const ColoredBox(color: Color(0xFF2A2A2E)),
                            ),
                            // Играющий трек: затемнение + «play» поверх обложки.
                            if (isCur) ...const [
                              SizedBox(
                                width: 44,
                                height: 44,
                                child: ColoredBox(color: Colors.black54),
                              ),
                              Icon(Icons.play_arrow_rounded,
                                  size: 26, color: Colors.white),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: isCur
                                        ? Colors.white
                                        : Colors.white70)),
                            Text(t.artist,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13, color: Colors.white54)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
