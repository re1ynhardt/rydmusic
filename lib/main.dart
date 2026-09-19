import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:provider/provider.dart';

import 'main_shell.dart';
import 'models/track.dart';
import 'navigation.dart';
import 'providers/audio_quality_provider.dart';
import 'providers/auth_provider.dart';
import 'providers/cached_tracks_provider.dart';
import 'providers/favorites_provider.dart';
import 'providers/home_provider.dart';
import 'providers/language_provider.dart';
import 'providers/now_playing_visibility.dart';
import 'providers/player_provider.dart';
import 'providers/playlists_provider.dart';
import 'providers/theme_provider.dart';
import 'providers/vk_auth_provider.dart';
import 'screens/auth_screen.dart';
import 'services/audiomack_service.dart';
import 'services/deezer_service.dart';
import 'services/music_source.dart';
import 'services/soundcloud_service.dart';
import 'services/vk_service.dart';
import 'services/youtube_po_token_resolver.dart';
import 'services/youtube_service.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';
import 'widgets/mini_player.dart';

/// Единственный список разработчиков приложения. Добавляйте сюда e-mail
/// зарегистрированных аккаунтов в нижнем регистре.
const developerEmails = <String>{'ussr9covok@gmail.com'};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // google_fonts по умолчанию может ХОДИТЬ В СЕТЬ за шрифтом Inter при
  // первой отрисовке текста и держать кадр, пока не скачает/не закэширует
  // файл — заметный source лагов и рывков на первом запуске или при
  // плохой сети. Отключаем рантайм-загрузку: пакет сразу использует
  // системный шрифт без сетевых обращений и без задержки кадра. Чтобы
  // Inter реально применялся, добавьте .ttf в assets проекта и объявите
  // его в pubspec.yaml (fonts:) — тогда google_fonts подхватит его из
  // бандла, тоже без сети.
  GoogleFonts.config.allowRuntimeFetching = false;

  // Требует в AndroidManifest.xml: сервис AudioService, ресивер
  // MediaButtonReceiver и разрешения WAKE_LOCK / FOREGROUND_SERVICE /
  // FOREGROUND_SERVICE_MEDIA_PLAYBACK / POST_NOTIFICATIONS — всё это уже
  // добавлено в манифест. Без них init() зависает на сплеш-экране.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.soundwave.app.audio',
    androidNotificationChannelName: 'Soundwave Playback',
    androidNotificationOngoing: true,
    androidStopForegroundOnPause: true,
  );

  // Тема грузится синхронно из SharedPreferences до runApp, чтобы первый
  // же кадр отрисовался уже с сохранённой палитрой, без мигания.
  final themeProvider = await ThemeProvider.load();

  // Качество звука грузится тем же способом и по той же причине.
  final audioQualityProvider = await AudioQualityProvider.load();

  // Язык интерфейса — тем же способом и по той же причине: первый кадр
  // сразу на нужном языке. Заодно выставляет AppStrings.current для кода
  // без BuildContext (провайдеры, сервисы).
  final languageProvider = await LanguageProvider.load();

  // Создаются один раз здесь (а не внутри builder MaterialApp), чтобы
  // при пересборках (например, смена темы) не плодить новые экземпляры
  // NavigatorObserver — Navigator ожидает стабильный список observers
  // на всё время жизни приложения.
  final nowPlayingVisibility = NowPlayingVisibility();
  final nowPlayingObserver = NowPlayingRouteObserver(nowPlayingVisibility);

  final sources = <MusicSourceType, MusicSource>{
    // Client_id больше не передаётся вручную — SoundCloudService сам
    // добывает его парсингом веб-плеера при первом запросе и обновляет
    // при протухании (см. soundcloud_client_id_resolver.dart).
    MusicSourceType.soundcloud: SoundCloudService(),
    MusicSourceType.audiomack: AudiomackService(
      // TODO: подставить реальные ключи Audiomack (см. README.md).
      apiKey: const String.fromEnvironment(
        'AUDIOMACK_API_KEY',
        defaultValue: '',
      ),
      apiSecret: const String.fromEnvironment(
        'AUDIOMACK_API_SECRET',
        defaultValue: '',
      ),
    ),
    // Публичный API Deezer, без ключа/токена — см. подробности в DeezerService.
    MusicSourceType.deezer: DeezerService(),
    // Поиск через ytmusicapi, воспроизведение через yt-dlp + po_token
    // из скрытого WebView — см. подробности в YouTubeService.
    MusicSourceType.youtube: YouTubeService(),
    // Поиск/резолв через yt-dlp (VK не отдаёт публичный API для музыки),
    // прямое воспроизведение или скачивание+дешифровка HLS — см.
    // VkService/VKHLSService.
    MusicSourceType.vk: VkService(),
  };

  runApp(
    SoundwaveApp(
      sources: sources,
      themeProvider: themeProvider,
      audioQualityProvider: audioQualityProvider,
      languageProvider: languageProvider,
      nowPlayingVisibility: nowPlayingVisibility,
      nowPlayingObserver: nowPlayingObserver,
      developerEmails: developerEmails,
    ),
  );

  // Прогрев YouTube-сессии в фоне, сразу после первого кадра (раньше
  // нельзя — headless WebView требует уже поднятые плагины).
  //
  // Резолв YouTube-трека состоит из двух шагов: добыть
  // po_token/visitor_data скрытым WebView и скормить их yt-dlp. Первый
  // шаг — это загрузка настоящей страницы youtube.com, самая долгая
  // часть всей цепочки. Токены общие для всех видео и живут часами
  // (см. YoutubeSessionResolver), поэтому их выгодно добыть заранее,
  // пока пользователь ищет трек, а не в момент нажатия на него.
  // Если сессия с прошлого запуска ещё жива — здесь вообще ничего не
  // произойдёт.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    YoutubeSessionResolver.instance.prewarm();
  });
}

