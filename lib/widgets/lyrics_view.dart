import 'package:flutter/material.dart';
import '../models/track.dart';
import '../providers/language_provider.dart';
import '../providers/player_provider.dart';
import '../services/lyrics_service.dart';

/// Текст песни. Оптимизации: фиксированная высота строки (itemExtent —
/// без измерения детей), перестройка только при смене активной строки
/// (бинарный поиск по тику позиции), без ShaderMask/BackdropFilter.
class LyricsView extends StatefulWidget {
  const LyricsView({super.key, required this.track, required this.player});
  final Track track;
  final PlayerProvider player;

  @override
  State<LyricsView> createState() => _LyricsViewState();
}

class _LyricsViewState extends State<LyricsView> {
  static const _h = 60.0;
  static const _on = TextStyle(
      fontSize: 20, fontWeight: FontWeight.w800, height: 1.2, color: Colors.white);
  static const _off = TextStyle(
      fontSize: 20, fontWeight: FontWeight.w800, height: 1.2, color: Colors.white38);

  final _sc = ScrollController();
  Lyrics? _lyrics;
  bool _loading = true, _error = false, _drag = false;
  int _active = -1;

  @override
  void initState() {
    super.initState();
    // Подписка именно на позицию, а не на провайдер целиком: раньше
    // _tick дёргался на каждое уведомление PlayerProvider (в том числе
    // не связанное с позицией), теперь — только когда позиция реально
    // сдвинулась (см. PlayerProvider.positionListenable).
    widget.player.positionListenable.addListener(_tick);
    _load();
  }

  @override
  void dispose() {
    widget.player.positionListenable.removeListener(_tick);
    _sc.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final l = await LyricsService.instance.fetch(widget.track);
      if (!mounted) return;
      setState(() {
        _lyrics = l;
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tick(jump: true);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
        });
      }
    }
  }

  void _tick({bool jump = false}) {
    final l = _lyrics;
    if (l == null || !l.isSynced) return;
    final ms = widget.player.position.inMilliseconds;
    final ls = l.lines;
    var lo = 0, hi = ls.length - 1, r = -1;
    while (lo <= hi) {
      final m = (lo + hi) >> 1;
      if (ls[m].ms <= ms) {
        r = m;
        lo = m + 1;
      } else {
        hi = m - 1;
      }
    }
    if (r == _active && !jump) return;
    if (r != _active) setState(() => _active = r);
    if (_drag || r < 0 || !_sc.hasClients) return;
    final off = (r * _h).clamp(0.0, _sc.position.maxScrollExtent);
    if (jump) {
      _sc.jumpTo(off);
    } else {
      _sc.animateTo(off,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
        ),
      );
    }
    final l = _lyrics;
    if (_error || l == null) {
      return Center(
        child: TextButton(
          onPressed: _error
              ? () {
                  setState(() {
                    _loading = true;
                    _error = false;
                  });
                  _load();
                }
              : null,
          child: Text(
            _error ? l10n.lyricsLoadFailed : l10n.lyricsNotFound,
            style: const TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ),
      );
    }
    if (!l.isSynced) {
      return ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Text(l.plain,
              style: const TextStyle(
                  fontSize: 18,
                  height: 1.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white70)),
        ],
      );
    }
    final lines = l.lines;
    return LayoutBuilder(builder: (context, c) {
      final pad = ((c.maxHeight - _h) / 2).clamp(0.0, double.infinity);
      return NotificationListener<ScrollNotification>(
        onNotification: (n) {
          if (n is ScrollStartNotification) {
            _drag = n.dragDetails != null;
          } else if (n is ScrollEndNotification) {
            _drag = false;
          }
          return false;
        },
        child: ListView.builder(
          controller: _sc,
          itemExtent: _h,
          padding: EdgeInsets.symmetric(vertical: pad),
          itemCount: lines.length,
          itemBuilder: (_, i) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () =>
                widget.player.seek(Duration(milliseconds: lines[i].ms)),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(lines[i].text,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: i == _active ? _on : _off),
            ),
          ),
        ),
      );
    });
  }
}
