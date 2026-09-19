import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'models/track.dart';
import 'providers/language_provider.dart';
import 'providers/player_provider.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'services/music_source.dart';
import 'widgets/premium_nav_bar.dart';

class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.sources,
    required this.developerEmails,
  });
  final Map<MusicSourceType, MusicSource> sources;
  final Set<String> developerEmails;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  // IndexedStack держит все страницы живыми в памяти между переключениями
  // вкладок — так экран библиотеки не пересобирается заново при каждом
  // возврате на него, что заметно на слабых устройствах. Список — геттер,
  // а не закэшированное поле: за сохранение состояния вкладок отвечает
  // сверка Element'ов по типу (её делает сам Flutter), а не то, держим ли
  // мы старый объект Widget'а. Благодаря этому при смене темы виджеты
  // пересобираются с новой палитрой, а прокрутка и локальный стейт вкладок
  // не теряются.
  List<Widget> get _pages => [
    HomeScreen(sources: widget.sources),
    SearchScreen(sources: widget.sources),
    const LibraryScreen(),
    ProfileScreen(
      developerEmails: widget.developerEmails,
      onGoToLibrary: () => setState(() => _index = 2),
      onOpenSettings: _openSettings,
    ),
  ];

  // Настройки больше не вкладка нижней панели — их открывают кнопкой
  // в правом верхнем углу профиля, обычным push'ем поверх шелла.
  // Мини-плеер при этом остаётся видимым: он рисуется глобально поверх
  // корневого Navigator'а (см. main.dart).
  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          body: SettingsScreen(
            sources: widget.sources,
            developerEmails: widget.developerEmails,
            showBackButton: true,
          ),
        ),
      ),
    );
  }

  String? _lastShownError;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // Показываем снек-бар, если очередной playTrack() не смог проиграть
    // ни одного трека (например, всё внезапно упёрлось в 404 от SoundCloud).
    //
    // ВАЖНО для плавности: MainShell оборачивает IndexedStack сразу со
    // всеми четырьмя вкладками (Home/Search/Library/Settings) — watch() на весь
    // PlayerProvider здесь означало, что при каждом тике позиции
    // воспроизведения (несколько раз в секунду) Flutter заново вызывал
    // build() у ВСЕХ экранов разом, чтобы сверить дерево виджетов,
    // даже если каждый из них сам по себе бережно использует select.
    // select на конкретное поле убирает эту лишнюю работу полностью.
    final error = context.select<PlayerProvider, String?>((p) => p.lastError);
    if (error != null && error != _lastShownError) {
      _lastShownError = error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(error)));
      });
    }

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: IndexedStack(index: _index, children: _pages),
          ),
          // Нижняя навигация: сама панель — единственное, что осталось
          // здесь. Мини-плеер теперь рисуется глобально, ОДИН РАЗ поверх
          // всего Navigator'а (см. main.dart) — чтобы оставаться видимым
          // и на экранах, куда переходят через Navigator.push (плейлист,
          // настройки и т.д.), а не только на вкладках MainShell.
          // Позиционирован он ровно на той же высоте, где раньше сидел
          // прямо здесь (navBarHeight + navBarBottomMargin + barSpacing),
          // так что визуально ничего не сдвинулось.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: PremiumNavBar(
              selectedIndex: _index,
              onSelect: (i) => setState(() => _index = i),
              items: [
                NavItem(
                  icon: Icons.home_outlined,
                  selectedIcon: Icons.home_rounded,
                  label: l10n.navHome,
                ),
                NavItem(
                  icon: Icons.search_rounded,
                  selectedIcon: Icons.search_rounded,
                  label: l10n.navSearch,
                ),
                NavItem(
                  icon: Icons.library_music_outlined,
                  selectedIcon: Icons.library_music_rounded,
                  label: l10n.navLibrary,
                ),
                NavItem(
                  icon: Icons.person_outline_rounded,
                  selectedIcon: Icons.person_rounded,
                  label: l10n.navProfile,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