class SoundwaveApp extends StatelessWidget {
  const SoundwaveApp({
    super.key,
    required this.sources,
    required this.themeProvider,
    required this.audioQualityProvider,
    required this.languageProvider,
    required this.nowPlayingVisibility,
    required this.nowPlayingObserver,
    required this.developerEmails,
  });
  final Map<MusicSourceType, MusicSource> sources;
  final ThemeProvider themeProvider;
  final AudioQualityProvider audioQualityProvider;
  final LanguageProvider languageProvider;
  final NowPlayingVisibility nowPlayingVisibility;
  final NowPlayingRouteObserver nowPlayingObserver;
  final Set<String> developerEmails;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // Регистрируется ДО PlayerProvider: последнему нужен готовый
        // экземпляр CachedTracksProvider уже в момент создания (см. ниже),
        // а MultiProvider разворачивает провайдеры по порядку — каждый
        // следующий получает context, в котором предыдущие уже доступны.
        ChangeNotifierProvider(
          create: (_) => CachedTracksProvider(sources: sources),
        ),
        ChangeNotifierProvider(
          create: (context) => PlayerProvider(
            sources: sources,
            cachedTracksProvider: context.read<CachedTracksProvider>(),
          ),
        ),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => VkAuthProvider()),
        // ProxyProvider, а не обычный Provider: FavoritesProvider и
        // PlaylistsProvider должны знать, ЗА КОГО сейчас грузить/сохранять
        // библиотеку (email из AuthProvider), и перегружать её заново при
        // входе/выходе/смене пользователя — раньше библиотека была общей
        // на устройство и жила в SharedPreferences, теперь она в Yandex
        // Object Storage и привязана к аккаунту.
        ChangeNotifierProxyProvider<AuthProvider, FavoritesProvider>(
          create: (_) => FavoritesProvider(),
          update: (_, auth, favorites) {
            favorites!.setUser(auth.user?.email);
            return favorites;
          },
        ),
        ChangeNotifierProxyProvider<AuthProvider, PlaylistsProvider>(
          create: (_) => PlaylistsProvider(),
          update: (_, auth, playlists) {
            playlists!.setUser(auth.user?.email);
            return playlists;
          },
        ),
        // Регистрируется ПОСЛЕ FavoritesProvider: рекомендации главного
        // экрана строятся на основе избранного, и каждое изменение
        // библиотеки (лайк/дизлайк, смена пользователя) должно
        // планировать пересчёт подборки — см. scheduleRecommendationsRefresh.
        // Сам пересчёт дебаунсится и пропускается, если топ-артисты не
        // изменились (см. HomeProvider), так что лишних сетевых походов
        // это не создаёт даже при частых лайках.
        ChangeNotifierProxyProvider<FavoritesProvider, HomeProvider>(
          create: (_) => HomeProvider(sources: sources),
          update: (_, favorites, home) {
            home!.scheduleRecommendationsRefresh(favorites.favorites);
            return home;
          },
        ),
        ChangeNotifierProvider.value(value: themeProvider),
        ChangeNotifierProvider.value(value: audioQualityProvider),
        ChangeNotifierProvider.value(value: languageProvider),
        // От этого флага зависит видимость глобального мини-плеера
        // (см. builder ниже и _GlobalMiniPlayerOverlay) — обновляет его
        // nowPlayingObserver, подключённый через navigatorObservers.
        ChangeNotifierProvider.value(value: nowPlayingVisibility),
      ],
      // Selector, а не watch на весь провайдер: перестраивается только
      // сам MaterialApp (и через него — всё дерево ниже), когда реально
      // меняется режим темы, без лишних промежуточных перестроений.
      child: Selector<ThemeProvider, AppThemeMode>(
        selector: (_, provider) => provider.mode,
        builder: (context, mode, _) {
          return MaterialApp(
            title: 'Soundwave',
            debugShowCheckedModeBanner: false,
            theme: AppTheme.forMode(mode),
            navigatorKey: rootNavigatorKey,
            navigatorObservers: [nowPlayingObserver],
            // Мини-плеер рисуется здесь — ОДИН РАЗ поверх всего Navigator'а
            // (а не внутри отдельных экранов), поэтому остаётся на экране
            // при любом Navigator.push (плейлист, настройки и т.д.), а не
            // только на трёх вкладках MainShell. Прячется только когда
            // открыт сам NowPlayingScreen — см. _GlobalMiniPlayerOverlay.
            builder: (context, child) => Stack(
              children: [
                if (child != null) Positioned.fill(child: child),
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom:
                      AppLayout.navBarHeight +
                      AppLayout.navBarBottomMargin +
                      AppLayout.barSpacing,
                  child: _GlobalMiniPlayerOverlay(),
                ),
              ],
            ),
            home: AuthGate(sources: sources, developerEmails: developerEmails),
          );
        },
      ),
    );
  }
}

