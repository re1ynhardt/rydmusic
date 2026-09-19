import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/track.dart';
import '../providers/language_provider.dart';
import '../providers/player_provider.dart';
import '../services/music_source.dart';
import '../theme/app_theme.dart';
import '../widgets/add_to_playlist_sheet.dart';
import '../widgets/track_tile.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.sources});
  final Map<MusicSourceType, MusicSource> sources;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  static const _pageSize = 15;
  // Порог до конца списка (в пикселях), при котором стартует подгрузка
  // следующей страницы — заранее, чтобы не было заметного "прыжка"
  // контента, когда пользователь долистает до самого низа.
  static const _prefetchThreshold = 600.0;

  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  static const _histKey = 'search_history';
  static const _histMax = 25;
  List<String> _history = [];

  String _query = '';
  List<Track> _results = [];
  final Set<String> _seenIds = {};

  // Сколько уже запрошено у каждого источника — используется как offset
  // для следующей страницы. Отдельно по источникам: у каждого своя
  // пагинация и свой темп исчерпания результатов.
  final Map<MusicSourceType, int> _offsets = {};
  // Источник помечается исчерпанным, когда вернул меньше, чем просили —
  // после этого больше не дёргаем его на последующих страницах.
  final Set<MusicSourceType> _exhausted = {};

  bool _loadingFirstPage = false;
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadHistory();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final remaining = _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (remaining <= _prefetchThreshold) {
      _loadMore();
    }
  }

  Future<void> _loadHistory() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => _history = p.getStringList(_histKey) ?? []);
  }

  Future<void> _saveHistory() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_histKey, _history);
  }

  /// Последний запрос — первым, дубликаты (без учёта регистра) убираем,
  /// храним не больше [_histMax].
  void _remember(String q) {
    final l = q.toLowerCase();
    _history = [q, ..._history.where((e) => e.toLowerCase() != l)]
        .take(_histMax)
        .toList();
    _saveHistory();
  }

  void _removeFromHistory(String q) {
    setState(() => _history = _history.where((e) => e != q).toList());
    _saveHistory();
  }

  void _clearHistory() {
    setState(() => _history = []);
    _saveHistory();
  }

  /// Поиск стартует ТОЛЬКО по кнопке подтверждения на клавиатуре
  /// (или по тапу на элемент истории) — не при вводе.
  void _submit(String query) {
    final q = query.trim();
    if (q.isEmpty) return;
    _remember(q);
    _startSearch(q);
  }

  /// Крестик в строке поиска: очищает поле и сбрасывает результаты/
  /// пагинацию — то же самое, что происходит при ручном стирании текста
  /// (см. [_onChanged]), просто по одному тапу. Показывается всегда,
  /// независимо от длины запроса (даже на пустом поле) — это просто
  /// быстрый способ сбросить фокус/поле, а не индикатор "есть что
  /// стирать".
  void _clearSearch() {
    _controller.clear();
    _onChanged('');
  }

  void _onChanged(String query) {
    setState(() {
      // Поле очищено — сбрасываем результаты и снова показываем историю.
      if (query.trim().isEmpty) {
        _query = '';
        _results = [];
        _loadingFirstPage = false;
        _loadingMore = false;
        _seenIds.clear();
        _offsets.clear();
        _exhausted.clear();
      }
    });
  }

  /// Новый запрос — сбрасываем всю пагинацию и грузим первую страницу.
  Future<void> _startSearch(String query) async {
    _query = query;
    _seenIds.clear();
    _offsets.clear();
    _exhausted.clear();
    setState(() {
      _results = [];
      _loadingFirstPage = true;
    });

    final page = await _fetchPage(query);
    if (!mounted || _query != query) return;
    setState(() {
      _results = page;
      _loadingFirstPage = false;
    });
  }

  /// Подгружает следующую страницу (по [_pageSize] с каждого ещё не
  /// исчерпанного источника) и добавляет её в конец текущего списка.
  Future<void> _loadMore() async {
    if (_loadingMore || _loadingFirstPage) return;
    if (_query.isEmpty) return;
    if (_exhausted.length >= widget.sources.length) return; // всё исчерпано

    setState(() => _loadingMore = true);
    final query = _query;
    final page = await _fetchPage(query);
    if (!mounted || _query != query) return;
    setState(() {
      _results = [..._results, ...page];
      _loadingMore = false;
    });
  }

  /// Запрашивает у каждого не исчерпанного источника ещё [_pageSize]
  /// треков начиная с его текущего offset, отсеивает дубликаты (по id)
  /// и продвигает offset/exhausted-состояние источников.
  /// Порядок источников в выдаче: сначала SoundCloud, потом YouTube,
  /// потом Deezer, остальные — в порядке, в котором их передали в
  /// MainShell (см. main.dart). Раньше порядок в списке результатов
  /// определялся исключительно порядком вставки в карту sources — и
  /// получалось SoundCloud → Deezer → YouTube (Audiomack без ключей
  /// молчит пустым списком, поэтому в выдаче незаметен). Задаём его
  /// явно здесь же, а не переставляя записи в main.dart: карта sources
  /// используется ещё в паре мест (кэш, экран настроек), где порядок
  /// не важен, и трогать его там незачем.
  static const List<MusicSourceType> _sourceOrder = [
    MusicSourceType.youtube,
    MusicSourceType.soundcloud,
    MusicSourceType.deezer,
  ];

  int _sourceRank(MusicSourceType type) {
    final i = _sourceOrder.indexOf(type);
    // Источники, не перечисленные явно (Audiomack, VK), идут следом,
    // сохраняя между собой тот же относительный порядок, в котором они
    // лежат в исходной карте — indexOf на самой карте это как раз даёт.
    return i >= 0 ? i : _sourceOrder.length + widget.sources.keys.toList().indexOf(type);
  }

  Future<List<Track>> _fetchPage(String query) async {
    final activeSources = widget.sources.entries
        .where((e) => !_exhausted.contains(e.key))
        .toList()
      // Future.wait ниже сохраняет порядок этого списка независимо от
      // того, какой источник ответил быстрее — сортировка тут и есть
      // единственное, что определяет порядок в итоговой выдаче.
      ..sort((a, b) => _sourceRank(a.key).compareTo(_sourceRank(b.key)));

    final results = await Future.wait(activeSources.map((entry) async {
      final offset = _offsets[entry.key] ?? 0;
      try {
        final tracks = await entry.value
            .search(query, limit: _pageSize, offset: offset);
        _offsets[entry.key] = offset + tracks.length;
        if (tracks.length < _pageSize) {
          _exhausted.add(entry.key);
        }
        return tracks;
      } catch (_) {
        // Один упавший источник (недоступен, протух ключ и т.п.) не должен
        // останавливать подгрузку остальных — просто считаем его исчерпанным.
        _exhausted.add(entry.key);
        return <Track>[];
      }
    }));

    final merged = <Track>[];
    for (final track in results.expand((e) => e)) {
      if (_seenIds.add(track.id)) {
        merged.add(track);
      }
    }
    return merged;
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final allExhausted = _exhausted.length >= widget.sources.length;
    // select, а не watch — см. пояснение в library_screen.dart: иначе
    // список результатов поиска перестраивался бы целиком на каждый тик
    // позиции воспроизведения.
    final hasMiniPlayer =
        context.select<PlayerProvider, bool>((p) => p.currentTrack != null);
    final bottomInset =
        AppLayout.reservedBottomSpace(hasMiniPlayer: hasMiniPlayer);
    // История видна, пока поиск не запущен (поле пустое или идёт набор);
    // при наборе фильтруется по введённому тексту.
    List<String> hist = const [];
    if (_query.isEmpty && !_loadingFirstPage) {
      final typed = _controller.text.trim().toLowerCase();
      hist = typed.isEmpty
          ? _history
          : _history.where((e) => e.toLowerCase().contains(typed)).toList();
    }

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(14),
              ),
              child: TextField(
                controller: _controller,
                onChanged: _onChanged,
                onSubmitted: _submit,
                textInputAction: TextInputAction.search,
                style: TextStyle(color: AppColors.textPrimary),
                cursorColor: AppColors.accentEnd,
                // Отключено намеренно: это поиск, а не текст для проверки
                // орфографии — composing-регион от автокоррекции/spellcheck
                // не нужен, а после того как мини-плеер стал глобальным
                // виджетом (см. NowPlayingRouteObserver.didPush), его
                // цветное подчёркивание может "утечь" на другой текст
                // экрана при быстром переходе, пока ввод не подтверждён.
                autocorrect: false,
                enableSuggestions: false,
                spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
                decoration: InputDecoration(
                  hintText: l10n.searchHint,
                  hintStyle: TextStyle(color: AppColors.textSecondary),
                  prefixIcon: Icon(Icons.search_rounded,
                      color: AppColors.textSecondary),
                  // Показывается всегда (не только когда поле непустое) —
                  // см. комментарий у _clearSearch.
                  suffixIcon: IconButton(
                    icon: Icon(Icons.close_rounded,
                        size: 20, color: AppColors.textSecondary),
                    splashRadius: 18,
                    onPressed: _clearSearch,
                  ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),
          if (_loadingFirstPage)
            Padding(
              padding: EdgeInsets.only(top: 24),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: AppColors.accentEnd,
                ),
              ),
            ),
          Expanded(
            child: hist.isNotEmpty
                ? _HistoryList(
                    items: hist,
                    bottomInset: bottomInset,
                    onTap: (q) {
                      FocusScope.of(context).unfocus();
                      _controller.value = TextEditingValue(
                        text: q,
                        selection: TextSelection.collapsed(offset: q.length),
                      );
                      _submit(q);
                    },
                    onRemove: _removeFromHistory,
                    onClear: _clearHistory,
                  )
                : _results.isEmpty && !_loadingFirstPage
                ? Center(
                    child: Text(
                      _query.isEmpty
                          ? l10n.searchPrompt
                          : l10n.nothingFound,
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.fromLTRB(20, 0, 20, bottomInset),
                    physics: const BouncingScrollPhysics(),
                    // +1 под нижний индикатор подгрузки/конца списка — сам
                    // список при этом остаётся обычным ленивым
                    // ListView.builder без дополнительной виртуализации.
                    itemCount: _results.length + 1,
                    itemBuilder: (context, i) {
                      if (i == _results.length) {
                        return _BottomStatus(
                          loading: _loadingMore,
                          exhausted: allExhausted && _results.isNotEmpty,
                        );
                      }
                      final track = _results[i];
                      return TrackTile(
                        key: ValueKey(track.id),
                        track: track,
                        onAddToPlaylist: () =>
                            showAddToPlaylistSheet(context, track),
                        onTap: () => context
                            .read<PlayerProvider>()
                            .playTrack(track, queue: _results),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _BottomStatus extends StatelessWidget {
  const _BottomStatus({required this.loading, required this.exhausted});
  final bool loading;
  final bool exhausted;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (loading) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              color: AppColors.accentEnd,
            ),
          ),
        ),
      );
    }
    if (exhausted) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            l10n.searchEnd,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({
    required this.items,
    required this.bottomInset,
    required this.onTap,
    required this.onRemove,
    required this.onClear,
  });
  final List<String> items;
  final double bottomInset;
  final ValueChanged<String> onTap;
  final ValueChanged<String> onRemove;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Индекс 0 — заголовок, дальше элементы истории (фиксированная
    // высота строки — без измерения, дёшево на слабых устройствах).
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(20, 0, 8, bottomInset),
      itemCount: items.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return SizedBox(
            height: 44,
            child: Row(
              children: [
                Text(l10n.recent,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppColors.textPrimary)),
                const Spacer(),
                TextButton(
                  onPressed: onClear,
                  child: Text(l10n.clear,
                      style: TextStyle(color: AppColors.textSecondary)),
                ),
              ],
            ),
          );
        }
        final q = items[i - 1];
        return SizedBox(
          height: 48,
          child: InkWell(
            onTap: () => onTap(q),
            child: Row(
              children: [
                Icon(Icons.history_rounded,
                    size: 20, color: AppColors.textSecondary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(q,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 15, color: AppColors.textPrimary)),
                ),
                IconButton(
                  splashRadius: 18,
                  icon: Icon(Icons.close_rounded,
                      size: 18, color: AppColors.textSecondary),
                  onPressed: () => onRemove(q),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