/// Обёртка над [MiniPlayer], которая решает, показывать ли его вообще:
/// прячется на время, пока открыт полноэкранный NowPlayingScreen (иначе
/// поверх него висел бы ещё один мини-плеер того же трека), и не ловит
/// тапы, пока спрятан. Сам [MiniPlayer] уже умеет схлопываться в ничто,
/// когда играть вообще нечего — эта обёртка добавляет только второе
/// условие видимости.
class _GlobalMiniPlayerOverlay extends StatefulWidget {
  const _GlobalMiniPlayerOverlay();

  @override
  State<_GlobalMiniPlayerOverlay> createState() =>
      _GlobalMiniPlayerOverlayState();
}

class _GlobalMiniPlayerOverlayState extends State<_GlobalMiniPlayerOverlay>
    with SingleTickerProviderStateMixin {
  // Раньше здесь был AnimatedOpacity. Он гасит мини-плеер, но оставляет
  // его в дереве: пока открыт NowPlayingScreen (а там два собственных
  // BackdropFilter с sigma=70), прозрачный мини-плеер продолжает
  // существовать со своим блюром и подписками. Теперь по окончании
  // затухания поддерево выбрасывается целиком — на самом тяжёлом экране
  // приложения не остаётся ни одного лишнего размытия.
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: 1,
  );

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nowPlayingOpen = context.select<NowPlayingVisibility, bool>(
      (v) => v.isOpen,
    );
    if (nowPlayingOpen) {
      if (_fade.status != AnimationStatus.dismissed &&
          _fade.status != AnimationStatus.reverse) {
        _fade.reverse();
      }
    } else if (_fade.status != AnimationStatus.completed &&
        _fade.status != AnimationStatus.forward) {
      _fade.forward();
    }

    return AnimatedBuilder(
      animation: _fade,
      // child строится один раз и передаётся внутрь — сам мини-плеер не
      // пересобирается на каждый кадр затухания.
      child: const RepaintBoundary(child: MiniPlayer()),
      builder: (context, child) {
        final t = Curves.easeOut.transform(_fade.value);
        if (t == 0) return const SizedBox.shrink();
        return IgnorePointer(
          ignoring: nowPlayingOpen,
          child: Opacity(opacity: t, child: child),
        );
      },
    );
  }
}

/// Показывает экран входа, пока пользователь не авторизован, иначе —
/// основное приложение.
class AuthGate extends StatefulWidget {
  const AuthGate({
    super.key,
    required this.sources,
    required this.developerEmails,
  });
  final Map<MusicSourceType, MusicSource> sources;
  final Set<String> developerEmails;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

/// Проверяет канал обновлений ровно один раз на каждый запуск приложения,
/// уже после восстановления локальной сессии. Это не зависит от того,
/// открывал ли пользователь вкладку настроек или вошёл ли в аккаунт.
class _AuthGateState extends State<AuthGate> {
  final _updateService = UpdateService();
  bool _updateCheckStarted = false;

  void _startUpdateCheck() {
    if (_updateCheckStarted) return;
    _updateCheckStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
  }

  Future<void> _checkForUpdate() async {
    try {
      final update = await _updateService.latest();
      if (!mounted || update == null || !_updateService.isNewer(update)) {
        return;
      }
      // Скачивание и запуск системного установщика происходят сразу.
      // Android всё равно требует обязательного подтверждения от владельца
      // устройства — обойти это приложением нельзя.
      await _updateService.downloadAndInstall(update);
    } catch (_) {
      // Нет сети/канала обновлений — старт приложения не должен страдать.
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();

    if (auth.initializing) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    _startUpdateCheck();
    if (!auth.isLoggedIn) {
      return const AuthScreen();
    }
    return MainShell(
      sources: widget.sources,
      developerEmails: widget.developerEmails,
    );
  }
}
